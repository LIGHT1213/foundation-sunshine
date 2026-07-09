/**
 * @file src/platform/macos/microphone.mm
 * @brief Definitions for audio capture on macOS.
 */
#include "src/platform/common.h"
#include "src/platform/macos/av_audio.h"
#include "src/platform/macos/mic_write.h"
#include "src/platform/macos/sck_audio.h"

#include "src/config.h"
#include "src/logging.h"

#include <memory>

namespace platf {
  using namespace std::literals;

  struct av_mic_t: public mic_t {
    AVAudio *av_audio_capture {};

    ~av_mic_t() override {
      [av_audio_capture release];
    }

    capture_e
    sample(std::vector<float> &sample_in) override {
      const uint32_t neededBytes = static_cast<uint32_t>(sample_in.size() * sizeof(float));
      uint8_t *dst = reinterpret_cast<uint8_t *>(sample_in.data());

      uint32_t remaining = neededBytes;

      while (remaining > 0) {
        uint32_t avail = 0;
        void *tail = TPCircularBufferTail(&av_audio_capture->audioSampleBuffer, &avail);

        if (avail == 0) {
          // 5 second timeout prevents indefinite hanging on a stalled session.
          dispatch_time_t timeout = dispatch_time(DISPATCH_TIME_NOW, 5LL * NSEC_PER_SEC);
          if (dispatch_semaphore_wait(av_audio_capture->audioSemaphore, timeout) != 0) {
            BOOST_LOG(warning) << "Audio sample timeout - no audio data within 5 seconds"sv;
            std::fill(sample_in.begin(), sample_in.end(), 0.0f);
            return capture_e::timeout;
          }
          continue;
        }

        const uint32_t toCopy = (avail < remaining) ? avail : remaining;
        std::memcpy(dst, tail, toCopy);
        TPCircularBufferConsume(&av_audio_capture->audioSampleBuffer, toCopy);

        dst += toCopy;
        remaining -= toCopy;
      }

      return capture_e::ok;
    }
  };

  struct macos_audio_control_t: public audio_control_t {
    AVCaptureDevice *audio_capture_device {};

  public:
    int
    set_sink(const std::string &sink) override {
      BOOST_LOG(warning) << "audio_control_t::set_sink() unimplemented: "sv << sink;
      return 0;
    }

    std::unique_ptr<mic_t>
    microphone(const std::uint8_t *mapping, int channels, std::uint32_t sample_rate, std::uint32_t frame_size, bool continuous_audio) override {
      // The platf::audio_control_t::microphone() contract on Sunshine is
      // "capture the audio to stream TO the client" (i.e. system playback,
      // the equivalent of WASAPI loopback on Windows / PulseAudio monitor on
      // Linux). On macOS that is system audio.
      //
      // Capture path priority:
      // 1. Core Audio Process Tap (macOS 14.0+) — the official LizardByte
      //    approach, delivers interleaved float32 directly, no SCK quirks.
      // 2. ScreenCaptureKit audio (macOS 13.0+) — fallback if Tap unavailable.
      // 3. AVFoundation microphone — only when the user explicitly configures
      //    an input sink (config::audio.sink); streams mic input, not game audio.
      (void) mapping;
      (void) continuous_audio;

      // If user explicitly configured a sink, capture that specific input device.
      if (!config::audio.sink.empty()) {
        const char *audio_sink = config::audio.sink.c_str();
        BOOST_LOG(info) << "Using configured audio sink: "sv << audio_sink;

        // Try Core Audio device capture first (supports virtual devices like BlackHole)
        AudioObjectID devID = [AVAudio findInputDeviceByName:[NSString stringWithUTF8String:audio_sink]];
        if (devID != kAudioObjectUnknown) {
          auto mic = std::make_unique<av_mic_t>();
          mic->av_audio_capture = [[AVAudio alloc] init];
          mic->av_audio_capture.hostAudioEnabled = YES;
          if ([mic->av_audio_capture setupDeviceCapture:devID sampleRate:sample_rate frameSize:frame_size channels:channels] == 0) {
            return mic;
          }
          BOOST_LOG(warning) << "Core Audio device capture failed for sink, trying AVFoundation."sv;
        }

        // Fallback: AVFoundation microphone path
        auto mic = std::make_unique<av_mic_t>();
        mic->av_audio_capture = [[AVAudio alloc] init];
        mic->av_audio_capture.hostAudioEnabled = YES;

        if ((audio_capture_device = [AVAudio findMicrophone:[NSString stringWithUTF8String:audio_sink]]) == nullptr) {
          BOOST_LOG(error) << "opening microphone '"sv << audio_sink << "' failed."sv;
          BOOST_LOG(error) << "Available inputs:"sv;
          for (NSString *name in [AVAudio microphoneNames]) {
            BOOST_LOG(error) << "\t"sv << [name UTF8String];
          }
          return nullptr;
        }

        if ([mic->av_audio_capture setupMicrophone:audio_capture_device sampleRate:sample_rate frameSize:frame_size channels:channels]) {
          BOOST_LOG(error) << "Failed to setup microphone."sv;
          return nullptr;
        }

        return mic;
      }

      // No explicit sink configured. Auto-detect BlackHole for system audio capture.
      // BlackHole routes system audio to a virtual input device, letting us capture
      // without the host playing sound through speakers (host stays silent).
      NSArray<NSString *> *blackholeNames = @[@"BlackHole 2ch", @"BlackHole 16ch", @"BlackHole 64ch", @"BlackHole 128ch", @"BlackHole"];
      for (NSString *bwName in blackholeNames) {
        AudioObjectID devID = [AVAudio findInputDeviceByName:bwName];
        if (devID != kAudioObjectUnknown) {
          BOOST_LOG(info) << "Found virtual audio device: "sv << [bwName UTF8String] << " — using for system audio capture"sv;
          BOOST_LOG(info) << "IMPORTANT: set your system output to this BlackHole device to stream audio (host will be silent)."sv;
          auto mic = std::make_unique<av_mic_t>();
          mic->av_audio_capture = [[AVAudio alloc] init];
          mic->av_audio_capture.hostAudioEnabled = YES;
          if ([mic->av_audio_capture setupDeviceCapture:devID sampleRate:sample_rate frameSize:frame_size channels:channels] == 0) {
            return mic;
          }
          BOOST_LOG(warning) << "Failed to capture from "sv << [bwName UTF8String] << ", trying next option."sv;
        }
      }

      // No BlackHole found. Try Core Audio Process Tap (macOS 14.0+) as last resort.
      // Note: Tap may deliver silence under certain TCC configurations.
      if (@available(macOS 14.0, *)) {
        auto mic = std::make_unique<av_mic_t>();
        mic->av_audio_capture = [[AVAudio alloc] init];
        mic->av_audio_capture.hostAudioEnabled = YES;

        BOOST_LOG(info) << "No BlackHole found. Trying Core Audio system tap (install BlackHole for reliable capture)."sv;
        if ([mic->av_audio_capture setupSystemTap:sample_rate frameSize:frame_size channels:channels] == 0) {
          return mic;
        }
      }

      // Final fallback: ScreenCaptureKit audio
      auto sck = make_sck_system_audio(channels, sample_rate, frame_size);
      if (sck) {
        return sck;
      }

      BOOST_LOG(error) << "All audio capture methods failed. Install BlackHole and set it as system output."sv;
      return nullptr;
    }

    std::optional<sink_t>
    sink_info() override {
      sink_t sink;
      return sink;
    }

    bool
    is_sink_available(const std::string &sink) override {
      BOOST_LOG(warning) << "audio_control_t::is_sink_available() unimplemented: "sv << sink;
      return true;
    }

    int
    write_mic_data(const char *data, size_t size, uint16_t seq = 0) override {
      // Render client microphone audio to the host's default output device.
      if (!mic_redirect) {
        return -1;
      }
      return mic_redirect->write_data(data, size, seq);
    }

    int
    init_mic_redirect_device() override {
      if (mic_redirect) {
        return 0;
      }
      mic_redirect = std::make_unique<platf::audio::mic_write_coreaudio_t>();
      if (mic_redirect->init() != 0) {
        mic_redirect.reset();
        return -1;
      }
      return 0;
    }

    void
    release_mic_redirect_device() override {
      mic_redirect.reset();
    }

  private:
    std::unique_ptr<platf::audio::mic_write_coreaudio_t> mic_redirect;
  };

  std::unique_ptr<audio_control_t>
  audio_control() {
    return std::make_unique<macos_audio_control_t>();
  }
}  // namespace platf

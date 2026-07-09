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

      // Log the IOProc diagnostic snapshot (written by the RT IO thread) here,
      // off the real-time audio thread. Only for the first few frames.
      if (av_audio_capture->ioProcData && av_audio_capture->ioProcData->diagnosticCounter <= 10) {
        UInt32 c = av_audio_capture->ioProcData->diagnosticCounter;
        if (c > 0 && c <= 10) {
          BOOST_LOG(info) << "IOProc snapshot #"sv << c
                          << ": inBytes="sv << av_audio_capture->ioProcData->rtInputBytes
                          << " outBytes="sv << av_audio_capture->ioProcData->rtOutputBytes
                          << " wrote="sv << (av_audio_capture->ioProcData->rtWroteData ? "yes"sv : "no"sv)
                          << " (scope="sv << (av_audio_capture->ioProcData->captureFromOutputScope ? "output-first"sv : "input-first"sv) << ")"sv;
        }
      }

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
      // Capture path priority (macOS 14.0+):
      // 1. Core Audio Process Tap — the official, native approach. No third-party
      //    driver needed. Requires NSAudioCaptureUsageDescription in Info.plist
      //    and "System Audio Recording" TCC consent. This is what LizardByte
      //    Sunshine uses in production (PR #4209). The hostAudioEnabled flag
      //    controls CATapMuted/CATapUnmuted so the host can stay silent.
      // 2. BlackHole virtual loopback — fallback if Tap unavailable or denied.
      //    NOTE: BlackHole is BROKEN on macOS 26 (Tahoe) due to CoreAudio stack
      //    changes — the driver's ring-buffer mirroring no longer works.
      // 3. ScreenCaptureKit audio — last resort.
      // 4. AVFoundation microphone — only for explicit mic input (config::audio.sink).
      (void) mapping;
      (void) continuous_audio;

      // Determine whether host audio should play during streaming.
      // The user explicitly wants the host machine to stay silent during
      // streaming ("我不希望串流的时候sunshine运行的机器有声音"). We default to
      // CATapMuted (host silent). Set SUNSHINE_HOST_AUDIO=1 to unmute the host.
      // On macOS the Core Audio Process Tap supports muteBehavior which mutes
      // the host while still delivering audio to the capture — exactly what we
      // need. (This differs from BlackHole which always plays through speakers.)
      const char *hostAudioEnv = std::getenv("SUNSHINE_HOST_AUDIO");
      BOOL hostAudio = (hostAudioEnv != nullptr && hostAudioEnv[0] == '1');

      BOOST_LOG(info) << "Audio: selecting capture method (sink='"sv << (config::audio.sink.empty() ? "(none)"sv : config::audio.sink)
                      << "', hostAudio="sv << (hostAudio ? "yes"sv : "no"sv) << ")"sv;

      // Determine macOS major version for capture-path selection.
      // macOS 26 (Tahoe) broke both BlackHole (CoreAudio stack change) and
      // Process Tap (AudioDeviceCreateIOProcID hangs indefinitely on aggregate
      // devices). On macOS 26+, ScreenCaptureKit is the only working path.
      NSOperatingSystemVersion osVer = [[NSProcessInfo processInfo] operatingSystemVersion];
      bool isTahoeOrLater = osVer.majorVersion >= 26;

      // Path 1: On macOS 14-25, try Core Audio Process Tap first (native, no driver).
      // On macOS 26+, skip it — AudioDeviceCreateIOProcID hangs (confirmed OS bug).
      bool tapAvailable = false;
      if (@available(macOS 14.0, *)) {
        tapAvailable = true;
      }
      if (!isTahoeOrLater && tapAvailable) {
        BOOST_LOG(info) << "Trying Core Audio Process Tap (native system audio capture)..."sv;
        auto mic = std::make_unique<av_mic_t>();
        mic->av_audio_capture = [[AVAudio alloc] init];
        mic->av_audio_capture.hostAudioEnabled = hostAudio;
        if ([mic->av_audio_capture setupSystemTap:sample_rate frameSize:frame_size channels:channels] == 0) {
          BOOST_LOG(info) << "Core Audio Process Tap started successfully"sv;
          return mic;
        }
        BOOST_LOG(warning) << "Core Audio Process Tap failed"sv;
      }
      else if (isTahoeOrLater) {
        BOOST_LOG(info) << "macOS 26+ detected — skipping Process Tap (AudioDeviceCreateIOProcID hangs) and BlackHole (loopback broken). Using ScreenCaptureKit audio."sv;
      }

      // Path 2: On macOS 26+, ScreenCaptureKit audio is the primary path.
      // SCK captures system audio via a different API stack that doesn't depend
      // on the broken HAL Process Tap or BlackHole driver. Requires Screen
      // Recording TCC permission (same as video capture).
      bool sckAvailable = false;
      if (@available(macOS 13.0, *)) {
        sckAvailable = true;
      }
      if (isTahoeOrLater || sckAvailable) {
        BOOST_LOG(info) << "Trying ScreenCaptureKit audio capture..."sv;
        auto sck = make_sck_system_audio(channels, sample_rate, frame_size);
        if (sck) {
          BOOST_LOG(info) << "ScreenCaptureKit audio capture started successfully"sv;
          return sck;
        }
        BOOST_LOG(warning) << "ScreenCaptureKit audio capture failed (may need Screen Recording permission)"sv;
      }

      // Path 2: If user configured an explicit sink, try that device (BlackHole, mic, etc.)
      if (!config::audio.sink.empty()) {
        const char *audio_sink = config::audio.sink.c_str();
        BOOST_LOG(info) << "Trying configured audio sink: "sv << audio_sink;

        AudioObjectID devID = [AVAudio findInputDeviceByName:[NSString stringWithUTF8String:audio_sink]];
        if (devID != kAudioObjectUnknown) {
          auto mic = std::make_unique<av_mic_t>();
          mic->av_audio_capture = [[AVAudio alloc] init];
          mic->av_audio_capture.hostAudioEnabled = hostAudio;
          if ([mic->av_audio_capture setupDeviceCapture:devID sampleRate:sample_rate frameSize:frame_size channels:channels] == 0) {
            return mic;
          }
          BOOST_LOG(warning) << "Core Audio device capture failed for sink, trying AVFoundation."sv;
        }

        // Fallback: AVFoundation microphone path
        auto mic = std::make_unique<av_mic_t>();
        mic->av_audio_capture = [[AVAudio alloc] init];
        mic->av_audio_capture.hostAudioEnabled = hostAudio;

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

      // Path 3 (macOS < 14 only): Auto-detect BlackHole as a fallback.
      // On macOS 14+ the Process Tap and SCK paths above are preferred.
      // On macOS 26+ BlackHole is broken (CoreAudio stack change).
      if (!isTahoeOrLater) {
        BOOST_LOG(info) << "Scanning for BlackHole virtual device (fallback)..."sv;
        NSArray<NSString *> *blackholeNames = @[@"BlackHole 2ch", @"BlackHole 16ch", @"BlackHole 64ch", @"BlackHole 128ch", @"BlackHole"];
        for (NSString *bwName in blackholeNames) {
          AudioObjectID devID = [AVAudio findInputDeviceByName:bwName];
          if (devID != kAudioObjectUnknown) {
            BOOST_LOG(info) << "Found virtual audio device: "sv << [bwName UTF8String] << " — using for system audio capture"sv;
            auto mic = std::make_unique<av_mic_t>();
            mic->av_audio_capture = [[AVAudio alloc] init];
            mic->av_audio_capture.hostAudioEnabled = hostAudio;
            if ([mic->av_audio_capture setupDeviceCapture:devID sampleRate:sample_rate frameSize:frame_size channels:channels] == 0) {
              return mic;
            }
            BOOST_LOG(warning) << "Failed to capture from "sv << [bwName UTF8String] << ", trying next option."sv;
          }
        }
      }

      BOOST_LOG(error) << "All audio capture methods failed."sv;
      if (isTahoeOrLater) {
        BOOST_LOG(error) << "On macOS 26+, grant 'Screen Recording' permission in System Settings → Privacy & Security (ScreenCaptureKit audio needs it)."sv;
      }
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

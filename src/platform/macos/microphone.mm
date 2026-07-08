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
      auto sample_size = sample_in.size();

      uint32_t length = 0;
      void *byteSampleBuffer = TPCircularBufferTail(&av_audio_capture->audioSampleBuffer, &length);

      while (length < sample_size * sizeof(float)) {
        // Bounded wait (500ms) so a stalled capture session (device unplugged,
        // app backgrounded) cannot wedge the audio pull thread forever. The
        // previous DISPATCH-equivalent [signal wait] with no timeout deadlocked.
        if (![av_audio_capture.samplesArrivedSignal waitUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.5]]) {
          BOOST_LOG(warning) << "Microphone: timed out waiting for audio data."sv;
          return capture_e::timeout;
        }
        byteSampleBuffer = TPCircularBufferTail(&av_audio_capture->audioSampleBuffer, &length);
      }

      // TPCircularBufferTail can return NULL when fillCount==0; never feed NULL
      // to std::vector (UB/segfault). Emit silence instead.
      if (!byteSampleBuffer) {
        std::fill_n(std::begin(sample_in), sample_size, 0.0f);
        return capture_e::ok;
      }

      const float *sampleBuffer = (float *) byteSampleBuffer;
      std::vector<float> vectorBuffer(sampleBuffer, sampleBuffer + sample_size);

      std::copy_n(std::begin(vectorBuffer), sample_size, std::begin(sample_in));

      TPCircularBufferConsume(&av_audio_capture->audioSampleBuffer, sample_size * sizeof(float));

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
      // Linux). On macOS that is system audio, captured via ScreenCaptureKit
      // (macOS 13.0+). The legacy AVFoundation path below only captures the
      // microphone input device, which is the wrong thing for streaming game
      // audio — it is kept only as a last-resort fallback.
      (void) mapping;
      (void) continuous_audio;

      auto sck = make_sck_system_audio(channels, sample_rate, frame_size);
      if (sck) {
        return sck;
      }
      BOOST_LOG(warning) << "SCK system audio unavailable; falling back to AVAudio microphone capture (will stream mic, not game audio)."sv;

      auto mic = std::make_unique<av_mic_t>();
      const char *audio_sink = "";

      if (!config::audio.sink.empty()) {
        audio_sink = config::audio.sink.c_str();
      }

      if ((audio_capture_device = [AVAudio findMicrophone:[NSString stringWithUTF8String:audio_sink]]) == nullptr) {
        BOOST_LOG(error) << "opening microphone '"sv << audio_sink << "' failed. Please set a valid input source in the Sunshine config."sv;
        BOOST_LOG(error) << "Available inputs:"sv;

        for (NSString *name in [AVAudio microphoneNames]) {
          BOOST_LOG(error) << "\t"sv << [name UTF8String];
        }

        return nullptr;
      }

      mic->av_audio_capture = [[AVAudio alloc] init];

      if ([mic->av_audio_capture setupMicrophone:audio_capture_device sampleRate:sample_rate frameSize:frame_size channels:channels]) {
        BOOST_LOG(error) << "Failed to setup microphone."sv;
        return nullptr;
      }

      return mic;
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
      // NOTE: this is "voice intercom" only — macOS has no public API to
      // create a virtual input device that games would pick up as a local mic.
      // See src/platform/macos/mic_write.h for details.
      if (!mic_redirect) {
        return -1;
      }
      return mic_redirect->write_data(data, size, seq);
    }

    int
    init_mic_redirect_device() override {
      // Lazily create the Core Audio render session on first use.
      if (mic_redirect) {
        return 0;  // already initialized
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

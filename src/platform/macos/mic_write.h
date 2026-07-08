/**
 * @file src/platform/macos/mic_write.h
 * @brief Client-microphone-to-host rendering on macOS.
 *
 * Receives Opus-encoded mic packets from the client, decodes them to PCM, and
 * renders the PCM to the host's default audio output device via Core Audio
 * (AudioUnit). This provides a "voice intercom": the client's voice plays
 * through the host's speakers.
 *
 * It is NOT a full virtual microphone: macOS has no public API to create a
 * virtual input device that games would pick up as a mic (the Windows path
 * uses VB-Cable; macOS would need a Core Audio HAL plugin / DriverKit driver,
 * which requires signing and is out of scope here). Games expecting a local
 * microphone will not see the client's audio through this path.
 */
#pragma once

#include <cstddef>
#include <cstdint>
#include <memory>

namespace platf::audio {

  // RAII handle to a Core Audio render session. Created by init_mic_redirect();
  // write_mic_data() feeds Opus packets; the dtor tears everything down.
  class mic_write_coreaudio_t {
  public:
    mic_write_coreaudio_t();
    ~mic_write_coreaudio_t();

    mic_write_coreaudio_t(const mic_write_coreaudio_t &) = delete;
    mic_write_coreaudio_t &operator=(const mic_write_coreaudio_t &) = delete;

    // Initialize the Opus decoder (48kHz mono, matching the client stream) and
    // open the default output AudioUnit. Returns 0 on success.
    int
    init();

    // Decode an Opus packet and queue its PCM into the render ring buffer.
    // Returns 0 on success, non-zero on decode/render failure.
    int
    write_data(const char *data, size_t len, uint16_t seq);

  private:
    struct impl;
    std::unique_ptr<impl> p_;
  };

}  // namespace platf::audio

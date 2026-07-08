/**
 * @file src/platform/macos/sck_audio.h
 * @brief ScreenCaptureKit-based system audio capture for macOS 13.0+.
 *
 * Captures system playback audio (what the user hears) via a dedicated
 * SCStream configured with capturesAudio=YES and an SCStreamOutputTypeAudio
 * output. This is the macOS equivalent of WASAPI loopback (Windows) /
 * PulseAudio monitor sources (Linux), which the legacy AVFoundation path on
 * macOS could not provide at all.
 *
 * Frames arrive as CMSampleBufferRef wrapping an AudioBufferList of float
 * samples; they are queued into a TPCircularBuffer and drained as
 * std::vector<float> by the platf::mic_t::sample() contract that
 * src/audio.cpp drives.
 */
#pragma once

#include "src/platform/common.h"

namespace platf {
  /**
   * @brief Create a mic_t that captures macOS system playback audio via SCK.
   * @param channels Target channel count (filled into output samples).
   * @param sample_rate Target sample rate in Hz.
   * @param frame_size Number of float samples per channel to block on per call.
   * @return A mic_t, or nullptr if SCK is unavailable / permission denied.
   */
  std::unique_ptr<mic_t>
  make_sck_system_audio(int channels, std::uint32_t sample_rate, std::uint32_t frame_size);
}  // namespace platf

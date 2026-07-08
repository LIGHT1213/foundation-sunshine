/**
 * @file src/platform/macos/sck_capture.h
 * @brief ScreenCaptureKit-based display capture for macOS 12.3+.
 *
 * Replaces the legacy AVCaptureScreenInput path (src/platform/macos/av_video.m)
 * which is capped at 60fps, has no HDR support, and crashes when screen-capture
 * permission is missing (AVVideo displayNames inserts nil into an NSDictionary).
 *
 * ScreenCaptureKit (SCStream) provides:
 *   - high frame rate capture (display native refresh rate)
 *   - per-display capture (SCDisplay matching CGDirectDisplayID)
 *   - IOSurface-backed CVPixelBufferRef frames handed to VideoToolbox with
 *     zero copy via the existing nv12_zero_device
 *   - graceful permission handling (no crash when permission is absent)
 */
#pragma once

#include "src/platform/common.h"

#include <CoreGraphics/CoreGraphics.h>

namespace platf {
  /**
   * @brief Build a display_t backed by ScreenCaptureKit.
   * @param display_id The CGDirectDisplayID to capture (CGMainDisplayID() if 0/unmatched).
   * @param frame_rate Target frame rate (0 = capture at display native rate).
   * @return A display_t whose capture() yields CVPixelBufferRef-backed images,
   *         or nullptr if ScreenCaptureKit is unavailable or permission is denied.
   */
  std::shared_ptr<display_t>
  make_sck_display(CGDirectDisplayID display_id, int frame_rate);
}  // namespace platf

/**
 * @file src/platform/macos/av_img_t.h
 * @brief Declarations for AV image types on macOS.
 */
#pragma once

#include "src/platform/common.h"

#include <CoreMedia/CoreMedia.h>
#include <CoreVideo/CoreVideo.h>

namespace platf {
  struct av_sample_buf_t {
    CMSampleBufferRef buf;

    explicit av_sample_buf_t(CMSampleBufferRef buf):
        buf((CMSampleBufferRef) CFRetain(buf)) {}

    ~av_sample_buf_t() {
      if (buf != nullptr) {
        CFRelease(buf);
      }
    }
  };

  struct av_pixel_buf_t {
    CVPixelBufferRef buf;

    // Constructor
    explicit av_pixel_buf_t(CMSampleBufferRef sb):
        buf((CVPixelBufferRef) CFRetain(CMSampleBufferGetImageBuffer(sb))) {
      // Retain the pixel buffer so its lifetime is INDEPENDENT of the sample
      // buffer. CMSampleBufferGetImageBuffer follows the "Get" rule and returns
      // an un-retained reference; without this retain, downstream code
      // (nv12_zero_device::convert stores the CVPixelBufferRef in av_frame->
      // data[3]) can outlive the av_img and access a freed pixel buffer,
      // crashing inside CFRetain / VideoToolbox.
      CVPixelBufferLockBaseAddress(buf, kCVPixelBufferLock_ReadOnly);
    }

    [[nodiscard]] uint8_t *
    data() const {
      return static_cast<uint8_t *>(CVPixelBufferGetBaseAddress(buf));
    }

    // Destructor
    ~av_pixel_buf_t() {
      if (buf != nullptr) {
        CVPixelBufferUnlockBaseAddress(buf, kCVPixelBufferLock_ReadOnly);
        CVPixelBufferRelease(buf);
      }
    }
  };

  struct av_img_t: img_t {
    std::shared_ptr<av_sample_buf_t> sample_buffer;
    std::shared_ptr<av_pixel_buf_t> pixel_buffer;
  };

  struct temp_retain_av_img_t {
    std::shared_ptr<av_sample_buf_t> sample_buffer;
    std::shared_ptr<av_pixel_buf_t> pixel_buffer;
    uint8_t *data;

    temp_retain_av_img_t(
      std::shared_ptr<av_sample_buf_t> sb,
      std::shared_ptr<av_pixel_buf_t> pb,
      uint8_t *dt):
        sample_buffer(std::move(sb)),
        pixel_buffer(std::move(pb)), data(dt) {}
  };
}  // namespace platf

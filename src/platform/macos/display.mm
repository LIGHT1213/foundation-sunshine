/**
 * @file src/platform/macos/display.mm
 * @brief Definitions for display capture on macOS.
 */
#include "src/platform/common.h"
#include "src/platform/macos/av_img_t.h"
#include "src/platform/macos/av_video.h"
#include "src/platform/macos/nv12_zero_device.h"
#include "src/platform/macos/sck_capture.h"

#include "src/config.h"
#include "src/logging.h"

#import <Metal/Metal.h>
#import <AppKit/AppKit.h>
#import <CoreGraphics/CoreGraphics.h>  // CGPreflightScreenCaptureAccess

// Avoid conflict between AVFoundation and libavutil both defining AVMediaType
#define AVMediaType AVMediaType_FFmpeg
#include "src/video.h"
#undef AVMediaType

namespace fs = std::filesystem;

namespace platf {
  using namespace std::literals;

  struct av_display_t: public display_t {
    AVVideo *av_capture {};
    CGDirectDisplayID display_id {};

    ~av_display_t() override {
      [av_capture release];
    }

    capture_e
    capture(const push_captured_image_cb_t &push_captured_image_cb, const pull_free_image_cb_t &pull_free_image_cb, bool *cursor) override {
      auto signal = [av_capture capture:^(CMSampleBufferRef sampleBuffer) {
        auto new_sample_buffer = std::make_shared<av_sample_buf_t>(sampleBuffer);
        auto new_pixel_buffer = std::make_shared<av_pixel_buf_t>(new_sample_buffer->buf);

        std::shared_ptr<img_t> img_out;
        if (!pull_free_image_cb(img_out)) {
          // got interrupt signal
          // returning false here stops capture backend
          return false;
        }
        auto av_img = std::static_pointer_cast<av_img_t>(img_out);

        auto old_data_retainer = std::make_shared<temp_retain_av_img_t>(
          av_img->sample_buffer,
          av_img->pixel_buffer,
          img_out->data);

        av_img->sample_buffer = new_sample_buffer;
        av_img->pixel_buffer = new_pixel_buffer;
        img_out->data = new_pixel_buffer->data();

        img_out->width = (int) CVPixelBufferGetWidth(new_pixel_buffer->buf);
        img_out->height = (int) CVPixelBufferGetHeight(new_pixel_buffer->buf);
        img_out->row_pitch = (int) CVPixelBufferGetBytesPerRow(new_pixel_buffer->buf);
        img_out->pixel_pitch = img_out->row_pitch / img_out->width;

        old_data_retainer = nullptr;

        if (!push_captured_image_cb(std::move(img_out), true)) {
          // got interrupt signal
          // returning false here stops capture backend
          return false;
        }

        return true;
      }];

      // Time out if no frame arrives (e.g. permission revoked mid-stream or
      // display goes idle). Returning timeout lets the caller fail gracefully
      // instead of hanging forever on DISPATCH_TIME_FOREVER.
      if (dispatch_semaphore_wait(signal, dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC)) != 0) {
        BOOST_LOG(error) << "Timed out waiting for capture frame (screen-capture permission or display issue)."sv;
        return capture_e::timeout;
      }

      return capture_e::ok;
    }

    std::shared_ptr<img_t>
    alloc_img() override {
      return std::make_shared<av_img_t>();
    }

    std::unique_ptr<avcodec_encode_device_t>
    make_avcodec_encode_device(pix_fmt_e pix_fmt) override {
      if (pix_fmt == pix_fmt_e::yuv420p) {
        av_capture.pixelFormat = kCVPixelFormatType_32BGRA;

        return std::make_unique<avcodec_encode_device_t>();
      }
      else if (pix_fmt == pix_fmt_e::nv12 || pix_fmt == pix_fmt_e::p010) {
        auto device = std::make_unique<nv12_zero_device>();

        device->init(static_cast<void *>(av_capture), pix_fmt, setResolution, setPixelFormat);

        return device;
      }
      else {
        BOOST_LOG(error) << "Unsupported Pixel Format."sv;
        return nullptr;
      }
    }

    int
    dummy_img(img_t *img) override {
      auto signal = [av_capture capture:^(CMSampleBufferRef sampleBuffer) {
        auto new_sample_buffer = std::make_shared<av_sample_buf_t>(sampleBuffer);
        auto new_pixel_buffer = std::make_shared<av_pixel_buf_t>(new_sample_buffer->buf);

        auto av_img = (av_img_t *) img;

        auto old_data_retainer = std::make_shared<temp_retain_av_img_t>(
          av_img->sample_buffer,
          av_img->pixel_buffer,
          img->data);

        av_img->sample_buffer = new_sample_buffer;
        av_img->pixel_buffer = new_pixel_buffer;
        img->data = new_pixel_buffer->data();

        img->width = (int) CVPixelBufferGetWidth(new_pixel_buffer->buf);
        img->height = (int) CVPixelBufferGetHeight(new_pixel_buffer->buf);
        img->row_pitch = (int) CVPixelBufferGetBytesPerRow(new_pixel_buffer->buf);
        img->pixel_pitch = img->row_pitch / img->width;

        old_data_retainer = nullptr;

        // returning false here stops capture backend
        return false;
      }];

      // Same 3s timeout as capture() — see comment there.
      if (dispatch_semaphore_wait(signal, dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC)) != 0) {
        BOOST_LOG(error) << "Timed out waiting for dummy capture frame."sv;
        return -1;
      }

      return 0;
    }

    /**
     * A bridge from the pure C++ code of the hwdevice_t class to the pure Objective C code.
     *
     * display --> an opaque pointer to an object of this class
     * width --> the intended capture width
     * height --> the intended capture height
     */
    static void
    setResolution(void *display, int width, int height) {
      [static_cast<AVVideo *>(display) setFrameWidth:width frameHeight:height];
    }

    static void
    setPixelFormat(void *display, OSType pixelFormat) {
      static_cast<AVVideo *>(display).pixelFormat = pixelFormat;
    }
  };

  // Enumerate displays via NSScreen (safe even without screen-capture
  // permission, unlike AVVideo's displayNames which inserts nil into an
  // NSDictionary). Returns the matched CGDirectDisplayID for display_name,
  // or CGMainDisplayID() as a safe default.
  namespace {
    struct display_info_t {
      CGDirectDisplayID id;
      std::string name;
    };

    std::vector<display_info_t>
    enumerate_displays() {
      std::vector<display_info_t> result;
      @autoreleasepool {
        NSArray<NSScreen *> *screens = [NSScreen screens];
        for (NSScreen *screen in screens) {
          display_info_t info {};
          NSNumber *num = screen.deviceDescription[@"NSScreenNumber"];
          info.id = num.unsignedIntValue;
          // localizedName is macOS 10.15+; fall back to a generic label.
          NSString *name = screen.localizedName;
          info.name = name ? std::string(name.UTF8String) : ("Display " + std::to_string(info.id));
          result.push_back(std::move(info));
        }
      }
      if (result.empty()) {
        // No screens reported (e.g. headless). Provide the main display id so
        // capture can still be attempted and fail with a clear error.
        result.push_back({ CGMainDisplayID(), "Main Display" });
      }
      return result;
    }
  }  // namespace

  std::shared_ptr<display_t>
  display(platf::mem_type_e hwdevice_type, const std::string &display_name, const video::config_t &config) {
    if (hwdevice_type != platf::mem_type_e::system && hwdevice_type != platf::mem_type_e::videotoolbox) {
      BOOST_LOG(error) << "Could not initialize display with the given hw device type."sv;
      return nullptr;
    }

    // Preflight the Screen Recording TCC permission before creating ANY capture
    // backend. Without it, ScreenCaptureKit's async enumeration can crash and
    // AVFoundation's capture callback never fires, so dummy_img()/capture()
    // block forever on DISPATCH_TIME_FOREVER — hanging encoder probe and
    // preventing the HTTP server from starting. Bail out here so the encoder
    // probe fails fast and the Web UI still comes up to show the error.
    if (!CGPreflightScreenCaptureAccess()) {
      BOOST_LOG(error) << "Screen capture permission denied. Grant 'Screen "
                       << "Recording' to this app in System Settings → Privacy "
                       << "& Security, then restart Sunshine."sv;
      return nullptr;
    }

    // Resolve the target display id from the user-supplied name (which is the
    // CGDirectDisplayID as a decimal string on macOS, matching upstream).
    CGDirectDisplayID requested_id = CGMainDisplayID();
    const auto infos = enumerate_displays();
    BOOST_LOG(info) << "Detecting displays"sv;
    for (const auto &di : infos) {
      BOOST_LOG(info) << "Detected display: "sv << di.name << " (id: "sv << di.id << ") connected: true"sv;
      if (!display_name.empty() && std::atoi(display_name.c_str()) == (int) di.id) {
        requested_id = di.id;
      }
    }
    BOOST_LOG(info) << "Configuring selected display ("sv << requested_id << ") to stream"sv;

    // ScreenCaptureKit (macOS 12.3+) is the only supported capture backend on
    // this fork. The legacy AVFoundation path (AVCaptureScreenInput) is
    // deprecated and on macOS 14+/26 it (a) cannot produce frames without a
    // fully-granted TCC context, and (b) crashes inside NSConcreteMapTable
    // dealloc when the AVVideo object is torn down after a failed/stalled
    // capture. Falling back to it turned every "SCK unavailable" case into a
    // segfault, so we no longer do — surface the failure instead and let the
    // Web UI come up so the user can fix permissions.
    auto sck_disp = make_sck_display(requested_id, config.framerate);
    if (sck_disp) {
      return sck_disp;
    }
    BOOST_LOG(error) << "ScreenCaptureKit unavailable. Ensure 'Screen Recording' "
                     << "permission is granted to this app and that you are on "
                     << "macOS 12.3+. The legacy AVFoundation backend is not "
                     << "used (it crashes on modern macOS)."sv;
    return nullptr;
  }

  std::vector<std::string>
  display_names(mem_type_e /*hwdevice_type*/) {
    std::vector<std::string> names;
    const auto infos = enumerate_displays();
    names.reserve(infos.size());
    for (const auto &info : infos) {
      names.push_back(info.name);
    }
    return names;
  }

  /**
   * @brief Returns if GPUs/drivers have changed since the last call to this function.
   * @return `true` if a change has occurred or if it is unknown whether a change occurred.
   */
  bool
  needs_encoder_reenumeration() {
    // We don't track GPU state, so we will always reenumerate. Fortunately, it is fast on macOS.
    return true;
  }

  std::vector<std::string>
  adapter_names() {
    // Enumerate Metal devices so the WebUI/encoder-probing can report the GPU.
    // On Apple Silicon there is typically a single integrated GPU; on Intel
    // Macs there may be discrete + integrated.
    std::vector<std::string> names;

    @autoreleasepool {
      NSArray<id<MTLDevice>> *devices = MTLCopyAllDevices();
      for (id<MTLDevice> device in devices) {
        NSString *n = device.name;
        if (n) names.emplace_back(n.UTF8String);
      }
      if (names.empty()) {
        id<MTLDevice> default_device = MTLCreateSystemDefaultDevice();
        if (default_device) {
          NSString *n = default_device.name;
          if (n) names.emplace_back(n.UTF8String);
        }
      }
    }
    if (names.empty()) {
      names.emplace_back("default");
    }
    return names;
  }
}  // namespace platf

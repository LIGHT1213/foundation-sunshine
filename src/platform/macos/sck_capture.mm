/**
 * @file src/platform/macos/sck_capture.mm
 * @brief ScreenCaptureKit-based display capture implementation.
 *
 * Implements platf::display_t using SCStream (macOS 12.3+). Captured frames
 * arrive as CVPixelBufferRef inside CMSampleBufferRef and are surfaced to the
 * encoder via the existing av_img_t / av_pixel_buf_t wrappers, so the
 * nv12_zero_device zero-copy path works unchanged.
 */
#import "src/platform/macos/sck_capture.h"

#import <ScreenCaptureKit/ScreenCaptureKit.h>
#import <CoreGraphics/CoreGraphics.h>  // CGPreflightScreenCaptureAccess
#import <CoreVideo/CoreVideo.h>
#import <CoreMedia/CoreMedia.h>
#import <AppKit/AppKit.h>

#include "src/platform/macos/av_img_t.h"
#include "src/platform/macos/nv12_zero_device.h"

#include "src/logging.h"

#include <atomic>
#include <dispatch/dispatch.h>
#include <objc/message.h>  // objc_msgSend_fpret (CGFloat scalar return)

namespace fs = std::filesystem;

using namespace std::literals;

#if __MAC_OS_X_VERSION_MAX_ALLOWED >= 120300
  #define SUNSHINE_HAS_SCK 1
#else
  #define SUNSHINE_HAS_SCK 0
#endif

#if SUNSHINE_HAS_SCK

// ===== Objective-C bridge (must live at global scope, not in a namespace) =====

API_AVAILABLE(macos(12.3))
@interface SCKStreamDelegate: NSObject <SCStreamOutput, SCStreamDelegate> {
  @public
  // Signaled whenever a fresh frame arrives. The capture loop waits on it.
  dispatch_semaphore_t frameSignal_;
  // Most recent retained CMSampleBufferRef (+1 retain), or NULL. Stored as
  // raw pointer + atomic because std::atomic is non-copyable and cannot back
  // an ObjC @property.
  std::atomic<CMSampleBufferRef> pendingSample_;
}

- (instancetype)init;
- (CMSampleBufferRef)consumeSample;  // returns a +1 retained sample or NULL

@end

@implementation SCKStreamDelegate

- (instancetype)init {
  self = [super init];
  if (self) {
    frameSignal_ = dispatch_semaphore_create(0);
    // Construct atomically (std::atomic_init is deprecated in C++20).
    new (&pendingSample_) std::atomic<CMSampleBufferRef>(NULL);
  }
  return self;
}

- (void)stream:(SCStream *)stream
  didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer
             ofType:(SCStreamOutputType)type {
  if (type != SCStreamOutputTypeScreen) {
    return;
  }

  CMSampleBufferRef old = pendingSample_.exchange((CMSampleBufferRef) CFRetain(sampleBuffer));
  if (old) {
    CFRelease(old);
  }
  dispatch_semaphore_signal(frameSignal_);
}

- (void)stream:(SCStream *)stream didStopWithError:(NSError *)err {
  const char *msg = err.localizedDescription.UTF8String;
  BOOST_LOG(error) << "ScreenCaptureKit stream stopped: "sv << (msg ? msg : "unknown");
  dispatch_semaphore_signal(frameSignal_);
}

- (CMSampleBufferRef)consumeSample {
  return pendingSample_.exchange(NULL);
}

- (void)dealloc {
  // MRC: the ivars are CF/dispatch objects (+1 from create) not tracked by ARC.
  if (frameSignal_) { dispatch_release(frameSignal_); frameSignal_ = nil; }
  CMSampleBufferRef leaked = pendingSample_.load();
  if (leaked) CFRelease(leaked);
  [super dealloc];
}

@end

// ===== C++ display_t implementation =====

namespace platf {

  class API_AVAILABLE(macos(12.3)) sck_display_t: public display_t {
  public:
    sck_display_t() = default;

    ~sck_display_t() override {
      stop();
    }

    bool
    init(CGDirectDisplayID display_id, int frame_rate);

    capture_e
    capture(const push_captured_image_cb_t &push_captured_image_cb,
      const pull_free_image_cb_t &pull_free_image_cb, bool * /*cursor*/) override;

    std::shared_ptr<img_t>
    alloc_img() override {
      return std::make_shared<av_img_t>();
    }

    std::unique_ptr<avcodec_encode_device_t>
    make_avcodec_encode_device(pix_fmt_e pix_fmt) override;

    int
    dummy_img(img_t *img) override;

    // HDR overrides (default display_t implementations return false).
    bool
    is_hdr() override;

    bool
    get_hdr_metadata(SS_HDR_METADATA &metadata) override;

  private:
    void
    stop();

    // Probe HDR capability of the NSScreen matching display_id; fills
    // hdrCapable_ / hdrPeakLuminance_.
    void
    probe_hdr(CGDirectDisplayID display_id);

    int width_ {0};
    int height_ {0};
    OSType pixelFormat_ {kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange};
    SCStream *stream_ __strong {nil};
    SCStreamConfiguration *cfg_ __strong {nil};
    SCKStreamDelegate *delegate_ __strong {nil};
    dispatch_queue_t sampleQueue_ __strong {nil};
    // HDR state (populated in init()).
    bool hdrCapable_ {false};
    float hdrPeakLuminance_ {1000.0f};  // nits, conservative default
  };

  bool
  sck_display_t::init(CGDirectDisplayID display_id, int frame_rate) {
    // Preflight screen-capture TCC permission BEFORE touching ScreenCaptureKit.
    // On macOS 14+/26 (Tahoe) the SCShareableContent async enumeration can
    // crash the process (segfault inside the framework) when the calling app
    // lacks the Screen Recording permission — the completionHandler is invoked
    // on a tearing-down context. CGPreflightScreenCaptureAccess() (10.15+) lets
    // us detect the missing permission synchronously and bail out cleanly so
    // the caller falls back to AVFoundation instead of segfaulting.
    if (!CGPreflightScreenCaptureAccess()) {
      BOOST_LOG(warning) << "ScreenCaptureKit: no screen-capture permission; "
                         << "grant 'Screen Recording' to the host app in System "
                         << "Settings → Privacy & Security. Falling back to "
                         << "AVFoundation capture."sv;
      return false;
    }

    // Enumerate shareable content (async) and find the SCDisplay matching
    // the requested CGDirectDisplayID. Block on a semaphore during setup.
    __block SCDisplay *matchedDisplay = nil;
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);

    [SCShareableContent getShareableContentExcludingDesktopWindows:NO
                                              onScreenWindowsOnly:YES
                                                completionHandler:^(SCShareableContent * _Nullable content, NSError * _Nullable err) {
      if (err || !content) {
        const char *m = err ? err.localizedDescription.UTF8String : "nil content";
        BOOST_LOG(error) << "ScreenCaptureKit: failed to enumerate shareable content: "sv << (m ? m : "unknown");
      }
      else {
        for (SCDisplay *d in content.displays) {
          if (d.displayID == display_id) {
            matchedDisplay = [d retain];  // MRC: __block vars aren't retained
            break;
          }
        }
        if (!matchedDisplay && content.displays.count > 0) {
          matchedDisplay = [content.displays.firstObject retain];
        }
      }
      dispatch_semaphore_signal(sem);
    }];
    // 3s timeout: without TCC permission the completionHandler can be invoked
    // on a tearing-down context and crash, or never fire — FOREVER would hang.
    if (dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC)) != 0) {
      BOOST_LOG(error) << "ScreenCaptureKit: timed out enumerating shareable content."sv;
      return false;
    }

    if (!matchedDisplay) {
      BOOST_LOG(error) << "ScreenCaptureKit: no matching display found for id "sv << display_id;
      return false;
    }

    // Defense against a macOS Tahoe (26.x) ScreenCaptureKit bug: when TCC
    // permission is missing or stale (e.g. adhoc-signed binary whose CDHash
    // changed after rebuild), SCShareableContent can hand back a non-nil but
    // invalid (zombie) SCDisplay. Passing it to SCContentFilter crashes inside
    // objc_retain. Validate the frame before use — a zombie returns a
    // zero-sized rect, and a zero width/height is unusable anyway.
    CGRect bounds = matchedDisplay.frame;
    if (CGRectIsEmpty(bounds) || CGRectGetWidth(bounds) <= 0 || CGRectGetHeight(bounds) <= 0) {
      BOOST_LOG(error) << "ScreenCaptureKit: display "sv << display_id
                       << " returned an invalid frame (permission missing or "
                       << "stale). Falling back to AVFoundation."sv;
      return false;
    }
    width_ = (int) CGRectGetWidth(bounds);
    height_ = (int) CGRectGetHeight(bounds);

    // Surface dimensions on the public display_t members.
    width = width_;
    height = height_;
    env_width = width_;
    env_height = height_;

    SCContentFilter *filter = [[SCContentFilter alloc] initWithDisplay:matchedDisplay
                                                      excludingWindows:@[]];
    // matchedDisplay was retained in the completion handler (MRC: __block vars
    // aren't auto-retained). The filter keeps its own reference, so release ours.
    [matchedDisplay release];
    matchedDisplay = nil;

    cfg_ = [[SCStreamConfiguration alloc] init];
    cfg_.width = (size_t) width_;
    cfg_.height = (size_t) height_;
    cfg_.scalesToFit = NO;
    cfg_.showsCursor = YES;
    cfg_.queueDepth = 5;
    cfg_.pixelFormat = pixelFormat_;
    if (frame_rate > 0) {
      cfg_.minimumFrameInterval = CMTimeMake(1, frame_rate);
    }
    else {
      cfg_.minimumFrameInterval = kCMTimeInvalid;  // native rate
    }

    sampleQueue_ = dispatch_queue_create("sunshine.sck.capture", DISPATCH_QUEUE_SERIAL);
    delegate_ = [[SCKStreamDelegate alloc] init];

    stream_ = [[SCStream alloc] initWithFilter:filter configuration:cfg_ delegate:delegate_];
    // SCStream retains filter/cfg/delegate; release our +1 from alloc.
    [filter release];

    NSError *addErr = nil;
    BOOL added = [stream_ addStreamOutput:delegate_
                                      type:SCStreamOutputTypeScreen
                        sampleHandlerQueue:sampleQueue_
                                       error:&addErr];
    if (!added || addErr) {
      const char *m = addErr ? addErr.localizedDescription.UTF8String : "unknown";
      BOOST_LOG(error) << "ScreenCaptureKit: failed to add stream output: "sv << m;
      return false;
    }

    __block NSError *startErr = nil;
    dispatch_semaphore_t startSem = dispatch_semaphore_create(0);
    [stream_ startCaptureWithCompletionHandler:^(NSError * _Nullable err) {
      // MRC: __block object vars are NOT retained by the block. err is an
      // autoreleased parameter released when the handler's autorelease pool
      // drains, so retain it to survive past the semaphore wait.
      startErr = [err retain];
      dispatch_semaphore_signal(startSem);
    }];
    // 5s timeout: capture backend init can be slow on first TCC grant, but a
    // missing-permission / framework hang must not deadlock encoder probe.
    if (dispatch_semaphore_wait(startSem, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC)) != 0) {
      BOOST_LOG(error) << "ScreenCaptureKit: startCapture timed out."sv;
      return false;
    }

    if (startErr) {
      const char *m = startErr.localizedDescription.UTF8String;
      BOOST_LOG(error) << "ScreenCaptureKit: startCapture failed: "sv << (m ? m : "unknown");
      [startErr release];
      return false;
    }
    // startErr is nil here (success path), nothing to release.

    BOOST_LOG(info) << "ScreenCaptureKit: capturing display "sv << display_id
                    << " at "sv << width_ << "x"sv << height_;

    // Probe HDR capability of the matching NSScreen (macOS 14+ exposes EDR
    // peak luminance). We report HDR when the display advertises a peak EDR
    // color value > 1.0. On older macOS or non-HDR panels this stays false.
    probe_hdr(display_id);

    return true;
  }

  void
  sck_display_t::probe_hdr(CGDirectDisplayID display_id) {
    @autoreleasepool {
      for (NSScreen *screen in [NSScreen screens]) {
        NSNumber *num = screen.deviceDescription[@"NSScreenNumber"];
        if (num.unsignedIntValue != display_id) continue;

        // maximumPotentialExtendedDynamicRangeColorValue (macOS 14+) returns the
        // panel's peak EDR color value (CGFloat, 1.0 = SDR, >1.0 = HDR). This
        // property is NOT declared in older SDK headers, so we cannot call it as
        // a typed property — the compiler treats the unknown selector as
        // returning `id` and emits a warning, and at runtime the CGFloat return
        // value gets misinterpreted as an ObjC object pointer, crashing inside
        // objc_msgSend/objc_retain.
        //
        // Resolve the selector at runtime via objc_msgSend with the correct
        // scalar return convention (CGFloat = double on arm64), guarded by
        // respondsToSelector: so older macOS that lacks the selector is safe.
        if (@available(macOS 14.0, *)) {
          SEL edrSel = NSSelectorFromString(@"maximumPotentialExtendedDynamicRangeColorValue");
          if ([screen respondsToSelector:edrSel]) {
            // Call via the ObjC runtime with the correct scalar return type.
            // On arm64, CGFloat (double) returns go through plain objc_msgSend;
            // on x86_64 the fp-return variant objc_msgSend_fpret is required.
            // Cast objc_msgSend to a typed function pointer so the compiler
            // uses the right ABI for the CGFloat return value.
#if defined(__x86_64__)
            CGFloat peak = ((CGFloat(*)(id, SEL))objc_msgSend_fpret)(screen, edrSel);
#else
            CGFloat peak = ((CGFloat(*)(id, SEL))objc_msgSend)(screen, edrSel);
#endif
            if (peak > 1.0) {
              hdrCapable_ = true;
              // EDR peak → nits: Apple does not expose absolute nits directly,
              // but a value of 2.0 typically maps to ~1000 nits, 4.0 to ~1600.
              // Use a conservative fixed mapping until a real luminance API ships.
              hdrPeakLuminance_ = std::max(1000.0f, (float) peak * 500.0f);
              BOOST_LOG(info) << "ScreenCaptureKit: HDR display detected, peak EDR="sv
                              << peak << " (~"sv << hdrPeakLuminance_ << " nits)"sv;
            }
          }
        }
        break;
      }
    }
  }

  bool
  sck_display_t::is_hdr() {
    return hdrCapable_;
  }

  bool
  sck_display_t::get_hdr_metadata(SS_HDR_METADATA &metadata) {
    if (!hdrCapable_) {
      return false;
    }

    // BT.2020 + PQ (SMPTE ST 2084) static mastering metadata. Primaries are
    // the standard BT.2020 chromaticities (normalized to 50000). The luminance
    // fields use the probed peak (falling back to a safe 1000 nits default).
    std::memset(&metadata, 0, sizeof(metadata));

    // BT.2020 primaries (x,y normalized to 50000).
    metadata.displayPrimaries[0].x = 15600;  // Red   (0.708, 0.292)
    metadata.displayPrimaries[0].y = 23000;
    metadata.displayPrimaries[1].x = 7500;   // Green (0.170, 0.797)
    metadata.displayPrimaries[1].y = 39850;
    metadata.displayPrimaries[2].x = 15000;  // Blue  (0.131, 0.046)
    metadata.displayPrimaries[2].y = 3000;
    metadata.whitePoint.x = 15635;           // D65 (0.3127, 0.3290)
    metadata.whitePoint.y = 16450;

    metadata.maxDisplayLuminance = (uint16_t) hdrPeakLuminance_;
    metadata.minDisplayLuminance = 1;        // 0.0001 nits

    // Content light levels are populated per-frame by the dynamic-metadata
    // path (hdr_luminance_stats); without GPU luminance analysis (the macOS
    // equivalent of Windows' D3D11 compute shader) we leave them at 0 so the
    // client falls back to display-static HDR10.
    metadata.maxContentLightLevel = 0;
    metadata.maxFrameAverageLightLevel = 0;
    metadata.maxFullFrameLuminance = (uint16_t) hdrPeakLuminance_;

    return true;
  }

  capture_e
  sck_display_t::capture(const push_captured_image_cb_t &push_captured_image_cb,
    const pull_free_image_cb_t &pull_free_image_cb, bool * /*cursor*/) {
    // Wait for the next frame with a 10s timeout. Under normal streaming the
    // frame signal fires ~60×/s; a 10s gap means the stream has stopped or the
    // display went to sleep. Returning timeout lets the caller restart instead
    // of hanging the capture thread forever on DISPATCH_TIME_FOREVER.
    if (dispatch_semaphore_wait(delegate_->frameSignal_,
          dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC)) != 0) {
      BOOST_LOG(warning) << "ScreenCaptureKit: timed out waiting for capture frame."sv;
      return capture_e::timeout;
    }

    CMSampleBufferRef sample = [delegate_ consumeSample];
    if (!sample) {
      return capture_e::ok;  // spurious wake (e.g. didStopWithError)
    }

    auto sample_guard = std::make_shared<av_sample_buf_t>(sample);
    CFRelease(sample);
    auto pixel_buffer = std::make_shared<av_pixel_buf_t>(sample_guard->buf);

    std::shared_ptr<img_t> img_out;
    if (!pull_free_image_cb(img_out)) {
      return capture_e::interrupted;
    }
    auto av_img = std::static_pointer_cast<av_img_t>(img_out);

    auto old_retainer = std::make_shared<temp_retain_av_img_t>(
      av_img->sample_buffer, av_img->pixel_buffer, img_out->data);

    av_img->sample_buffer = sample_guard;
    av_img->pixel_buffer = pixel_buffer;
    img_out->data = pixel_buffer->data();

    img_out->width = (int) CVPixelBufferGetWidth(pixel_buffer->buf);
    img_out->height = (int) CVPixelBufferGetHeight(pixel_buffer->buf);
    img_out->row_pitch = (int) CVPixelBufferGetBytesPerRow(pixel_buffer->buf);
    img_out->pixel_pitch = img_out->row_pitch / img_out->width;

    old_retainer = nullptr;

    if (!push_captured_image_cb(std::move(img_out), true)) {
      return capture_e::interrupted;
    }
    return capture_e::ok;
  }

  std::unique_ptr<avcodec_encode_device_t>
  sck_display_t::make_avcodec_encode_device(pix_fmt_e pix_fmt) {
    if (pix_fmt == pix_fmt_e::yuv420p) {
      pixelFormat_ = kCVPixelFormatType_32BGRA;
      return std::make_unique<avcodec_encode_device_t>();
    }
    else if (pix_fmt == pix_fmt_e::nv12 || pix_fmt == pix_fmt_e::p010) {
      OSType pf = (pix_fmt == pix_fmt_e::nv12)
        ? kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        : kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange;
      pixelFormat_ = pf;
      if (cfg_) {
        cfg_.pixelFormat = pf;
        [stream_ updateConfiguration:cfg_ completionHandler:^(NSError * _Nullable err) {
          if (err) {
            const char *m = err.localizedDescription.UTF8String;
            BOOST_LOG(warning) << "ScreenCaptureKit: pixel format update failed: "sv << (m ? m : "unknown");
          }
        }];
      }

      auto device = std::make_unique<nv12_zero_device>();
      // SCK resolution is fixed at stream creation; resolution/pixel callbacks
      // are no-ops (pixel format is applied live above).
      device->init(static_cast<void *>(this), pix_fmt,
        [](void *, int, int) {},
        [](void *, int) {});
      return device;
    }
    BOOST_LOG(error) << "Unsupported Pixel Format."sv;
    return nullptr;
  }

  int
  sck_display_t::dummy_img(img_t *img) {
    // Bounded 10s wait — same rationale as capture(). Without it, a missing
    // permission or stopped stream deadlocks encoder probe.
    if (dispatch_semaphore_wait(delegate_->frameSignal_,
          dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC)) != 0) {
      BOOST_LOG(error) << "ScreenCaptureKit: timed out waiting for dummy capture frame."sv;
      return -1;
    }
    CMSampleBufferRef sample = [delegate_ consumeSample];
    if (!sample) {
      return -1;
    }

    auto sample_guard = std::make_shared<av_sample_buf_t>(sample);
    CFRelease(sample);
    auto pixel_buffer = std::make_shared<av_pixel_buf_t>(sample_guard->buf);

    auto av_img = (av_img_t *) img;
    auto old_retainer = std::make_shared<temp_retain_av_img_t>(
      av_img->sample_buffer, av_img->pixel_buffer, img->data);

    av_img->sample_buffer = sample_guard;
    av_img->pixel_buffer = pixel_buffer;
    img->data = pixel_buffer->data();

    img->width = (int) CVPixelBufferGetWidth(pixel_buffer->buf);
    img->height = (int) CVPixelBufferGetHeight(pixel_buffer->buf);
    img->row_pitch = (int) CVPixelBufferGetBytesPerRow(pixel_buffer->buf);
    img->pixel_pitch = img->row_pitch / img->width;
    return 0;
  }

  void
  sck_display_t::stop() {
    // This file compiles under MRC (no -fobjc-arc), so __strong ivars are
    // no-ops and assignment to nil does NOT release. Release explicitly.
    if (stream_) {
      // Synchronously wait for stopCapture to complete so SCK schedules no NEW
      // callbacks. SCStream does NOT retain its delegate, so we must not free
      // the delegate/callback state until all in-flight callbacks are done.
      dispatch_semaphore_t stopSem = dispatch_semaphore_create(0);
      [stream_ stopCaptureWithCompletionHandler:^(NSError * _Nullable) {
        dispatch_semaphore_signal(stopSem);
      }];
      dispatch_semaphore_wait(stopSem, dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC));
      [stopSem release];

      // Drain any callback already executing on the serial sample queue. We are
      // on the capture/C++ thread, never on sampleQueue_, so this can't deadlock.
      if (sampleQueue_) {
        dispatch_sync(sampleQueue_, ^{});
      }

      [stream_ release];
      stream_ = nil;
    }
    // Order matters: delegate_ and sampleQueue_ may still be referenced by a
    // callback drained above, so release them only AFTER the drain.
    if (cfg_) { [cfg_ release]; cfg_ = nil; }
    if (delegate_) { [delegate_ release]; delegate_ = nil; }
    if (sampleQueue_) { dispatch_release(sampleQueue_); sampleQueue_ = nil; }
  }

  std::shared_ptr<display_t>
  make_sck_display(CGDirectDisplayID display_id, int frame_rate) {
    if (@available(macOS 12.3, *)) {
      auto disp = std::make_shared<sck_display_t>();
      if (disp->init(display_id, frame_rate)) {
        return disp;
      }
      return nullptr;
    }
    BOOST_LOG(info) << "ScreenCaptureKit requires macOS 12.3+; falling back to AVFoundation."sv;
    return nullptr;
  }

#else  // !SUNSHINE_HAS_SCK

  std::shared_ptr<display_t>
  make_sck_display(CGDirectDisplayID, int) {
    return nullptr;
  }

#endif  // SUNSHINE_HAS_SCK

}  // namespace platf

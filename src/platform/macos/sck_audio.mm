/**
 * @file src/platform/macos/sck_audio.mm
 * @brief ScreenCaptureKit system audio capture implementation.
 *
 * Captures macOS system playback audio via a dedicated SCStream with
 * capturesAudio=YES. Frames arrive as CMSampleBufferRef wrapping float PCM;
 * they are appended to a TPCircularBuffer and drained by mic_t::sample().
 */
#import "src/platform/macos/sck_audio.h"

#import <ScreenCaptureKit/ScreenCaptureKit.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreAudio/CoreAudio.h>

#include "third-party/TPCircularBuffer/TPCircularBuffer.h"

#include "src/logging.h"

#include <atomic>
#include <dispatch/dispatch.h>
#include <mutex>

using namespace std::literals;

#if __MAC_OS_X_VERSION_MAX_ALLOWED >= 130000
  #define SUNSHINE_HAS_SCK_AUDIO 1
#else
  #define SUNSHINE_HAS_SCK_AUDIO 0
#endif

#if SUNSHINE_HAS_SCK_AUDIO

// ===== Objective-C bridge =====
//
// Owns the SCStream and the latest retained CMSampleBufferRef from the audio
// output. The C++ mic_t drains it on demand. Keeping the state in ivars (not
// @property) avoids ObjC synthesis of copy/assign for non-copyable types.

API_AVAILABLE(macos(13.0))
@interface SCKAudioDelegate: NSObject <SCStreamOutput, SCStreamDelegate> {
  @public
  dispatch_semaphore_t frameSignal_;
  std::mutex sampleMu_;
  CMSampleBufferRef pendingSample_;  // +1 retained or NULL
}

- (instancetype)init;
- (CMSampleBufferRef)takeSample;  // returns +1 retained sample or NULL

@end

@implementation SCKAudioDelegate

- (instancetype)init {
  self = [super init];
  if (self) {
    frameSignal_ = dispatch_semaphore_create(0);
    pendingSample_ = NULL;
  }
  return self;
}

- (void)dealloc {
  if (pendingSample_) CFRelease(pendingSample_);
  [super dealloc];
}

- (void)stream:(SCStream *)stream
  didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer
             ofType:(SCStreamOutputType)type {
  if (type != SCStreamOutputTypeAudio) {
    return;
  }

  std::lock_guard<std::mutex> lk(sampleMu_);
  CMSampleBufferRef old = pendingSample_;
  pendingSample_ = (CMSampleBufferRef) CFRetain(sampleBuffer);
  if (old) CFRelease(old);
  dispatch_semaphore_signal(frameSignal_);
}

- (void)stream:(SCStream *)stream didStopWithError:(NSError *)err {
  const char *m = err.localizedDescription.UTF8String;
  BOOST_LOG(error) << "ScreenCaptureKit audio stream stopped: "sv << (m ? m : "unknown");
  dispatch_semaphore_signal(frameSignal_);
}

- (CMSampleBufferRef)takeSample {
  std::lock_guard<std::mutex> lk(sampleMu_);
  CMSampleBufferRef sb = pendingSample_;
  pendingSample_ = NULL;
  return sb;  // +1 retained (caller must release)
}

@end

// ===== C++ mic_t =====

namespace platf {

  class API_AVAILABLE(macos(13.0)) sck_system_audio_t: public mic_t {
  public:
    sck_system_audio_t() = default;
    ~sck_system_audio_t() override {
      // MRC: __strong ivars are no-ops, so release explicitly.
      if (stream_) {
        [stream_ stopCaptureWithCompletionHandler:^(NSError * _Nullable) {}];
        [stream_ release];
        stream_ = nil;
      }
      if (delegate_) { [delegate_ release]; delegate_ = nil; }
      if (queue_) { dispatch_release(queue_); queue_ = nil; }
      TPCircularBufferCleanup(&buf_);
    }

    bool
    init(int channels, std::uint32_t sample_rate, std::uint32_t /*frame_size*/);

    capture_e
    sample(std::vector<float> &sample_in) override;

  private:
    // Append a single CMSampleBufferRef's float PCM into the ring buffer.
    void
    appendSampleBuffer(CMSampleBufferRef sb);

    SCStream *stream_ __strong {nil};
    SCKAudioDelegate *delegate_ __strong {nil};
    dispatch_queue_t queue_ __strong {nil};
    TPCircularBuffer buf_ {};
    int channels_ {2};
    std::uint32_t sample_rate_ {48000};
  };

  bool
  sck_system_audio_t::init(int channels, std::uint32_t sample_rate, std::uint32_t /*frame_size*/) {
    channels_ = channels;
    sample_rate_ = sample_rate;

    // ~2s of stereo float headroom.
    if (!TPCircularBufferInit(&buf_, sample_rate * channels * sizeof(float) * 2)) {
      BOOST_LOG(error) << "SCK audio: failed to init circular buffer"sv;
      return false;
    }

    // Pick the primary display as the audio source (SCK ties system audio to a
    // display filter). Same zombie-SCDisplay / TCC-permission caveats as the
    // video path in sck_capture.mm apply here — validate the frame before use.
    __block SCDisplay *matchedDisplay = nil;
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    [SCShareableContent getShareableContentExcludingDesktopWindows:NO
                                              onScreenWindowsOnly:YES
                                                completionHandler:^(SCShareableContent * _Nullable content, NSError * _Nullable err) {
      if (err || !content) {
        const char *m = err ? err.localizedDescription.UTF8String : "nil";
        BOOST_LOG(error) << "SCK audio: enumerate failed: "sv << (m ? m : "unknown");
      }
      else if (content.displays.count > 0) {
        matchedDisplay = [content.displays.firstObject retain];  // MRC: __block not auto-retained
      }
      dispatch_semaphore_signal(sem);
    }];
    // 3s timeout — without TCC permission the completionHandler may never fire
    // (or fires on a tearing-down context), so FOREVER would deadlock init().
    if (dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC)) != 0) {
      BOOST_LOG(error) << "SCK audio: timed out enumerating shareable content (permission missing?)."sv;
      return false;
    }
    if (!matchedDisplay) {
      return false;
    }
    // Zombie guard: an invalid SCDisplay has a zero-sized frame, and passing
    // it to SCContentFilter crashes inside objc_retain (see sck_capture.mm).
    CGRect frame = matchedDisplay.frame;
    if (CGRectIsEmpty(frame) || CGRectGetWidth(frame) <= 0 || CGRectGetHeight(frame) <= 0) {
      BOOST_LOG(error) << "SCK audio: display returned invalid frame (permission missing or stale)."sv;
      return false;
    }

    SCContentFilter *filter = [[SCContentFilter alloc] initWithDisplay:matchedDisplay
                                                      excludingWindows:@[]];
    // Release our retain on matchedDisplay (filter keeps its own reference).
    [matchedDisplay release];
    matchedDisplay = nil;

    SCStreamConfiguration *cfg = [[SCStreamConfiguration alloc] init];
    cfg.capturesAudio = YES;
    cfg.excludesCurrentProcessAudio = YES;
    cfg.sampleRate = (NSInteger) sample_rate;
    cfg.channelCount = (NSInteger) channels;

    queue_ = dispatch_queue_create("sunshine.sck.audio", DISPATCH_QUEUE_SERIAL);
    delegate_ = [[SCKAudioDelegate alloc] init];

    stream_ = [[SCStream alloc] initWithFilter:filter configuration:cfg delegate:delegate_];
    // SCStream retains filter/cfg/delegate; release our +1 from alloc.
    [filter release];
    [cfg release];

    NSError *addErr = nil;
    BOOL added = [stream_ addStreamOutput:delegate_
                                      type:SCStreamOutputTypeAudio
                        sampleHandlerQueue:queue_
                                       error:&addErr];
    if (!added || addErr) {
      const char *m = addErr ? addErr.localizedDescription.UTF8String : "unknown";
      BOOST_LOG(error) << "SCK audio: addStreamOutput failed: "sv << m;
      return false;
    }

    __block NSError *startErr = nil;
    dispatch_semaphore_t startSem = dispatch_semaphore_create(0);
    [stream_ startCaptureWithCompletionHandler:^(NSError * _Nullable err) {
      startErr = [err retain];  // MRC: retain autoreleased err past the handler
      dispatch_semaphore_signal(startSem);
    }];
    // 5s timeout for stream start (capture backend init can be slow on first grant).
    if (dispatch_semaphore_wait(startSem, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC)) != 0) {
      BOOST_LOG(error) << "SCK audio: startCapture timed out."sv;
      return false;
    }

    if (startErr) {
      const char *m = startErr.localizedDescription.UTF8String;
      BOOST_LOG(error) << "SCK audio: startCapture failed: "sv << (m ? m : "unknown");
      [startErr release];
      return false;
    }

    BOOST_LOG(info) << "SCK audio: capturing system audio ("sv << channels
                    << "ch @ "sv << sample_rate << "Hz)"sv;
    return true;
  }

  void
  sck_system_audio_t::appendSampleBuffer(CMSampleBufferRef sb) {
    // SCK delivers non-interleaved float32 PCM. Extract the AudioBufferList
    // via the two-call pattern: first query the needed size, then fill.
    size_t needed = 0;
    OSStatus st = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
      sb, &needed, nullptr, 0, nullptr, nullptr, 0, nullptr);
    if (st != noErr || needed == 0) {
      return;
    }

    // Stack buffer sized for up to 16 channels (AudioBufferList is variable-length).
    if (needed > sizeof(AudioBufferList) + 16 * sizeof(AudioBuffer)) {
      BOOST_LOG(warning) << "SCK audio: unexpectedly large AudioBufferList ("sv << needed << ")"sv;
      return;
    }
    alignas(AudioBufferList) char ablStorage[ sizeof(AudioBufferList) + 16 * sizeof(AudioBuffer) ];
    AudioBufferList *abl = (AudioBufferList *) ablStorage;
    CMBlockBufferRef retainedBB = nullptr;
    st = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
      sb, nullptr, abl, sizeof(ablStorage), nullptr, nullptr, 0, &retainedBB);
    if (st != noErr || !retainedBB) {
      if (retainedBB) CFRelease(retainedBB);
      return;
    }

    for (UInt32 b = 0; b < abl->mNumberBuffers; b++) {
      const AudioBuffer &ab = abl->mBuffers[b];
      if (!ab.mData || ab.mDataByteSize == 0) continue;
      uint32_t available = 0;
      void *dst = TPCircularBufferHead(&buf_, &available);
      if (dst && available >= ab.mDataByteSize) {
        memcpy(dst, ab.mData, ab.mDataByteSize);
        TPCircularBufferProduce(&buf_, ab.mDataByteSize);
      }
      else {
        break;  // ring full, drop the rest of this buffer
      }
    }
    CFRelease(retainedBB);
  }

  capture_e
  sck_system_audio_t::sample(std::vector<float> &sample_in) {
    const std::size_t needed = sample_in.size();
    std::size_t have = 0;

    while (have < needed) {
      // Drain any pending SCK sample buffer into the ring buffer.
      if (CMSampleBufferRef sb = [delegate_ takeSample]) {
        appendSampleBuffer(sb);
        CFRelease(sb);
      }

      uint32_t length = 0;
      void *tail = TPCircularBufferTail(&buf_, &length);
      if (!tail || length == 0) {
        // Nothing buffered: wait briefly for the next SCK audio frame. A bounded
        // timeout (3s) ensures sample() can't hang forever if the stream stops
        // or permission is revoked mid-session; we surface a timeout so the
        // caller can restart rather than deadlock.
        if (dispatch_semaphore_wait(delegate_->frameSignal_,
              dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC)) != 0) {
          BOOST_LOG(warning) << "SCK audio: timed out waiting for audio frame."sv;
          return capture_e::timeout;
        }
        continue;
      }

      const std::size_t take = std::min(needed - have, (std::size_t)(length / sizeof(float)));
      memcpy(sample_in.data() + have, tail, take * sizeof(float));
      have += take;
      TPCircularBufferConsume(&buf_, (uint32_t)(take * sizeof(float)));
    }

    return capture_e::ok;
  }

  std::unique_ptr<mic_t>
  make_sck_system_audio(int channels, std::uint32_t sample_rate, std::uint32_t frame_size) {
    if (@available(macOS 13.0, *)) {
      auto mic = std::make_unique<sck_system_audio_t>();
      if (mic->init(channels, sample_rate, frame_size)) {
        return mic;
      }
      return nullptr;
    }
    BOOST_LOG(info) << "SCK system audio requires macOS 13.0+"sv;
    return nullptr;
  }

#else  // !SUNSHINE_HAS_SCK_AUDIO

  std::unique_ptr<mic_t>
  make_sck_system_audio(int, std::uint32_t, std::uint32_t) {
    return nullptr;
  }

#endif  // SUNSHINE_HAS_SCK_AUDIO

}  // namespace platf

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

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cmath>
#include <cstdlib>
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
  std::atomic<bool> stopped_;        // set by didStopWithError
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
    stopped_ = false;
  }
  return self;
}

- (void)dealloc {
  if (pendingSample_) CFRelease(pendingSample_);
  if (frameSignal_) { dispatch_release(frameSignal_); frameSignal_ = nil; }
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
  stopped_.store(true, std::memory_order_release);
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
      // Restore system output mute state FIRST, before tearing down the stream.
      muteSystemOutput(false);

      // MRC: __strong ivars are no-ops, so release explicitly. Mirror the
      // sck_display_t::stop() drain pattern: wait for stopCapture, drain the
      // serial callback queue, THEN release the delegate (SCStream does NOT
      // retain its delegate, so freeing it while a callback is in-flight on
      // queue_ is a use-after-free).
      if (stream_) {
        dispatch_semaphore_t stopSem = dispatch_semaphore_create(0);
        [stream_ stopCaptureWithCompletionHandler:^(NSError * _Nullable) {
          dispatch_semaphore_signal(stopSem);
        }];
        bool stopped = dispatch_semaphore_wait(stopSem,
          dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC)) == 0;
        [stopSem release];
        if (stopped) {
          // Bounded drain: a bare dispatch_sync(queue_, ^{}) can hang forever
          // if SCK scheduled work that never completes during teardown. We
          // bound the drain and, on timeout, leak the queue+delegate+stream to
          // avoid a use-after-free (a hang is worse than a leak here — this
          // destructor runs on the session::join critical path).
          if (queue_) {
            dispatch_semaphore_t drainSem = dispatch_semaphore_create(0);
            dispatch_async(queue_, ^{
              dispatch_semaphore_signal(drainSem);
            });
            bool drained = dispatch_semaphore_wait(drainSem,
              dispatch_time(DISPATCH_TIME_NOW, 1 * NSEC_PER_SEC)) == 0;
            [drainSem release];
            if (!drained) {
              BOOST_LOG(warning) << "SCK audio: drain timed out; leaking stream/queue/delegate to avoid hang"sv;
              // Leak to avoid UAF: do NOT release delegate_/queue_/stream_.
              stream_ = nil;
              delegate_ = nil;
              queue_ = nil;
              TPCircularBufferCleanup(&buf_);
              return;
            }
          }
          [stream_ release];
          stream_ = nil;
        }
        else {
          // stopCapture timed out: the stream may still be delivering callbacks,
          // so leaking is safer than releasing. This mirrors sck_display_t::stop().
          BOOST_LOG(warning) << "SCK audio: stopCapture timed out; leaking stream to avoid UAF"sv;
          stream_ = nil;  // leak
          delegate_ = nil;
          queue_ = nil;
          TPCircularBufferCleanup(&buf_);
          return;
        }
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

    // Mute/unmute the system output device so the host stays silent during
    // streaming. SCK captures the audio mix regardless of output device mute
    // state, so muting the speakers doesn't affect capture quality.
    void
    muteSystemOutput(bool mute);

    SCStream *stream_ __strong {nil};
    SCKAudioDelegate *delegate_ __strong {nil};
    dispatch_queue_t queue_ __strong {nil};
    TPCircularBuffer buf_ {};
    int channels_ {2};
    std::uint32_t sample_rate_ {48000};
    AudioObjectID mutedDeviceID_ {kAudioObjectUnknown};  // device we muted (to restore on teardown)
    bool didMute_ {false};  // whether we actually muted the output
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
      // Cleanup half-allocated members so the destructor doesn't call stopCapture
      // on a stream that never fully started (which can hang SCK internals).
      if (queue_) { dispatch_release(queue_); queue_ = nil; }
      if (delegate_) { [delegate_ release]; delegate_ = nil; }
      if (stream_) { [stream_ release]; stream_ = nil; }
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
      if (queue_) { dispatch_release(queue_); queue_ = nil; }
      if (delegate_) { [delegate_ release]; delegate_ = nil; }
      if (stream_) { [stream_ release]; stream_ = nil; }
      return false;
    }

    if (startErr) {
      const char *m = startErr.localizedDescription.UTF8String;
      BOOST_LOG(error) << "SCK audio: startCapture failed: "sv << (m ? m : "unknown");
      [startErr release];
      if (queue_) { dispatch_release(queue_); queue_ = nil; }
      if (delegate_) { [delegate_ release]; delegate_ = nil; }
      if (stream_) { [stream_ release]; stream_ = nil; }
      return false;
    }

    BOOST_LOG(info) << "SCK audio: capturing system audio ("sv << channels
                    << "ch @ "sv << sample_rate << "Hz)"sv;

    // Mute the system output so the host stays silent during streaming.
    // SCK captures the audio mix before it reaches the output device, so
    // muting the speakers doesn't affect capture. Set SUNSHINE_HOST_AUDIO=1
    // to keep the host audible.
    if (!std::getenv("SUNSHINE_HOST_AUDIO")) {
      muteSystemOutput(true);
    }

    return true;
  }

  void
  sck_system_audio_t::appendSampleBuffer(CMSampleBufferRef sb) {
    // SCK delivers float32 PCM. The layout depends on the format flags:
    //   - NonInterleaved (the common case): AudioBufferList has one
    //     AudioBuffer per channel (mNumberBuffers == channels), each holding
    //     a whole channel's samples: [L0 L1 ... Ln][R0 R1 ... Rn].
    //   - Interleaved (rare): a single AudioBuffer with all channels
    //     interleaved per frame: [L0 R0 L1 R1 ...].
    // Downstream (TPCircularBuffer -> sample() -> Opus multistream) expects
    // INTERLEAVED float32: [L0 R0 L1 R1 ...]. So for the non-interleaved case
    // we must de-planarize here. The old code memcpy'd each channel buffer
    // sequentially, producing [LLLL...RRRR...] which Opus decoded as garbage.
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

    // Determine layout from the format description.
    const AudioStreamBasicDescription *asbd = nullptr;
    CMFormatDescriptionRef fmtDesc = CMSampleBufferGetFormatDescription(sb);
    if (fmtDesc) {
      asbd = CMAudioFormatDescriptionGetStreamBasicDescription(fmtDesc);
    }
    const UInt32 chans = asbd ? asbd->mChannelsPerFrame : abl->mNumberBuffers;
    const bool nonInterleaved = (!asbd || (asbd->mFormatFlags & kAudioFormatFlagIsNonInterleaved)) && abl->mNumberBuffers > 1;
    const OSStatus nFrames = (OSStatus) CMSampleBufferGetNumSamples(sb);

    if (nonInterleaved && chans >= 2 && asbd && (asbd->mFormatFlags & kAudioFormatFlagIsFloat) && asbd->mBitsPerChannel == 32) {
      // Planar float32 -> interleaved float32, one frame at a time.
      for (OSStatus n = 0; n < nFrames; ++n) {
        uint32_t available = 0;
        float *dst = (float *) TPCircularBufferHead(&buf_, &available);
        if (!dst || available < chans * (uint32_t) sizeof(float)) {
          break;  // ring full, drop the rest of this sample buffer
        }
        for (UInt32 c = 0; c < chans; ++c) {
          const float *src = (const float *) abl->mBuffers[c].mData;
          dst[c] = src[n];
        }
        TPCircularBufferProduce(&buf_, chans * (uint32_t) sizeof(float));
      }
    }
    else {
      // Already interleaved (single buffer) or unusual layout: copy as-is.
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
    }
    CFRelease(retainedBB);
  }

  void
  sck_system_audio_t::muteSystemOutput(bool mute) {
    if (mute) {
      // Find the default output device
      AudioObjectPropertyAddress devAddr = {
        kAudioHardwarePropertyDefaultOutputDevice,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain
      };
      UInt32 devSize = sizeof(AudioObjectID);
      AudioObjectID outputDevice = kAudioObjectUnknown;
      OSStatus s = AudioObjectGetPropertyData(kAudioObjectSystemObject, &devAddr, 0, NULL, &devSize, &outputDevice);
      if (s != noErr || outputDevice == kAudioObjectUnknown) {
        BOOST_LOG(warning) << "SCK audio: couldn't find default output device to mute"sv;
        return;
      }

      // Check if the device supports muting
      AudioObjectPropertyAddress muteAddr = {
        kAudioDevicePropertyMute,
        kAudioDevicePropertyScopeOutput,
        kAudioObjectPropertyElementMain
      };
      AudioObjectPropertyAddress isSettableAddr = muteAddr;
      Boolean isSettable = FALSE;
      OSStatus settableStatus = AudioObjectIsPropertySettable(outputDevice, &isSettableAddr, &isSettable);
      if (settableStatus != noErr || !isSettable) {
        BOOST_LOG(info) << "SCK audio: output device doesn't support hardware mute — host will play audio"sv;
        return;
      }

      // Read current mute state (to restore later)
      UInt32 currentMute = 0;
      UInt32 muteSize = sizeof(currentMute);
      s = AudioObjectGetPropertyData(outputDevice, &muteAddr, 0, NULL, &muteSize, &currentMute);
      if (s != noErr) {
        BOOST_LOG(warning) << "SCK audio: couldn't read output mute state"sv;
        return;
      }

      if (currentMute == 0) {
        // Device is currently unmuted — mute it and remember to restore
        UInt32 newMute = 1;
        s = AudioObjectSetPropertyData(outputDevice, &muteAddr, 0, NULL, sizeof(newMute), &newMute);
        if (s == noErr) {
          mutedDeviceID_ = outputDevice;
          didMute_ = true;
          BOOST_LOG(info) << "SCK audio: muted system output (host stays silent during streaming)"sv;
        }
        else {
          BOOST_LOG(warning) << "SCK audio: failed to mute output device"sv;
        }
      }
    }
    else {
      // Restore: unmute the device we muted
      if (didMute_ && mutedDeviceID_ != kAudioObjectUnknown) {
        AudioObjectPropertyAddress muteAddr = {
          kAudioDevicePropertyMute,
          kAudioDevicePropertyScopeOutput,
          kAudioObjectPropertyElementMain
        };
        UInt32 unmute = 0;
        AudioObjectSetPropertyData(mutedDeviceID_, &muteAddr, 0, NULL, sizeof(unmute), &unmute);
        BOOST_LOG(info) << "SCK audio: restored system output (unmuted)"sv;
        didMute_ = false;
        mutedDeviceID_ = kAudioObjectUnknown;
      }
    }
  }

  capture_e
  sck_system_audio_t::sample(std::vector<float> &sample_in) {
    const std::size_t needed = sample_in.size();
    std::size_t have = 0;

    // Overall deadline for this sample() call. SCK may keep delivering frames
    // even after the client disconnects (the system is still playing audio),
    // so the inner "while (have < needed)" loop can run indefinitely if data
    // is always available — it never reaches the semaphore-wait branch and the
    // caller never gets a chance to re-check shutdown_event->peek(). A short
    // deadline (250ms, >> a single Opus frame at 5-20ms) guarantees sample()
    // returns regularly even when the ring is continuously fed, so the caller's
    // shutdown peek stays responsive.
    const auto deadline = std::chrono::steady_clock::now() + std::chrono::milliseconds(250);

    while (have < needed) {
      // If the stream stopped (didStopWithError), request reinit so the caller
      // tears down and recreates the SCStream instead of spinning on timeout.
      if (delegate_->stopped_.load(std::memory_order_acquire)) {
        BOOST_LOG(info) << "SCK audio: stream stopped, requesting reinit"sv;
        return capture_e::reinit;
      }

      // Deadline expired: return what we have so far (padded with silence) so
      // the caller can re-check shutdown. Without this, continuous audio makes
      // this loop run forever and wedges session::join.
      if (std::chrono::steady_clock::now() >= deadline) {
        if (have < needed) {
          std::fill_n(sample_in.data() + have, needed - have, 0.0f);
        }
        return capture_e::ok;
      }

      // Drain any pending SCK sample buffer into the ring buffer.
      if (CMSampleBufferRef sb = [delegate_ takeSample]) {
        appendSampleBuffer(sb);
        CFRelease(sb);
      }

      uint32_t length = 0;
      void *tail = TPCircularBufferTail(&buf_, &length);
      if (!tail || length == 0) {
        // Nothing buffered: wait briefly for the next SCK audio frame. A bounded
        // timeout (1s) keeps the sampling loop responsive to shutdown — the
        // caller's while(!shutdown_event->peek()) only re-checks between sample()
        // calls, so a long wait here delays session teardown and risks the 10s
        // hang deadline. On timeout we surface capture_e::timeout so the caller
        // can loop back and observe shutdown.
        if (dispatch_semaphore_wait(delegate_->frameSignal_,
              dispatch_time(DISPATCH_TIME_NOW, 1 * NSEC_PER_SEC)) != 0) {
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

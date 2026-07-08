/**
 * @file src/platform/macos/mic_write.mm
 * @brief Client microphone redirection to the host's default output on macOS.
 *
 * Pipeline: Opus packet (from client) → opus_decode → float PCM ring buffer →
 * AudioUnit render callback → host speakers.
 *
 * The render callback pulls from the ring buffer; if it underflows, silence is
 * emitted (no blocking — Core Audio callbacks must not block). This keeps the
 * intercom low-latency without risking audio glitches.
 */
#include "src/platform/macos/mic_write.h"

#include "third-party/TPCircularBuffer/TPCircularBuffer.h"

#include "src/logging.h"

#include <AudioUnit/AudioUnit.h>
#include <CoreAudio/CoreAudio.h>

#include <opus/opus.h>

#include <atomic>
#include <cstring>
#include <mutex>
#include <vector>

using namespace std::literals;

namespace platf::audio {

  namespace {
    constexpr int kMicSampleRate = 48000;
    constexpr int kMicChannels = 1;  // client mic stream is mono
  }  // namespace

  struct mic_write_coreaudio_t::impl {
    OpusDecoder *decoder {nullptr};
    AudioComponentInstance au {nullptr};
    TPCircularBuffer ring {};
    std::atomic<bool> running {false};

    ~impl() {
      running = false;
      if (au) {
        AudioOutputUnitStop(au);
        AudioComponentInstanceDispose(au);
        au = nullptr;
      }
      TPCircularBufferCleanup(&ring);
      if (decoder) {
        opus_decoder_destroy(decoder);
        decoder = nullptr;
      }
    }

    // AudioUnit render callback: pull PCM from the ring buffer into
    // ioData. Runs on the realtime audio thread — must not block or allocate.
    static OSStatus
    render(void *inRefCon,
      AudioUnitRenderActionFlags * /*ioActionFlags*/,
      const AudioTimeStamp * /*inTimeStamp*/,
      UInt32 /*inBusNumber*/,
      UInt32 inNumberFrames,
      AudioBufferList *ioData) {
      auto *self = static_cast<impl *>(inRefCon);
      // Teardown guard: once running goes false the destructor is tearing down
      // the ring buffer; emit silence rather than reading freed memory.
      if (!self->running.load(std::memory_order_acquire)) {
        if (ioData && ioData->mNumberBuffers > 0) {
          memset(ioData->mBuffers[0].mData, 0, ioData->mBuffers[0].mDataByteSize);
        }
        return noErr;
      }
      if (!ioData || ioData->mNumberBuffers == 0) {
        return noErr;
      }

      AudioBuffer &buf = ioData->mBuffers[0];
      const auto needed = inNumberFrames * sizeof(float);
      auto *out = (float *) buf.mData;

      uint32_t available = 0;
      void *src = TPCircularBufferTail(&self->ring, &available);

      if (src && available >= needed) {
        memcpy(out, src, needed);
        TPCircularBufferConsume(&self->ring, needed);
      }
      else {
        // Underflow: emit silence (do not block the realtime thread).
        memset(out, 0, buf.mDataByteSize);
      }
      return noErr;
    }
  };

  mic_write_coreaudio_t::mic_write_coreaudio_t():
      p_(std::make_unique<impl>()) {}

  mic_write_coreaudio_t::~mic_write_coreaudio_t() = default;

  int
  mic_write_coreaudio_t::init() {
    int opus_err = 0;
    p_->decoder = opus_decoder_create(kMicSampleRate, kMicChannels, &opus_err);
    if (!p_->decoder || opus_err != OPUS_OK) {
      BOOST_LOG(error) << "mic_write: opus_decoder_create failed: "sv << opus_err;
      return -1;
    }

    if (!TPCircularBufferInit(&p_->ring, kMicSampleRate * kMicChannels * sizeof(float) * 4)) {
      BOOST_LOG(error) << "mic_write: ring buffer init failed"sv;
      return -1;
    }

    // Open the default output AudioUnit.
    AudioComponentDescription desc {};
    desc.componentType = kAudioUnitType_Output;
    desc.componentSubType = kAudioUnitSubType_DefaultOutput;
    desc.componentManufacturer = kAudioUnitManufacturer_Apple;

    AudioComponent comp = AudioComponentFindNext(nullptr, &desc);
    if (!comp) {
      BOOST_LOG(error) << "mic_write: default output AudioComponent not found"sv;
      return -1;
    }

    OSStatus st = AudioComponentInstanceNew(comp, &p_->au);
    if (st != noErr || !p_->au) {
      BOOST_LOG(error) << "mic_write: AudioComponentInstanceNew failed: "sv << st;
      return -1;
    }

    // Configure the stream format: 48kHz, mono, 32-bit float, non-interleaved.
    AudioStreamBasicDescription fmt {};
    fmt.mSampleRate = (Float64) kMicSampleRate;
    fmt.mFormatID = kAudioFormatLinearPCM;
    fmt.mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked;
    fmt.mFramesPerPacket = 1;
    fmt.mChannelsPerFrame = kMicChannels;
    fmt.mBitsPerChannel = 32;
    fmt.mBytesPerFrame = sizeof(float) * kMicChannels;
    fmt.mBytesPerPacket = fmt.mBytesPerFrame;

    st = AudioUnitSetProperty(p_->au, kAudioUnitProperty_StreamFormat,
      kAudioUnitScope_Input, 0, &fmt, sizeof(fmt));
    if (st != noErr) {
      BOOST_LOG(error) << "mic_write: set StreamFormat failed: "sv << st;
      return -1;
    }

    AURenderCallbackStruct cb {};
    cb.inputProc = impl::render;
    cb.inputProcRefCon = p_.get();
    st = AudioUnitSetProperty(p_->au, kAudioUnitProperty_SetRenderCallback,
      kAudioUnitScope_Input, 0, &cb, sizeof(cb));
    if (st != noErr) {
      BOOST_LOG(error) << "mic_write: set RenderCallback failed: "sv << st;
      return -1;
    }

    st = AudioUnitInitialize(p_->au);
    if (st != noErr) {
      BOOST_LOG(error) << "mic_write: AudioUnitInitialize failed: "sv << st;
      return -1;
    }

    // Set running=true BEFORE AudioOutputUnitStart so the render callback (which
    // starts firing the moment we start) sees the flag as true.
    p_->running = true;
    st = AudioOutputUnitStart(p_->au);
    if (st != noErr) {
      p_->running = false;
      BOOST_LOG(error) << "mic_write: AudioOutputUnitStart failed: "sv << st;
      return -1;
    }

    BOOST_LOG(info) << "mic_write: client mic redirect to default output ("sv
                    << kMicSampleRate << "Hz mono)"sv;
    return 0;
  }

  int
  mic_write_coreaudio_t::write_data(const char *data, size_t len, uint16_t /*seq*/) {
    if (!p_->running || !p_->decoder) {
      return -1;
    }

    // Decode into a scratch buffer. Max frame size for Opus at 48kHz mono.
    // opus_decode_float outputs float PCM (matching the AudioUnit format);
    // opus_decode would output int16 and require an extra conversion.
    float pcm[5760];  // 120ms * 48kHz
    int samples = opus_decode_float(p_->decoder,
      (const unsigned char *) data, (opus_int32) len,
      pcm, 5760, 0);
    if (samples < 0) {
      BOOST_LOG(debug) << "mic_write: opus_decode failed: "sv << samples;
      return -1;
    }

    const auto bytes = (uint32_t)(samples * sizeof(float));
    uint32_t available = 0;
    void *dst = TPCircularBufferHead(&p_->ring, &available);
    if (dst && available >= bytes) {
      memcpy(dst, pcm, bytes);
      TPCircularBufferProduce(&p_->ring, bytes);
    }
    // Else: ring full, drop (the realtime callback will catch up).
    return 0;
  }

}  // namespace platf::audio

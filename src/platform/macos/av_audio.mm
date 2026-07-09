/**
 * @file src/platform/macos/av_audio.mm
 * @brief Implementation of macOS audio capture with dual input paths.
 *
 * 1. **Microphone capture** - AVFoundation (specific input device via config::audio.sink)
 * 2. **System-wide audio tap** - Core Audio Process Tap + Aggregate Device (macOS 14.0+)
 *
 * Both paths feed the same TPCircularBuffer / dispatch_semaphore pair consumed by
 * av_mic_t::sample() in microphone.mm.
 *
 * Ported from LizardByte/Sunshine official implementation (PR #2617).
 */
#import "src/platform/macos/av_audio.h"

#include "src/platform/macos/coreaudio_helpers.h"
#include "src/logging.h"

#import <AudioToolbox/AudioConverter.h>
#import <CoreAudio/AudioHardwareBase.h>
#import <CoreAudio/AudioHardwareDeprecated.h>
#import <CoreAudio/AudioHardwareTapping.h>
#import <CoreAudio/CATapDescription.h>

namespace platf {
  using namespace std::literals;

  OSStatus
  audioConverterComplexInputProc(AudioConverterRef inAudioConverter, UInt32 *ioNumberDataPackets, AudioBufferList *ioData, AudioStreamPacketDescription **outDataPacketDescription, void *inUserData) {
    auto *inputInfo = static_cast<AudioConverterInputData *>(inUserData);

    if (inputInfo->framesProvided >= inputInfo->inputFrames) {
      *ioNumberDataPackets = 0;
      return noErr;
    }

    UInt32 framesToProvide = std::min(*ioNumberDataPackets, inputInfo->inputFrames - inputInfo->framesProvided);

    ioData->mNumberBuffers = 1;
    ioData->mBuffers[0].mNumberChannels = inputInfo->deviceChannels;
    ioData->mBuffers[0].mDataByteSize = framesToProvide * inputInfo->deviceChannels * sizeof(float);
    ioData->mBuffers[0].mData = inputInfo->inputData + (inputInfo->framesProvided * inputInfo->deviceChannels);

    inputInfo->framesProvided += framesToProvide;
    *ioNumberDataPackets = framesToProvide;

    return noErr;
  }

  // Process a single AudioBufferList: convert/passthrough into the ring buffer.
  // Returns true if data was written. Used for both input and output scopes.
  static bool
  processAudioBufferList(const AudioBufferList *bufList, AVAudioIOProcData *procData) {
    if (!bufList || bufList->mNumberBuffers == 0) {
      return false;
    }

    AudioBuffer buffer = bufList->mBuffers[0];
    if (!buffer.mData || buffer.mDataByteSize == 0) {
      return false;
    }

    UInt32 clientChannels = procData->clientRequestedChannels;
    UInt32 deviceChannels = procData->aggregateDeviceChannels;
    if (deviceChannels == 0) {
      deviceChannels = clientChannels;
    }
    if (deviceChannels == 0) {
      return false;
    }

    AVAudio *avAudio = procData->avAudio;
    auto *inputSamples = static_cast<float *>(buffer.mData);
    UInt32 inputFrames = buffer.mDataByteSize / (deviceChannels * sizeof(float));

    if (procData->audioConverter) {
      UInt32 maxOutputFrames = procData->conversionBufferSize / (clientChannels * sizeof(float));
      UInt32 requestedOutputFrames = maxOutputFrames;

      AudioConverterInputData inputData = { 0 };
      inputData.inputData = inputSamples;
      inputData.inputFrames = inputFrames;
      inputData.framesProvided = 0;
      inputData.deviceChannels = deviceChannels;
      inputData.avAudio = avAudio;

      AudioBufferList outputBufferList = { 0 };
      outputBufferList.mNumberBuffers = 1;
      outputBufferList.mBuffers[0].mNumberChannels = clientChannels;
      outputBufferList.mBuffers[0].mDataByteSize = procData->conversionBufferSize;
      outputBufferList.mBuffers[0].mData = procData->conversionBuffer;

      UInt32 outputFrameCount = requestedOutputFrames;
      OSStatus converterStatus = AudioConverterFillComplexBuffer(
        procData->audioConverter,
        audioConverterComplexInputProc,
        &inputData,
        &outputFrameCount,
        &outputBufferList,
        nullptr);

      if (converterStatus == noErr && outputFrameCount > 0) {
        UInt32 actualOutputBytes = outputFrameCount * clientChannels * sizeof(float);
        TPCircularBufferProduceBytes(&avAudio->audioSampleBuffer, procData->conversionBuffer, actualOutputBytes);
        return true;
      }
      // Fallback: write raw data
      TPCircularBufferProduceBytes(&avAudio->audioSampleBuffer, buffer.mData, buffer.mDataByteSize);
      return true;
    }

    // No conversion needed — direct passthrough
    TPCircularBufferProduceBytes(&avAudio->audioSampleBuffer, buffer.mData, buffer.mDataByteSize);
    return true;
  }

  OSStatus
  systemAudioIOProc(AudioObjectID inDevice, const AudioTimeStamp *inNow, const AudioBufferList *inInputData, const AudioTimeStamp *inInputTime, AudioBufferList *outOutputData, const AudioTimeStamp *inOutputTime, void *inClientData) {
    auto *procData = static_cast<AVAudioIOProcData *>(inClientData);
    if (!procData || !procData->avAudio) {
      return noErr;
    }

    UInt32 clientChannels = procData->clientRequestedChannels;
    UInt32 clientFrameSize = procData->clientRequestedFrameSize;
    AVAudio *avAudio = procData->avAudio;
    if (clientChannels == 0) {
      // Invalid configuration; avoid divide-by-zero in silence path.
      return noErr;
    }

    // Try input scope first (Core Audio Tap delivers here), then output scope
    // (virtual loopback devices like BlackHole mirror output data here).
    bool didWriteData = processAudioBufferList(inInputData, procData);
    if (!didWriteData) {
      didWriteData = processAudioBufferList(outOutputData, procData);
    }

    if (!didWriteData) {
      UInt32 silenceFrames = clientFrameSize > 0 ? std::min(clientFrameSize, 2048U) : 512U;

      if (procData->conversionBuffer && procData->conversionBufferSize > 0) {
        UInt32 maxSilenceFrames = procData->conversionBufferSize / (clientChannels * sizeof(float));
        silenceFrames = std::min(silenceFrames, maxSilenceFrames);
        UInt32 silenceBytes = silenceFrames * clientChannels * sizeof(float);
        memset(procData->conversionBuffer, 0, silenceBytes);
        TPCircularBufferProduceBytes(&avAudio->audioSampleBuffer, procData->conversionBuffer, silenceBytes);
      }
      else {
        float silenceBuffer[512 * 8] = { 0 };
        UInt32 maxStackFrames = sizeof(silenceBuffer) / (clientChannels * sizeof(float));
        silenceFrames = std::min(silenceFrames, maxStackFrames);
        UInt32 silenceBytes = silenceFrames * clientChannels * sizeof(float);
        TPCircularBufferProduceBytes(&avAudio->audioSampleBuffer, silenceBuffer, silenceBytes);
      }
    }

    dispatch_semaphore_signal(avAudio->audioSemaphore);
    return noErr;
  }
}  // namespace platf

@implementation AVAudio

+ (NSArray<AVCaptureDevice *> *)microphones {
  using namespace std::literals;
  BOOST_LOG(debug) << "Discovering microphones"sv;

  if ([[NSProcessInfo processInfo] isOperatingSystemAtLeastVersion:((NSOperatingSystemVersion) { 10, 15, 0 })]) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wunguarded-availability-new"
    AVCaptureDeviceDiscoverySession *discoverySession = [AVCaptureDeviceDiscoverySession discoverySessionWithDeviceTypes: @[ AVCaptureDeviceTypeMicrophone, AVCaptureDeviceTypeExternal ]
                                                                                                                mediaType: AVMediaTypeAudio
                                                                                                                 position: AVCaptureDevicePositionUnspecified];
    NSArray *devices = discoverySession.devices;
    return devices;
#pragma clang diagnostic pop
  }
  else {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    NSArray *devices = [AVCaptureDevice devicesWithMediaType: AVMediaTypeAudio];
    return devices;
#pragma clang diagnostic pop
  }
}

+ (NSArray<NSString *> *)microphoneNames {
  using namespace std::literals;
  NSMutableArray *result = [NSMutableArray array];

  for (AVCaptureDevice *device in [AVAudio microphones]) {
    [result addObject: [device localizedName]];
  }

  BOOST_LOG(info) << "Found "sv << [result count] << " microphones"sv;
  return result;
}

+ (AVCaptureDevice *)findMicrophone:(NSString *)name {
  using namespace std::literals;

  if (name == nil) {
    BOOST_LOG(warning) << "Microphone not found: (nil)"sv;
    return nil;
  }

  for (AVCaptureDevice *device in [AVAudio microphones]) {
    if ([[device localizedName] isEqualToString: name]) {
      return device;
    }
  }

  BOOST_LOG(warning) << "Microphone not found: "sv << [name UTF8String];
  return nil;
}

+ (AudioObjectID)findInputDeviceByName:(NSString *)name {
  using namespace std::literals;

  if (!name) {
    return kAudioObjectUnknown;
  }

  AudioObjectPropertyAddress propertyAddress = {
    .mSelector = kAudioHardwarePropertyDevices,
    .mScope = kAudioObjectPropertyScopeGlobal,
    .mElement = kAudioObjectPropertyElementMain
  };

  UInt32 dataSize = 0;
  OSStatus status = AudioObjectGetPropertyDataSize(kAudioObjectSystemObject, &propertyAddress, 0, NULL, &dataSize);
  if (status != noErr || dataSize == 0) {
    return kAudioObjectUnknown;
  }

  UInt32 deviceCount = dataSize / sizeof(AudioObjectID);
  AudioObjectID *deviceIDs = (AudioObjectID *) malloc(dataSize);
  if (!deviceIDs) {
    return kAudioObjectUnknown;
  }

  status = AudioObjectGetPropertyData(kAudioObjectSystemObject, &propertyAddress, 0, NULL, &dataSize, deviceIDs);
  if (status != noErr) {
    free(deviceIDs);
    return kAudioObjectUnknown;
  }

  AudioObjectID foundID = kAudioObjectUnknown;
  for (UInt32 i = 0; i < deviceCount; i++) {
    // Check if this device has input streams
    AudioObjectPropertyAddress inputAddr = {
      .mSelector = kAudioDevicePropertyStreamConfiguration,
      .mScope = kAudioDevicePropertyScopeInput,
      .mElement = kAudioObjectPropertyElementMain
    };
    UInt32 inputSize = 0;
    AudioObjectGetPropertyDataSize(deviceIDs[i], &inputAddr, 0, NULL, &inputSize);
    if (inputSize == 0) {
      continue;  // not an input device
    }

    // Get device name (CFString variant — returns a retained CFStringRef)
    AudioObjectPropertyAddress nameAddr = {
      .mSelector = kAudioDevicePropertyDeviceNameCFString,
      .mScope = kAudioObjectPropertyScopeGlobal,
      .mElement = kAudioObjectPropertyElementMain
    };
    CFStringRef deviceName = NULL;
    UInt32 nameSize = sizeof(deviceName);
    OSStatus nameStatus = AudioObjectGetPropertyData(deviceIDs[i], &nameAddr, 0, NULL, &nameSize, &deviceName);

    if (nameStatus == noErr && deviceName) {
      BOOL match = [name isEqualToString: (__bridge NSString *) deviceName];
      CFRelease(deviceName);
      if (match) {
        foundID = deviceIDs[i];
        break;
      }
    }
  }

  free(deviceIDs);
  return foundID;
}

- (int)setupDeviceCapture:(AudioObjectID)deviceID sampleRate:(UInt32)sampleRate frameSize:(UInt32)frameSize channels:(UInt8)channels {
  using namespace std::literals;

  if (deviceID == kAudioObjectUnknown) {
    BOOST_LOG(error) << "Cannot setup device capture: invalid device ID"sv;
    return -1;
  }

  // Get device name for logging (CFString variant)
  AudioObjectPropertyAddress nameAddr = {
    .mSelector = kAudioDevicePropertyDeviceNameCFString,
    .mScope = kAudioObjectPropertyScopeGlobal,
    .mElement = kAudioObjectPropertyElementMain
  };
  CFStringRef deviceName = NULL;
  UInt32 nameSize = sizeof(deviceName);
  OSStatus nameStatus = AudioObjectGetPropertyData(deviceID, &nameAddr, 0, NULL, &nameSize, &deviceName);
  if (nameStatus == noErr && deviceName) {
    BOOST_LOG(info) << "Setting up Core Audio device capture: "sv << [(__bridge NSString *) deviceName UTF8String];
    CFRelease(deviceName);
  }

  // Query actual device sample rate and channel count
  Float64 deviceSampleRate = (Float64) sampleRate;
  UInt32 sampleRateSize = sizeof(Float64);
  AudioObjectPropertyAddress sampleRateAddr = {
    .mSelector = kAudioDevicePropertyNominalSampleRate,
    .mScope = kAudioObjectPropertyScopeGlobal,
    .mElement = kAudioObjectPropertyElementMain
  };
  OSStatus rateStatus = AudioObjectGetPropertyData(deviceID, &sampleRateAddr, 0, NULL, &sampleRateSize, &deviceSampleRate);
  if (rateStatus != noErr || deviceSampleRate <= 0.0) {
    deviceSampleRate = (Float64) sampleRate;
  }
  BOOST_LOG(debug) << "Device sample rate: "sv << deviceSampleRate << "Hz (requested "sv << sampleRate << "Hz)"sv;

  UInt32 deviceChannels = 0;
  // Query input scope first (BlackHole mirrors output to its input).
  AudioObjectPropertyAddress streamConfigAddr = {
    .mSelector = kAudioDevicePropertyStreamConfiguration,
    .mScope = kAudioDevicePropertyScopeInput,
    .mElement = kAudioObjectPropertyElementMain
  };
  UInt32 streamConfigSize = 0;
  AudioObjectGetPropertyDataSize(deviceID, &streamConfigAddr, 0, NULL, &streamConfigSize);
  if (streamConfigSize > 0) {
    AudioBufferList *streamConfig = (AudioBufferList *) malloc(streamConfigSize);
    if (streamConfig) {
      AudioObjectGetPropertyData(deviceID, &streamConfigAddr, 0, NULL, &streamConfigSize, streamConfig);
      if (streamConfig->mNumberBuffers > 0) {
        deviceChannels = streamConfig->mBuffers[0].mNumberChannels;
      }
      free(streamConfig);
    }
  }
  // If input scope returned 0 channels, try output scope (some virtual devices
  // expose their format only on the output side).
  if (deviceChannels == 0) {
    streamConfigAddr.mScope = kAudioDevicePropertyScopeOutput;
    streamConfigSize = 0;
    AudioObjectGetPropertyDataSize(deviceID, &streamConfigAddr, 0, NULL, &streamConfigSize);
    if (streamConfigSize > 0) {
      AudioBufferList *streamConfig = (AudioBufferList *) malloc(streamConfigSize);
      if (streamConfig) {
        AudioObjectGetPropertyData(deviceID, &streamConfigAddr, 0, NULL, &streamConfigSize, streamConfig);
        if (streamConfig->mNumberBuffers > 0) {
          deviceChannels = streamConfig->mBuffers[0].mNumberChannels;
        }
        free(streamConfig);
      }
    }
  }
  if (deviceChannels == 0) {
    deviceChannels = channels;  // final fallback
  }
  BOOST_LOG(debug) << "Device channels: "sv << deviceChannels << " (requested "sv << (int) channels << ")"sv;

  // Set up format conversion if needed
  BOOL needsConversion = (deviceSampleRate != (Float64) sampleRate) || (deviceChannels != (UInt32) channels);

  // Allocate ioProcData
  self->ioProcData = (AVAudioIOProcData *) malloc(sizeof(AVAudioIOProcData));
  if (!self->ioProcData) {
    return -1;
  }
  self->ioProcData->avAudio = self;
  self->ioProcData->clientRequestedChannels = channels;
  self->ioProcData->clientRequestedFrameSize = frameSize;
  self->ioProcData->clientRequestedSampleRate = sampleRate;
  self->ioProcData->aggregateDeviceSampleRate = (UInt32) deviceSampleRate;
  self->ioProcData->aggregateDeviceChannels = deviceChannels;
  self->ioProcData->audioConverter = NULL;
  self->ioProcData->conversionBuffer = NULL;
  self->ioProcData->conversionBufferSize = 0;

  if (needsConversion) {
    AudioStreamBasicDescription sourceFormat = { 0 };
    sourceFormat.mSampleRate = deviceSampleRate;
    sourceFormat.mFormatID = kAudioFormatLinearPCM;
    sourceFormat.mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked;
    sourceFormat.mBytesPerPacket = sizeof(float) * deviceChannels;
    sourceFormat.mFramesPerPacket = 1;
    sourceFormat.mBytesPerFrame = sizeof(float) * deviceChannels;
    sourceFormat.mChannelsPerFrame = deviceChannels;
    sourceFormat.mBitsPerChannel = 32;

    AudioStreamBasicDescription targetFormat = { 0 };
    targetFormat.mSampleRate = (Float64) sampleRate;
    targetFormat.mFormatID = kAudioFormatLinearPCM;
    targetFormat.mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked;
    targetFormat.mBytesPerPacket = sizeof(float) * channels;
    targetFormat.mFramesPerPacket = 1;
    targetFormat.mBytesPerFrame = sizeof(float) * channels;
    targetFormat.mChannelsPerFrame = channels;
    targetFormat.mBitsPerChannel = 32;

    AudioConverterNew(&sourceFormat, &targetFormat, &self->ioProcData->audioConverter);
  }

  // Pre-allocate conversion buffer
  UInt32 maxFrames = frameSize * 8;
  self->ioProcData->conversionBufferSize = maxFrames * channels * sizeof(float);
  self->ioProcData->conversionBuffer = (float *) malloc(self->ioProcData->conversionBufferSize);
  if (!self->ioProcData->conversionBuffer) {
    BOOST_LOG(error) << "Failed to allocate conversion buffer"sv;
    return -1;
  }

  // Initialize the ring buffer + semaphore
  [self initializeAudioBuffer: channels];

  // Create and start the IOProc on this device
  self->captureDeviceID = deviceID;  // IOProc registered on this device
  self->captureDeviceIsAggregate = false;  // BlackHole is a pre-existing device, NOT an aggregate — do not destroy it
  self->tapObjectID = kAudioObjectUnknown;
  self->ioProcID = NULL;

  OSStatus status = AudioDeviceCreateIOProcID(deviceID, platf::systemAudioIOProc, self->ioProcData, &self->ioProcID);
  if (status != kAudioHardwareNoError) {
    BOOST_LOG(error) << "AudioDeviceCreateIOProcID failed: "sv << ca::Status(status);
    return -1;
  }

  status = AudioDeviceStart(deviceID, self->ioProcID);
  if (status != kAudioHardwareNoError) {
    BOOST_LOG(error) << "AudioDeviceStart failed: "sv << ca::Status(status);
    AudioDeviceDestroyIOProcID(deviceID, self->ioProcID);
    self->ioProcID = NULL;
    return -1;
  }

  BOOST_LOG(info) << "Core Audio device capture started successfully"sv;
  return 0;
}

- (int)setupMicrophone:(AVCaptureDevice *)device sampleRate:(UInt32)sampleRate frameSize:(UInt32)frameSize channels:(UInt8)channels {
  using namespace std::literals;

  if (device == nil) {
    BOOST_LOG(error) << "Cannot setup microphone: device is nil"sv;
    return -1;
  }

  BOOST_LOG(info) << "Setting up microphone: "sv << [[device localizedName] UTF8String] << " with "sv << sampleRate << "Hz"sv;

  self.audioCaptureSession = [[AVCaptureSession alloc] init];

  NSError *nsError;
  AVCaptureDeviceInput *audioInput = [AVCaptureDeviceInput deviceInputWithDevice: device error: &nsError];
  if (audioInput == nil) {
    BOOST_LOG(error) << "Failed to create audio input: "sv << (nsError ? [[nsError localizedDescription] UTF8String] : "unknown"sv);
    return -1;
  }

  if ([self.audioCaptureSession canAddInput: audioInput]) {
    [self.audioCaptureSession addInput: audioInput];
  }
  else {
    BOOST_LOG(error) << "Cannot add audio input"sv;
    [audioInput release];
    return -1;
  }

  AVCaptureAudioDataOutput *audioOutput = [[AVCaptureAudioDataOutput alloc] init];

  [audioOutput setAudioSettings: @{
    (NSString *) AVFormatIDKey: [NSNumber numberWithUnsignedInt: kAudioFormatLinearPCM],
    (NSString *) AVSampleRateKey: [NSNumber numberWithUnsignedInt: sampleRate],
    (NSString *) AVNumberOfChannelsKey: [NSNumber numberWithUnsignedInt: channels],
    (NSString *) AVLinearPCMBitDepthKey: [NSNumber numberWithUnsignedInt: 32],
    (NSString *) AVLinearPCMIsFloatKey: @YES,
    (NSString *) AVLinearPCMIsNonInterleaved: @NO
  }];

  dispatch_queue_attr_t qos = dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_USER_INITIATED, DISPATCH_QUEUE_PRIORITY_HIGH);
  dispatch_queue_t recordingQueue = dispatch_queue_create("audioSamplingQueue", qos);
  [audioOutput setSampleBufferDelegate: self queue: recordingQueue];

  if ([self.audioCaptureSession canAddOutput: audioOutput]) {
    [self.audioCaptureSession addOutput: audioOutput];
  }
  else {
    [audioInput release];
    [audioOutput release];
    return -1;
  }

  self.audioConnection = [audioOutput connectionWithMediaType: AVMediaTypeAudio];

  [self initializeAudioBuffer: channels];

  [self.audioCaptureSession startRunning];
  BOOST_LOG(info) << "Audio capture session started"sv;

  [audioInput release];
  [audioOutput release];
  return 0;
}

- (void)captureOutput:(AVCaptureOutput *)output
  didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer
         fromConnection:(AVCaptureConnection *)connection {
  if (connection == self.audioConnection) {
    AudioBufferList audioBufferList;
    CMBlockBufferRef blockBuffer = NULL;

    OSStatus st = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(sampleBuffer, NULL, &audioBufferList, sizeof(audioBufferList), NULL, NULL, 0, &blockBuffer);
    if (st != noErr || audioBufferList.mNumberBuffers == 0 || !blockBuffer) {
      if (blockBuffer) CFRelease(blockBuffer);
      return;
    }

    AudioBuffer audioBuffer = audioBufferList.mBuffers[0];
    if (audioBuffer.mData && audioBuffer.mDataByteSize > 0) {
      TPCircularBufferProduceBytes(&self->audioSampleBuffer, audioBuffer.mData, audioBuffer.mDataByteSize);
      dispatch_semaphore_signal(self->audioSemaphore);
    }
    CFRelease(blockBuffer);  // ProduceBytes copies data, safe to release
  }
}

- (int)setupSystemTap:(UInt32)sampleRate frameSize:(UInt32)frameSize channels:(UInt8)channels {
  using namespace std::literals;
  BOOST_LOG(info) << "Setting up Core Audio system tap: "sv << sampleRate << "Hz, "sv << (int) channels << "ch, frameSize="sv << frameSize;

  if ([self initializeSystemTapContext: sampleRate frameSize: frameSize channels: channels] != 0) {
    return -1;
  }

  CATapDescription *tapDescription = [self createSystemTapDescriptionForChannels: channels];
  if (!tapDescription) {
    [self cleanupSystemTapContext: nil];
    return -1;
  }

  OSStatus aggregateStatus = [self createAggregateDeviceWithTapDescription: tapDescription sampleRate: sampleRate frameSize: frameSize];
  if (aggregateStatus != noErr) {
    [self cleanupSystemTapContext: tapDescription];
    return -1;
  }

  OSStatus configureStatus = [self configureDevicePropertiesAndConverter: sampleRate clientChannels: channels];
  if (configureStatus != noErr) {
    [self cleanupSystemTapContext: tapDescription];
    return -1;
  }

  [self initializeAudioBuffer: channels];

  OSStatus ioProcStatus = [self createAndStartAggregateDeviceIOProc: tapDescription];
  if (ioProcStatus != noErr) {
    [self cleanupSystemTapContext: tapDescription];
    return -1;
  }

  [tapDescription release];

  BOOST_LOG(info) << "Core Audio system tap started successfully"sv;
  return 0;
}

- (OSStatus)getDeviceProperty:(AudioObjectID)deviceID
                     selector:(AudioObjectPropertySelector)selector
                        scope:(AudioObjectPropertyScope)scope
                      element:(AudioObjectPropertyElement)element
                         size:(UInt32 *)ioDataSize
                         data:(void *)outData {
  AudioObjectPropertyAddress addr = {
    .mSelector = selector,
    .mScope = scope,
    .mElement = element
  };

  return AudioObjectGetPropertyData(deviceID, &addr, 0, NULL, ioDataSize, outData);
}

- (void)cleanupSystemTapContext:(id)tapDescription {
  using namespace std::literals;

  if (self->ioProcID && self->captureDeviceID != kAudioObjectUnknown) {
    AudioDeviceStop(self->captureDeviceID, self->ioProcID);
    AudioDeviceDestroyIOProcID(self->captureDeviceID, self->ioProcID);
    self->ioProcID = NULL;
  }

  // Only destroy the aggregate device if we created it (Tap path).
  // For BlackHole/device-capture path, captureDeviceID is a pre-existing system
  // device — calling AudioHardwareDestroyAggregateDevice on it would corrupt
  // Core Audio state and may crash.
  if (self->captureDeviceIsAggregate && self->captureDeviceID != kAudioObjectUnknown) {
    AudioHardwareDestroyAggregateDevice(self->captureDeviceID);
  }
  self->captureDeviceID = kAudioObjectUnknown;
  self->captureDeviceIsAggregate = false;

  if (self->tapObjectID != kAudioObjectUnknown) {
    AudioHardwareDestroyProcessTap(self->tapObjectID);
    self->tapObjectID = kAudioObjectUnknown;
  }

  if (self->ioProcData) {
    if (self->ioProcData->conversionBuffer) {
      free(self->ioProcData->conversionBuffer);
      self->ioProcData->conversionBuffer = NULL;
    }
    if (self->ioProcData->audioConverter) {
      AudioConverterDispose(self->ioProcData->audioConverter);
      self->ioProcData->audioConverter = NULL;
    }
    free(self->ioProcData);
    self->ioProcData = NULL;
  }

  if (tapDescription) {
    [tapDescription release];
  }
}

- (void)initializeAudioBuffer:(UInt8)channels {
  TPCircularBufferCleanup(&self->audioSampleBuffer);

  // 30ms buffer (6 packets of 240 samples)
  int ringBufferSize = 6 * 240 * channels * sizeof(float);
  TPCircularBufferInit(&self->audioSampleBuffer, ringBufferSize);

  if (self->audioSemaphore) {
    dispatch_release(self->audioSemaphore);
  }
  self->audioSemaphore = dispatch_semaphore_create(0);
}

- (void)cleanupAudioBuffer {
  if (self->audioSemaphore) {
    dispatch_semaphore_signal(self->audioSemaphore);
    dispatch_release(self->audioSemaphore);
    self->audioSemaphore = NULL;
  }
  TPCircularBufferCleanup(&self->audioSampleBuffer);
}

- (void)dealloc {
  [self cleanupSystemTapContext: nil];

  if (self.audioCaptureSession) {
    [self.audioCaptureSession stopRunning];
    self.audioCaptureSession = nil;
  }
  self.audioConnection = nil;

  [self cleanupAudioBuffer];
  [super dealloc];
}

// MARK: - System Tap private methods

- (int)initializeSystemTapContext:(UInt32)sampleRate frameSize:(UInt32)frameSize channels:(UInt8)channels {
  using namespace std::literals;

  if (![[NSProcessInfo processInfo] isOperatingSystemAtLeastVersion:((NSOperatingSystemVersion) { 14, 0, 0 })]) {
    BOOST_LOG(error) << "macOS version requirement not met for Core Audio Tap (need 14.0+)"sv;
    return -1;
  }

  self->tapObjectID = kAudioObjectUnknown;
  self->captureDeviceID = kAudioObjectUnknown;
  self->captureDeviceIsAggregate = false;
  self->ioProcID = NULL;

  self->ioProcData = (AVAudioIOProcData *) malloc(sizeof(AVAudioIOProcData));
  if (!self->ioProcData) {
    return -1;
  }

  self->ioProcData->avAudio = self;
  self->ioProcData->clientRequestedChannels = channels;
  self->ioProcData->clientRequestedFrameSize = frameSize;
  self->ioProcData->clientRequestedSampleRate = sampleRate;
  self->ioProcData->audioConverter = NULL;
  self->ioProcData->conversionBuffer = NULL;
  self->ioProcData->conversionBufferSize = 0;

  return 0;
}

- (CATapDescription *)createSystemTapDescriptionForChannels:(UInt8)channels {
  using namespace std::literals;

  NSArray *excludeProcesses = @[];
  CATapDescription *tapDescription = [[CATapDescription alloc] initStereoGlobalTapButExcludeProcesses: excludeProcesses];

  NSString *uniqueName = [NSString stringWithFormat: @"SunshineAVAudio-Tap-%p", (void *) self];
  NSUUID *uniqueUUID = [[NSUUID alloc] init];
  tapDescription.name = uniqueName;
  tapDescription.UUID = uniqueUUID;

  if (std::getenv("SUNSHINE_PUBLIC_AUDIO_TAP")) {
    [tapDescription setPrivate: NO];
  }
  else {
    [tapDescription setPrivate: YES];
  }

  if (self.hostAudioEnabled) {
    tapDescription.muteBehavior = CATapUnmuted;
  }
  else {
    tapDescription.muteBehavior = CATapMuted;
  }

  OSStatus status = AudioHardwareCreateProcessTap(tapDescription, &self->tapObjectID);

  [uniqueUUID release];

  if (status != noErr) {
    BOOST_LOG(error) << "AudioHardwareCreateProcessTap failed: "sv << ca::Status(status);
    [tapDescription release];
    return nil;
  }

  return tapDescription;
}

- (OSStatus)createAggregateDeviceWithTapDescription:(CATapDescription *)tapDescription sampleRate:(UInt32)sampleRate frameSize:(UInt32)frameSize {
  using namespace std::literals;

  NSString *tapUIDString = nil;
  if ([tapDescription respondsToSelector: @selector(UUID)]) {
    tapUIDString = [[tapDescription UUID] UUIDString];
  }
  if (!tapUIDString) {
    return kAudioHardwareUnspecifiedError;
  }

  NSDictionary *subTapDictionary = @{
    @kAudioSubTapUIDKey: tapUIDString,
    @kAudioSubTapDriftCompensationKey: @YES,
  };

  NSDictionary *aggregateProperties = @{
    @kAudioAggregateDeviceNameKey: [NSString stringWithFormat: @"SunshineAggregate-%p", (void *) self],
    @kAudioAggregateDeviceUIDKey: [NSString stringWithFormat: @"com.sunshine.aggregate-%p", (void *) self],
    @kAudioAggregateDeviceTapListKey: @[subTapDictionary],
    @kAudioAggregateDeviceTapAutoStartKey: @NO,
    @kAudioAggregateDeviceIsPrivateKey: std::getenv("SUNSHINE_PUBLIC_AUDIO_TAP") ? @NO : @YES,
  };

  OSStatus status = AudioHardwareCreateAggregateDevice((CFDictionaryRef) aggregateProperties, &self->captureDeviceID);
  if (status != noErr && status != 'ExtA') {
    BOOST_LOG(error) << "AudioHardwareCreateAggregateDevice failed: "sv << ca::Status(status);
    return status;
  }
  self->captureDeviceIsAggregate = true;  // Mark for cleanup — must destroy this aggregate on teardown

  if (self->captureDeviceID != kAudioObjectUnknown) {
    AudioObjectPropertyAddress sampleRateAddr = {
      .mSelector = kAudioDevicePropertyNominalSampleRate,
      .mScope = kAudioObjectPropertyScopeGlobal,
      .mElement = kAudioObjectPropertyElementMain
    };
    Float64 deviceSampleRate = (Float64) sampleRate;
    AudioObjectSetPropertyData(self->captureDeviceID, &sampleRateAddr, 0, NULL, sizeof(Float64), &deviceSampleRate);

    AudioObjectPropertyAddress bufferSizeAddr = {
      .mSelector = kAudioDevicePropertyBufferFrameSize,
      .mScope = kAudioObjectPropertyScopeGlobal,
      .mElement = kAudioObjectPropertyElementMain
    };
    UInt32 deviceFrameSize = frameSize;
    AudioObjectSetPropertyData(self->captureDeviceID, &bufferSizeAddr, 0, NULL, sizeof(UInt32), &deviceFrameSize);
  }

  return noErr;
}

- (OSStatus)configureDevicePropertiesAndConverter:(UInt32)clientSampleRate
                                    clientChannels:(UInt8)clientChannels {
  using namespace std::literals;

  Float64 aggregateDeviceSampleRate = (Float64) clientSampleRate;
  UInt32 aggregateDeviceChannels = clientChannels;

  UInt32 sampleRateQuerySize = sizeof(Float64);
  OSStatus sampleRateStatus = [self getDeviceProperty: self->captureDeviceID
                                            selector: kAudioDevicePropertyNominalSampleRate
                                               scope: kAudioObjectPropertyScopeGlobal
                                             element: kAudioObjectPropertyElementMain
                                                size: &sampleRateQuerySize
                                                data: &aggregateDeviceSampleRate];
  if (sampleRateStatus != noErr || aggregateDeviceSampleRate <= 0.0) {
    aggregateDeviceSampleRate = (Float64) clientSampleRate;
  }

  AudioObjectPropertyAddress streamConfigAddr = {
    .mSelector = kAudioDevicePropertyStreamConfiguration,
    .mScope = kAudioDevicePropertyScopeInput,
    .mElement = kAudioObjectPropertyElementMain
  };

  UInt32 streamConfigSize = 0;
  OSStatus scStat = AudioObjectGetPropertyDataSize(self->captureDeviceID, &streamConfigAddr, 0, NULL, &streamConfigSize);

  if (scStat == noErr && streamConfigSize > 0) {
    AudioBufferList *streamConfig = (AudioBufferList *) malloc(streamConfigSize);
    if (streamConfig) {
      AudioObjectGetPropertyData(self->captureDeviceID, &streamConfigAddr, 0, NULL, &streamConfigSize, streamConfig);
      if (streamConfig->mNumberBuffers > 0) {
        aggregateDeviceChannels = streamConfig->mBuffers[0].mNumberChannels;
      }
      free(streamConfig);
    }
  }

  BOOL needsConversion = (aggregateDeviceSampleRate != clientSampleRate) || (aggregateDeviceChannels != clientChannels);

  if (needsConversion) {
    AudioStreamBasicDescription sourceFormat = { 0 };
    sourceFormat.mSampleRate = (Float64) aggregateDeviceSampleRate;
    sourceFormat.mFormatID = kAudioFormatLinearPCM;
    sourceFormat.mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked;
    sourceFormat.mBytesPerPacket = sizeof(float) * aggregateDeviceChannels;
    sourceFormat.mFramesPerPacket = 1;
    sourceFormat.mBytesPerFrame = sizeof(float) * aggregateDeviceChannels;
    sourceFormat.mChannelsPerFrame = aggregateDeviceChannels;
    sourceFormat.mBitsPerChannel = 32;

    AudioStreamBasicDescription targetFormat = { 0 };
    targetFormat.mSampleRate = (Float64) clientSampleRate;
    targetFormat.mFormatID = kAudioFormatLinearPCM;
    targetFormat.mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked;
    targetFormat.mBytesPerPacket = sizeof(float) * clientChannels;
    targetFormat.mFramesPerPacket = 1;
    targetFormat.mBytesPerFrame = sizeof(float) * clientChannels;
    targetFormat.mChannelsPerFrame = clientChannels;
    targetFormat.mBitsPerChannel = 32;

    OSStatus converterStatus = AudioConverterNew(&sourceFormat, &targetFormat, &self->ioProcData->audioConverter);
    if (converterStatus != noErr) {
      BOOST_LOG(error) << "AudioConverterNew failed: "sv << ca::Status(converterStatus);
      return converterStatus;
    }
  }

  UInt32 maxFrames = self->ioProcData->clientRequestedFrameSize * 8;
  self->ioProcData->conversionBufferSize = maxFrames * clientChannels * sizeof(float);
  self->ioProcData->conversionBuffer = (float *) malloc(self->ioProcData->conversionBufferSize);

  if (!self->ioProcData->conversionBuffer) {
    if (self->ioProcData->audioConverter) {
      AudioConverterDispose(self->ioProcData->audioConverter);
      self->ioProcData->audioConverter = NULL;
    }
    return kAudioHardwareUnspecifiedError;
  }

  self->ioProcData->aggregateDeviceSampleRate = aggregateDeviceSampleRate;
  self->ioProcData->aggregateDeviceChannels = aggregateDeviceChannels;

  return noErr;
}

- (OSStatus)createAndStartAggregateDeviceIOProc:(CATapDescription *)tapDescription {
  using namespace std::literals;

  OSStatus status = AudioDeviceCreateIOProcID(self->captureDeviceID, platf::systemAudioIOProc, self->ioProcData, &self->ioProcID);
  if (status != kAudioHardwareNoError) {
    BOOST_LOG(error) << "AudioDeviceCreateIOProcID failed: "sv << ca::Status(status);
    return status;
  }

  status = AudioDeviceStart(self->captureDeviceID, self->ioProcID);
  if (status != kAudioHardwareNoError) {
    BOOST_LOG(error) << "AudioDeviceStart failed: "sv << ca::Status(status);
    AudioDeviceDestroyIOProcID(self->captureDeviceID, self->ioProcID);
    return status;
  }

  return noErr;
}

@end

/**
 * @file src/platform/macos/av_audio.h
 * @brief Declarations for macOS audio capture with dual input paths.
 *
 * This header defines the AVAudio class which provides distinct audio capture methods:
 * 1. **Microphone capture** - Uses AVFoundation framework to capture from specific microphone devices
 * 2. **System-wide audio tap** - Uses Core Audio taps to capture all system audio output (macOS 14.0+)
 *
 * The system-wide audio tap allows capturing audio from all applications and system sounds,
 * while microphone capture focuses on input from physical or virtual microphone devices.
 */
#pragma once

// platform includes
#import <AudioToolbox/AudioToolbox.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreAudio/CoreAudio.h>

// lib includes
#include "third-party/TPCircularBuffer/TPCircularBuffer.h"

#include <dispatch/dispatch.h>

NS_ASSUME_NONNULL_BEGIN

// Forward declarations
@class AVAudio;
@class CATapDescription;

namespace platf {
  /**
   * @brief Provide captured PCM frames to AudioConverter.
   */
  OSStatus audioConverterComplexInputProc(AudioConverterRef _Nullable inAudioConverter, UInt32 *_Nonnull ioNumberDataPackets, AudioBufferList *_Nonnull ioData, AudioStreamPacketDescription *_Nullable *_Nullable outDataPacketDescription, void *_Nonnull inUserData);

  /**
   * @brief Receive system-audio tap samples from Core Audio.
   */
  OSStatus systemAudioIOProc(AudioObjectID inDevice, const AudioTimeStamp *_Nullable inNow, const AudioBufferList *_Nullable inInputData, const AudioTimeStamp *_Nullable inInputTime, AudioBufferList *_Nullable outOutputData, const AudioTimeStamp *_Nullable inOutputTime, void *_Nullable inClientData);
}  // namespace platf

/**
 * @brief Data structure for AudioConverter input callback.
 */
struct AudioConverterInputData {
  float *inputData;  ///< Pointer to input audio data
  UInt32 inputFrames;  ///< Total number of input frames available
  UInt32 framesProvided;  ///< Number of frames already provided to converter
  UInt32 deviceChannels;  ///< Number of channels in the device audio
  AVAudio *avAudio;  ///< Reference to the AVAudio instance
};

/**
 * @brief IOProc client data structure for Core Audio system taps.
 */
typedef struct {
  AVAudio *avAudio;  ///< Reference to AVAudio instance
  UInt32 clientRequestedChannels;  ///< Number of channels requested by client
  UInt32 clientRequestedSampleRate;  ///< Sample rate requested by client
  UInt32 clientRequestedFrameSize;  ///< Frame size requested by client
  UInt32 aggregateDeviceSampleRate;  ///< Sample rate of the aggregate device
  UInt32 aggregateDeviceChannels;  ///< Number of channels in aggregate device
  AudioConverterRef _Nullable audioConverter;  ///< Audio converter for format conversion
  float *_Nullable conversionBuffer;  ///< Pre-allocated buffer for audio conversion
  UInt32 conversionBufferSize;  ///< Size of the conversion buffer in bytes
} AVAudioIOProcData;

/**
 * @brief Core Audio capture class for macOS audio input and system-wide audio tapping.
 */
@interface AVAudio: NSObject <AVCaptureAudioDataOutputSampleBufferDelegate> {
@public
  TPCircularBuffer audioSampleBuffer;  ///< Shared circular buffer for both audio capture paths
  dispatch_semaphore_t audioSemaphore;  ///< Real-time safe semaphore for signaling audio sample availability
@private
  // System-wide audio tap components (Core Audio)
  AudioObjectID tapObjectID;  ///< Core Audio tap object identifier for system audio capture
  AudioObjectID aggregateDeviceID;  ///< Aggregate device ID for system tap audio routing
  AudioDeviceIOProcID ioProcID;  ///< IOProc identifier for real-time audio processing
  AVAudioIOProcData *_Nullable ioProcData;  ///< Context data for IOProc callbacks and format conversion
}

// AVFoundation microphone capture properties
@property (nonatomic, assign, nullable) AVCaptureSession *audioCaptureSession;
@property (nonatomic, assign, nullable) AVCaptureConnection *audioConnection;
@property (nonatomic, assign) BOOL hostAudioEnabled;  ///< Whether host audio playback should be enabled

+ (NSArray<AVCaptureDevice *> *)microphones;
+ (NSArray<NSString *> *)microphoneNames;
+ (nullable AVCaptureDevice *)findMicrophone:(nullable NSString *)name;

- (int)setupMicrophone:(nullable AVCaptureDevice *)device sampleRate:(UInt32)sampleRate frameSize:(UInt32)frameSize channels:(UInt8)channels;

/**
 * @brief Sets up system-wide audio tap for capturing all system audio.
 * Requires macOS 14.0+ and appropriate permissions.
 */
- (int)setupSystemTap:(UInt32)sampleRate frameSize:(UInt32)frameSize channels:(UInt8)channels;

- (void)initializeAudioBuffer:(UInt8)channels;
- (void)cleanupAudioBuffer;
- (void)cleanupSystemTapContext:(nullable id)tapDescription;

@end

NS_ASSUME_NONNULL_END

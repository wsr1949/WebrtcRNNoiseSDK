#import <Foundation/Foundation.h>
#import "WRNAPMTypes.h"
#import "WRNVADTypes.h"

NS_ASSUME_NONNULL_BEGIN

@interface WRNNoiseSuppressor : NSObject

@property (nonatomic, assign, getter=isVoiceDetectionEnabled) BOOL voiceDetectionEnabled;

/// 启用 WebRTC 回音消除；须与 `processRenderPCM:frameCount:` 配合送入播放参考 PCM。
@property (nonatomic, assign, getter=isEchoCancellationEnabled) BOOL echoCancellationEnabled;

/// 采集相对扬声器参考的总延迟（毫秒）。-1 表示由 AEC3 自估。
@property (nonatomic, assign) NSInteger streamDelayMs;

/// AEC3 延迟调参。`applyMask == 0` 使用 WebRTC 默认。
@property (nonatomic, assign) WRNEchoCanceller3Tuning echoCancellerTuning;

/// RNNoise 湿声比例，默认 0.58；TTS 回声段可降至 0.35。
@property (nonatomic, assign) float rnnoiseWetMix;

- (instancetype)initWithSampleRate:(int)sampleRate channels:(int)channels NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

/// 原地处理一帧 10 ms 采集 PCM。若 outVAD 非空则写入双源 VAD 结果。
- (float)processCapturePCM:(int16_t *)pcm
                frameCount:(int)frameCount
                    outVAD:(nullable WRNVADFrameInfo *)outVAD
            outApmFrameRms:(nullable double *)outApmFrameRms;

/// 送入一帧 10 ms 扬声器参考 PCM（与采集同采样率/声道）。仅在 `echoCancellationEnabled` 时生效。
- (void)processRenderPCM:(const int16_t *)pcm frameCount:(int)frameCount;

/// 重建 AEC。外部延迟把「参考调用次数 - 采集调用次数」加进对齐，旧实例上的差额会一直留着。
- (void)resetEchoCanceller;

@end

NS_ASSUME_NONNULL_END

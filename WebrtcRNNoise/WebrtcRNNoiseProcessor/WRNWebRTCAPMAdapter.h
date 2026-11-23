#import <Foundation/Foundation.h>
#import "WRNAPMTypes.h"

NS_ASSUME_NONNULL_BEGIN

/// WebRTC APM 采集适配（需链接 `WebRTCAPM.xcframework`）。
@interface WRNWebRTCAPMAdapter : NSObject

/// 为 YES 时通过 `VoiceActivityDetector` 产出采集 VAD 概率（`vadEnabled` 会同步此项）。
@property (nonatomic, assign, getter=isVoiceDetectionEnabled) BOOL voiceDetectionEnabled;

/// 为 YES 时在 WebRTC APM 中启用回音消除；需同步向 `processRenderPCM:` 送入扬声器参考 PCM。默认 NO。
@property (nonatomic, assign, getter=isEchoCancellationEnabled) BOOL echoCancellationEnabled;

/// 采集相对扬声器参考的总延迟（毫秒）。-1 表示不调用 `set_stream_delay_ms`，由 AEC3 自估。默认 -1。
@property (nonatomic, assign) NSInteger streamDelayMs;

/// AEC3 延迟相关调参。`applyMask == 0` 时恢复 WebRTC 默认。设置后会重建 APM。
@property (nonatomic, assign) WRNEchoCanceller3Tuning echoCancellerTuning;

- (instancetype)initWithSampleRate:(int)sampleRate channels:(int)channels;

/// 原地处理一帧采集 PCM，并返回 WebRTC VAD 概率（未开启 voiceDetection 时为 0）。
- (float)processCapturePCM:(int16_t *)pcm frameCount:(int)frameCount;

- (void)processRenderPCM:(const int16_t *)pcm frameCount:(int)frameCount;
- (void)resetAPM;

@end

NS_ASSUME_NONNULL_END

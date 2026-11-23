#import <Foundation/Foundation.h>
#import "WRNAPMTypes.h"
#import "WRNVADTypes.h"

NS_ASSUME_NONNULL_BEGIN

/// 可复用的 WebRTC APM + RNNoise 裸 PCM 处理器。
///
/// 输入和输出格式固定且保持不变：
/// 16000 Hz、单声道、有符号 16-bit little-endian 裸 PCM。
@interface WRNNoiseProcessor : NSObject

- (instancetype)init NS_UNAVAILABLE;

+ (instancetype)sharedProcessor;

@property (nonatomic, assign, getter=isVadEnabled) BOOL vadEnabled;

/// 开启后须用 `processRenderPCMStreamData:hostTimeTicks:` 送入实际播出的 PCM（计划播放 hostTime）。
/// 眼镜无采样时间戳：采集先进 JitterBuffer，参考按播出顺序送进 AEC3。
/// 播放后测出的延迟会交给 AEC3，残余回声按对齐参考做频谱抑制。
/// RNNoise 降噪和 VAD 仍处理采集。
@property (nonatomic, assign, getter=isEchoCancellationEnabled) BOOL echoCancellationEnabled;

/// 采集相对扬声器参考的总管线延迟 hint（毫秒）：播放缓冲 + 声学 + BLE 等。默认 -1 由 AEC3 自估。
@property (nonatomic, assign) NSInteger streamDelayMs;

@property (nonatomic, assign) WRNEchoCanceller3Tuning echoCancellerTuning;

/// 控制台输出 `[WRN_AEC]` 诊断，默认 YES。
@property (nonatomic, assign) BOOL echoDiagnosticsLoggingEnabled;

@property (nonatomic, assign) float rnnoiseVADThreshold;
@property (nonatomic, assign) float webrtcVADThreshold;
@property (nonatomic, assign) NSTimeInterval vadEndHangoverSeconds;

@property (nonatomic, assign, readonly) WRNVADFrameInfo lastVADFrameInfo;
@property (nonatomic, assign, readonly) BOOL vadUtteranceHasSpeech;
@property (nonatomic, assign, readonly) BOOL utteranceSpeechEnded;

+ (NSData *)processPCMData:(NSData *)pcmData;
+ (nullable NSData *)processPCMFileAtURL:(NSURL *)fileURL error:(NSError **)error;

/// 扬声器参考 PCM：16 kHz / mono / s16le，与真实播放同步送入。
- (void)processRenderPCMStreamData:(NSData *)pcmData;

/// 同上。`hostTimeTicks` 直接传 AudioUnit `AudioTimeStamp.mHostTime`，SDK 内部换算。0 表示调用当下。
- (void)processRenderPCMStreamData:(NSData *)pcmData hostTimeTicks:(uint64_t)hostTimeTicks;

/// 同上；`baseHostTimeNs` 为缓冲区首样本的纳秒时刻。0 表示调用当下。
- (void)processRenderPCMStreamData:(NSData *)pcmData baseHostTimeNs:(uint64_t)baseHostTimeNs;

/// 当前回音消除计数摘要（供宿主 `LWLog` 或对照 `[WRN_AEC]` 周期行）。
- (NSString *)echoCancellationDiagnostics;

/// 拍照传图把麦克风打断之后调用一次。正常播报不要调用。
/// 只移动还没送进 AEC3 的参考，对齐到当前正在播的声音。
- (void)catchUpUnsentEchoReferenceAfterCaptureGap;

- (NSData *)processPCMStreamData:(NSData *)pcmData;
- (void)resetProcessor;

@end

NS_ASSUME_NONNULL_END

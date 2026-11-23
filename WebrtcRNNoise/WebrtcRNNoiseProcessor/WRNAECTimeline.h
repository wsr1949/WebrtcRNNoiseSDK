#import <Foundation/Foundation.h>
#include <stdint.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, WRNAECReferenceAvailability) {
    /// 参考环在 t_capture - D 附近有对应播放帧（远端应已通过 render 路径送入 APM）。
    WRNAECReferenceAvailabilityMatched = 0,
    /// 无 TTS / 无播放窗口：不应送 ProcessReverseStream。
    WRNAECReferenceAvailabilitySkippedNoFarEnd,
    /// 在播放窗口内但环内缺参考（对齐欠载）。
    WRNAECReferenceAvailabilityUnderrun,
};

@interface WRNAECTimeline : NSObject

+ (uint64_t)hostTimeNanoseconds;
+ (uint64_t)frameDurationNs;
/// AudioUnit `AudioTimeStamp.mHostTime`（秒）→ 与 `hostTimeNanoseconds` 同域的纳秒。
+ (uint64_t)nanosecondsFromAudioHostSeconds:(double)hostTimeSeconds;

/// 管线延迟 D（毫秒）：声学 + 播放缓冲 + BLE 等。<0 表示仅依赖 WebRTC AEC3 内估，诊断时用 200 ms 作展示。
@property (nonatomic, assign) NSInteger pipelineDelayMs;

@property (nonatomic, assign, readonly) NSUInteger renderFramesIngested;
@property (nonatomic, assign, readonly) NSUInteger captureFramesProcessed;
@property (nonatomic, assign, readonly) NSUInteger matchedReferences;
@property (nonatomic, assign, readonly) NSUInteger skippedNoFarEnd;
@property (nonatomic, assign, readonly) NSUInteger underrunReferences;
@property (nonatomic, assign, readonly) NSUInteger ringFrames;
@property (nonatomic, assign, readonly) NSUInteger maxPendingCaptureFramesObserved;
@property (nonatomic, assign, readonly) NSUInteger referenceClampCount;
@property (nonatomic, assign, readonly) uint64_t ringDepthNs;
@property (nonatomic, assign, readonly) BOOL farEndPlaybackActive;
@property (nonatomic, assign, readonly) uint64_t lastRenderHostTimeNs;

- (void)reset;

/// 写入一帧已送入 APM 的扬声器参考（固定 160 采样 / 10 ms）。
- (void)ingestRenderFrame:(const int16_t *)samples hostTimeNs:(uint64_t)hostTimeNs;

/// 扬声器播放结束或 flush（段间停顿）。
- (void)noteRenderPlaybackEnded;

/// 当前采集时刻是否处于 TTS 回声消除窗口（与参考是否已入环无关）。
- (BOOL)isEchoCancellationWindowForCaptureHostTimeNs:(uint64_t)captureHostTimeNs;

/// 背压用：无 TTS 窗口恒为 YES；在播窗口内仅当 ring 已有对应参考时为 YES。
- (BOOL)isReferenceReadyForCaptureHostTimeNs:(uint64_t)captureHostTimeNs;

/// 采集入环前查询：是否处于应对消的回声窗口。
- (WRNAECReferenceAvailability)availabilityForCaptureHostTimeNs:(uint64_t)captureHostTimeNs;

/// `t_capture - D` 在环内查找参考 PCM（160 样本）；成功返回 YES 并写入 outFrame。
- (BOOL)copyReferencePCM:(int16_t *)outFrame forCaptureHostTimeNs:(uint64_t)captureHostTimeNs;

/// 按 ingest 序号配对：`renderOrdinal = renderIngested - delayFrames - captureLagFrames`（burst 友好）。
- (BOOL)copyReferencePCM:(int16_t *)outFrame captureLagFrames:(NSUInteger)captureLagFrames;

- (void)noteCaptureFrameProcessed;
- (void)notePendingCaptureFrames:(NSUInteger)frameCount;

/// `targetRefNs - newestRenderNs`（毫秒）；正数表示采集时间轴相对参考偏「未来」。
- (NSInteger)referenceSkewMsForCaptureHostTimeNs:(uint64_t)captureHostTimeNs;

@end

NS_ASSUME_NONNULL_END
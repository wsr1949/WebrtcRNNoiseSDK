//
//  WRNEchoCanceller.h
//  WebrtcRNNoise
//
//  眼镜麦比喇叭晚几百毫秒，而且每次播放都不一样。延迟实时跟踪后交给 AEC3。
//  喇叭到眼镜麦再经 Opus 之后，波形相关很低，AEC3 会把回声当成插话放行。
//  播放期间改用频谱回声传递比抑制，不靠整段增益门。
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface WRNEchoCanceller : NSObject

- (void)reset;

/// 16 kHz / mono / s16le。按调用顺序接到播放队列末尾。`hostTimeNs` 只保留给调用方，不参与摆放。
- (void)writeReferenceBytes:(const void *)bytes
                      length:(NSUInteger)length
                  hostTimeNs:(uint64_t)hostTimeNs;

/// 眼镜回传的 PCM，格式同上。到达时间取当前 mach 时间。返回等长数据。
- (NSData *)processCapturePCM:(NSData *)pcmData;

/// 关掉整段增益门。延迟估计和对齐参考仍然工作，抑制由外部 AEC3 完成。
- (void)setDelayAlignerOnly:(BOOL)alignerOnly;

/// 用这段采集更新延迟。若调用前已经锁定，把对齐后的参考写入 `reference`（等长）并返回 YES。
- (BOOL)fillAlignedReference:(int16_t *)reference
                       count:(int)count
                  forCapture:(const int16_t *)capture
           arrivalHostTimeNs:(uint64_t)arrivalHostTimeNs;

/// 播放期间按频谱回声传递比抑制。`reference` 须已与采集对齐。`enabled == NO` 时不改样本。
- (void)applyResidualSuppressionToSamples:(int16_t *)samples
                                reference:(const int16_t *)reference
                                    count:(int)count
                                  enabled:(BOOL)enabled;

/// 已锁定时返回延迟毫秒，否则返回 -1。
- (int)lockedDelayMs;

/// 对齐模式为 `delay=.. locked=.. ncc=.. peak=.. win=.. aec3=1 far=.. near=.. skew=..`。门控自测仍带 erle/gain。
- (NSString *)diagnostics;

@end

NS_ASSUME_NONNULL_END

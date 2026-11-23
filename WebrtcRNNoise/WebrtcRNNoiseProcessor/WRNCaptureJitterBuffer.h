#import <Foundation/Foundation.h>
#import <stdint.h>

NS_ASSUME_NONNULL_BEGIN

/// 蓝牙采集抖动吸收：任意线程 push，仅在 APM 串行线程 pop 10 ms 帧。
/// 不用包到达时刻做对齐，只稳定输出节拍与水位。
@interface WRNCaptureJitterBuffer : NSObject

@property (nonatomic, assign, readonly) int waterMs;
@property (nonatomic, assign, readonly) NSUInteger dropSampleCount;
@property (nonatomic, assign, readonly) NSUInteger duplicateSampleCount;

- (void)reset;

/// 16 kHz mono s16le。
- (void)pushPCMBytes:(const void *)bytes length:(NSUInteger)length;

/// 水位低于最小值时返回 NO。`captureOutHostTimeNs` 为 iOS 侧取出该帧的时刻（非外设采样时刻）。
- (BOOL)popFrame160:(int16_t *)outFrame captureOutHostTimeNs:(uint64_t *)captureOutHostTimeNs;

@end

NS_ASSUME_NONNULL_END
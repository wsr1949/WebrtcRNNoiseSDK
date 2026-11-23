#import <Foundation/Foundation.h>
#import <stdint.h>

NS_ASSUME_NONNULL_BEGIN

/// 播放参考 FIFO：每 10 ms 帧带「计划播出」hostTime，供无 TS 场景近似配对。
@interface WRNRenderHostTimeQueue : NSObject

@property (nonatomic, assign, readonly) int queuedMs;

- (void)reset;

- (void)pushFrame160:(const int16_t *)frame playHostTimeNs:(uint64_t)playHostTimeNs;

/// 按播出顺序弹出一帧。
- (BOOL)popFrontFrame160:(int16_t *)outFrame playHostTimeNs:(uint64_t *)playHostTimeNs;

/// 查看队头起第 offset 帧的播放时刻，不取出。
- (BOOL)peekFramePlayHostTimeNs:(uint64_t *)playHostTimeNs atFrameOffset:(int)offset;

@end

NS_ASSUME_NONNULL_END
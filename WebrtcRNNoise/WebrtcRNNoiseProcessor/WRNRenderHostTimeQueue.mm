#import "WRNRenderHostTimeQueue.h"
#import <os/lock.h>

static const int kWRNRenderQSamplesPerFrame = 160;
static const int kWRNRenderQMaxFrames = 600;

typedef struct {
    int16_t samples[kWRNRenderQSamplesPerFrame];
    uint64_t playHostTimeNs;
} WRNRenderQueueEntry;

@implementation WRNRenderHostTimeQueue {
    WRNRenderQueueEntry *_entries;
    int _head;
    int _tail;
    int _count;
    os_unfair_lock _lock;
}

- (instancetype)init {
    self = [super init];
    if (!self) return nil;
    _entries = (WRNRenderQueueEntry *)calloc((size_t)kWRNRenderQMaxFrames, sizeof(WRNRenderQueueEntry));
    _lock = OS_UNFAIR_LOCK_INIT;
    return self;
}

- (void)dealloc {
    free(_entries);
}

- (void)reset {
    os_unfair_lock_lock(&_lock);
    _head = _tail = _count = 0;
    os_unfair_lock_unlock(&_lock);
}

- (int)queuedMs {
    os_unfair_lock_lock(&_lock);
    int ms = _count * 10;
    os_unfair_lock_unlock(&_lock);
    return ms;
}

- (void)pushFrame160:(const int16_t *)frame playHostTimeNs:(uint64_t)playHostTimeNs {
    if (!frame) return;
    os_unfair_lock_lock(&_lock);
    if (_count >= kWRNRenderQMaxFrames) {
        _head = (_head + 1) % kWRNRenderQMaxFrames;
        _count -= 1;
    }
    memcpy(_entries[_tail].samples, frame, (size_t)kWRNRenderQSamplesPerFrame * sizeof(int16_t));
    _entries[_tail].playHostTimeNs = playHostTimeNs;
    _tail = (_tail + 1) % kWRNRenderQMaxFrames;
    _count += 1;
    os_unfair_lock_unlock(&_lock);
}

- (BOOL)peekFramePlayHostTimeNs:(uint64_t *)playHostTimeNs atFrameOffset:(int)offset {
    os_unfair_lock_lock(&_lock);
    if (offset < 0 || offset >= _count) {
        os_unfair_lock_unlock(&_lock);
        return NO;
    }
    int index = (_head + offset) % kWRNRenderQMaxFrames;
    if (playHostTimeNs) *playHostTimeNs = _entries[index].playHostTimeNs;
    os_unfair_lock_unlock(&_lock);
    return YES;
}

- (BOOL)popFrontFrame160:(int16_t *)outFrame playHostTimeNs:(uint64_t *)playHostTimeNs {
    if (!outFrame) return NO;
    os_unfair_lock_lock(&_lock);
    if (_count == 0) {
        os_unfair_lock_unlock(&_lock);
        return NO;
    }
    memcpy(outFrame, _entries[_head].samples, (size_t)kWRNRenderQSamplesPerFrame * sizeof(int16_t));
    if (playHostTimeNs) *playHostTimeNs = _entries[_head].playHostTimeNs;
    _head = (_head + 1) % kWRNRenderQMaxFrames;
    _count -= 1;
    os_unfair_lock_unlock(&_lock);
    return YES;
}

@end
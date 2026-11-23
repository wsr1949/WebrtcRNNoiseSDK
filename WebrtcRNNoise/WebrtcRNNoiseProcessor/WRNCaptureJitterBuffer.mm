#import "WRNCaptureJitterBuffer.h"
#import <mach/mach_time.h>
#import <os/lock.h>

static const int kWRNJBSampleRate = 16000;
static const int kWRNJBSamplesPer10Ms = 160;
static const int kWRNJBTargetMs = 40;
static const int kWRNJBMinMs = 20;
static const int kWRNJBMaxMs = 70;

static uint64_t WRNJBHostNs(void) {
    static mach_timebase_info_data_t tb;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ mach_timebase_info(&tb); });
    return mach_absolute_time() * tb.numer / tb.denom;
}

@implementation WRNCaptureJitterBuffer {
    int16_t *_ring;
    int _capacitySamples;
    int _read;
    int _count;
    os_unfair_lock _lock;
    int _highMsStreak;
    int _lowMsStreak;
    int16_t _lastSample;
    NSUInteger _dropSamples;
    NSUInteger _dupSamples;
}

- (instancetype)init {
    self = [super init];
    if (!self) return nil;
    _capacitySamples = 200 * kWRNJBSampleRate / 1000;
    _ring = (int16_t *)calloc((size_t)_capacitySamples, sizeof(int16_t));
    _lock = OS_UNFAIR_LOCK_INIT;
    _lastSample = 0;
    return self;
}

- (void)dealloc {
    free(_ring);
}

- (void)reset {
    os_unfair_lock_lock(&_lock);
    _read = 0;
    _count = 0;
    _highMsStreak = 0;
    _lowMsStreak = 0;
    _lastSample = 0;
    os_unfair_lock_unlock(&_lock);
}

- (int)waterMs {
    os_unfair_lock_lock(&_lock);
    int ms = _count * 1000 / kWRNJBSampleRate;
    os_unfair_lock_unlock(&_lock);
    return ms;
}

- (NSUInteger)dropSampleCount {
    return _dropSamples;
}

- (NSUInteger)duplicateSampleCount {
    return _dupSamples;
}

- (void)pushPCMBytes:(const void *)bytes length:(NSUInteger)length {
    if (!bytes || length < sizeof(int16_t)) return;
    const int16_t *src = (const int16_t *)bytes;
    int samples = (int)(length / sizeof(int16_t));
    os_unfair_lock_lock(&_lock);
    for (int i = 0; i < samples; i++) {
        if (_count >= _capacitySamples) {
            _read = (_read + 1) % _capacitySamples;
            _count -= 1;
            _dropSamples += 1;
        }
        int write = (_read + _count) % _capacitySamples;
        _ring[write] = src[i];
        _lastSample = src[i];
        _count += 1;
    }
    int waterMs = _count * 1000 / kWRNJBSampleRate;
    int targetSamples = kWRNJBTargetMs * kWRNJBSampleRate / 1000;
    if (waterMs > kWRNJBTargetMs) {
        int drop = waterMs > kWRNJBMaxMs ? 8 : 2;
        for (int d = 0; d < drop && _count > targetSamples; d++) {
            _read = (_read + 1) % _capacitySamples;
            _count -= 1;
            _dropSamples += 1;
        }
    }
    os_unfair_lock_unlock(&_lock);
}

- (BOOL)popFrame160:(int16_t *)outFrame captureOutHostTimeNs:(uint64_t *)captureOutHostTimeNs {
    if (!outFrame) return NO;
    os_unfair_lock_lock(&_lock);
    int waterMs = _count * 1000 / kWRNJBSampleRate;
    if (waterMs < kWRNJBMinMs) {
        if (waterMs > 0 && _lowMsStreak >= 20) {
            outFrame[0] = _lastSample;
            for (int i = 1; i < kWRNJBSamplesPer10Ms; i++) outFrame[i] = _lastSample;
            _dupSamples += (NSUInteger)kWRNJBSamplesPer10Ms;
            _lowMsStreak = 0;
            if (captureOutHostTimeNs) *captureOutHostTimeNs = WRNJBHostNs();
            os_unfair_lock_unlock(&_lock);
            return YES;
        }
        if (waterMs == 0) _lowMsStreak += 1;
        os_unfair_lock_unlock(&_lock);
        return NO;
    }
    _lowMsStreak = 0;
  for (int i = 0; i < kWRNJBSamplesPer10Ms; i++) {
        outFrame[i] = _ring[_read];
        _read = (_read + 1) % _capacitySamples;
        _count -= 1;
        _lastSample = outFrame[i];
    }
    if (captureOutHostTimeNs) *captureOutHostTimeNs = WRNJBHostNs();
    os_unfair_lock_unlock(&_lock);
    return YES;
}

@end
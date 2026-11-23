#import "WRNAECTimeline.h"

#include <mach/mach_time.h>

static const int kFrameSamples = 160;
static const NSUInteger kFrameBytes = kFrameSamples * sizeof(int16_t);
static const NSUInteger kMaxRingFrames = 450; // 4.5 s @ 10 ms
static const uint64_t kFarEndInactiveGapNs = 150 * 1000000ULL; // 150 ms
static const NSInteger kDiagnosticDelayWhenUnsetMs = 350;

@interface WRNTimestampedPCMFrame : NSObject
@property (nonatomic, assign) uint64_t hostTimeNs;
@property (nonatomic, assign) NSUInteger ingestOrdinal;
@property (nonatomic, copy) NSData *pcm;
@end

@implementation WRNTimestampedPCMFrame
@end

@implementation WRNAECTimeline {
    NSMutableArray<WRNTimestampedPCMFrame *> *_ring;
    NSUInteger _renderFramesIngested;
    NSUInteger _captureFramesProcessed;
    NSUInteger _matchedReferences;
    NSUInteger _skippedNoFarEnd;
    NSUInteger _underrunReferences;
    NSUInteger _maxPendingCaptureFramesObserved;
    NSUInteger _referenceClampCount;
    uint64_t _lastRenderHostTimeNs;
    BOOL _farEndPlaybackActive;
}

+ (uint64_t)hostTimeNanoseconds {
    static mach_timebase_info_data_t s_timebase;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        mach_timebase_info(&s_timebase);
    });
    uint64_t t = mach_absolute_time();
    return t * s_timebase.numer / s_timebase.denom;
}

+ (uint64_t)nanosecondsFromMilliseconds:(NSInteger)ms {
    if (ms < 0) {
        ms = kDiagnosticDelayWhenUnsetMs;
    }
    return (uint64_t)ms * 1000000ULL;
}

+ (uint64_t)frameDurationNs {
    return 10 * 1000000ULL;
}

+ (uint64_t)nanosecondsFromAudioHostSeconds:(double)hostTimeSeconds {
    if (!(hostTimeSeconds > 0)) {
        return 0;
    }
    return (uint64_t)(hostTimeSeconds * 1000000000.0);
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _pipelineDelayMs = -1;
        _ring = [NSMutableArray array];
        [self reset];
    }
    return self;
}

- (NSUInteger)ringFrames {
    return _ring.count;
}

- (uint64_t)ringDepthNs {
    if (_ring.count < 2) {
        return _ring.count > 0 ? [WRNAECTimeline frameDurationNs] : 0;
    }
    WRNTimestampedPCMFrame *first = _ring.firstObject;
    WRNTimestampedPCMFrame *last = _ring.lastObject;
    if (last.hostTimeNs <= first.hostTimeNs) {
        return 0;
    }
    return last.hostTimeNs - first.hostTimeNs;
}

- (void)reset {
    [_ring removeAllObjects];
    _renderFramesIngested = 0;
    _captureFramesProcessed = 0;
    _matchedReferences = 0;
    _skippedNoFarEnd = 0;
    _underrunReferences = 0;
    _maxPendingCaptureFramesObserved = 0;
    _referenceClampCount = 0;
    _lastRenderHostTimeNs = 0;
    _farEndPlaybackActive = NO;
}

- (NSUInteger)referenceClampCount {
    return _referenceClampCount;
}

- (uint64_t)lastRenderHostTimeNs {
    return _lastRenderHostTimeNs;
}

- (void)trimRingIfNeeded {
    while (_ring.count > kMaxRingFrames) {
        [_ring removeObjectAtIndex:0];
    }
}

- (void)updateFarEndActiveForRenderTime:(uint64_t)hostTimeNs {
    _lastRenderHostTimeNs = hostTimeNs;
    _farEndPlaybackActive = YES;
}

- (void)ingestRenderFrame:(const int16_t *)samples hostTimeNs:(uint64_t)hostTimeNs {
    if (!samples) {
        return;
    }
    [self updateFarEndActiveForRenderTime:hostTimeNs];
    _renderFramesIngested += 1;
    WRNTimestampedPCMFrame *slot = [WRNTimestampedPCMFrame new];
    slot.hostTimeNs = hostTimeNs;
    slot.ingestOrdinal = _renderFramesIngested;
    slot.pcm = [NSData dataWithBytes:samples length:kFrameBytes];
    [_ring addObject:slot];
    [self trimRingIfNeeded];
}

- (void)noteRenderPlaybackEnded {
    _farEndPlaybackActive = NO;
}

- (WRNTimestampedPCMFrame *)newestFrameAtOrBefore:(uint64_t)targetHostTimeNs {
    WRNTimestampedPCMFrame *candidate = nil;
    for (WRNTimestampedPCMFrame *frame in _ring) {
        if (frame.hostTimeNs <= targetHostTimeNs) {
            if (!candidate || frame.hostTimeNs > candidate.hostTimeNs) {
                candidate = frame;
            }
        }
    }
    return candidate;
}

- (BOOL)isFarEndRecentlyActiveAtCaptureTime:(uint64_t)captureHostTimeNs {
    (void)captureHostTimeNs;
    if (!_farEndPlaybackActive || _lastRenderHostTimeNs == 0) {
        return NO;
    }
    return _ring.count > 0;
}

- (BOOL)isEchoCancellationWindowForCaptureHostTimeNs:(uint64_t)captureHostTimeNs {
    return [self isFarEndRecentlyActiveAtCaptureTime:captureHostTimeNs];
}

- (BOOL)isReferenceReadyForCaptureHostTimeNs:(uint64_t)captureHostTimeNs {
    if (![self isFarEndRecentlyActiveAtCaptureTime:captureHostTimeNs]) {
        return YES;
    }
    if (_ring.count == 0) {
        return NO;
    }
    return YES;
}

- (WRNAECReferenceAvailability)availabilityForCaptureHostTimeNs:(uint64_t)captureHostTimeNs {
    if (![self isFarEndRecentlyActiveAtCaptureTime:captureHostTimeNs]) {
        _skippedNoFarEnd += 1;
        return WRNAECReferenceAvailabilitySkippedNoFarEnd;
    }

    uint64_t delayNs = [WRNAECTimeline nanosecondsFromMilliseconds:_pipelineDelayMs];
    uint64_t targetRefNs =
        captureHostTimeNs > delayNs ? captureHostTimeNs - delayNs : 0;
    WRNTimestampedPCMFrame *ref = [self referenceFrameForCaptureHostTimeNs:captureHostTimeNs];
    if (!ref) {
        _underrunReferences += 1;
        return WRNAECReferenceAvailabilityUnderrun;
    }

    _matchedReferences += 1;
    return WRNAECReferenceAvailabilityMatched;
}

- (WRNTimestampedPCMFrame *)referenceFrameForCaptureHostTimeNs:(uint64_t)captureHostTimeNs {
    if (![self isFarEndRecentlyActiveAtCaptureTime:captureHostTimeNs]) {
        return nil;
    }
    if (_ring.count == 0) {
        return nil;
    }
    uint64_t delayNs = [WRNAECTimeline nanosecondsFromMilliseconds:_pipelineDelayMs];
    uint64_t targetRefNs =
        captureHostTimeNs > delayNs ? captureHostTimeNs - delayNs : 0;
    const uint64_t slackNs = [WRNAECTimeline frameDurationNs] * 8;
    WRNTimestampedPCMFrame *newest = _ring.lastObject;
    WRNTimestampedPCMFrame *ref = [self newestFrameAtOrBefore:targetRefNs];
    BOOL clamped = NO;
    if (!ref || ref.hostTimeNs + slackNs < targetRefNs) {
        ref = newest;
        clamped = YES;
    }
    if (targetRefNs > newest.hostTimeNs + slackNs) {
        ref = newest;
        clamped = YES;
    }
    if (clamped) {
        _referenceClampCount += 1;
    }
    return ref;
}

- (NSInteger)referenceSkewMsForCaptureHostTimeNs:(uint64_t)captureHostTimeNs {
    if (_ring.count == 0) {
        return 0;
    }
    uint64_t delayNs = [WRNAECTimeline nanosecondsFromMilliseconds:_pipelineDelayMs];
    uint64_t targetRefNs =
        captureHostTimeNs > delayNs ? captureHostTimeNs - delayNs : 0;
    uint64_t newestRenderNs = _ring.lastObject.hostTimeNs;
    int64_t skewNs = (int64_t)targetRefNs - (int64_t)newestRenderNs;
    return (NSInteger)(skewNs / 1000000LL);
}

- (WRNTimestampedPCMFrame *)frameWithIngestOrdinal:(NSUInteger)ordinal clamped:(BOOL *)outClamped {
    WRNTimestampedPCMFrame *exact = nil;
    WRNTimestampedPCMFrame *bestBefore = nil;
    for (WRNTimestampedPCMFrame *frame in _ring) {
        if (frame.ingestOrdinal == ordinal) {
            exact = frame;
            break;
        }
        if (frame.ingestOrdinal <= ordinal &&
            (!bestBefore || frame.ingestOrdinal > bestBefore.ingestOrdinal)) {
            bestBefore = frame;
        }
    }
    if (exact) {
        if (outClamped) {
            *outClamped = NO;
        }
        return exact;
    }
    if (bestBefore) {
        if (outClamped) {
            *outClamped = YES;
        }
        _referenceClampCount += 1;
        return bestBefore;
    }
    if (_ring.count > 0) {
        if (outClamped) {
            *outClamped = YES;
        }
        _referenceClampCount += 1;
        return _ring.firstObject;
    }
    if (outClamped) {
        *outClamped = NO;
    }
    return nil;
}

- (BOOL)copyReferencePCM:(int16_t *)outFrame captureLagFrames:(NSUInteger)captureLagFrames {
    if (!outFrame) {
        return NO;
    }
    if (!_farEndPlaybackActive || _ring.count == 0) {
        return NO;
    }
    NSInteger delayMs = _pipelineDelayMs;
    if (delayMs < 0) {
        delayMs = kDiagnosticDelayWhenUnsetMs;
    }
    NSUInteger delayFrames = (NSUInteger)((delayMs + 5) / 10);
    if (_renderFramesIngested <= delayFrames + captureLagFrames) {
        return NO;
    }
    NSUInteger targetOrdinal = _renderFramesIngested - delayFrames - captureLagFrames;
    BOOL clamped = NO;
    WRNTimestampedPCMFrame *ref = [self frameWithIngestOrdinal:targetOrdinal clamped:&clamped];
    (void)clamped;
    if (!ref || ref.pcm.length < kFrameBytes) {
        return NO;
    }
    memcpy(outFrame, ref.pcm.bytes, kFrameBytes);
    return YES;
}

- (BOOL)copyReferencePCM:(int16_t *)outFrame forCaptureHostTimeNs:(uint64_t)captureHostTimeNs {
    if (!outFrame) {
        return NO;
    }
    WRNTimestampedPCMFrame *ref = [self referenceFrameForCaptureHostTimeNs:captureHostTimeNs];
    if (!ref || ref.pcm.length < kFrameBytes) {
        return NO;
    }
    memcpy(outFrame, ref.pcm.bytes, kFrameBytes);
    return YES;
}

- (void)noteCaptureFrameProcessed {
    _captureFramesProcessed += 1;
}

- (void)notePendingCaptureFrames:(NSUInteger)frameCount {
    if (frameCount > _maxPendingCaptureFramesObserved) {
        _maxPendingCaptureFramesObserved = frameCount;
    }
}

@end
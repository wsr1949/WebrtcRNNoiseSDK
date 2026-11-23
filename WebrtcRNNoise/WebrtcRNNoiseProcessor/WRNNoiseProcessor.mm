#import "WRNNoiseProcessor.h"
#import "WRNNoiseSuppressor.h"
#import "WRNAECTimeline.h"
#import "WRNEchoCanceller.h"
#import "WRNCaptureJitterBuffer.h"
#import "WRNRenderHostTimeQueue.h"

#include <math.h>
#include <stdlib.h>
#include <string.h>
#include <mach/mach_time.h>
#include <stdatomic.h>
#import <os/lock.h>

static const int kWRNSampleRate = 16000;
static const int kWRNChannels = 1;
static const int kWRNFrameSamples = 160;
static const NSUInteger kWRNFrameBytes = kWRNFrameSamples * sizeof(int16_t);
static const NSUInteger kWRNSampleBytes = sizeof(int16_t);
static const double kWRNTargetRMS = 9800.0;
static const double kWRNEnvelopeGateRMS = 1200.0;
static const double kWRNPeakCeiling = 30000.0;
static const double kWRNMaxGain = 3.2;
static const double kWRNEnvelopeAttackSeconds = 0.03;
static const double kWRNEnvelopeReleaseSeconds = 0.25;
static const double kWRNGainAttackSeconds = 0.08;
static const double kWRNGainReleaseSeconds = 0.45;
static const float kWRNDefaultRNNoiseVADThreshold = 0.58f;
static const float kWRNDefaultWebRTCVADThreshold = 0.42f;
static const float kWRNDefaultVADOffThresholdHysteresis = 0.15f;
static const NSUInteger kWRNMinConfirmedDualSpeechFrames = 8;
static const NSTimeInterval kWRNFrameDurationSeconds = 0.01;
static const NSTimeInterval kWRNDefaultVADHangoverSeconds = 1.0;
static const NSTimeInterval kWRNMinVADHangoverSeconds = 0.1;
static const NSTimeInterval kWRNMaxVADHangoverSeconds = 10.0;
static const NSUInteger kWRNDefaultVADHangoverFrames =
    (NSUInteger)llround(kWRNDefaultVADHangoverSeconds / kWRNFrameDurationSeconds);
static const NSInteger kWRNInvalidStreamDelayMs = -1;
static const NSInteger kWRNDefaultGlassesPipelineDelayMs = 350;
/// 还没测到延迟时给 AEC3 的初始值。测到之后改成实测延迟，不再用这个数。
static const NSInteger kWRNGlassesAECBaselineDelayMs = 55;
static const int kWRNGlassesDelayHistSamples = 19200;
static const int kWRNGlassesDelaySearchSamples = 640;
static const int kWRNGlassesDelayMinSamples = 1600;
static const int kWRNGlassesDelayMaxSamples = 14400;
/// render 队列与 JitterBuffer 出队时刻的近似配对偏移（毫秒），不用蓝牙包到达时刻。
static const NSInteger kWRNGlassesRenderPairingOffsetMs = 55;
static const NSTimeInterval kWRNGlassesAPMResetIntervalSeconds = 30.0;
static const NSInteger kWRNCaptureIngressBiasMs = 50;
/// 眼镜编码 + BLE + 手机收包，无设备时间戳时用于 ingress 锚定 batch 末帧。
static const NSInteger kWRNBleIngressPipelineMs = 180;
/// render 锚相对 ingress 估计的最大单包修正，避免 skew 一步跳太大。
static const NSInteger kWRNCaptureAnchorMaxSlewMs = 60;
static const uint64_t kWRNCaptureTimelineGapResyncNs = 1200 * 1000000ULL;
static const NSInteger kWRNCaptureTimelineNudgeMaxStepMs = 15;
static const NSInteger kWRNCaptureTimelineNudgeDeadbandMs = 25;
/// 采集前从 ring 注入对应参考再 ProcessCapture；APM 不再依赖超大 streamDelay。
static const NSInteger kWRNAPMStreamDelayWhenPairedMs = 0;
static const double kWRNFarEndAGCGateRMS = 800.0;
static const double kWRNFarEndLoudRenderRMS = 400.0;
static const NSTimeInterval kWRNAECDiagnosticLogIntervalSeconds = 3.0;
static const uint64_t kWRNBadRenderBaseLagNs = 1000000000ULL;
static const int64_t kWRNRenderClockSkewThresholdMs = 500;

static uint64_t WRNMachTicksToNanoseconds(uint64_t ticks) {
    static mach_timebase_info_data_t timebase;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        mach_timebase_info(&timebase);
    });
    if (timebase.denom == 0) return ticks;
    return ticks * timebase.numer / timebase.denom;
}

static const void *kWRNProcessorStateQueueKey = &kWRNProcessorStateQueueKey;

static void WRNAECLog(NSString *format, ...) NS_FORMAT_FUNCTION(1, 2);

static void WRNAECLog(NSString *format, ...) {
    va_list args;
    va_start(args, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    NSLog(@"[WRN_AEC] %@", message);
}

static inline int16_t WRNClampedInt16(double value) {
    return (int16_t)MAX(-kWRNPeakCeiling, MIN(kWRNPeakCeiling, value));
}

static inline double WRNSmoothingAlpha(double seconds) {
    return exp(-1.0 / (seconds * kWRNSampleRate));
}

static const double kWRNAECMetricEmaAlpha = 0.08;

static inline double WRNFrameRMS(const int16_t *samples, NSUInteger count) {
    if (!samples || count == 0) {
        return 0;
    }
    double energy = 0;
    for (NSUInteger i = 0; i < count; i++) {
        double s = (double)samples[i];
        energy += s * s;
    }
    return sqrt(energy / (double)count);
}

static inline double WRNUpdateEma(double ema, double sample, double alpha) {
    if (ema <= 0) {
        return sample;
    }
    return alpha * sample + (1.0 - alpha) * ema;
}

@interface WRNNoiseProcessor ()
@property (nonatomic, strong) WRNNoiseSuppressor *suppressor;
@property (nonatomic, strong) WRNAECTimeline *aecTimeline;
@property (nonatomic, strong) WRNEchoCanceller *echoCanceller;
@property (nonatomic, strong) dispatch_queue_t stateQueue;
@property (nonatomic, strong) NSMutableData *pendingPCMData;
@property (nonatomic, strong) NSMutableData *pendingRenderPCMData;
@property (nonatomic, strong) NSMutableData *readyPCMData;
@property (nonatomic, assign) double envelopeEnergy;
@property (nonatomic, assign) double gain;
@property (nonatomic, assign) BOOL hasEnvelope;
@property (nonatomic, assign) double farEndEnvelopeRMS;

- (void)performOnStateQueue:(dispatch_block_t)block;
- (NSData *)processPCMStreamDataOnStateQueue:(NSData *)pcmData;
- (NSData *)flushPendingPCMDataOnStateQueue;
- (void)processRenderPCMStreamDataOnStateQueue:(NSData *)pcmData baseHostTimeNs:(uint64_t)baseHostTimeNs;
- (void)configureGlassesAEC3OnStateQueue;
- (void)applyGlassesAPMPeriodicResetOnStateQueue;
- (void)startGlassesAPMTimerOnStateQueue;
- (void)stopGlassesAPMTimerOnStateQueue;
- (void)tickGlassesAPMOnStateQueue;
- (BOOL)pumpOneGlassesFrameOnStateQueue;
- (void)noteGlassesJitterWaterOnStateQueue;
- (void)decayFarEndEnvelopeOnStateQueue;
- (NSData *)ingestGlassesCaptureToJitterOnStateQueue:(NSData *)pcmData;
- (void)writeGlassesReferenceNow:(NSData *)pcmData hostTimeNs:(uint64_t)hostTimeNs;
- (void)flushPendingRenderPCMDataOnStateQueue;
- (void)clearStreamStateOnStateQueue;
- (void)clearVADSessionStateOnStateQueue;
- (void)updateVADStateWithFrame:(WRNVADFrameInfo)frameInfo;
- (WRNVADFrameInfo)vadFrameInfoByApplyingThresholds:(WRNVADFrameInfo)rawFrameInfo;
- (NSData *)processAlignedPCMData:(NSData *)pcmData
                  trimOutputBytes:(NSUInteger)trimOutputBytes
               captureHostTimeNs:(uint64_t)captureHostTimeNs;
- (void)applySmoothAGCToSamples:(int16_t *)samples sampleCount:(NSUInteger)sampleCount;
- (void)processPendingCaptureOnStateQueueForce:(BOOL)force;
- (void)consumeCaptureFrameDataOnStateQueue:(NSData *)frameData
                            trimOutputBytes:(NSUInteger)trimOutputBytes
                                      force:(BOOL)force;
- (void)pushRenderFrameOnStateQueue:(const int16_t *)frame hostTimeNs:(uint64_t)hostTimeNs;
- (void)syncStreamDelayOnStateQueue;
- (uint64_t)nextCaptureFrameHostTimeNsOnStateQueue;
- (uint64_t)peekNextCaptureFrameHostTimeNsOnStateQueue;
- (void)noteCaptureIngressOnStateQueue:(NSUInteger)newFullFrames pendingWasEmpty:(BOOL)pendingWasEmpty;
- (NSData *)concatenatePCMData:(NSData *)first second:(NSData *)second;
- (void)updateFarEndEnvelopeWithFrame:(const int16_t *)frame;
- (NSData *)takeReadyPCMOnStateQueue;
- (void)resetAECDiagnosticSessionCountersOnStateQueue;
- (NSString *)aecDiagnosticCountsLineOnStateQueue;
- (void)emitAECDiagnosticsOnStateQueueForce:(BOOL)force event:(NSString * _Nullable)event;
- (void)noteAECFrameMetricsWithInRms:(double)inRms
                         apmOutRms:(double)apmOutRms
                      finalOutRms:(double)finalOutRms
                        refSkewMs:(double)refSkewMs;
- (void)checkAECWeakEchoOnStateQueue;
- (void)noteReferenceAvailabilityOnStateQueue:(WRNAECReferenceAvailability)availability force:(BOOL)force;
- (BOOL)isFarEndActiveForMetricsOnStateQueue;
- (NSInteger)baselineStreamDelayMsOnStateQueue;
- (void)applyEchoCancellerTuningForDelayMs:(NSInteger)delayMs;
- (void)anchorCaptureBatchOnStateQueueWithTotalFrames:(NSUInteger)totalFrames useRenderClock:(BOOL)useRenderClock;
- (void)extendCaptureStreamTimelineOnStateQueueWithTotalFrames:(NSUInteger)totalFrames;
- (BOOL)shouldResyncCaptureTimelineOnStateQueue;
- (NSInteger)apmStreamDelayMsOnStateQueue;
- (NSInteger)totalCaptureToRenderDelayMsOnStateQueue;
- (void)nudgeCaptureTimelineTowardRenderOnStateQueue;
@end

@implementation WRNNoiseProcessor {
    BOOL _vadEnabled;
    float _rnnoiseVADThreshold;
    float _webrtcVADThreshold;
    WRNVADFrameInfo _lastVADFrameInfo;
    BOOL _vadUtteranceHasSpeech;
    BOOL _utteranceSpeechEnded;
    NSUInteger _vadEndHangoverFrames;
    NSUInteger _vadSilenceFrameCount;
    NSUInteger _vadStrongSpeechFrameCount;
    NSInteger _streamDelayMs;
    uint64_t _captureFrameHostTimeNs;
    uint64_t _captureBatchStartNs;
    NSUInteger _captureBatchNextIndex;
    NSUInteger _captureBatchTotal;
    NSUInteger _aecCaptureIngressBytes;
    NSUInteger _aecCaptureOutFrames;
    BOOL _echoDiagnosticsLoggingEnabled;
    CFAbsoluteTime _aecLastDiagnosticLogTime;
    NSUInteger _aecUnderrunStreak;
    NSUInteger _aecRefNotReadyBreakCount;
    NSUInteger _lastReadyOutBytes;
    uint64_t _renderNextFrameHostTimeNs;
    double _aecEmaInRms;
    double _aecEmaOutRms;
    double _aecEmaErlDb;
    double _aecEmaRefSkewMs;
    double _aecEmaPostAgcGain;
    CFAbsoluteTime _aecWeakEchoBadSince;
    BOOL _aecWeakEchoLogged;
    BOOL _ignoreExternalRenderBaseHostTime;
    BOOL _renderClockSkewLogged;
    NSInteger _effectiveDelayMs;
    NSUInteger _aecFarActiveMetricFrames;
    NSUInteger _aecPairedRefFrames;
    NSUInteger _aecPairedRefMissFrames;
    char _lastCaptureAnchorSource;
    BOOL _glassesEchoEnabled;
    BOOL _glassesAlignedFeed;
    NSInteger _glassesFedDelayMs;
    uint64_t _captureArrivalHostTimeNs;
    atomic_bool _glassesEchoAtomic;
    os_unfair_lock _renderLock;
    NSMutableData *_directRenderPending;
    NSMutableData *_renderAwaitingConsume;
    uint64_t _directRenderNextNs;
    WRNCaptureJitterBuffer *_captureJitter;
    WRNRenderHostTimeQueue *_renderTimeQueue;
    dispatch_source_t _glassesApmTimer;
    CFAbsoluteTime _glassesApmSessionStart;
    uint64_t _glassesLastCaptureOutNs;
    uint64_t _glassesLastRenderPlayNs;
    int _glassesRenderPairHits;
    int _glassesRenderPairMiss;
    int _glassesOutFrames;
    int _glassesLastPairSkewMs;
    uint64_t _glassesLastPairNs;
    int _glassesJbMinMs;
    int16_t *_glassesRenderHist;
    int _glassesRenderHistWrite;
    int _glassesRenderHistCount;
    int16_t _glassesCaptureSearch[kWRNGlassesDelaySearchSamples];
    int _glassesCaptureSearchCount;
    int _glassesDelaySamples;
    int _glassesDelayLocked;
    float _glassesDelayNcc;
    int _glassesDelayPendingSamples;
    int _glassesDelayPendingCount;
    int _glassesDelayWeakCount;
    NSInteger _glassesAppliedDelayMs;
}

#pragma mark - Configuration

- (BOOL)isVadEnabled {
    __block BOOL enabled = NO;
    [self performOnStateQueue:^{ enabled = self->_vadEnabled; }];
    return enabled;
}

- (void)setVadEnabled:(BOOL)vadEnabled {
    [self performOnStateQueue:^{
        if (self->_vadEnabled == vadEnabled) return;
        self->_vadEnabled = vadEnabled;
        self.suppressor.voiceDetectionEnabled = vadEnabled;
        [self clearVADSessionStateOnStateQueue];
    }];
}

- (BOOL)isEchoCancellationEnabled {
    return atomic_load_explicit(&_glassesEchoAtomic, memory_order_acquire);
}

- (void)setEchoCancellationEnabled:(BOOL)echoCancellationEnabled {
    [self performOnStateQueue:^{
        self->_glassesEchoEnabled = echoCancellationEnabled;
        atomic_store_explicit(&self->_glassesEchoAtomic, echoCancellationEnabled, memory_order_release);
        os_unfair_lock_lock(&self->_renderLock);
        self->_directRenderPending.length = 0;
        self->_renderAwaitingConsume.length = 0;
        self->_directRenderNextNs = 0;
        os_unfair_lock_unlock(&self->_renderLock);
        if (echoCancellationEnabled) {
            [self->_captureJitter reset];
            [self->_renderTimeQueue reset];
            self.readyPCMData.length = 0;
            [self configureGlassesAEC3OnStateQueue];
            self.pendingPCMData.length = 0;
            self.pendingRenderPCMData.length = 0;
            self->_renderNextFrameHostTimeNs = 0;
            self->_glassesAlignedFeed = NO;
            self->_glassesFedDelayMs = -1;
            self->_glassesApmSessionStart = CFAbsoluteTimeGetCurrent();
            self->_glassesRenderPairHits = 0;
            self->_glassesRenderPairMiss = 0;
            self->_glassesOutFrames = 0;
            self->_glassesLastPairSkewMs = 0;
            self->_glassesLastPairNs = 0;
            self->_glassesJbMinMs = -1;
            [self resetGlassesDelayTrackerOnStateQueue];
            [self startGlassesAPMTimerOnStateQueue];
        } else {
            [self stopGlassesAPMTimerOnStateQueue];
            self.suppressor.echoCancellationEnabled = NO;
        }
    }];
}

- (BOOL)echoDiagnosticsLoggingEnabled {
    __block BOOL enabled = NO;
    [self performOnStateQueue:^{ enabled = self->_echoDiagnosticsLoggingEnabled; }];
    return enabled;
}

- (void)setEchoDiagnosticsLoggingEnabled:(BOOL)echoDiagnosticsLoggingEnabled {
    [self performOnStateQueue:^{ self->_echoDiagnosticsLoggingEnabled = echoDiagnosticsLoggingEnabled; }];
}

- (NSString *)echoCancellationDiagnostics {
    __block NSString *line = nil;
    [self performOnStateQueue:^{
        double rms = self.farEndEnvelopeRMS;
        double refDb = rms > 1.0 ? 20.0 * log10(rms / 32768.0) : -120.0;
        int jbNowMs = [self->_captureJitter waterMs];
        int jbMs = self->_glassesJbMinMs >= 0 ? self->_glassesJbMinMs : jbNowMs;
        self->_glassesJbMinMs = jbNowMs;
        int rendQMs = [self->_renderTimeQueue queuedMs];
        int pairSkewMs = 0;
        if (self->_glassesLastPairNs > 0 && self->_glassesLastCaptureOutNs >= self->_glassesLastPairNs) {
            int64_t ageNs = (int64_t)self->_glassesLastCaptureOutNs - (int64_t)self->_glassesLastPairNs;
            if (ageNs < 200000000LL) pairSkewMs = self->_glassesLastPairSkewMs;
        }
        line = [NSString stringWithFormat:
                @"noTS=1 jb=%dms rendQ=%dms pairSkew=%dms hit=%d miss=%d ref=%.0fdB dly=%dms ncc=%.2f out=%d",
                jbMs, rendQMs, pairSkewMs, self->_glassesRenderPairHits, self->_glassesRenderPairMiss, refDb,
                self->_glassesDelayLocked ? self->_glassesDelaySamples * 1000 / kWRNSampleRate : -1,
                self->_glassesDelayNcc, self->_glassesOutFrames];
    }];
    return line ?: @"";
}

- (NSInteger)streamDelayMs {
    __block NSInteger value = kWRNInvalidStreamDelayMs;
    [self performOnStateQueue:^{ value = self->_streamDelayMs; }];
    return value;
}

- (void)setStreamDelayMs:(NSInteger)streamDelayMs {
    [self performOnStateQueue:^{
        self->_streamDelayMs = streamDelayMs;
        [self syncStreamDelayOnStateQueue];
        if (self.suppressor.isEchoCancellationEnabled) {
            [self emitAECDiagnosticsOnStateQueueForce:YES event:@"delay_change"];
        }
    }];
}

- (WRNEchoCanceller3Tuning)echoCancellerTuning {
    __block WRNEchoCanceller3Tuning tuning = WRNEchoCanceller3TuningDefault();
    [self performOnStateQueue:^{ tuning = self.suppressor.echoCancellerTuning; }];
    return tuning;
}

- (void)setEchoCancellerTuning:(WRNEchoCanceller3Tuning)echoCancellerTuning {
    [self performOnStateQueue:^{ self.suppressor.echoCancellerTuning = echoCancellerTuning; }];
}

- (void)processRenderPCMStreamData:(NSData *)pcmData {
    [self processRenderPCMStreamData:pcmData baseHostTimeNs:0];
}

- (void)processRenderPCMStreamData:(NSData *)pcmData hostTimeTicks:(uint64_t)hostTimeTicks {
    uint64_t ticks = hostTimeTicks != 0 ? hostTimeTicks : mach_absolute_time();
    [self processRenderPCMStreamData:pcmData baseHostTimeNs:WRNMachTicksToNanoseconds(ticks)];
}

- (void)processRenderPCMStreamData:(NSData *)pcmData baseHostTimeNs:(uint64_t)baseHostTimeNs {
    if (atomic_load_explicit(&_glassesEchoAtomic, memory_order_acquire)) {
        uint64_t ns = baseHostTimeNs > 0 ? baseHostTimeNs : WRNMachTicksToNanoseconds(mach_absolute_time());
        [self writeGlassesReferenceNow:pcmData hostTimeNs:ns];
        return;
    }
    [self performOnStateQueue:^{
        [self processRenderPCMStreamDataOnStateQueue:pcmData baseHostTimeNs:baseHostTimeNs];
    }];
}

- (float)rnnoiseVADThreshold {
    __block float value = 0.f;
    [self performOnStateQueue:^{ value = self->_rnnoiseVADThreshold; }];
    return value;
}

- (void)setRnnoiseVADThreshold:(float)rnnoiseVADThreshold {
    [self performOnStateQueue:^{ self->_rnnoiseVADThreshold = rnnoiseVADThreshold; }];
}

- (float)webrtcVADThreshold {
    __block float value = 0.f;
    [self performOnStateQueue:^{ value = self->_webrtcVADThreshold; }];
    return value;
}

- (void)setWebrtcVADThreshold:(float)webrtcVADThreshold {
    [self performOnStateQueue:^{ self->_webrtcVADThreshold = webrtcVADThreshold; }];
}

- (NSTimeInterval)vadEndHangoverSeconds {
    __block NSTimeInterval seconds = 0;
    [self performOnStateQueue:^{
        seconds = (NSTimeInterval)self->_vadEndHangoverFrames * kWRNFrameDurationSeconds;
    }];
    return seconds;
}

- (void)setVadEndHangoverSeconds:(NSTimeInterval)vadEndHangoverSeconds {
    [self performOnStateQueue:^{
        NSTimeInterval clamped =
            MAX(kWRNMinVADHangoverSeconds, MIN(kWRNMaxVADHangoverSeconds, vadEndHangoverSeconds));
        NSUInteger frames = (NSUInteger)llround(clamped / kWRNFrameDurationSeconds);
        self->_vadEndHangoverFrames = MAX((NSUInteger)1, frames);
    }];
}

#pragma mark - VAD readout

- (WRNVADFrameInfo)lastVADFrameInfo {
    __block WRNVADFrameInfo info = {0};
    [self performOnStateQueue:^{ info = self->_lastVADFrameInfo; }];
    return info;
}

- (BOOL)vadUtteranceHasSpeech {
    __block BOOL value = NO;
    [self performOnStateQueue:^{ value = self->_vadUtteranceHasSpeech; }];
    return value;
}

- (BOOL)utteranceSpeechEnded {
    __block BOOL value = NO;
    [self performOnStateQueue:^{ value = self->_utteranceSpeechEnded; }];
    return value;
}

- (void)performOnStateQueue:(dispatch_block_t)block {
    if (dispatch_get_specific(kWRNProcessorStateQueueKey)) {
        block();
        return;
    }
    dispatch_sync(self.stateQueue, block);
}

#pragma mark - Lifecycle

+ (instancetype)sharedProcessor {
    static WRNNoiseProcessor *processor = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        processor = [[WRNNoiseProcessor alloc] initPrivate];
    });
    return processor;
}

+ (NSData *)processPCMData:(NSData *)pcmData {
    WRNNoiseProcessor *processor = self.sharedProcessor;
    [processor resetProcessor];
    NSMutableData *output = [[processor processPCMStreamData:pcmData] mutableCopy];
    [output appendData:[processor processPCMStreamData:NSData.data]];
    NSAssert(output.length == pcmData.length, @"WRNNoiseProcessor 必须保持裸 PCM 字节长度不变。");
    [processor resetProcessor];
    return output;
}

+ (NSData *)processPCMFileAtURL:(NSURL *)fileURL error:(NSError **)error {
    NSData *pcmData = [NSData dataWithContentsOfURL:fileURL options:0 error:error];
    if (!pcmData) return nil;
    return [self processPCMData:pcmData];
}

- (instancetype)initPrivate {
    self = [super init];
    if (!self) return nil;
    _stateQueue = dispatch_queue_create("com.webrtc.wrnnoiseprocessor.state", DISPATCH_QUEUE_SERIAL);
    dispatch_queue_set_specific(_stateQueue, kWRNProcessorStateQueueKey, (void *)kWRNProcessorStateQueueKey, NULL);
    _suppressor = [[WRNNoiseSuppressor alloc] initWithSampleRate:kWRNSampleRate channels:kWRNChannels];
    _aecTimeline = [WRNAECTimeline new];
    _echoCanceller = [WRNEchoCanceller new];
    _pendingPCMData = [NSMutableData data];
    _pendingRenderPCMData = [NSMutableData data];
    _directRenderPending = [NSMutableData data];
    _renderAwaitingConsume = [NSMutableData data];
    _captureJitter = [WRNCaptureJitterBuffer new];
    _renderTimeQueue = [WRNRenderHostTimeQueue new];
    _renderLock = OS_UNFAIR_LOCK_INIT;
    _readyPCMData = [NSMutableData data];
    _glassesRenderHist = (int16_t *)calloc((size_t)kWRNGlassesDelayHistSamples, sizeof(int16_t));
    _glassesAppliedDelayMs = -1;
    _streamDelayMs = kWRNInvalidStreamDelayMs;
    _captureFrameHostTimeNs = 0;
    _gain = 1.0;
    _rnnoiseVADThreshold = kWRNDefaultRNNoiseVADThreshold;
    _webrtcVADThreshold = kWRNDefaultWebRTCVADThreshold;
    _vadEndHangoverFrames = kWRNDefaultVADHangoverFrames;
    _echoDiagnosticsLoggingEnabled = YES;
    _aecLastDiagnosticLogTime = 0;
    return self;
}

- (NSData *)processPCMStreamData:(NSData *)pcmData {
    __block NSData *result = nil;
    [self performOnStateQueue:^{
        if (self->_glassesEchoEnabled) {
            result = [self ingestGlassesCaptureToJitterOnStateQueue:pcmData];
        } else {
            self->_captureArrivalHostTimeNs = WRNMachTicksToNanoseconds(mach_absolute_time());
            result = [self processPCMStreamDataOnStateQueue:pcmData];
        }
    }];
    return result ?: NSData.data;
}

- (void)resetProcessor {
    [self performOnStateQueue:^{ [self clearStreamStateOnStateQueue]; }];
}

#pragma mark - Stream processing (state queue)

- (NSData *)processPCMStreamDataOnStateQueue:(NSData *)pcmData {
    if (pcmData.length == 0) {
        NSData *tail = [self flushPendingPCMDataOnStateQueue];
        if (tail.length == 0) return [self takeReadyPCMOnStateQueue];
        [self.readyPCMData appendData:tail];
        return [self takeReadyPCMOnStateQueue];
    }

    if (self->_glassesEchoEnabled) {
        return [self ingestGlassesCaptureToJitterOnStateQueue:pcmData];
    }

    if (self.suppressor.isEchoCancellationEnabled) {
        NSData *leading = [self takeReadyPCMOnStateQueue];
        NSUInteger pendingBefore = self.pendingPCMData.length;
        _aecCaptureIngressBytes += pcmData.length;
        [self.pendingPCMData appendData:pcmData];
        NSUInteger framesAdded = pcmData.length / kWRNFrameBytes;
        [self noteCaptureIngressOnStateQueue:framesAdded pendingWasEmpty:(pendingBefore == 0)];
        [self processPendingCaptureOnStateQueueForce:NO];
        NSData *trailing = [self takeReadyPCMOnStateQueue];
        NSData *output = [self concatenatePCMData:leading second:trailing];
        _lastReadyOutBytes = output.length;
        return output;
    }

    NSMutableData *input = [NSMutableData dataWithData:self.pendingPCMData];
    [input appendData:pcmData];
    NSUInteger evenLength = (input.length / kWRNSampleBytes) * kWRNSampleBytes;
    NSUInteger processableLength = (evenLength / kWRNFrameBytes) * kWRNFrameBytes;
    NSUInteger pendingLength = input.length - processableLength;
    NSData *processableData = [input subdataWithRange:NSMakeRange(0, processableLength)];
    self.pendingPCMData.length = 0;
    if (pendingLength > 0) {
        [self.pendingPCMData appendData:[input subdataWithRange:NSMakeRange(processableLength, pendingLength)]];
    }
    NSData *processed = [self processAlignedPCMData:processableData
                                    trimOutputBytes:processableLength
                                 captureHostTimeNs:0];
    if (self.readyPCMData.length == 0) return processed;
    [self.readyPCMData appendData:processed];
    return [self takeReadyPCMOnStateQueue];
}

- (NSData *)flushPendingPCMDataOnStateQueue {
    if (self->_glassesEchoEnabled) {
        return [self ingestGlassesCaptureToJitterOnStateQueue:NSData.data];
    }
    if (self.pendingPCMData.length == 0) return NSData.data;
    if (self.suppressor.isEchoCancellationEnabled) {
        [self processPendingCaptureOnStateQueueForce:YES];
        if (self.pendingPCMData.length > 0) {
            NSUInteger originalLength = self.pendingPCMData.length;
            NSMutableData *paddedData = [NSMutableData dataWithLength:kWRNFrameBytes];
            memcpy(paddedData.mutableBytes, self.pendingPCMData.bytes, originalLength);
            self.pendingPCMData.length = 0;
            [self consumeCaptureFrameDataOnStateQueue:paddedData
                                      trimOutputBytes:originalLength
                                                force:YES];
        }
        return NSData.data;
    }
    NSUInteger originalLength = self.pendingPCMData.length;
    NSMutableData *paddedData = [NSMutableData dataWithLength:kWRNFrameBytes];
    memcpy(paddedData.mutableBytes, self.pendingPCMData.bytes, MIN(originalLength, kWRNFrameBytes));
    self.pendingPCMData.length = 0;
    return [self processAlignedPCMData:paddedData
                        trimOutputBytes:MIN(originalLength, kWRNFrameBytes)
                     captureHostTimeNs:0];
}

- (void)configureGlassesAEC3OnStateQueue {
    if (!self.suppressor.isEchoCancellationEnabled) {
        self.suppressor.echoCancellationEnabled = YES;
    }
    self.suppressor.rnnoiseWetMix = 0.58f;
    // 无 TS：AEC3 内部估延迟 + 快跟踪（需 Vendor WebRTCAPM 暴露对应字段）。
    WRNEchoCanceller3Tuning desired = WRNEchoCanceller3TuningGlassesNoTS();
    WRNEchoCanceller3Tuning current = self.suppressor.echoCancellerTuning;
    if (current.applyMask != desired.applyMask ||
        current.delayUseExternalDelayEstimator != desired.delayUseExternalDelayEstimator ||
        current.delayEstimateSmoothing != desired.delayEstimateSmoothing ||
        current.delayEstimateSmoothingDelayFound != desired.delayEstimateSmoothingDelayFound ||
        current.filterCoarseInitialLengthBlocks != desired.filterCoarseInitialLengthBlocks) {
        self.suppressor.echoCancellerTuning = desired;
    }
    NSInteger baseline = self->_streamDelayMs >= 0 ? self->_streamDelayMs : kWRNGlassesAECBaselineDelayMs;
    self.suppressor.streamDelayMs = baseline;
}

- (void)startGlassesAPMTimerOnStateQueue {
    if (_glassesApmTimer) return;
    _glassesApmTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, _stateQueue);
    dispatch_source_set_timer(_glassesApmTimer, dispatch_time(DISPATCH_TIME_NOW, 0),
                              (uint64_t)(kWRNFrameDurationSeconds * NSEC_PER_SEC), (uint64_t)(1 * NSEC_PER_MSEC));
    __weak typeof(self) weakSelf = self;
    dispatch_source_set_event_handler(_glassesApmTimer, ^{
        __strong typeof(weakSelf) self = weakSelf;
        if (!self || !self->_glassesEchoEnabled) return;
        [self tickGlassesAPMOnStateQueue]; // 水位高时一次补多帧，避免定时器合并后采集堆在 90ms
        [self applyGlassesAPMPeriodicResetOnStateQueue];
    });
    dispatch_resume(_glassesApmTimer);
}

- (void)stopGlassesAPMTimerOnStateQueue {
    if (!_glassesApmTimer) return;
    dispatch_source_cancel(_glassesApmTimer);
    _glassesApmTimer = nil;
}

- (void)applyGlassesAPMPeriodicResetOnStateQueue {
    if (!_glassesEchoEnabled) return;
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (now - _glassesApmSessionStart < kWRNGlassesAPMResetIntervalSeconds) return;
    [_captureJitter reset];
    [_renderTimeQueue reset];
    self.readyPCMData.length = 0;
    [self.suppressor resetEchoCanceller];
    [self configureGlassesAEC3OnStateQueue];
    self.farEndEnvelopeRMS = 0;
    _glassesApmSessionStart = now;
    _glassesRenderPairHits = 0;
    _glassesRenderPairMiss = 0;
    _glassesOutFrames = 0;
    _glassesLastPairSkewMs = 0;
    _glassesLastPairNs = 0;
    _glassesJbMinMs = -1;
    // 滤镜状态清掉，已经对准的延迟和回声传递比留着，下一帧立刻装回去。
    _glassesAppliedDelayMs = -1;
}

- (void)resetGlassesDelayTrackerOnStateQueue {
    _glassesRenderHistWrite = 0;
    _glassesRenderHistCount = 0;
    _glassesCaptureSearchCount = 0;
    _glassesDelaySamples = 0;
    _glassesDelayLocked = 0;
    _glassesDelayNcc = 0;
    _glassesDelayPendingSamples = 0;
    _glassesDelayPendingCount = 0;
    _glassesDelayWeakCount = 0;
    _glassesAppliedDelayMs = -1;
    if (_glassesRenderHist) {
        memset(_glassesRenderHist, 0, (size_t)kWRNGlassesDelayHistSamples * sizeof(int16_t));
    }
    memset(_glassesCaptureSearch, 0, sizeof(_glassesCaptureSearch));
    [_echoCanceller reset];
}

- (void)appendGlassesRenderHistory:(const int16_t *)samples {
    if (!_glassesRenderHist || !samples) return;
    for (int i = 0; i < kWRNFrameSamples; i++) {
        _glassesRenderHist[_glassesRenderHistWrite] = samples[i];
        _glassesRenderHistWrite += 1;
        if (_glassesRenderHistWrite >= kWRNGlassesDelayHistSamples) _glassesRenderHistWrite = 0;
        if (_glassesRenderHistCount < kWRNGlassesDelayHistSamples) _glassesRenderHistCount += 1;
    }
}

- (int16_t)glassesRenderSampleAtLag:(int)lagFromNewest {
    int index = _glassesRenderHistWrite - 1 - lagFromNewest;
    while (index < 0) index += kWRNGlassesDelayHistSamples;
    return _glassesRenderHist[index];
}

- (float)glassesDelayNccAtLag:(int)lag {
    const int count = kWRNGlassesDelaySearchSamples;
    if (lag < 0 || !_glassesRenderHist || _glassesRenderHistCount < lag + count) return -1.f;
    const int histSize = kWRNGlassesDelayHistSamples;
    int index = _glassesRenderHistWrite - 1 - (lag + count - 1);
    while (index < 0) index += histSize;
    const int16_t *hist = _glassesRenderHist;
    const int16_t *capture = _glassesCaptureSearch;
    double dot = 0;
    double nearEnergy = 0;
    double farEnergy = 0;
    for (int i = 0; i < count; i++) {
        double near = capture[i];
        double far = hist[index];
        dot += near * far;
        nearEnergy += near * near;
        farEnergy += far * far;
        if (++index == histSize) index = 0;
    }
    if (nearEnergy < 2000.0 * count || farEnergy < 2000.0 * count) return -1.f;
    return (float)(dot / (sqrt(nearEnergy * farEnergy) + 1e-8));
}

- (BOOL)glassesRecentRenderActive {
    if (_glassesRenderHistCount < 800) return NO;
    double energy = 0;
    for (int i = 0; i < 800; i++) {
        float sample = (float)[self glassesRenderSampleAtLag:i];
        energy += sample * sample;
    }
    return energy > 10000.0 * 800.0;
}

- (BOOL)glassesDelayMaxLag:(int *)maxLag {
    if (_glassesCaptureSearchCount < kWRNGlassesDelaySearchSamples) return NO;
    if (![self glassesRecentRenderActive]) return NO;
    int max = _glassesRenderHistCount - kWRNGlassesDelaySearchSamples;
    if (max > kWRNGlassesDelayMaxSamples) max = kWRNGlassesDelayMaxSamples;
    if (max < kWRNGlassesDelayMinSamples) return NO;
    *maxLag = max;
    return YES;
}

- (void)glassesDelayGlobalPeakMaxLag:(int)maxLag lag:(int *)lagOut score:(float *)scoreOut {
    float best = -1.f;
    int bestLag = 0;
    for (int lag = kWRNGlassesDelayMinSamples; lag <= maxLag; lag += 16) {
        float ncc = [self glassesDelayNccAtLag:lag];
        if (ncc > best) {
            best = ncc;
            bestLag = lag;
        }
    }
    if (best >= 0.f) {
        int start = bestLag - 8;
        int end = bestLag + 8;
        if (start < kWRNGlassesDelayMinSamples) start = kWRNGlassesDelayMinSamples;
        if (end > maxLag) end = maxLag;
        for (int lag = start; lag <= end; lag++) {
            float ncc = [self glassesDelayNccAtLag:lag];
            if (ncc > best) {
                best = ncc;
                bestLag = lag;
            }
        }
    }
    *lagOut = bestLag;
    *scoreOut = best;
}

- (void)glassesDelayConsiderPeakLag:(int)bestLag score:(float)best {
    if (best < 0.35f) {
        _glassesDelayPendingCount = 0;
        return;
    }
    if (_glassesDelayPendingCount > 0 && abs(bestLag - _glassesDelayPendingSamples) <= 32) {
        _glassesDelayPendingCount += 1;
    } else {
        _glassesDelayPendingSamples = bestLag;
        _glassesDelayPendingCount = 1;
    }
    if (_glassesDelayPendingCount < 2) {
        if (!_glassesDelayLocked) _glassesDelayNcc = best;
        return;
    }
    _glassesDelaySamples = bestLag;
    _glassesDelayLocked = 1;
    _glassesDelayNcc = best;
    _glassesDelayPendingCount = 0;
    _glassesDelayWeakCount = 0;
}

- (void)updateGlassesDelayOnStateQueue {
    int maxLag = 0;
    if (![self glassesDelayMaxLag:&maxLag]) return;
    if (!_glassesDelayLocked) {
        int bestLag = 0;
        float best = -1.f;
        [self glassesDelayGlobalPeakMaxLag:maxLag lag:&bestLag score:&best];
        [self glassesDelayConsiderPeakLag:bestLag score:best];
        return;
    }
    // 40ms 窗上，只看当前延迟附近。峰还在就向它走 1ms，假峰够不着。
    static const int offsets[] = {0, 16, -16, 32, -32, 64, -64, 128, -128, 256, -256};
    float heldScore = -1.f;
    float best = -1.f;
    int bestLag = _glassesDelaySamples;
    for (int i = 0; i < (int)(sizeof(offsets) / sizeof(offsets[0])); i++) {
        int lag = _glassesDelaySamples + offsets[i];
        if (lag < kWRNGlassesDelayMinSamples || lag > maxLag) continue;
        float ncc = [self glassesDelayNccAtLag:lag];
        if (offsets[i] == 0) heldScore = ncc;
        if (ncc > best) {
            best = ncc;
            bestLag = lag;
        }
    }
    if (heldScore >= 0.f) _glassesDelayNcc = heldScore;
    if (best >= 0.25f) {
        _glassesDelayWeakCount = 0;
        _glassesDelayPendingCount = 0;
        int step = bestLag - _glassesDelaySamples;
        if (step > 16) step = 16;
        if (step < -16) step = -16;
        _glassesDelaySamples += step;
        return;
    }
    _glassesDelayWeakCount += 1;
    // 附近的峰连续约 200ms 都低于 0.25，才重新全局搜索。
    if (_glassesDelayWeakCount < 10) return;
    int peakLag = 0;
    float peak = -1.f;
    [self glassesDelayGlobalPeakMaxLag:maxLag lag:&peakLag score:&peak];
    [self glassesDelayConsiderPeakLag:peakLag score:peak];
}

- (void)applyGlassesDelayToAEC3OnStateQueue {
    if (!_glassesDelayLocked) return;
    NSInteger ms = _glassesDelaySamples / 16;
    if (ms < 80) ms = 80;
    if (ms > 900) ms = 900;
    if (llabs(ms - _glassesAppliedDelayMs) < 12 && _glassesAppliedDelayMs >= 0) return;
    self.suppressor.streamDelayMs = ms;
    _glassesAppliedDelayMs = ms;
}

- (void)trackGlassesEchoOnStateQueue:(const int16_t *)capture
                              render:(const int16_t *)render
                          haveRender:(BOOL)haveRender {
    memmove(_glassesCaptureSearch,
            _glassesCaptureSearch + kWRNFrameSamples,
            (size_t)(kWRNGlassesDelaySearchSamples - kWRNFrameSamples) * sizeof(int16_t));
    memcpy(_glassesCaptureSearch + (kWRNGlassesDelaySearchSamples - kWRNFrameSamples),
           capture,
           kWRNFrameBytes);
    if (_glassesCaptureSearchCount < kWRNGlassesDelaySearchSamples) {
        _glassesCaptureSearchCount += kWRNFrameSamples;
    }
    int16_t silent[kWRNFrameSamples] = {0};
    [self appendGlassesRenderHistory:haveRender ? render : silent];
    if ((_glassesOutFrames & 1) == 0) {
        [self updateGlassesDelayOnStateQueue];
    }
    [self applyGlassesDelayToAEC3OnStateQueue];
}

- (BOOL)pumpOneGlassesFrameOnStateQueue {
    int16_t capture[kWRNFrameSamples];
    uint64_t captureOutNs = 0;
    if (![_captureJitter popFrame160:capture captureOutHostTimeNs:&captureOutNs]) return NO;
    _glassesLastCaptureOutNs = captureOutNs;
    int16_t render[kWRNFrameSamples] = {0};
    uint64_t renderPlayNs = 0;
    BOOL haveRender = [_renderTimeQueue popFrontFrame160:render playHostTimeNs:&renderPlayNs];
    if (haveRender) {
        _glassesRenderPairHits += 1;
        _glassesLastRenderPlayNs = renderPlayNs;
        int64_t deltaNs = (int64_t)captureOutNs - (int64_t)renderPlayNs;
        _glassesLastPairSkewMs = (int)(deltaNs / 1000000) - (int)kWRNGlassesRenderPairingOffsetMs;
        _glassesLastPairNs = captureOutNs;
        [self updateFarEndEnvelopeWithFrame:render];
        [self.suppressor processRenderPCM:render frameCount:kWRNFrameSamples];
    } else {
        _glassesRenderPairMiss += 1;
        [self decayFarEndEnvelopeOnStateQueue];
    }
    [self trackGlassesEchoOnStateQueue:capture render:render haveRender:haveRender];
    WRNVADFrameInfo raw = {0};
    [self.suppressor processCapturePCM:capture
                            frameCount:kWRNFrameSamples
                                outVAD:self->_vadEnabled ? &raw : NULL
                        outApmFrameRms:NULL];
    if (_glassesDelayLocked &&
        _glassesRenderHistCount >= _glassesDelaySamples + kWRNFrameSamples) {
        int16_t aligned[kWRNFrameSamples];
        for (int i = 0; i < kWRNFrameSamples; i++) {
            int lagFromNewest = _glassesDelaySamples + (kWRNFrameSamples - 1 - i);
            aligned[i] = [self glassesRenderSampleAtLag:lagFromNewest];
        }
        [_echoCanceller applyResidualSuppressionToSamples:capture
                                               reference:aligned
                                                   count:kWRNFrameSamples
                                                 enabled:YES];
    }
    if (self->_vadEnabled) {
        [self updateVADStateWithFrame:[self vadFrameInfoByApplyingThresholds:raw]];
    }
    [self applySmoothAGCToSamples:capture sampleCount:kWRNFrameSamples];
    [self.readyPCMData appendBytes:capture length:kWRNFrameBytes];
    _glassesOutFrames += 1;
    return YES;
}

- (void)noteGlassesJitterWaterOnStateQueue {
    int water = [_captureJitter waterMs];
    if (_glassesJbMinMs < 0 || water < _glassesJbMinMs) _glassesJbMinMs = water;
}

- (void)decayFarEndEnvelopeOnStateQueue {
    if (self.farEndEnvelopeRMS < 1.0) {
        self.farEndEnvelopeRMS = 0;
        return;
    }
    double alpha = exp(-kWRNFrameDurationSeconds / 0.35);
    self.farEndEnvelopeRMS *= alpha;
}

- (void)tickGlassesAPMOnStateQueue {
    [self noteGlassesJitterWaterOnStateQueue];
    int water = [_captureJitter waterMs];
    int budget = 1;
    if (water > 55) budget = 2;
    if (water > 70) budget = 4;
    if (water > 100) budget = 6;
    for (int i = 0; i < budget; i++) {
        if (![self pumpOneGlassesFrameOnStateQueue]) break;
    }
    [self noteGlassesJitterWaterOnStateQueue];
}

- (NSData *)ingestGlassesCaptureToJitterOnStateQueue:(NSData *)pcmData {
    if (pcmData.length > 0) {
        [_captureJitter pushPCMBytes:pcmData.bytes length:pcmData.length];
    }
    return [self takeReadyPCMOnStateQueue];
}

- (void)writeGlassesReferenceNow:(NSData *)pcmData hostTimeNs:(uint64_t)hostTimeNs {
    if (pcmData.length == 0) return;
    uint64_t frameHostNs = 0;
    if (hostTimeNs > 0) {
        frameHostNs = hostTimeNs;
        if (_directRenderNextNs > 0 && frameHostNs < _directRenderNextNs) {
            frameHostNs = _directRenderNextNs;
        }
    } else {
        frameHostNs = _directRenderNextNs > 0 ? _directRenderNextNs : WRNMachTicksToNanoseconds(mach_absolute_time());
    }
    os_unfair_lock_lock(&_renderLock);
    [_directRenderPending appendData:pcmData];
    int16_t frame[kWRNFrameSamples];
    const uint64_t frameStepNs = (uint64_t)(kWRNFrameDurationSeconds * 1000000000.0);
    while (_directRenderPending.length >= kWRNFrameBytes) {
        memcpy(frame, _directRenderPending.bytes, kWRNFrameBytes);
        [_directRenderPending replaceBytesInRange:NSMakeRange(0, kWRNFrameBytes) withBytes:NULL length:0];
        [_renderTimeQueue pushFrame160:frame playHostTimeNs:frameHostNs];
        [self updateFarEndEnvelopeWithFrame:frame];
        frameHostNs += frameStepNs;
        _directRenderNextNs = frameHostNs;
    }
    os_unfair_lock_unlock(&_renderLock);
}

- (void)ingestGlassesEchoReferenceOnStateQueue:(NSData *)pcmData baseHostTimeNs:(uint64_t)baseHostTimeNs {
    (void)baseHostTimeNs;
    [self writeGlassesReferenceNow:pcmData hostTimeNs:0];
}

- (void)processRenderPCMStreamDataOnStateQueue:(NSData *)pcmData baseHostTimeNs:(uint64_t)baseHostTimeNs {
    if (self->_glassesEchoEnabled) {
        [self ingestGlassesEchoReferenceOnStateQueue:pcmData baseHostTimeNs:baseHostTimeNs];
        return;
    }
    if (!self.suppressor.isEchoCancellationEnabled) return;
    if (pcmData.length == 0) {
        [self.aecTimeline noteRenderPlaybackEnded];
        [self flushPendingRenderPCMDataOnStateQueue];
        _renderNextFrameHostTimeNs = 0;
        return;
    }
    if (self.pendingRenderPCMData.length == 0) {
        uint64_t machNow = [WRNAECTimeline hostTimeNanoseconds];
        BOOL useExternalBase = (baseHostTimeNs > 0 && !_ignoreExternalRenderBaseHostTime);
        if (useExternalBase) {
            int64_t skewMs = (int64_t)((int64_t)baseHostTimeNs - (int64_t)machNow) / 1000000LL;
            if (!_renderClockSkewLogged && labs(skewMs) > kWRNRenderClockSkewThresholdMs) {
                _ignoreExternalRenderBaseHostTime = YES;
                _renderClockSkewLogged = YES;
                [self emitAECDiagnosticsOnStateQueueForce:YES event:@"render_clock_skew"];
                useExternalBase = NO;
            }
        }
        if (useExternalBase) {
            if (_renderNextFrameHostTimeNs > 0 &&
                baseHostTimeNs + kWRNBadRenderBaseLagNs < _renderNextFrameHostTimeNs) {
                useExternalBase = NO;
            }
        }
        if (useExternalBase) {
            if (_renderNextFrameHostTimeNs == 0) {
                _renderNextFrameHostTimeNs = baseHostTimeNs;
            } else {
                _renderNextFrameHostTimeNs = MAX(_renderNextFrameHostTimeNs, baseHostTimeNs);
            }
        } else if (_renderNextFrameHostTimeNs == 0) {
            _renderNextFrameHostTimeNs = machNow;
        }
    }
    [self.pendingRenderPCMData appendData:pcmData];
    const uint64_t frameDurationNs = [WRNAECTimeline frameDurationNs];
    int16_t frame[kWRNFrameSamples];
    while (self.pendingRenderPCMData.length >= kWRNFrameBytes) {
        memcpy(frame, self.pendingRenderPCMData.bytes, kWRNFrameBytes);
        [self.pendingRenderPCMData replaceBytesInRange:NSMakeRange(0, kWRNFrameBytes) withBytes:NULL length:0];
        uint64_t hostTimeNs = _renderNextFrameHostTimeNs;
        _renderNextFrameHostTimeNs += frameDurationNs;
        [self pushRenderFrameOnStateQueue:frame hostTimeNs:hostTimeNs];
    }
}

- (void)flushPendingRenderPCMDataOnStateQueue {
    if (self.pendingRenderPCMData.length == 0) return;
    int16_t frame[kWRNFrameSamples] = {0};
    memcpy(frame, self.pendingRenderPCMData.bytes, self.pendingRenderPCMData.length);
    self.pendingRenderPCMData.length = 0;
    uint64_t hostTimeNs =
        _renderNextFrameHostTimeNs > 0 ? _renderNextFrameHostTimeNs : [WRNAECTimeline hostTimeNanoseconds];
    [self pushRenderFrameOnStateQueue:frame hostTimeNs:hostTimeNs];
    _renderNextFrameHostTimeNs = 0;
}

- (void)pushRenderFrameOnStateQueue:(const int16_t *)frame hostTimeNs:(uint64_t)hostTimeNs {
    [self updateFarEndEnvelopeWithFrame:frame];
    [self.aecTimeline ingestRenderFrame:frame hostTimeNs:hostTimeNs];
    [self processPendingCaptureOnStateQueueForce:NO];
}

- (void)updateFarEndEnvelopeWithFrame:(const int16_t *)frame {
    double energy = 0;
    for (int i = 0; i < kWRNFrameSamples; i++) {
        double sample = (double)frame[i];
        energy += sample * sample;
    }
    double frameRMS = sqrt(energy / (double)kWRNFrameSamples);
    double tau = frameRMS > self.farEndEnvelopeRMS ? 0.02 : 0.35;
    double alpha = exp(-kWRNFrameDurationSeconds / tau);
    self.farEndEnvelopeRMS = alpha * self.farEndEnvelopeRMS + (1.0 - alpha) * frameRMS;
}

- (NSInteger)baselineStreamDelayMsOnStateQueue {
    NSInteger timelineDelay = _streamDelayMs;
    if (timelineDelay < 0 || timelineDelay > 1500) {
        timelineDelay = kWRNDefaultGlassesPipelineDelayMs;
    }
    return timelineDelay;
}

/// 宿主 `streamDelayMs` 仅覆盖喇叭→眼镜麦；采集 PCM 经 BLE 才到手机，APM 须叠加 BLE 管道。
- (NSInteger)apmStreamDelayMsOnStateQueue {
    NSInteger base = [self baselineStreamDelayMsOnStateQueue];
    NSInteger total = base + kWRNBleIngressPipelineMs;
    return MIN(total, 1500);
}

- (NSInteger)totalCaptureToRenderDelayMsOnStateQueue {
    return [self apmStreamDelayMsOnStateQueue];
}

- (void)applyEchoCancellerTuningForDelayMs:(NSInteger)delayMs {
    WRNEchoCanceller3Tuning desired = WRNEchoCanceller3TuningDefault();
    desired.applyMask = WRNEchoCanceller3TuningDelayDefaultDelay;
    desired.delayDefaultDelay = (int)delayMs;
    desired.delayUseExternalDelayEstimator = 0;
    WRNEchoCanceller3Tuning current = self.suppressor.echoCancellerTuning;
    if (current.applyMask != desired.applyMask || current.delayDefaultDelay != desired.delayDefaultDelay ||
        current.delayUseExternalDelayEstimator != desired.delayUseExternalDelayEstimator) {
        self.suppressor.echoCancellerTuning = desired;
    }
}

- (void)syncStreamDelayOnStateQueue {
    if (self->_glassesEchoEnabled) {
        // `streamDelayMs` 仅在创建/重置/周期 Reset 时写入 APM，避免打乱 AEC3 内部收敛。
        return;
    }
    NSInteger ringDelayMs = [self apmStreamDelayMsOnStateQueue];
    _effectiveDelayMs = ringDelayMs;
    self.aecTimeline.pipelineDelayMs = ringDelayMs;
    self.suppressor.streamDelayMs = kWRNAPMStreamDelayWhenPairedMs;
    [self applyEchoCancellerTuningForDelayMs:kWRNAPMStreamDelayWhenPairedMs];
}

- (uint64_t)ingressLastCaptureFrameHostTimeNsOnStateQueue {
    uint64_t now = [WRNAECTimeline hostTimeNanoseconds];
    uint64_t offsetNs = (uint64_t)(kWRNCaptureIngressBiasMs + kWRNBleIngressPipelineMs) * 1000000ULL;
    return now > offsetNs ? now - offsetNs : now;
}

- (void)anchorCaptureBatchOnStateQueueWithTotalFrames:(NSUInteger)totalFrames useRenderClock:(BOOL)useRenderClock {
    if (totalFrames == 0) {
        return;
    }
    const uint64_t frameDurationNs = [WRNAECTimeline frameDurationNs];
    uint64_t lastFrameNs = [self ingressLastCaptureFrameHostTimeNsOnStateQueue];
    _lastCaptureAnchorSource = 'i';

    if (useRenderClock) {
        WRNAECTimeline *timeline = self.aecTimeline;
        uint64_t lastRenderNs = timeline.lastRenderHostTimeNs;
        if (lastRenderNs > 0) {
            NSInteger delayMs = [self totalCaptureToRenderDelayMsOnStateQueue];
            uint64_t delayNs = (uint64_t)delayMs * 1000000ULL;
            uint64_t renderAnchoredLast =
                lastRenderNs > delayNs ? lastRenderNs - delayNs : lastRenderNs;
            int64_t slewMs = (int64_t)((int64_t)renderAnchoredLast - (int64_t)lastFrameNs) / 1000000LL;
            if (slewMs > kWRNCaptureAnchorMaxSlewMs) {
                renderAnchoredLast =
                    lastFrameNs + (uint64_t)kWRNCaptureAnchorMaxSlewMs * 1000000ULL;
            } else if (slewMs < -kWRNCaptureAnchorMaxSlewMs) {
                renderAnchoredLast =
                    lastFrameNs - (uint64_t)kWRNCaptureAnchorMaxSlewMs * 1000000ULL;
            }
            lastFrameNs = renderAnchoredLast;
            _lastCaptureAnchorSource = 'r';
        }
    }

    uint64_t spanNs = (totalFrames > 1) ? (totalFrames - 1) * frameDurationNs : 0;
    _captureBatchStartNs = lastFrameNs > spanNs ? lastFrameNs - spanNs : lastFrameNs;
    _captureBatchNextIndex = 0;
    _captureBatchTotal = totalFrames;

    if (_echoDiagnosticsLoggingEnabled) {
        WRNAECTimeline *timeline = self.aecTimeline;
        int64_t skewMs = 0;
        if (timeline.lastRenderHostTimeNs > 0) {
            skewMs = ((int64_t)lastFrameNs - (int64_t)timeline.lastRenderHostTimeNs) / 1000000LL;
        }
        WRNAECLog(@"event=capture_anchor source=%c batchFrames=%lu lastSkewToRenderMs=%lld ingressBleMs=%ld",
                  _lastCaptureAnchorSource,
                  (unsigned long)totalFrames,
                  (long long)skewMs,
                  (long)(kWRNCaptureIngressBiasMs + kWRNBleIngressPipelineMs));
    }
}

- (BOOL)shouldResyncCaptureTimelineOnStateQueue {
    if (_captureFrameHostTimeNs == 0) {
        return YES;
    }
    uint64_t now = [WRNAECTimeline hostTimeNanoseconds];
    return now > _captureFrameHostTimeNs + kWRNCaptureTimelineGapResyncNs;
}

- (void)nudgeCaptureTimelineTowardRenderOnStateQueue {
    WRNAECTimeline *timeline = self.aecTimeline;
    if (_captureFrameHostTimeNs == 0 || timeline.lastRenderHostTimeNs == 0) {
        return;
    }
    if (!timeline.farEndPlaybackActive && self.farEndEnvelopeRMS < kWRNFarEndAGCGateRMS) {
        return;
    }
    NSInteger delayMs = [self totalCaptureToRenderDelayMsOnStateQueue];
    uint64_t delayNs = (uint64_t)delayMs * 1000000ULL;
    uint64_t lastRenderNs = timeline.lastRenderHostTimeNs;
    uint64_t targetLastNs = lastRenderNs > delayNs ? lastRenderNs - delayNs : 0;
    int64_t errMs =
        ((int64_t)targetLastNs - (int64_t)_captureFrameHostTimeNs) / 1000000LL;
    if (labs(errMs) <= kWRNCaptureTimelineNudgeDeadbandMs) {
        return;
    }
    NSInteger stepMs = (NSInteger)errMs;
    if (stepMs > kWRNCaptureTimelineNudgeMaxStepMs) {
        stepMs = kWRNCaptureTimelineNudgeMaxStepMs;
    } else if (stepMs < -kWRNCaptureTimelineNudgeMaxStepMs) {
        stepMs = -kWRNCaptureTimelineNudgeMaxStepMs;
    }
    int64_t stepNs = (int64_t)stepMs * 1000000LL;
    uint64_t uStepNs = stepNs >= 0 ? (uint64_t)stepNs : 0;
    if (stepNs < 0) {
        uint64_t absStep = (uint64_t)(-stepNs);
        if (_captureFrameHostTimeNs > absStep) {
            _captureFrameHostTimeNs -= absStep;
        }
        if (_captureBatchStartNs > absStep) {
            _captureBatchStartNs -= absStep;
        }
    } else {
        _captureFrameHostTimeNs += uStepNs;
        _captureBatchStartNs += uStepNs;
    }
    _lastCaptureAnchorSource = 'n';
}

- (void)extendCaptureStreamTimelineOnStateQueueWithTotalFrames:(NSUInteger)totalFrames {
    if (totalFrames == 0) {
        return;
    }
    const uint64_t frameDurationNs = [WRNAECTimeline frameDurationNs];
    uint64_t nextFirstNs = _captureFrameHostTimeNs + frameDurationNs;
    _captureBatchStartNs = nextFirstNs;
    _captureBatchNextIndex = 0;
    _captureBatchTotal = totalFrames;
    _lastCaptureAnchorSource = 'c';
    [self nudgeCaptureTimelineTowardRenderOnStateQueue];
}

- (void)noteCaptureIngressOnStateQueue:(NSUInteger)newFullFrames pendingWasEmpty:(BOOL)pendingWasEmpty {
    (void)newFullFrames;
    NSUInteger totalFrames = self.pendingPCMData.length / kWRNFrameBytes;
    if (totalFrames == 0) {
        return;
    }

    if (!pendingWasEmpty) {
        _captureBatchTotal = totalFrames;
        return;
    }

  // BLE 常见「一包 8 帧、处理完 pending 清零」：不能每包全量 anchor，否则时间轴被撕碎。
    if (_captureFrameHostTimeNs > 0 && ![self shouldResyncCaptureTimelineOnStateQueue]) {
        [self extendCaptureStreamTimelineOnStateQueueWithTotalFrames:totalFrames];
        return;
    }

    BOOL useRenderClock =
        [self isFarEndActiveForMetricsOnStateQueue] || self.aecTimeline.farEndPlaybackActive;
    [self anchorCaptureBatchOnStateQueueWithTotalFrames:totalFrames useRenderClock:useRenderClock];
    [self nudgeCaptureTimelineTowardRenderOnStateQueue];
}

- (NSData *)concatenatePCMData:(NSData *)first second:(NSData *)second {
    if (first.length == 0) {
        return second ?: NSData.data;
    }
    if (second.length == 0) {
        return first;
    }
    NSMutableData *combined = [first mutableCopy];
    [combined appendData:second];
    return combined;
}

- (uint64_t)peekNextCaptureFrameHostTimeNsOnStateQueue {
    const uint64_t frameDurationNs = [WRNAECTimeline frameDurationNs];
    if (_captureBatchNextIndex < _captureBatchTotal) {
        return _captureBatchStartNs + _captureBatchNextIndex * frameDurationNs;
    }
    if (_captureFrameHostTimeNs > 0) {
        return _captureFrameHostTimeNs + frameDurationNs;
    }
    return [self ingressLastCaptureFrameHostTimeNsOnStateQueue];
}

- (uint64_t)nextCaptureFrameHostTimeNsOnStateQueue {
    const uint64_t frameDurationNs = [WRNAECTimeline frameDurationNs];
    if (_captureBatchNextIndex < _captureBatchTotal) {
        uint64_t timestamp = _captureBatchStartNs + _captureBatchNextIndex * frameDurationNs;
        _captureBatchNextIndex += 1;
        _captureFrameHostTimeNs = timestamp;
        return timestamp;
    }
    uint64_t now = [WRNAECTimeline hostTimeNanoseconds];
    if (_captureFrameHostTimeNs == 0) {
        _captureFrameHostTimeNs = [self ingressLastCaptureFrameHostTimeNsOnStateQueue];
        return _captureFrameHostTimeNs;
    }
  // 长时间无包后再到达：用 ingress 重锚，避免时间轴与 render 脱节。
    if ([self shouldResyncCaptureTimelineOnStateQueue]) {
        _captureFrameHostTimeNs = [self ingressLastCaptureFrameHostTimeNsOnStateQueue];
        _lastCaptureAnchorSource = 'g';
        _captureBatchNextIndex = 0;
        _captureBatchTotal = 0;
        return _captureFrameHostTimeNs;
    }
    _captureFrameHostTimeNs += frameDurationNs;
    return _captureFrameHostTimeNs;
}

- (void)processPendingCaptureOnStateQueueForce:(BOOL)force {
    if (!self.suppressor.isEchoCancellationEnabled) return;
    NSUInteger pendingFrames = self.pendingPCMData.length / kWRNFrameBytes;
    [self.aecTimeline notePendingCaptureFrames:pendingFrames];
    while (self.pendingPCMData.length >= kWRNFrameBytes) {
        uint64_t captureHostTimeNs = [self peekNextCaptureFrameHostTimeNsOnStateQueue];
        if (!force &&
            [self.aecTimeline isEchoCancellationWindowForCaptureHostTimeNs:captureHostTimeNs] &&
            self.aecTimeline.ringFrames == 0) {
            _aecRefNotReadyBreakCount += 1;
            break;
        }
        NSData *frameData = [self.pendingPCMData subdataWithRange:NSMakeRange(0, kWRNFrameBytes)];
        [self.pendingPCMData replaceBytesInRange:NSMakeRange(0, kWRNFrameBytes) withBytes:NULL length:0];
        [self consumeCaptureFrameDataOnStateQueue:frameData
                                  trimOutputBytes:kWRNFrameBytes
                                            force:force];
    }
}

- (void)consumeCaptureFrameDataOnStateQueue:(NSData *)frameData
                            trimOutputBytes:(NSUInteger)trimOutputBytes
                                      force:(BOOL)force {
    if (frameData.length < kWRNFrameBytes) return;
    uint64_t captureHostTimeNs = [self nextCaptureFrameHostTimeNsOnStateQueue];
    WRNAECReferenceAvailability availability =
        [self.aecTimeline availabilityForCaptureHostTimeNs:captureHostTimeNs];
    [self noteReferenceAvailabilityOnStateQueue:availability force:force];
    [self.aecTimeline noteCaptureFrameProcessed];
    _aecCaptureOutFrames += 1;

    NSData *processed = [self processAlignedPCMData:frameData
                                    trimOutputBytes:trimOutputBytes
                                 captureHostTimeNs:captureHostTimeNs];
    if ([self isFarEndActiveForMetricsOnStateQueue]) {
        [self checkAECWeakEchoOnStateQueue];
    }
    if (processed.length) [self.readyPCMData appendData:processed];
    [self emitAECDiagnosticsOnStateQueueForce:NO event:nil];
}

- (NSData *)takeReadyPCMOnStateQueue {
    if (self.readyPCMData.length == 0) return NSData.data;
    NSData *ready = [self.readyPCMData copy];
    self.readyPCMData.length = 0;
    return ready;
}

- (void)clearStreamStateOnStateQueue {
    BOOL wasEcho = self.suppressor.isEchoCancellationEnabled;
    self.pendingPCMData.length = 0;
    self.pendingRenderPCMData.length = 0;
    self.readyPCMData.length = 0;
    [self.aecTimeline reset];
    [self.echoCanceller reset];
    os_unfair_lock_lock(&_renderLock);
    _directRenderPending.length = 0;
    _renderAwaitingConsume.length = 0;
    _directRenderNextNs = 0;
    os_unfair_lock_unlock(&_renderLock);
    if (self->_glassesEchoEnabled) {
        [_captureJitter reset];
        [_renderTimeQueue reset];
        _glassesApmSessionStart = CFAbsoluteTimeGetCurrent();
        [self.suppressor resetEchoCanceller];
        [self configureGlassesAEC3OnStateQueue];
        self->_glassesAlignedFeed = NO;
        self->_glassesFedDelayMs = -1;
    } else {
        [self syncStreamDelayOnStateQueue];
    }
    _captureFrameHostTimeNs = 0;
    _captureBatchStartNs = 0;
    _captureBatchNextIndex = 0;
    _captureBatchTotal = 0;
    self.farEndEnvelopeRMS = 0;
    self.envelopeEnergy = 0.0;
    self.gain = 1.0;
    self.hasEnvelope = NO;
    _aecCaptureIngressBytes = 0;
    _aecCaptureOutFrames = 0;
    [self resetAECDiagnosticSessionCountersOnStateQueue];
    [self clearVADSessionStateOnStateQueue];
    if (wasEcho) [self emitAECDiagnosticsOnStateQueueForce:YES event:@"processor_reset"];
}

- (void)resetAECDiagnosticSessionCountersOnStateQueue {
    _aecLastDiagnosticLogTime = 0;
    _aecUnderrunStreak = 0;
    _aecRefNotReadyBreakCount = 0;
    _lastReadyOutBytes = 0;
    _renderNextFrameHostTimeNs = 0;
    _aecEmaInRms = 0;
    _aecEmaOutRms = 0;
    _aecEmaErlDb = 0;
    _aecEmaRefSkewMs = 0;
    _aecEmaPostAgcGain = 0;
    _aecWeakEchoBadSince = 0;
    _aecWeakEchoLogged = NO;
    _ignoreExternalRenderBaseHostTime = NO;
    _renderClockSkewLogged = NO;
    _effectiveDelayMs = kWRNInvalidStreamDelayMs;
    _aecFarActiveMetricFrames = 0;
    _aecPairedRefFrames = 0;
    _aecPairedRefMissFrames = 0;
    _lastCaptureAnchorSource = 0;
}

- (BOOL)isFarEndActiveForMetricsOnStateQueue {
    if (!self.suppressor.isEchoCancellationEnabled) {
        return NO;
    }
    if (self.aecTimeline.farEndPlaybackActive) {
        return YES;
    }
    return self.farEndEnvelopeRMS >= kWRNFarEndAGCGateRMS;
}

- (void)noteAECFrameMetricsWithInRms:(double)inRms
                         apmOutRms:(double)apmOutRms
                      finalOutRms:(double)finalOutRms
                        refSkewMs:(double)refSkewMs {
    _aecFarActiveMetricFrames += 1;
    _aecEmaInRms = WRNUpdateEma(_aecEmaInRms, inRms, kWRNAECMetricEmaAlpha);
    _aecEmaOutRms = WRNUpdateEma(_aecEmaOutRms, finalOutRms, kWRNAECMetricEmaAlpha);
    _aecEmaRefSkewMs = WRNUpdateEma(_aecEmaRefSkewMs, refSkewMs, kWRNAECMetricEmaAlpha);
    double denom = MAX(inRms, 1.0);
    double apmErlDb = 20.0 * log10(MAX(apmOutRms, 1.0) / denom);
    _aecEmaErlDb = WRNUpdateEma(_aecEmaErlDb, apmErlDb, kWRNAECMetricEmaAlpha);
}

- (void)checkAECWeakEchoOnStateQueue {
    if (!_echoDiagnosticsLoggingEnabled || _aecWeakEchoLogged) {
        return;
    }
    if (![self isFarEndActiveForMetricsOnStateQueue] || _aecEmaErlDb == 0) {
        _aecWeakEchoBadSince = 0;
        return;
    }
    if (_aecEmaErlDb > -6.0) {
        CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
        if (_aecWeakEchoBadSince <= 0) {
            _aecWeakEchoBadSince = now;
            return;
        }
        if (now - _aecWeakEchoBadSince >= 3.0) {
            _aecWeakEchoLogged = YES;
            [self emitAECDiagnosticsOnStateQueueForce:YES event:@"aec_weak_echo"];
        }
    } else {
        _aecWeakEchoBadSince = 0;
    }
}

- (NSString *)aecDiagnosticCountsLineOnStateQueue {
    WRNEchoCanceller3Tuning tuning = self.suppressor.echoCancellerTuning;
    NSUInteger pendingFrames = self.pendingPCMData.length / kWRNFrameBytes;
    WRNAECTimeline *timeline = self.aecTimeline;
    uint64_t ringDepthMs = timeline.ringDepthNs / 1000000ULL;
    uint64_t peekCaptureNs = [self peekNextCaptureFrameHostTimeNsOnStateQueue];
    int64_t renderCaptureSkewMs = 0;
    if (timeline.lastRenderHostTimeNs > 0) {
        renderCaptureSkewMs =
            ((int64_t)peekCaptureNs - (int64_t)timeline.lastRenderHostTimeNs) / 1000000LL;
    }
    BOOL farEnvActive = (self.farEndEnvelopeRMS >= kWRNFarEndAGCGateRMS);
    return [NSString stringWithFormat:
            @"mode=paired echo=%d streamDelayMs=%ld ringDelayMs=%ld apmDelay=%ld apmBleMs=%ld tuneMask=0x%x farActive=%d farEnvActive=%d "
            @"renderIngested=%lums captureOut=%lums pairedRef=%lu pairedMiss=%lu matched=%lu skippedNoFarEnd=%lu underrun=%lu "
            @"ring=%lu ringDepth=%llums maxPending=%lu pendingNow=%lu pendingHeld=%lu refNotReadyBreak=%lu "
            @"readyOutBytes=%lu captureIngress=%lu farRMS=%.0f refSkewMs=%.0f inRms=%.0f outRms=%.0f erlDb=%.1f "
            @"refClamped=%lu postAgcGain=%.2f renderCaptureSkewMs=%lld captureAnchor=%c",
            self.suppressor.isEchoCancellationEnabled ? 1 : 0,
            (long)([self baselineStreamDelayMsOnStateQueue]),
            (long)(_effectiveDelayMs >= 0 ? _effectiveDelayMs : [self apmStreamDelayMsOnStateQueue]),
            (long)self.suppressor.streamDelayMs,
            (long)kWRNBleIngressPipelineMs,
            tuning.applyMask,
            timeline.farEndPlaybackActive ? 1 : 0,
            farEnvActive ? 1 : 0,
            (unsigned long)(timeline.renderFramesIngested * 10),
            (unsigned long)(timeline.captureFramesProcessed * 10),
            (unsigned long)_aecPairedRefFrames,
            (unsigned long)_aecPairedRefMissFrames,
            (unsigned long)timeline.matchedReferences,
            (unsigned long)timeline.skippedNoFarEnd,
            (unsigned long)timeline.underrunReferences,
            (unsigned long)timeline.ringFrames,
            ringDepthMs,
            (unsigned long)timeline.maxPendingCaptureFramesObserved,
            (unsigned long)pendingFrames,
            (unsigned long)timeline.maxPendingCaptureFramesObserved,
            (unsigned long)_aecRefNotReadyBreakCount,
            (unsigned long)_lastReadyOutBytes,
            (unsigned long)_aecCaptureIngressBytes,
            self.farEndEnvelopeRMS,
            _aecEmaRefSkewMs,
            _aecEmaInRms,
            _aecEmaOutRms,
            _aecEmaErlDb,
            (unsigned long)timeline.referenceClampCount,
            _aecEmaPostAgcGain,
            (long long)renderCaptureSkewMs,
            _lastCaptureAnchorSource > 0 ? _lastCaptureAnchorSource : '-'];
}

- (void)noteReferenceAvailabilityOnStateQueue:(WRNAECReferenceAvailability)availability force:(BOOL)force {
    if (availability == WRNAECReferenceAvailabilityMatched ||
        availability == WRNAECReferenceAvailabilitySkippedNoFarEnd) {
        _aecUnderrunStreak = 0;
        return;
    }
    if (!force) {
        return;
    }
    _aecUnderrunStreak += 1;
    if (!_echoDiagnosticsLoggingEnabled) return;
    BOOL shouldLog = (_aecUnderrunStreak == 1 || _aecUnderrunStreak == 5 || _aecUnderrunStreak == 20 ||
                      (_aecUnderrunStreak % 50 == 0));
    if (!shouldLog) return;
    WRNAECLog(@"event=ref_underrun streak=%lu %@", (unsigned long)_aecUnderrunStreak,
              [self aecDiagnosticCountsLineOnStateQueue]);
}

- (void)emitAECDiagnosticsOnStateQueueForce:(BOOL)force event:(NSString *)event {
    if (!_echoDiagnosticsLoggingEnabled || !self.suppressor.isEchoCancellationEnabled) return;
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (event.length > 0) {
        WRNAECLog(@"event=%@ %@", event, [self aecDiagnosticCountsLineOnStateQueue]);
        _aecLastDiagnosticLogTime = now;
        return;
    }
    if (!force && _aecLastDiagnosticLogTime > 0 &&
        (now - _aecLastDiagnosticLogTime) < kWRNAECDiagnosticLogIntervalSeconds) {
        return;
    }
    _aecLastDiagnosticLogTime = now;
    WRNAECLog(@"tick %@", [self aecDiagnosticCountsLineOnStateQueue]);
}

- (void)clearVADSessionStateOnStateQueue {
    _lastVADFrameInfo = (WRNVADFrameInfo){0};
    _vadUtteranceHasSpeech = NO;
    _utteranceSpeechEnded = NO;
    _vadSilenceFrameCount = 0;
    _vadStrongSpeechFrameCount = 0;
}

- (BOOL)isFrameSilentForEndHangover:(WRNVADFrameInfo)frameInfo {
    const float rnnoiseOffThreshold =
        MAX(0.05f, _rnnoiseVADThreshold - kWRNDefaultVADOffThresholdHysteresis);
    const float webrtcOffThreshold =
        MAX(0.05f, _webrtcVADThreshold - kWRNDefaultVADOffThresholdHysteresis);
    return frameInfo.rnnoiseProbability < rnnoiseOffThreshold &&
           frameInfo.webrtcSpeechProbability < webrtcOffThreshold;
}

- (BOOL)shouldAccumulateVADSilenceFrame:(WRNVADFrameInfo)frameInfo {
    if ([self isFrameSilentForEndHangover:frameInfo]) return YES;
    return !frameInfo.webrtcSpeechActive;
}

- (WRNVADFrameInfo)vadFrameInfoByApplyingThresholds:(WRNVADFrameInfo)rawFrameInfo {
    rawFrameInfo.rnnoiseSpeechActive = rawFrameInfo.rnnoiseProbability >= _rnnoiseVADThreshold;
    rawFrameInfo.webrtcSpeechActive = rawFrameInfo.webrtcSpeechProbability >= _webrtcVADThreshold;
    rawFrameInfo.dualSpeechActive =
        rawFrameInfo.rnnoiseSpeechActive && rawFrameInfo.webrtcSpeechActive;
    return rawFrameInfo;
}

- (void)updateVADStateWithFrame:(WRNVADFrameInfo)frameInfo {
    if (!_vadEnabled) return;
    _lastVADFrameInfo = frameInfo;
    if (_utteranceSpeechEnded) return;
    const BOOL anySpeechActive = frameInfo.rnnoiseSpeechActive || frameInfo.webrtcSpeechActive;
    if (frameInfo.dualSpeechActive) {
        _vadUtteranceHasSpeech = YES;
        if (_vadStrongSpeechFrameCount < kWRNMinConfirmedDualSpeechFrames) _vadStrongSpeechFrameCount += 1;
        _vadSilenceFrameCount = 0;
        return;
    }
    if (anySpeechActive) {
        _vadUtteranceHasSpeech = YES;
        if (_vadStrongSpeechFrameCount >= kWRNMinConfirmedDualSpeechFrames) _vadSilenceFrameCount = 0;
        return;
    }
    if (!_vadUtteranceHasSpeech) return;
    if (_vadStrongSpeechFrameCount < kWRNMinConfirmedDualSpeechFrames) return;
    if ([self shouldAccumulateVADSilenceFrame:frameInfo]) _vadSilenceFrameCount += 1;
    if (_vadSilenceFrameCount >= _vadEndHangoverFrames) {
        _utteranceSpeechEnded = YES;
        _vadSilenceFrameCount = 0;
        _vadUtteranceHasSpeech = NO;
    }
}

- (NSData *)processAlignedPCMData:(NSData *)pcmData
                  trimOutputBytes:(NSUInteger)trimOutputBytes
               captureHostTimeNs:(uint64_t)captureHostTimeNs {
    if (pcmData.length == 0) return NSData.data;
    self.suppressor.rnnoiseWetMix =
        [self isFarEndActiveForMetricsOnStateQueue] ? 0.0f : 0.58f;
    NSMutableData *processedData = [pcmData mutableCopy];
    int16_t *samples = (int16_t *)processedData.mutableBytes;
    NSUInteger sampleCount = processedData.length / sizeof(int16_t);
    const uint64_t frameDurationNs = [WRNAECTimeline frameDurationNs];
    int16_t frame[kWRNFrameSamples] = {0};
    uint64_t frameHostTimeNs = captureHostTimeNs;
    for (NSUInteger offset = 0; offset < sampleCount; offset += kWRNFrameSamples) {
        memcpy(frame, samples + offset, kWRNFrameBytes);
        BOOL recordMetrics =
            (captureHostTimeNs > 0 && [self isFarEndActiveForMetricsOnStateQueue]);
        double inRms = recordMetrics ? WRNFrameRMS(frame, kWRNFrameSamples) : 0;
        if (self.suppressor.isEchoCancellationEnabled && frameHostTimeNs > 0) {
            int16_t refFrame[kWRNFrameSamples];
            BOOL inFarWindow =
                [self.aecTimeline isEchoCancellationWindowForCaptureHostTimeNs:frameHostTimeNs];
            if (inFarWindow) {
                NSUInteger captureLagFrames = 0;
                if (_captureBatchNextIndex > 0 && _captureBatchTotal >= _captureBatchNextIndex) {
                    captureLagFrames = _captureBatchTotal - _captureBatchNextIndex;
                }
                if ([self.aecTimeline copyReferencePCM:refFrame captureLagFrames:captureLagFrames]) {
                    [self.suppressor processRenderPCM:refFrame frameCount:kWRNFrameSamples];
                    _aecPairedRefFrames += 1;
                } else {
                    _aecPairedRefMissFrames += 1;
                }
            }
        }
        WRNVADFrameInfo rawVAD = {0};
        WRNVADFrameInfo *vadOut = _vadEnabled ? &rawVAD : NULL;
        double apmOutRms = 0;
        [self.suppressor processCapturePCM:frame
                                frameCount:kWRNFrameSamples
                                    outVAD:vadOut
                            outApmFrameRms:recordMetrics ? &apmOutRms : NULL];
        if (recordMetrics) {
            double finalOutRms = WRNFrameRMS(frame, kWRNFrameSamples);
            NSInteger refSkewMs = [self.aecTimeline referenceSkewMsForCaptureHostTimeNs:frameHostTimeNs];
            [self noteAECFrameMetricsWithInRms:inRms
                                     apmOutRms:apmOutRms
                                   finalOutRms:finalOutRms
                                     refSkewMs:(double)refSkewMs];
        }
        if (_vadEnabled) {
            [self updateVADStateWithFrame:[self vadFrameInfoByApplyingThresholds:rawVAD]];
        }
        memcpy(samples + offset, frame, kWRNFrameBytes);
        if (captureHostTimeNs > 0) {
            frameHostTimeNs += frameDurationNs;
        }
    }
    [self applySmoothAGCToSamples:samples sampleCount:sampleCount];
    if (captureHostTimeNs > 0 && [self isFarEndActiveForMetricsOnStateQueue]) {
        _aecEmaPostAgcGain = WRNUpdateEma(_aecEmaPostAgcGain, self.gain, kWRNAECMetricEmaAlpha);
    }
    processedData.length = trimOutputBytes;
    return processedData;
}

- (void)applySmoothAGCToSamples:(int16_t *)samples sampleCount:(NSUInteger)sampleCount {
    if (!samples || sampleCount == 0) return;
    const double envelopeAttack = WRNSmoothingAlpha(kWRNEnvelopeAttackSeconds);
    const double envelopeRelease = WRNSmoothingAlpha(kWRNEnvelopeReleaseSeconds);
    const double gainAttack = WRNSmoothingAlpha(kWRNGainAttackSeconds);
    const double gainRelease = WRNSmoothingAlpha(kWRNGainReleaseSeconds);
    if (!self.hasEnvelope) {
        self.envelopeEnergy = (double)samples[0] * (double)samples[0];
        self.gain = 1.0;
        self.hasEnvelope = YES;
    }
    for (NSUInteger i = 0; i < sampleCount; i++) {
        double sample = (double)samples[i];
        double instantEnergy = sample * sample;
        double envelopeAlpha = instantEnergy > self.envelopeEnergy ? envelopeAttack : envelopeRelease;
        self.envelopeEnergy = envelopeAlpha * self.envelopeEnergy + (1.0 - envelopeAlpha) * instantEnergy;
        double envelopeRMS = sqrt(MAX(1.0, self.envelopeEnergy));
        double targetGain = 1.0;
        BOOL farEndActive = self.suppressor.isEchoCancellationEnabled && self.farEndEnvelopeRMS >= kWRNFarEndAGCGateRMS;
        if (farEndActive) {
            self.gain = 1.0;
            targetGain = 1.0;
        } else if (envelopeRMS >= kWRNEnvelopeGateRMS) {
            targetGain = MIN(MAX(1.0, kWRNTargetRMS / envelopeRMS), kWRNMaxGain);
        }
        double gainAlpha = targetGain > self.gain ? gainAttack : gainRelease;
        self.gain = gainAlpha * self.gain + (1.0 - gainAlpha) * targetGain;
        samples[i] = WRNClampedInt16(sample * self.gain);
    }
}

@end
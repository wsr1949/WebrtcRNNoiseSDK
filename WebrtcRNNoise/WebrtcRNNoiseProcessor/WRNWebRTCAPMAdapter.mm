#import "WRNWebRTCAPMAdapter.h"

#if !__has_include("WebRTCAPM.h")
#error "Link WebRTCAPM.xcframework and ensure Headers/WebRTCAPM.h is visible when compiling WebrtcRNNoiseProcessor."
#endif

#include "WebRTCAPM.h"

@interface WRNWebRTCAPMAdapter () {
    int _sampleRate;
    int _channels;
    WebRTCAPM *_apm;
}
@end

@implementation WRNWebRTCAPMAdapter

- (void)dealloc {
    if (_apm) {
        WebRTCAPMDestroy(_apm);
        _apm = nullptr;
    }
}

- (instancetype)initWithSampleRate:(int)sampleRate channels:(int)channels {
    self = [super init];
    if (!self) {
        return nil;
    }
    _sampleRate = sampleRate;
    _channels = channels;
    _voiceDetectionEnabled = NO;
    _echoCancellationEnabled = NO;
    _streamDelayMs = -1;
    _echoCancellerTuning = WRNEchoCanceller3TuningDefault();
    [self resetAPM];
    return self;
}

- (void)setEchoCancellationEnabled:(BOOL)echoCancellationEnabled {
    if (_echoCancellationEnabled == echoCancellationEnabled) {
        return;
    }
    _echoCancellationEnabled = echoCancellationEnabled;
    [self resetAPM];
}

- (void)setStreamDelayMs:(NSInteger)streamDelayMs {
    _streamDelayMs = streamDelayMs;
    if (_apm) {
        WebRTCAPMSetStreamDelayMs(_apm, (int)streamDelayMs);
    }
}

- (void)setEchoCancellerTuning:(WRNEchoCanceller3Tuning)echoCancellerTuning {
    _echoCancellerTuning = echoCancellerTuning;
    [self resetAPM];
}

- (WebRTCAPMConfig)apmConfig {
    WebRTCAPMConfig config = WebRTCAPMDefaultConfig();
    config.sample_rate_hz = _sampleRate;
    config.channels = _channels;
    config.enable_echo_canceller = self.echoCancellationEnabled ? 1 : 0;
    config.enable_voice_detection = self.voiceDetectionEnabled ? 1 : 0;
    config.stream_delay_ms = (int)_streamDelayMs;
    // 回音消除打开时关掉 WebRTC AGC，避免和后级包络 AGC 叠在一起把残余回声重新拉高。
    if (self.echoCancellationEnabled) {
        config.enable_gain_controller = 0;
    }
    return config;
}

- (void)applyEchoCancellerTuning {
    if (!_apm || _echoCancellerTuning.applyMask == 0) {
        return;
    }
    WebRTCAPMEchoCanceller3Tuning tuning = {0};
    tuning.apply_mask = _echoCancellerTuning.applyMask;
    tuning.delay_default_delay = _echoCancellerTuning.delayDefaultDelay;
    tuning.delay_fixed_capture_delay_samples = _echoCancellerTuning.delayFixedCaptureDelaySamples;
    tuning.delay_use_external_delay_estimator = _echoCancellerTuning.delayUseExternalDelayEstimator;
    tuning.delay_estimate_smoothing = _echoCancellerTuning.delayEstimateSmoothing;
    tuning.delay_estimate_smoothing_delay_found =
        _echoCancellerTuning.delayEstimateSmoothingDelayFound;
    tuning.filter_coarse_initial_length_blocks =
        _echoCancellerTuning.filterCoarseInitialLengthBlocks;
    WebRTCAPMSetEchoCanceller3Tuning(_apm, &tuning);
}

- (void)resetAPM {
    if (_apm) {
        WebRTCAPMDestroy(_apm);
        _apm = nullptr;
    }
    WebRTCAPMConfig config = [self apmConfig];
    _apm = WebRTCAPMCreate(&config);
    [self applyEchoCancellerTuning];
}

- (float)processCapturePCM:(int16_t *)pcm frameCount:(int)frameCount {
    if (!_apm || !pcm || frameCount <= 0) {
        return 0.f;
    }

    WebRTCAPMCaptureVAD vad = {0};
    if (WebRTCAPMProcessCaptureWithVAD(_apm, pcm, frameCount, &vad) != 0) {
        return 0.f;
    }

    if (!self.voiceDetectionEnabled) {
        return 0.f;
    }

    return vad.speech_probability;
}

- (void)processRenderPCM:(const int16_t *)pcm frameCount:(int)frameCount {
    if (_apm && pcm && frameCount > 0) {
        WebRTCAPMProcessRender(_apm, pcm, frameCount);
    }
}

@end

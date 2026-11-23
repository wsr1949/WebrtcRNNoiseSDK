#import "WRNNoiseSuppressor.h"
#import "WRNWebRTCAPMAdapter.h"
#import "WRNAPMTypes.h"

#include <algorithm>
#include <math.h>

#include "rnnoise.h"

static inline int16_t WRNClampToInt16(float value) {
    value = std::max(-32768.0f, std::min(32767.0f, value));
    return static_cast<int16_t>(value);
}

static inline float WRNBlendSamples(float dry, float wet, float wetMix) {
    return dry * (1.0f - wetMix) + wet * wetMix;
}

static inline float WRNClampProbability(float value) {
    return std::max(0.f, std::min(1.f, value));
}

static inline float WRNSigmoidProbability(float value) {
    return WRNClampProbability(1.f / (1.f + expf(-value)));
}

@interface WRNNoiseSuppressor () {
    int _sampleRate;
    int _channels;
    int _samplesPer10ms;
    DenoiseState *_rnnoise;
    float _rnnoiseIn[480];
    float _rnnoiseOut[480];
    float _rnnoiseScratch[480];
    int16_t _apmFrame[480];
}
@property (nonatomic, strong) WRNWebRTCAPMAdapter *webrtc;
@end

@implementation WRNNoiseSuppressor

- (BOOL)isVoiceDetectionEnabled {
    return self.webrtc.voiceDetectionEnabled;
}

- (void)setVoiceDetectionEnabled:(BOOL)voiceDetectionEnabled {
    if (self.webrtc.voiceDetectionEnabled == voiceDetectionEnabled) {
        return;
    }
    self.webrtc.voiceDetectionEnabled = voiceDetectionEnabled;
    [self.webrtc resetAPM];
}

- (BOOL)isEchoCancellationEnabled {
    return self.webrtc.echoCancellationEnabled;
}

- (void)setEchoCancellationEnabled:(BOOL)echoCancellationEnabled {
    self.webrtc.echoCancellationEnabled = echoCancellationEnabled;
}

- (void)resetEchoCanceller {
    [self.webrtc resetAPM];
}

- (NSInteger)streamDelayMs {
    return self.webrtc.streamDelayMs;
}

- (void)setStreamDelayMs:(NSInteger)streamDelayMs {
    self.webrtc.streamDelayMs = streamDelayMs;
}

- (WRNEchoCanceller3Tuning)echoCancellerTuning {
    return self.webrtc.echoCancellerTuning;
}

- (void)setEchoCancellerTuning:(WRNEchoCanceller3Tuning)echoCancellerTuning {
    self.webrtc.echoCancellerTuning = echoCancellerTuning;
}

- (void)processRenderPCM:(const int16_t *)pcm frameCount:(int)frameCount {
    if (!self.echoCancellationEnabled || !pcm || frameCount != _samplesPer10ms) {
        return;
    }
    [self.webrtc processRenderPCM:pcm frameCount:frameCount];
}

- (instancetype)initWithSampleRate:(int)sampleRate channels:(int)channels {
    self = [super init];
    if (!self) {
        return nil;
    }

    NSAssert(sampleRate == 16000, @"WRNNoiseProcessor 仅支持 16 kHz PCM。");
    NSAssert(channels == 1, @"WRNNoiseProcessor 仅支持单声道 PCM。");

    _sampleRate = sampleRate;
    _channels = channels;
    _samplesPer10ms = sampleRate / 100;
    _webrtc = [[WRNWebRTCAPMAdapter alloc] initWithSampleRate:sampleRate channels:channels];
    _rnnoiseWetMix = 0.58f;
    _rnnoise = rnnoise_create(nullptr);
    return self;
}

- (void)dealloc {
    if (_rnnoise) {
        rnnoise_destroy(_rnnoise);
        _rnnoise = nullptr;
    }
}

static inline double WRNFrameRMSFromPCM(const int16_t *samples, int count) {
    if (!samples || count <= 0) {
        return 0;
    }
    double energy = 0;
    for (int i = 0; i < count; i++) {
        double s = (double)samples[i];
        energy += s * s;
    }
    return sqrt(energy / (double)count);
}

- (float)processCapturePCM:(int16_t *)pcm
                frameCount:(int)frameCount
                    outVAD:(WRNVADFrameInfo *)outVAD
            outApmFrameRms:(double *)outApmFrameRms {
    if (!pcm || frameCount != _samplesPer10ms || !_rnnoise) {
        if (outVAD) {
            *outVAD = (WRNVADFrameInfo){0};
        }
        return 0.0f;
    }

    const float webrtcProbability = [self.webrtc processCapturePCM:pcm frameCount:frameCount];
    memcpy(_apmFrame, pcm, frameCount * sizeof(int16_t));
    if (outApmFrameRms) {
        *outApmFrameRms = WRNFrameRMSFromPCM(pcm, frameCount);
    }

    for (int i = 0; i < frameCount; i++) {
        float current = static_cast<float>(pcm[i]);
        float next = static_cast<float>(pcm[MIN(i + 1, frameCount - 1)]);
        _rnnoiseIn[i * 3] = current;
        _rnnoiseIn[i * 3 + 1] = current + (next - current) / 3.0f;
        _rnnoiseIn[i * 3 + 2] = current + (next - current) * 2.0f / 3.0f;
    }

    float rnnoiseLogit = rnnoise_process_frame(_rnnoise, _rnnoiseOut, _rnnoiseIn);
    const float rnnoiseProbability = WRNSigmoidProbability(rnnoiseLogit);

    const float wetMix = std::max(0.f, std::min(1.f, self.rnnoiseWetMix));
    for (int i = 0; i < frameCount; i++) {
        _rnnoiseScratch[i] =
            (_rnnoiseOut[i * 3] + _rnnoiseOut[i * 3 + 1] + _rnnoiseOut[i * 3 + 2]) / 3.0f;
        pcm[i] = WRNClampToInt16(WRNBlendSamples(static_cast<float>(_apmFrame[i]),
                                                _rnnoiseScratch[i],
                                                wetMix));
    }

    if (outVAD) {
        outVAD->rnnoiseProbability = rnnoiseProbability;
        outVAD->webrtcSpeechProbability = WRNClampProbability(webrtcProbability);
        outVAD->rnnoiseSpeechActive = NO;
        outVAD->webrtcSpeechActive = NO;
        outVAD->dualSpeechActive = NO;
    }

    return rnnoiseProbability;
}

@end

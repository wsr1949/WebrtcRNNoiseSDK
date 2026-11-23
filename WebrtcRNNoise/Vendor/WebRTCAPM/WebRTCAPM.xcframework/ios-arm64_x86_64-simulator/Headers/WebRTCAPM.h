#ifndef WEBRTC_APM_WRAPPER_H
#define WEBRTC_APM_WRAPPER_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct WebRTCAPM WebRTCAPM;

typedef enum WebRTCAPMNoiseSuppressionLevel {
    WebRTCAPMNoiseSuppressionLevelLow = 0,
    WebRTCAPMNoiseSuppressionLevelModerate = 1,
    WebRTCAPMNoiseSuppressionLevelHigh = 2,
    WebRTCAPMNoiseSuppressionLevelVeryHigh = 3
} WebRTCAPMNoiseSuppressionLevel;

typedef struct WebRTCAPMConfig {
    int sample_rate_hz;
    int channels;
    int enable_high_pass_filter;
    int enable_echo_canceller;
    int enable_noise_suppression;
    WebRTCAPMNoiseSuppressionLevel noise_suppression_level;
    int enable_gain_controller;
    int gain_target_level_dbfs;
    int gain_compression_db;
    int gain_enable_limiter;
    /// 启用 WebRTC `VoiceActivityDetector`（与 ProcessStream 并行分析采集帧）。
    int enable_voice_detection;
    /// -1：不在 ProcessCapture 前调用 `set_stream_delay_ms`（由 AEC3 自估）。
    /// >=0：每次采集帧处理前设置总链路延迟（毫秒），适合已知蓝牙/播放缓冲延迟。
    int stream_delay_ms;
    /// -1：WebRTC 默认；0/1 映射 `AudioProcessing::Config::EchoCanceller::enforce_high_pass_filtering`。
    int echo_enforce_high_pass_filtering;
    /// -1：WebRTC 默认；0/1 映射 `export_linear_aec_output`。
    int echo_export_linear_aec_output;
} WebRTCAPMConfig;

/// AEC3（`EchoCanceller3Config`）可选调参。`apply_mask` 为 0 表示恢复 WebRTC 默认 AEC3 配置。
typedef struct WebRTCAPMEchoCanceller3Tuning {
    uint32_t apply_mask;
    int delay_default_delay;
    int delay_fixed_capture_delay_samples;
    int delay_use_external_delay_estimator;
    float delay_estimate_smoothing;
    float delay_estimate_smoothing_delay_found;
    int filter_coarse_initial_length_blocks;
} WebRTCAPMEchoCanceller3Tuning;

#define WEBRTC_APM_AEC3_TUNING_DELAY_DEFAULT_DELAY (1u << 0)
#define WEBRTC_APM_AEC3_TUNING_DELAY_FIXED_CAPTURE_DELAY_SAMPLES (1u << 1)
#define WEBRTC_APM_AEC3_TUNING_DELAY_USE_EXTERNAL_DELAY_ESTIMATOR (1u << 2)
#define WEBRTC_APM_AEC3_TUNING_DELAY_ESTIMATE_SMOOTHING (1u << 3)
#define WEBRTC_APM_AEC3_TUNING_DELAY_ESTIMATE_SMOOTHING_DELAY_FOUND (1u << 4)
#define WEBRTC_APM_AEC3_TUNING_FILTER_COARSE_INITIAL_LENGTH_BLOCKS (1u << 5)

typedef struct WebRTCAPMCaptureVAD {
    float speech_probability;
    int voice_detected;
} WebRTCAPMCaptureVAD;

WebRTCAPMConfig WebRTCAPMDefaultConfig(void);
WebRTCAPMEchoCanceller3Tuning WebRTCAPMEchoCanceller3TuningDefault(void);

WebRTCAPM *WebRTCAPMCreate(const WebRTCAPMConfig *config);
void WebRTCAPMDestroy(WebRTCAPM *apm);
int WebRTCAPMReset(WebRTCAPM *apm);

int WebRTCAPMProcessCapture(WebRTCAPM *apm, int16_t *pcm, int frame_count);
int WebRTCAPMProcessCaptureWithVAD(WebRTCAPM *apm,
                                   int16_t *pcm,
                                   int frame_count,
                                   WebRTCAPMCaptureVAD *out_vad);
int WebRTCAPMProcessRender(WebRTCAPM *apm, const int16_t *pcm, int frame_count);

/// 设置采集端总延迟（毫秒）。delay_ms < 0 表示不再调用 `set_stream_delay_ms`。
int WebRTCAPMSetStreamDelayMs(WebRTCAPM *apm, int delay_ms);
int WebRTCAPMGetStreamDelayMs(const WebRTCAPM *apm);

/// `tuning == NULL` 时清除自定义 AEC3 配置；否则在下次 `WebRTCAPMReset` / 创建时生效（会 Validate）。
int WebRTCAPMSetEchoCanceller3Tuning(WebRTCAPM *apm,
                                     const WebRTCAPMEchoCanceller3Tuning *tuning);
int WebRTCAPMGetEchoCanceller3Tuning(const WebRTCAPM *apm,
                                      WebRTCAPMEchoCanceller3Tuning *out_tuning);

float WebRTCAPMLastCaptureVADProbability(const WebRTCAPM *apm);

/// 非 0 表示本库已编入 WebRTC `VoiceActivityDetector`（需 `enable_voice_detection=1` 才会在运行时产出概率）。
int WebRTCAPMSupportsCaptureVAD(void);

int WebRTCAPMExpectedFrameCount(const WebRTCAPM *apm);
const char *WebRTCAPMVersion(void);

#ifdef __cplusplus
}
#endif

#endif

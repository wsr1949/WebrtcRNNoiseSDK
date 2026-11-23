#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// 单帧（10 ms）双源 VAD 结果。`vadEnabled = YES` 时由 `WRNNoiseProcessor` 每帧更新；
/// `lastVADFrameInfo` 中的 `*SpeechActive` / `dualSpeechActive` 已按处理器阈值换算，概率字段为原始值。
typedef struct {
    /// RNNoise 语音概率，约 0～1。来自 `rnnoise_process_frame` 输出经 sigmoid，在降噪混合后的 PCM 上计算。
    float rnnoiseProbability;
    /// WebRTC 语音概率，约 0～1。来自 `WebRTCAPMProcessCaptureWithVAD` 的 `VoiceActivityDetector`（`vadEnabled` 时 `enable_voice_detection=1`）。
    float webrtcSpeechProbability;
    /// RNNoise 是否判为语音：`rnnoiseProbability >= rnnoiseVADThreshold`（默认 0.58）。
    BOOL rnnoiseSpeechActive;
    /// WebRTC 是否判为语音：`webrtcSpeechProbability >= webrtcVADThreshold`（默认 0.42）。
    BOOL webrtcSpeechActive;
    /// 双源同时判语音：`rnnoiseSpeechActive && webrtcSpeechActive`。用于确认「强语音」与部分结束判停逻辑。
    BOOL dualSpeechActive;
} WRNVADFrameInfo;

NS_ASSUME_NONNULL_END

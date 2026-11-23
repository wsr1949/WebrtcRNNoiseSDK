#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// 与 `WebRTCAPMEchoCanceller3Tuning` 对应。`applyMask == 0` 表示使用 WebRTC 默认 AEC3 参数。
typedef struct WRNEchoCanceller3Tuning {
    uint32_t applyMask;
    int delayDefaultDelay;
    int delayFixedCaptureDelaySamples;
    int delayUseExternalDelayEstimator;
    float delayEstimateSmoothing;
    float delayEstimateSmoothingDelayFound;
    int filterCoarseInitialLengthBlocks;
} WRNEchoCanceller3Tuning;

FOUNDATION_EXPORT WRNEchoCanceller3Tuning WRNEchoCanceller3TuningDefault(void);
/// 无外设 TS 眼镜场景：AEC3 快跟踪 + 加长 coarse 初始滤波器。
FOUNDATION_EXPORT WRNEchoCanceller3Tuning WRNEchoCanceller3TuningGlassesNoTS(void);

FOUNDATION_EXPORT const uint32_t WRNEchoCanceller3TuningDelayDefaultDelay;
FOUNDATION_EXPORT const uint32_t WRNEchoCanceller3TuningDelayFixedCaptureDelaySamples;
FOUNDATION_EXPORT const uint32_t WRNEchoCanceller3TuningDelayUseExternalDelayEstimator;
FOUNDATION_EXPORT const uint32_t WRNEchoCanceller3TuningDelayEstimateSmoothing;
FOUNDATION_EXPORT const uint32_t WRNEchoCanceller3TuningDelayEstimateSmoothingDelayFound;
FOUNDATION_EXPORT const uint32_t WRNEchoCanceller3TuningFilterCoarseInitialLengthBlocks;

NS_ASSUME_NONNULL_END

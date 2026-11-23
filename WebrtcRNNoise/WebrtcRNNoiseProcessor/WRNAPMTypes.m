#import "WRNAPMTypes.h"

const uint32_t WRNEchoCanceller3TuningDelayDefaultDelay = (1u << 0);
const uint32_t WRNEchoCanceller3TuningDelayFixedCaptureDelaySamples = (1u << 1);
const uint32_t WRNEchoCanceller3TuningDelayUseExternalDelayEstimator = (1u << 2);
const uint32_t WRNEchoCanceller3TuningDelayEstimateSmoothing = (1u << 3);
const uint32_t WRNEchoCanceller3TuningDelayEstimateSmoothingDelayFound = (1u << 4);
const uint32_t WRNEchoCanceller3TuningFilterCoarseInitialLengthBlocks = (1u << 5);

WRNEchoCanceller3Tuning WRNEchoCanceller3TuningDefault(void) {
    WRNEchoCanceller3Tuning tuning = {0};
    tuning.delayDefaultDelay = 5;
    tuning.delayFixedCaptureDelaySamples = 0;
    tuning.delayUseExternalDelayEstimator = 0;
    tuning.delayEstimateSmoothing = 0.7f;
    tuning.delayEstimateSmoothingDelayFound = 0.7f;
    tuning.filterCoarseInitialLengthBlocks = 12;
    return tuning;
}

WRNEchoCanceller3Tuning WRNEchoCanceller3TuningGlassesNoTS(void) {
    WRNEchoCanceller3Tuning tuning = WRNEchoCanceller3TuningDefault();
    tuning.applyMask = WRNEchoCanceller3TuningDelayUseExternalDelayEstimator |
                       WRNEchoCanceller3TuningDelayEstimateSmoothing |
                       WRNEchoCanceller3TuningDelayEstimateSmoothingDelayFound |
                       WRNEchoCanceller3TuningFilterCoarseInitialLengthBlocks;
    tuning.delayUseExternalDelayEstimator = 1;
    tuning.delayEstimateSmoothing = 0.3f;
    tuning.delayEstimateSmoothingDelayFound = 0.3f;
    tuning.filterCoarseInitialLengthBlocks = 8;
    return tuning;
}

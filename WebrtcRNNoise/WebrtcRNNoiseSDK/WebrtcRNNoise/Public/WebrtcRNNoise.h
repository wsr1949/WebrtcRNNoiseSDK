#import <Foundation/Foundation.h>

//! Project version number for WebrtcRNNoise.
FOUNDATION_EXPORT double WebrtcRNNoiseVersionNumber;

//! Project version string for WebrtcRNNoise.
FOUNDATION_EXPORT const unsigned char WebrtcRNNoiseVersionString[];

#import <WebrtcRNNoise/WRNAPMTypes.h>
#import <WebrtcRNNoise/WRNNoiseProcessor.h>
#import <WebrtcRNNoise/WRNVADTypes.h>

/// SDK 版本字符串（含 wrapper 代数），便于宿主日志与问题定位。
FOUNDATION_EXPORT NSString *WRNSDKVersionString(void);

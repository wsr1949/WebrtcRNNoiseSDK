#import <WebrtcRNNoise/WebrtcRNNoise.h>

#include "WebRTCAPM.h"

NSString *WRNSDKVersionString(void) {
    return [NSString stringWithFormat:@"WebrtcRNNoise/1.0 (%@)", [NSString stringWithUTF8String:WebRTCAPMVersion()]];
}

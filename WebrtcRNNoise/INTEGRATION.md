# WebrtcRNNoise SDK 集成说明

对外只需 **一个** 动态 `WebrtcRNNoise.xcframework`（内含 WebRTC APM、RNNoise 与处理器实现）。

## 获取 xcframework

在仓库根目录执行：

```sh
chmod +x scripts/package_webrtc_rnnoise_xcframework.sh
./scripts/package_webrtc_rnnoise_xcframework.sh --skip-deps
```

首次或更新底层依赖时去掉 `--skip-deps`（会自动构建 `Vendor/` 下的 RNNoise 与 WebRTCAPM；WebRTC 构建较慢）。

产物路径：`Dist/WebrtcRNNoise.xcframework`  
可选 zip：`./scripts/package_webrtc_rnnoise_xcframework.sh --skip-deps --zip`

## Xcode 集成

1. 将 `WebrtcRNNoise.xcframework` 拖入工程。
2. 选中 App Target → **General** → **Frameworks, Libraries, and Embedded Content**。
3. 将 `WebrtcRNNoise.xcframework` 设为 **Embed & Sign**。

通常 **不需要** 再添加 `-lc++`、`-ObjC`，也 **不需要** 单独链接 `RNNoise` / `WebRTCAPM`。SDK 最低 **iOS 15.0**。

## 代码示例

```objc
#import <WebrtcRNNoise/WRNNoiseProcessor.h>

WRNNoiseProcessor *processor = [WRNNoiseProcessor sharedProcessor];
[processor resetProcessor];

// 回音消除：render 与 capture 可来自不同线程
processor.echoCancellationEnabled = YES;
// 管线总延迟 hint（播放缓冲 + 声学 + 传输）。未知时保持 -1，由 AEC3 自估
// processor.streamDelayMs = 200;
[processor processRenderPCMStreamData:playbackPCM]; // 与实际扬声器输出一致
NSData *processed = [processor processPCMStreamData:micPCM];

// 播放结束可 flush，段间停顿勿 resetProcessor（多轮 TTS 保留 AEC 状态）
[processor processRenderPCMStreamData:NSData.data];
```

### 多轮 TTS + 连续采集（眼镜 BLE）

- **采集**：会话开始后持续 `processPCMStreamData:`（允许突发大包）。
- **参考**：仅在 TTS 播放时从播放器回调 `processRenderPCMStreamData:`；**无播放时不要送静音参考**。
- **段间**：对每段 TTS 结束调用 `processRenderPCMStreamData:NSData.data` flush。
- **诊断**：Xcode 控制台 `[WRN_AEC]`，或 `-echoCancellationDiagnostics`（`matched` / `skippedNoFarEnd` / `underrun` 等）。

双源 VAD、文件一键处理等 API 见框架头文件 `WRNNoiseProcessor.h`。

## 公开头文件

- `WebrtcRNNoise.h`（umbrella）
- `WRNNoiseProcessor.h`
- `WRNVADTypes.h`
- `WRNSDKVersionString()`（版本查询）

`WebRTCAPM.h`、`rnnoise.h` 与内部实现 **不对外暴露**。

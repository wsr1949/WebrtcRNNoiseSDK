# WebrtcRNNoise

这是一个 Objective-C iOS demo，用于测试外部 PCM 音频的 RNNoise + WebRTC APM 降噪处理。

## 包含内容

- `ThirdParty/rnnoise-src`：RNNoise 官方源码。
- `Vendor/RNNoise/RNNoise.xcframework`：已生成的 RNNoise 静态 xcframework。
- `Vendor/WebRTCAPM/WebRTCAPM.xcframework`：已生成的 WebRTC APM 封装静态 xcframework。
- `WebRTCAPMWrapper`：对 WebRTC `AudioProcessing` 的小型 C ABI 封装。
- `WebrtcRNNoiseDemo`：Objective-C 测试 App。
- `WebrtcRNNoiseProcessor`：可复用的 `16 kHz / 单声道 / int16` 裸 PCM 处理封装（源码；对外分发见下方一键打包）。
- `WebrtcRNNoiseSDK`：动态 Framework 工程，用于生成对外 `WebrtcRNNoise.xcframework`。

## 一键打包对外 SDK（推荐）

生成可供外部工程 **Embed & Sign** 的动态 xcframework：

```sh
./scripts/package_webrtc_rnnoise_xcframework.sh
```

已有 `Vendor/` 依赖、只改了处理器代码时：

```sh
./scripts/package_webrtc_rnnoise_xcframework.sh --skip-deps
```

产物：`Dist/WebrtcRNNoise.xcframework`（公开头仅 `WRNNoiseProcessor.h` 等，见 [INTEGRATION.md](INTEGRATION.md)）。

常用参数：`--rebuild-deps`、`--zip`、`--output DIR`、`--check-only`。

## 构建 RNNoise

```sh
./scripts/build_rnnoise_ios.sh
```

输出产物：

- `Vendor/RNNoise/RNNoise.xcframework`

## 构建 WebRTC APM Wrapper

对于外部裸 PCM，WebRTC 里主要用到的是 `modules/audio_processing`。
本仓库提供了一个小型 wrapper target，用来暴露稳定的 C ABI：

- wrapper 源码：`WebRTCAPMWrapper`
- 公共头文件：`WebRTCAPMWrapper/include/WebRTCAPM.h`
- 构建脚本：`scripts/build_webrtc_apm_ios.sh`

执行构建：

```sh
./scripts/build_webrtc_apm_ios.sh
```

输出产物：

- `Vendor/WebRTCAPM/WebRTCAPM.xcframework`

这个产物比完整的 `WebRTC.xcframework` 小很多，但构建时仍需要 WebRTC 源码检出来编译依赖。
同时需要能访问 Chromium 相关基础设施，包括 `depot_tools`、CIPD 和 WebRTC 依赖。

如果无法访问 `chromium.googlesource.com`，可以覆盖 depot_tools 镜像地址：

```sh
DEPOT_TOOLS_GIT_URL=https://github.com/rust-skia/depot_tools.git ./scripts/build_webrtc_apm_ios.sh
```

在其他 target 中使用时，链接：

```text
Vendor/RNNoise/RNNoise.xcframework
Vendor/WebRTCAPM/WebRTCAPM.xcframework
```

只需链接两个 xcframework（`Vendor/RNNoise/RNNoise.xcframework`、`Vendor/WebRTCAPM/WebRTCAPM.xcframework`），
不必再配置 `Vendor/.../lib` 下的独立 `.a` 或 `include` 目录。
VAD 与说完判停通过 `[WRNNoiseProcessor sharedProcessor].vadEnabled` 等属性配置。

## 构建 demo

```sh
xcodebuild -project WebrtcRNNoiseDemo.xcodeproj \
  -scheme WebrtcRNNoiseDemo \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath build/DerivedData \
  CODE_SIGNING_ALLOWED=NO build
```

可复用处理器要求的音频格式：

- 16 kHz
- 单声道
- 有符号 16-bit PCM
- 输入裸 PCM，输出仍然是裸 PCM

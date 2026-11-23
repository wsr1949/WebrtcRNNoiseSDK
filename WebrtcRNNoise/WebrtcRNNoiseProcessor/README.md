# WebrtcRNNoiseProcessor

WebRTC APM（AEC3）+ RNNoise，固定 **16 kHz / mono / s16le** 裸 PCM。

## 回音消除（重构）

1. **Render**：`processRenderPCMStreamData:` 按 10 ms 切块，递增 `renderFramesIngested`。
2. **Capture**：`processPCMStreamData:` 凑满 10 ms 后，取参考序号 `captureOrdinal - delayFrames` 与 WebRTC `ProcessRender` 成对，再 `ProcessCapture`。
3. **声学延迟** `streamDelayMs`（默认 430）在 SDK 内按帧扣除；WebRTC 侧仅保留约 **10 ms** `apmResidual`。
4. 参考未到齐时采集**照常输出**（STT 不断流），对 WebRTC 送静音参考；喇叭播放后 `matched` 应上升。

## 集成

```bash
cd /Users/liebian/Desktop/WebrtcRNNoise
./scripts/package_webrtc_rnnoise_xcframework.sh --skip-deps
# 复制 Dist/WebrtcRNNoise.xcframework → App OtherSDKs
```

```objc
WRNNoiseProcessor *p = WRNNoiseProcessor.sharedProcessor;
[p resetProcessor];
p.echoCancellationEnabled = YES;
p.streamDelayMs = 430; // 或 UserDefaults 中锁定值

// 播放同时
[p processRenderPCMStreamData:playbackPCM];
// 采集
NSData *out = [p processPCMStreamData:micPCM];
```

## 日志

过滤 **`[WRN_AEC]`**。字段含 `mode=index`、`matched`、`waitStalls`、`pendingNow`、`farRMS`。

`-echoCancellationDiagnostics` 与 `tick` 同行格式；`echoDiagnosticsLoggingEnabled` 默认 YES。
#import "ViewController.h"
#import <WebrtcRNNoise/WRNNoiseProcessor.h>

#import <AVFoundation/AVFoundation.h>
#import <AudioToolbox/AudioToolbox.h>
static const double kRecorderSampleRate = 16000.0;
static const int kRecorderChannels = 1;
static const AVAudioFrameCount kTapBufferFrames = 160;
/// 回播比实时采集滞后的时长，模拟服务器 TTS 延迟，避免零延迟 mic→扬声器 正反馈啸叫。
static const NSTimeInterval kAECDebugPlaybackDelaySeconds = 0.75;
static const float kAECDebugPlaybackVolume = 0.26f;

@interface ViewController () <UIDocumentPickerDelegate, UITableViewDataSource, UITableViewDelegate>
@property (nonatomic, strong) UITextView *textView;
@property (nonatomic, strong) UITableView *tableView;
@property (nonatomic, strong) NSMutableArray<NSMutableDictionary<NSString *, id> *> *actionItems;
@property (nonatomic, strong) AVAudioEngine *audioEngine;
@property (nonatomic, strong) NSMutableData *recordingPCM;
@property (nonatomic, strong) dispatch_queue_t recordingQueue;
@property (nonatomic, strong) dispatch_queue_t processorQueue;
@property (nonatomic, strong) AVAudioConverter *pcmConverter;
@property (nonatomic, strong) AVAudioFormat *recordFormat;
@property (nonatomic, strong) AVAudioEngine *playbackEngine;
@property (nonatomic, strong) AVAudioPlayerNode *playbackNode;
@property (nonatomic, strong) AVAudioPlayerNode *loopbackPlayerNode;
@property (nonatomic, strong) NSMutableData *aecDebugProcessedPCM;
@property (nonatomic, strong) NSURL *originalURL;
@property (nonatomic, strong) NSURL *processedURL;
@property (nonatomic, assign) BOOL isRecording;
@property (nonatomic, assign) BOOL vadEnabled;
@property (nonatomic, assign) BOOL aecLoopbackDebugEnabled;
@property (nonatomic, assign) NSUInteger aecDebugFarEndSendOffset;
@property (nonatomic, assign) NSTimeInterval vadEndHangoverSeconds;
@end

@implementation ViewController

- (void)viewDidLoad {
    [super viewDidLoad];

    self.title = @"WebRTC + RNNoise";
    self.view.backgroundColor = UIColor.systemBackgroundColor;
    self.vadEnabled = NO;
    self.aecLoopbackDebugEnabled = NO;
    self.vadEndHangoverSeconds = WRNNoiseProcessor.sharedProcessor.vadEndHangoverSeconds;

    self.actionItems = [@[
        [@{@"id": @"vadToggle", @"title": @"VAD 自动停录", @"kind": @"switch", @"enabled": @YES} mutableCopy],
        [@{@"id": @"aecLoopbackToggle",
           @"title": @"AEC 调试：延迟回播刚录语音",
           @"kind": @"switch",
           @"enabled": @YES} mutableCopy],
        [@{@"id": @"vadHangover", @"title": @"", @"selector": NSStringFromSelector(@selector(configureVADHangover)), @"kind": @"action", @"enabled": @YES} mutableCopy],
        [@{@"id": @"record", @"title": @"开始录音 16k/mono/int16", @"selector": NSStringFromSelector(@selector(toggleRecording)), @"kind": @"action", @"enabled": @YES} mutableCopy],
        [@{@"id": @"playOriginal", @"title": @"播放原音频", @"selector": NSStringFromSelector(@selector(playOriginalAudio)), @"kind": @"action", @"enabled": @NO} mutableCopy],
        [@{@"id": @"playProcessed", @"title": @"播放 WebRTC + RNNoise + 增益后音频", @"selector": NSStringFromSelector(@selector(playProcessedAudio)), @"kind": @"action", @"enabled": @NO} mutableCopy],
        [@{@"id": @"shareOriginal", @"title": @"导出原音频裸 PCM", @"selector": NSStringFromSelector(@selector(shareOriginalPCM)), @"kind": @"action", @"enabled": @NO} mutableCopy],
        [@{@"id": @"shareProcessed", @"title": @"导出处理后裸 PCM", @"selector": NSStringFromSelector(@selector(shareProcessedPCM)), @"kind": @"action", @"enabled": @NO} mutableCopy],
        [@{@"id": @"importPCM", @"title": @"从文件导入 PCM 处理并分享", @"selector": NSStringFromSelector(@selector(openPCMFilePicker)), @"kind": @"action", @"enabled": @YES} mutableCopy],
    ] mutableCopy];

    self.textView = [[UITextView alloc] init];
    self.textView.editable = NO;
    self.textView.font = [UIFont monospacedSystemFontOfSize:14.0 weight:UIFontWeightRegular];
    self.textView.frame = CGRectMake(0, 0, CGRectGetWidth(self.view.bounds), 360.0);
    self.textView.text =
        @"录音格式: 16 kHz，单声道，有符号 16-bit 裸 PCM (.pcm)。\n"
        @"「AEC 调试：延迟回播刚录语音」在持续录音约 0.75 s 后，低音量播放刚才录到的内容（模拟分段 TTS），"
        @"参考在播放回调侧送入、采集独立上行（贴近眼镜 BLE + 手机扬声器场景）。"
        @"原音频含泄漏，处理后为消回音上行；段间停顿不会向 AEC 送零参考。";

    [self refreshVADHangoverRowTitle];

    self.tableView = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStyleInsetGrouped];
    self.tableView.dataSource = self;
    self.tableView.delegate = self;
    self.tableView.translatesAutoresizingMaskIntoConstraints = NO;
    self.tableView.rowHeight = 52.0;
    self.tableView.tableFooterView = self.textView;
    [self.tableView registerClass:UITableViewCell.class forCellReuseIdentifier:@"ActionCell"];
    [self.tableView registerClass:UITableViewCell.class forCellReuseIdentifier:@"SwitchCell"];
    [self.view addSubview:self.tableView];

    UILayoutGuide *guide = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [self.tableView.topAnchor constraintEqualToAnchor:guide.topAnchor],
        [self.tableView.leadingAnchor constraintEqualToAnchor:guide.leadingAnchor],
        [self.tableView.trailingAnchor constraintEqualToAnchor:guide.trailingAnchor],
        [self.tableView.bottomAnchor constraintEqualToAnchor:guide.bottomAnchor]
    ]];
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return self.actionItems.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    NSDictionary<NSString *, id> *item = self.actionItems[indexPath.row];
    BOOL enabled = [item[@"enabled"] boolValue];
    NSString *kind = item[@"kind"];

    if ([kind isEqualToString:@"switch"]) {
        UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"SwitchCell" forIndexPath:indexPath];
        cell.textLabel.text = item[@"title"];
        cell.textLabel.font = [UIFont systemFontOfSize:16.0 weight:UIFontWeightMedium];
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        UISwitch *toggle = (UISwitch *)cell.accessoryView;
        if (![toggle isKindOfClass:UISwitch.class]) {
            toggle = [[UISwitch alloc] init];
            cell.accessoryView = toggle;
        }
        [toggle removeTarget:nil action:NULL forControlEvents:UIControlEventValueChanged];
        NSString *itemID = item[@"id"];
        if ([itemID isEqualToString:@"aecLoopbackToggle"]) {
            [toggle addTarget:self
                          action:@selector(aecLoopbackSwitchChanged:)
                forControlEvents:UIControlEventValueChanged];
            toggle.on = self.aecLoopbackDebugEnabled;
        } else {
            [toggle addTarget:self action:@selector(vadSwitchChanged:) forControlEvents:UIControlEventValueChanged];
            toggle.on = self.vadEnabled;
        }
        toggle.enabled = enabled;
        return cell;
    }

    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"ActionCell" forIndexPath:indexPath];
    cell.accessoryView = nil;
    cell.textLabel.text = item[@"title"];
    cell.textLabel.font = [UIFont boldSystemFontOfSize:16.0];
    cell.textLabel.textAlignment = NSTextAlignmentCenter;
    cell.textLabel.textColor = enabled ? UIColor.systemBlueColor : UIColor.secondaryLabelColor;
    cell.selectionStyle = enabled ? UITableViewCellSelectionStyleDefault : UITableViewCellSelectionStyleNone;
    cell.userInteractionEnabled = enabled;
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    NSDictionary<NSString *, id> *item = self.actionItems[indexPath.row];
    if (![item[@"enabled"] boolValue] || [item[@"kind"] isEqualToString:@"switch"]) {
        return;
    }

    SEL selector = NSSelectorFromString(item[@"selector"]);
    if ([self respondsToSelector:selector]) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
        [self performSelector:selector];
#pragma clang diagnostic pop
    }
}

- (void)refreshVADHangoverRowTitle {
    [self setActionWithID:@"vadHangover"
                    title:[NSString stringWithFormat:@"VAD 结束判定时长: %.1f 秒", self.vadEndHangoverSeconds]];
}

- (void)applyVADHangoverSecondsToProcessor {
    WRNNoiseProcessor.sharedProcessor.vadEndHangoverSeconds = self.vadEndHangoverSeconds;
}

- (void)configureVADHangover {
    UIAlertController *alert =
        [UIAlertController alertControllerWithTitle:@"说话结束判定时长"
                                            message:@"双源不再同时判语音后，需持续该时长才自动停录"
                                     preferredStyle:UIAlertControllerStyleActionSheet];
    for (NSNumber *seconds in @[@0.3, @0.5, @1.0, @1.5, @2.0, @3.0, @5.0]) {
        const double value = seconds.doubleValue;
        NSString *title = [NSString stringWithFormat:@"%.1f 秒", value];
        UIAlertAction *action = [UIAlertAction actionWithTitle:title
                                                         style:UIAlertActionStyleDefault
                                                       handler:^(UIAlertAction *_Nonnull action) {
            self.vadEndHangoverSeconds = value;
            [self applyVADHangoverSecondsToProcessor];
            [self refreshVADHangoverRowTitle];
            [self appendLog:[NSString stringWithFormat:@"VAD 结束判定时长已设为 %.1f 秒。", value]];
        }];
        [alert addAction:action];
    }
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];

    UIPopoverPresentationController *popover = alert.popoverPresentationController;
    if (popover) {
        popover.sourceView = self.tableView;
        NSIndexPath *indexPath = [NSIndexPath indexPathForRow:2 inSection:0];
        popover.sourceRect = [self.tableView rectForRowAtIndexPath:indexPath];
    }
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)vadSwitchChanged:(UISwitch *)sender {
    if (self.aecLoopbackDebugEnabled && sender.isOn) {
        sender.on = NO;
        [self appendLog:@"AEC 回环调试期间请保持 VAD 关闭，以免自动停录。"];
        return;
    }
    self.vadEnabled = sender.isOn;
    WRNNoiseProcessor *processor = WRNNoiseProcessor.sharedProcessor;
    processor.vadEnabled = sender.isOn;
    [self applyVADHangoverSecondsToProcessor];
    [self appendLog:sender.isOn ? @"已开启双源 VAD（RNNoise + WebRTC VoiceActivityDetector）。" : @"已关闭双源 VAD。"];
}

- (void)aecLoopbackSwitchChanged:(UISwitch *)sender {
    if (self.isRecording) {
        sender.on = self.aecLoopbackDebugEnabled;
        return;
    }
    self.aecLoopbackDebugEnabled = sender.isOn;
    if (sender.isOn && self.vadEnabled) {
        self.vadEnabled = NO;
        WRNNoiseProcessor.sharedProcessor.vadEnabled = NO;
        [self.tableView reloadData];
    }
    [self appendLog:sender.isOn ? @"已开启 AEC 调试：下次录音将延迟回播刚录语音并启用回音消除。"
                               : @"已关闭 AEC 调试。"];
}

- (void)setActionWithID:(NSString *)itemID enabled:(BOOL)enabled {
    for (NSMutableDictionary<NSString *, id> *item in self.actionItems) {
        if ([item[@"id"] isEqualToString:itemID]) {
            item[@"enabled"] = @(enabled);
            break;
        }
    }
    [self.tableView reloadData];
}

- (void)setActionWithID:(NSString *)itemID title:(NSString *)title {
    for (NSMutableDictionary<NSString *, id> *item in self.actionItems) {
        if ([item[@"id"] isEqualToString:itemID]) {
            item[@"title"] = title;
            break;
        }
    }
    [self.tableView reloadData];
}

- (NSURL *)documentsURLWithFilename:(NSString *)filename {
    NSURL *documentsURL = [[[NSFileManager defaultManager] URLsForDirectory:NSDocumentDirectory
                                                                  inDomains:NSUserDomainMask] firstObject];
    return [documentsURL URLByAppendingPathComponent:filename];
}

- (void)appendLog:(NSString *)line {
    NSString *existing = self.textView.text ?: @"";
    self.textView.text = [existing stringByAppendingFormat:@"%@\n", line];
    NSRange bottom = NSMakeRange(self.textView.text.length, 0);
    [self.textView scrollRangeToVisible:bottom];
}

- (NSString *)messageForAudioStatus:(OSStatus)status operation:(NSString *)operation {
    if (status == noErr) {
        return nil;
    }
    return [NSString stringWithFormat:@"%@ failed: %d", operation, (int)status];
}

- (void)toggleRecording {
    if (self.isRecording) {
        [self stopRecordingWithReason:@"手动停止"];
        return;
    }

    AVAudioSession *session = AVAudioSession.sharedInstance;
    [session requestRecordPermission:^(BOOL granted) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (!granted) {
                [self appendLog:@"没有麦克风权限，无法录音。"];
                return;
            }
            [self startRecording];
        });
    }];
}

- (AudioStreamBasicDescription)pcmStreamDescription {
    AudioStreamBasicDescription pcmFormat = {0};
    pcmFormat.mSampleRate = kRecorderSampleRate;
    pcmFormat.mFormatID = kAudioFormatLinearPCM;
    pcmFormat.mFormatFlags =
        kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked | kAudioFormatFlagsNativeEndian;
    pcmFormat.mBytesPerPacket = sizeof(int16_t) * kRecorderChannels;
    pcmFormat.mFramesPerPacket = 1;
    pcmFormat.mBytesPerFrame = sizeof(int16_t) * kRecorderChannels;
    pcmFormat.mChannelsPerFrame = kRecorderChannels;
    pcmFormat.mBitsPerChannel = 16;
    return pcmFormat;
}

- (NSData *)pcmDataByConvertingInputBuffer:(AVAudioPCMBuffer *)inputBuffer {
    if (!inputBuffer || inputBuffer.frameLength == 0 || !self.pcmConverter) {
        return nil;
    }

    const double ratio =
        self.pcmRecordFormat.sampleRate / MAX(inputBuffer.format.sampleRate, 1.0);
    const AVAudioFrameCount outputCapacity =
        (AVAudioFrameCount)ceil((double)inputBuffer.frameLength * ratio) + 32;
    NSMutableData *pcmData = [NSMutableData dataWithCapacity:(NSUInteger)(outputCapacity * sizeof(int16_t))];

    __block BOOL hasInput = YES;
    AVAudioConverterInputBlock inputBlock =
        ^AVAudioBuffer *_Nullable(AVAudioPacketCount inNumberOfPackets, AVAudioConverterInputStatus *outStatus) {
        if (hasInput) {
            hasInput = NO;
            *outStatus = AVAudioConverterInputStatus_HaveData;
            return inputBuffer;
        }
        *outStatus = AVAudioConverterInputStatus_NoDataNow;
        return nil;
    };

    while (YES) {
        AVAudioPCMBuffer *outputBuffer =
            [[AVAudioPCMBuffer alloc] initWithPCMFormat:self.pcmRecordFormat frameCapacity:outputCapacity];
        if (!outputBuffer) {
            break;
        }

        NSError *error = nil;
        [self.pcmConverter convertToBuffer:outputBuffer error:&error withInputFromBlock:inputBlock];
        if (error || outputBuffer.frameLength == 0) {
            break;
        }

        const NSUInteger byteLength = outputBuffer.frameLength * sizeof(int16_t);
        [pcmData appendBytes:outputBuffer.int16ChannelData[0] length:byteLength];
    }

    return pcmData.length > 0 ? pcmData : nil;
}

- (AVAudioFormat *)pcmRecordFormat {
    if (!_recordFormat) {
        _recordFormat = [[AVAudioFormat alloc] initWithCommonFormat:AVAudioPCMFormatInt16
                                                         sampleRate:kRecorderSampleRate
                                                           channels:kRecorderChannels
                                                        interleaved:YES];
    }
    return _recordFormat;
}

- (void)startRecording {
    NSError *error = nil;
    AVAudioSession *session = AVAudioSession.sharedInstance;
    [session setCategory:AVAudioSessionCategoryPlayAndRecord
             withOptions:AVAudioSessionCategoryOptionDefaultToSpeaker
                   error:&error];
    if (error) {
        [self appendLog:[NSString stringWithFormat:@"配置音频会话失败: %@", error.localizedDescription]];
        return;
    }
    [session setPreferredSampleRate:kRecorderSampleRate error:nil];
    [session setActive:YES error:&error];
    if (error) {
        [self appendLog:[NSString stringWithFormat:@"启动音频会话失败: %@", error.localizedDescription]];
        return;
    }

    self.originalURL = [self documentsURLWithFilename:@"original_16k_mono_s16.pcm"];
    self.processedURL = nil;
    [[NSFileManager defaultManager] removeItemAtURL:self.originalURL error:nil];
    [[NSFileManager defaultManager] removeItemAtURL:[self documentsURLWithFilename:@"processed_16k_mono_s16.pcm"] error:nil];

    WRNNoiseProcessor *processor = WRNNoiseProcessor.sharedProcessor;
    const BOOL aecLoopback = self.aecLoopbackDebugEnabled;
    processor.vadEnabled = aecLoopback ? NO : self.vadEnabled;
    processor.echoCancellationEnabled = aecLoopback;
    [self applyVADHangoverSecondsToProcessor];
    [processor resetProcessor];

    self.audioEngine = [[AVAudioEngine alloc] init];
    AVAudioInputNode *inputNode = self.audioEngine.inputNode;
    AVAudioFormat *inputFormat = [inputNode outputFormatForBus:0];
    self.pcmConverter = [[AVAudioConverter alloc] initFromFormat:inputFormat toFormat:self.pcmRecordFormat];

    self.loopbackPlayerNode = nil;
    if (aecLoopback) {
        self.loopbackPlayerNode = [[AVAudioPlayerNode alloc] init];
        [self.audioEngine attachNode:self.loopbackPlayerNode];
        [self.audioEngine connect:self.loopbackPlayerNode
                                 to:self.audioEngine.mainMixerNode
                             format:self.pcmRecordFormat];
        self.audioEngine.mainMixerNode.outputVolume = kAECDebugPlaybackVolume;
        self.aecDebugFarEndSendOffset = 0;
    }

    self.recordingQueue = dispatch_queue_create("com.webrtc.demo.recording", DISPATCH_QUEUE_SERIAL);
    self.processorQueue = dispatch_queue_create("com.webrtc.demo.processor", DISPATCH_QUEUE_SERIAL);
    dispatch_sync(self.recordingQueue, ^{
        self.recordingPCM = [NSMutableData data];
        self.aecDebugProcessedPCM = aecLoopback ? [NSMutableData data] : nil;
        self.aecDebugFarEndSendOffset = 0;
    });
    self.isRecording = YES;

    __weak typeof(self) weakSelf = self;
    [inputNode installTapOnBus:0
                    bufferSize:kTapBufferFrames
                        format:inputFormat
                         block:^(AVAudioPCMBuffer *buffer, AVAudioTime *when) {
        [weakSelf handleCapturedBuffer:buffer];
    }];

    [self.audioEngine prepare];
    if (![self.audioEngine startAndReturnError:&error]) {
        [inputNode removeTapOnBus:0];
        self.audioEngine = nil;
        self.loopbackPlayerNode = nil;
        self.isRecording = NO;
        dispatch_sync(self.recordingQueue, ^{
            self.recordingPCM = nil;
        });
        self.recordingQueue = nil;
        self.processorQueue = nil;
        [self appendLog:[NSString stringWithFormat:@"启动录音引擎失败: %@", error.localizedDescription]];
        return;
    }
    if (aecLoopback) {
        [self.loopbackPlayerNode play];
    }
    NSString *vadHint = self.vadEnabled ? @"VAD 已启用，说完后静音将自动停录。" : @"";
    NSString *aecHint = aecLoopback
        ? [NSString stringWithFormat:@"AEC 调试：%.1f s 后开始回播刚录语音；对比「原音频」与「处理后」。", kAECDebugPlaybackDelaySeconds]
        : @"";
    self.textView.text = [NSString stringWithFormat:@"正在录音...\n格式: 16 kHz / 单声道 / s16le PCM\n%@\n%@",
                                                    vadHint, aecHint];
    [self setActionWithID:@"vadToggle" enabled:!aecLoopback];
    [self setActionWithID:@"aecLoopbackToggle" enabled:NO];
    [self setActionWithID:@"playOriginal" enabled:NO];
    [self setActionWithID:@"playProcessed" enabled:NO];
    [self setActionWithID:@"shareOriginal" enabled:NO];
    [self setActionWithID:@"shareProcessed" enabled:NO];
    [self setActionWithID:@"record" title:@"停止录音"];
    if (aecLoopback) {
        [self appendLog:[NSString stringWithFormat:@"开始 AEC 调试：%.1f s 延迟回播刚录内容，参考=播放，音量 %.0f%%。",
                                                 kAECDebugPlaybackDelaySeconds, kAECDebugPlaybackVolume * 100.0]];
    } else {
        [self appendLog:@"开始录音（AVAudioEngine 实时采集）。"];
    }
}

/// 必须在 `recordingQueue` 上调用：从已录缓冲取出下一段「延迟回播」PCM（模拟服务器下行）。
- (NSData *)consumeAECDebugDelayedFarEndChunkWithByteLength:(NSUInteger)byteLength {
    if (byteLength == 0 || byteLength % sizeof(int16_t) != 0) {
        return nil;
    }

    const NSUInteger delayBytes =
        (NSUInteger)(kAECDebugPlaybackDelaySeconds * kRecorderSampleRate) * sizeof(int16_t);
    const NSUInteger totalBytes = self.recordingPCM.length;
    if (totalBytes < delayBytes + self.aecDebugFarEndSendOffset + byteLength) {
        return nil;
    }

    NSData *chunk = [self.recordingPCM subdataWithRange:NSMakeRange(self.aecDebugFarEndSendOffset, byteLength)];
    self.aecDebugFarEndSendOffset += byteLength;
    return chunk;
}

- (void)scheduleFarEndPlaybackWithPCM:(NSData *)pcmData {
    AVAudioPlayerNode *player = self.loopbackPlayerNode;
    if (!player || pcmData.length < sizeof(int16_t)) {
        return;
    }

    const AVAudioFrameCount frameCount = (AVAudioFrameCount)(pcmData.length / sizeof(int16_t));
    AVAudioPCMBuffer *buffer =
        [[AVAudioPCMBuffer alloc] initWithPCMFormat:self.pcmRecordFormat frameCapacity:frameCount];
    if (!buffer || buffer.frameCapacity < frameCount) {
        return;
    }
    buffer.frameLength = frameCount;
    memcpy(buffer.int16ChannelData[0], pcmData.bytes, pcmData.length);
    [player scheduleBuffer:buffer completionHandler:nil];
}

- (void)handleCapturedBuffer:(AVAudioPCMBuffer *)inputBuffer {
    if (!self.isRecording || !inputBuffer || inputBuffer.frameLength == 0 || !self.pcmConverter ||
        !self.recordingQueue) {
        return;
    }

    NSData *pcmChunk = [self pcmDataByConvertingInputBuffer:inputBuffer];
    if (pcmChunk.length == 0) {
        return;
    }

    NSData *pcmCopy = [pcmChunk copy];
    dispatch_queue_t recordingQueue = self.recordingQueue;
    dispatch_queue_t processorQueue = self.processorQueue;
    const BOOL aecDebug = self.aecLoopbackDebugEnabled;

    dispatch_async(recordingQueue, ^{
        [self.recordingPCM appendData:pcmCopy];

        NSData *farEndPCM = nil;
        if (aecDebug) {
            farEndPCM = [self consumeAECDebugDelayedFarEndChunkWithByteLength:pcmCopy.length];
            if (farEndPCM) {
                NSData *playbackPCM = [farEndPCM copy];
                dispatch_async(dispatch_get_main_queue(), ^{
                    [self scheduleFarEndPlaybackWithPCM:playbackPCM];
                });
            }
        }

        NSData *farEndForProcessor = [farEndPCM copy];
        dispatch_async(processorQueue, ^{
            WRNNoiseProcessor *processor = WRNNoiseProcessor.sharedProcessor;
            if (aecDebug) {
                if (farEndForProcessor) {
                    [processor processRenderPCMStreamData:farEndForProcessor];
                }
                NSData *processed = [processor processPCMStreamData:pcmCopy];
                if (processed.length > 0) {
                    NSData *processedCopy = [processed copy];
                    dispatch_async(recordingQueue, ^{
                        [self.aecDebugProcessedPCM appendData:processedCopy];
                    });
                }
                return;
            }

            if (!self.vadEnabled) {
                (void)[processor processPCMStreamData:pcmCopy];
                return;
            }

            (void)[processor processPCMStreamData:pcmCopy];

            WRNVADFrameInfo vad = processor.lastVADFrameInfo;
            const BOOL shouldStop = processor.utteranceSpeechEnded;
            if (!shouldStop && !vad.dualSpeechActive) {
                return;
            }

            dispatch_async(dispatch_get_main_queue(), ^{
                if (!self.isRecording) {
                    return;
                }
                if (vad.dualSpeechActive) {
                    [self appendLog:[NSString stringWithFormat:@"VAD 语音帧: RNNoise=%.2f WebRTC=%.2f",
                                                     vad.rnnoiseProbability, vad.webrtcSpeechProbability]];
                }
                if (shouldStop) {
                    [self stopRecordingWithReason:@"双源 VAD 判定说话结束"];
                }
            });
        });
    });
}

- (void)stopRecordingWithReason:(NSString *)reason {
    if (!self.isRecording) {
        return;
    }
    const BOOL wasAecLoopback = self.aecLoopbackDebugEnabled;
    self.isRecording = NO;

    AVAudioInputNode *inputNode = self.audioEngine.inputNode;
    [inputNode removeTapOnBus:0];
    [self.loopbackPlayerNode stop];
    [self.audioEngine stop];
    self.audioEngine = nil;
    self.loopbackPlayerNode = nil;
    self.pcmConverter = nil;

    __block NSUInteger savedBytes = 0;
    __block NSData *aecProcessedSnapshot = nil;
    dispatch_queue_t recordingQueue = self.recordingQueue;
    dispatch_queue_t processorQueue = self.processorQueue;
    if (processorQueue) {
        dispatch_sync(processorQueue, ^{
            if (wasAecLoopback) {
                WRNNoiseProcessor *processor = WRNNoiseProcessor.sharedProcessor;
                [processor processRenderPCMStreamData:NSData.data];
                NSData *tail = [processor processPCMStreamData:NSData.data];
                if (tail.length > 0 && recordingQueue) {
                    dispatch_sync(recordingQueue, ^{
                        [self.aecDebugProcessedPCM appendData:tail];
                    });
                }
            }
        });
    }
    if (recordingQueue) {
        dispatch_sync(recordingQueue, ^{
            NSData *pcm = [self.recordingPCM copy];
            aecProcessedSnapshot = [self.aecDebugProcessedPCM copy];
            self.recordingPCM = nil;
            self.aecDebugProcessedPCM = nil;
            if (pcm.length > 0) {
                NSError *writeError = nil;
                [[NSFileManager defaultManager] removeItemAtURL:self.originalURL error:nil];
                if ([pcm writeToURL:self.originalURL options:NSDataWritingAtomic error:&writeError]) {
                    savedBytes = pcm.length;
                } else {
                    dispatch_async(dispatch_get_main_queue(), ^{
                        [self appendLog:[NSString stringWithFormat:@"保存录音失败: %@",
                                         writeError.localizedDescription]];
                    });
                }
            }
        });
    }
    if (wasAecLoopback && aecProcessedSnapshot.length > 0) {
        self.processedURL = [self documentsURLWithFilename:@"processed_16k_mono_s16.pcm"];
        [[NSFileManager defaultManager] removeItemAtURL:self.processedURL error:nil];
        NSError *processedWriteError = nil;
        if ([aecProcessedSnapshot writeToURL:self.processedURL
                                       options:NSDataWritingAtomic
                                         error:&processedWriteError]) {
            [self appendLog:@"AEC 回环：已保存实时处理后的 PCM（可与原录音对比）。"];
            [self appendLog:self.processedURL.path];
        } else {
            [self appendLog:[NSString stringWithFormat:@"保存 AEC 处理后 PCM 失败: %@",
                             processedWriteError.localizedDescription]];
        }
    }
    self.recordingQueue = nil;
    self.processorQueue = nil;

    [WRNNoiseProcessor.sharedProcessor resetProcessor];

    unsigned long long fileBytes = savedBytes;
    if (fileBytes == 0) {
        NSDictionary *attrs = [[NSFileManager defaultManager] attributesOfItemAtPath:self.originalURL.path
                                                                             error:nil];
        fileBytes = [attrs[NSFileSize] unsignedLongLongValue];
    }

    [self setActionWithID:@"record" title:@"开始录音 16k/mono/int16"];
    [self setActionWithID:@"vadToggle" enabled:YES];
    [self setActionWithID:@"aecLoopbackToggle" enabled:YES];
    [self setActionWithID:@"playOriginal" enabled:YES];
    [self setActionWithID:@"playProcessed" enabled:YES];
    [self setActionWithID:@"shareOriginal" enabled:YES];
    [self setActionWithID:@"shareProcessed" enabled:YES];
    const double durationSeconds = (double)fileBytes / (sizeof(int16_t) * kRecorderSampleRate);
    [self appendLog:[NSString stringWithFormat:@"录音结束（%@），%llu 字节，约 %.2f 秒",
                     reason, fileBytes, durationSeconds]];
    [self appendLog:self.originalURL.path];
}

- (void)playOriginalAudio {
    if (!self.originalURL) {
        [self appendLog:@"没有原始录音。"];
        return;
    }
    [self playPCMURL:self.originalURL label:@"播放原音频"];
}

- (void)playProcessedAudio {
    if (!self.originalURL) {
        [self appendLog:@"没有原始录音。"];
        return;
    }
    if (!self.processedURL && ![self processOriginalRecording]) {
        return;
    }
    [self playPCMURL:self.processedURL label:@"播放处理后音频"];
}

- (void)stopPCMPlayback {
    if (self.playbackNode.isPlaying) {
        [self.playbackNode stop];
    }
    if (self.playbackEngine.isRunning) {
        [self.playbackEngine stop];
    }
    self.playbackNode = nil;
    self.playbackEngine = nil;
}

- (void)playPCMURL:(NSURL *)url label:(NSString *)label {
    NSError *error = nil;
    NSData *pcmData = [self pcmDataFromPCMURL:url error:&error];
    if (!pcmData) {
        [self appendLog:[NSString stringWithFormat:@"%@失败: %@", label, error.localizedDescription ?: @"PCM 为空"]];
        return;
    }

    AVAudioSession *session = AVAudioSession.sharedInstance;
    [session setCategory:AVAudioSessionCategoryPlayback error:nil];
    [session setActive:YES error:nil];

    [self stopPCMPlayback];

    AVAudioFormat *format = self.pcmRecordFormat;
    AVAudioFrameCount frameCount = (AVAudioFrameCount)(pcmData.length / sizeof(int16_t));
    AVAudioPCMBuffer *buffer = [[AVAudioPCMBuffer alloc] initWithPCMFormat:format frameCapacity:frameCount];
    if (!buffer || buffer.frameCapacity < frameCount) {
        [self appendLog:[NSString stringWithFormat:@"%@失败: 无法分配播放缓冲", label]];
        return;
    }
    buffer.frameLength = frameCount;
    memcpy(buffer.int16ChannelData[0], pcmData.bytes, pcmData.length);

    self.playbackEngine = [[AVAudioEngine alloc] init];
    self.playbackNode = [[AVAudioPlayerNode alloc] init];
    [self.playbackEngine attachNode:self.playbackNode];
    [self.playbackEngine connect:self.playbackNode to:self.playbackEngine.mainMixerNode format:format];

    [self.playbackEngine prepare];
    if (![self.playbackEngine startAndReturnError:&error]) {
        [self stopPCMPlayback];
        [self appendLog:[NSString stringWithFormat:@"%@失败: %@", label, error.localizedDescription]];
        return;
    }

    __weak typeof(self) weakSelf = self;
    [self.playbackNode scheduleBuffer:buffer
                        completionHandler:^{
        dispatch_async(dispatch_get_main_queue(), ^{
            [weakSelf stopPCMPlayback];
        });
    }];
    [self.playbackNode play];
    [self appendLog:[NSString stringWithFormat:@"%@ (%.2f s)", label, (double)frameCount / kRecorderSampleRate]];
}

- (void)shareOriginalPCM {
    if (!self.originalURL) {
        [self appendLog:@"没有原始录音。"];
        return;
    }
    NSError *error = nil;
    NSData *pcmData = [self pcmDataFromPCMURL:self.originalURL error:&error];
    if (!pcmData) {
        [self appendLog:[NSString stringWithFormat:@"导出原音频裸 PCM 失败: %@", error.localizedDescription]];
        return;
    }
    NSString *filename = [NSString stringWithFormat:@"original_16k_mono_s16_%.0f.pcm", NSDate.date.timeIntervalSince1970];
    NSURL *pcmURL = [self documentsURLWithFilename:filename];
    if (![pcmData writeToURL:pcmURL options:NSDataWritingAtomic error:&error]) {
        [self appendLog:[NSString stringWithFormat:@"导出原音频裸 PCM 失败: %@", error.localizedDescription]];
        return;
    }
    [self presentShareForURL:pcmURL label:@"原音频裸 PCM" bytes:pcmData.length];
}

- (void)shareProcessedPCM {
    if (!self.originalURL) {
        [self appendLog:@"没有原始录音。"];
        return;
    }
    if (!self.processedURL && ![self processOriginalRecording]) {
        return;
    }
    NSString *filename = [NSString stringWithFormat:@"processed_16k_mono_s16_%.0f.pcm", NSDate.date.timeIntervalSince1970];
    NSError *error = nil;
    NSData *pcmData = [self pcmDataFromPCMURL:self.processedURL error:&error];
    if (!pcmData) {
        [self appendLog:[NSString stringWithFormat:@"导出处理后裸 PCM 失败: %@", error.localizedDescription]];
        return;
    }
    NSURL *pcmURL = [self documentsURLWithFilename:filename];
    if (![pcmData writeToURL:pcmURL options:NSDataWritingAtomic error:&error]) {
        [self appendLog:[NSString stringWithFormat:@"导出处理后裸 PCM 失败: %@", error.localizedDescription]];
        return;
    }
    [self presentShareForURL:pcmURL label:@"处理后裸 PCM" bytes:pcmData.length];
}

- (NSData *)pcmDataFromPCMURL:(NSURL *)pcmURL error:(NSError **)error {
    if (!pcmURL) {
        if (error) {
            *error = [NSError errorWithDomain:NSCocoaErrorDomain code:NSFileNoSuchFileError userInfo:nil];
        }
        return nil;
    }

    if ([pcmURL.pathExtension.lowercaseString isEqualToString:@"wav"]) {
        return [self pcmDataFromWAVURL:pcmURL error:error];
    }

    NSData *pcmData = [NSData dataWithContentsOfURL:pcmURL options:0 error:error];
    if (!pcmData || pcmData.length < sizeof(int16_t)) {
        if (error && !*error) {
            *error = [NSError errorWithDomain:NSCocoaErrorDomain code:NSFileReadUnknownError userInfo:nil];
        }
        return nil;
    }
    if (pcmData.length % sizeof(int16_t) != 0) {
        pcmData = [pcmData subdataWithRange:NSMakeRange(0, pcmData.length - 1)];
    }
    return pcmData;
}

- (void)presentShareForURL:(NSURL *)url label:(NSString *)label bytes:(NSUInteger)bytes {
    UIActivityViewController *activityController =
        [[UIActivityViewController alloc] initWithActivityItems:@[url] applicationActivities:nil];
    activityController.popoverPresentationController.sourceView = self.view;
    activityController.popoverPresentationController.sourceRect =
        CGRectMake(CGRectGetMidX(self.view.bounds), CGRectGetMidY(self.view.bounds), 1.0, 1.0);
    [self presentViewController:activityController animated:YES completion:nil];
    [self appendLog:[NSString stringWithFormat:@"已生成%@：%@ (%lu bytes)",
                     label, url.path, (unsigned long)bytes]];
}

- (NSData *)pcmDataFromWAVURL:(NSURL *)audioURL error:(NSError **)error {
    ExtAudioFileRef inputFile = NULL;
    OSStatus status = ExtAudioFileOpenURL((__bridge CFURLRef)audioURL, &inputFile);
    if (status != noErr) {
        if (error) {
            *error = [NSError errorWithDomain:NSOSStatusErrorDomain code:status userInfo:nil];
        }
        return nil;
    }

    AudioStreamBasicDescription pcmFormat = [self pcmStreamDescription];

    status = ExtAudioFileSetProperty(inputFile,
                                     kExtAudioFileProperty_ClientDataFormat,
                                     sizeof(pcmFormat),
                                     &pcmFormat);
    if (status != noErr) {
        ExtAudioFileDispose(inputFile);
        if (error) {
            *error = [NSError errorWithDomain:NSOSStatusErrorDomain code:status userInfo:nil];
        }
        return nil;
    }

    SInt64 frameLength = 0;
    UInt32 propertySize = sizeof(frameLength);
    status = ExtAudioFileGetProperty(inputFile,
                                     kExtAudioFileProperty_FileLengthFrames,
                                     &propertySize,
                                     &frameLength);
    if (status != noErr || frameLength <= 0) {
        ExtAudioFileDispose(inputFile);
        if (error) {
            *error = [NSError errorWithDomain:NSOSStatusErrorDomain
                                         code:(status == noErr ? -1 : status)
                                     userInfo:nil];
        }
        return nil;
    }

    NSMutableData *pcmData = [NSMutableData dataWithLength:(NSUInteger)frameLength * sizeof(int16_t)];
    AudioBufferList bufferList = {0};
    bufferList.mNumberBuffers = 1;
    bufferList.mBuffers[0].mNumberChannels = kRecorderChannels;
    bufferList.mBuffers[0].mDataByteSize = (UInt32)pcmData.length;
    bufferList.mBuffers[0].mData = pcmData.mutableBytes;

    UInt32 framesToRead = (UInt32)frameLength;
    status = ExtAudioFileRead(inputFile, &framesToRead, &bufferList);
    ExtAudioFileDispose(inputFile);
    if (status != noErr) {
        if (error) {
            *error = [NSError errorWithDomain:NSOSStatusErrorDomain code:status userInfo:nil];
        }
        return nil;
    }

    pcmData.length = framesToRead * sizeof(int16_t);
    return pcmData;
}

- (void)openPCMFilePicker {
    UIDocumentPickerViewController *picker =
        [[UIDocumentPickerViewController alloc] initWithDocumentTypes:@[@"public.data", @"public.item"]
                                                               inMode:UIDocumentPickerModeImport];
    picker.delegate = self;
    picker.allowsMultipleSelection = NO;
    [self presentViewController:picker animated:YES completion:nil];
}

- (void)documentPicker:(UIDocumentPickerViewController *)controller didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    NSURL *url = urls.firstObject;
    if (!url) {
        return;
    }

    NSError *error = nil;
    NSData *inputData = [NSData dataWithContentsOfURL:url options:0 error:&error];
    if (!inputData) {
        [self appendLog:[NSString stringWithFormat:@"读取导入 PCM 失败: %@", error.localizedDescription]];
        return;
    }
    if (inputData.length < sizeof(int16_t)) {
        [self appendLog:@"导入 PCM 为空。"];
        return;
    }

    NSMutableData *pcmData = [inputData mutableCopy];
    if (pcmData.length % sizeof(int16_t) != 0) {
        pcmData.length = pcmData.length - 1;
        [self appendLog:@"导入 PCM 字节数不是 2 的倍数，已忽略最后 1 个字节。"];
    }

    NSData *processedData = [self processedPCMDataFromPCMData:pcmData sourceLabel:url.lastPathComponent];
    if (!processedData) {
        return;
    }

    NSString *baseName = url.URLByDeletingPathExtension.lastPathComponent ?: @"imported";
    NSString *outputName = [NSString stringWithFormat:@"%@_processed_16k_mono_s16.pcm", baseName];
    NSURL *outputURL = [self documentsURLWithFilename:outputName];
    if (![processedData writeToURL:outputURL options:NSDataWritingAtomic error:&error]) {
        [self appendLog:[NSString stringWithFormat:@"写入处理后 PCM 失败: %@", error.localizedDescription]];
        return;
    }

    [self presentShareForURL:outputURL label:@"导入 PCM 处理结果" bytes:processedData.length];
}

- (void)documentPickerWasCancelled:(UIDocumentPickerViewController *)controller {
    [self appendLog:@"已取消导入 PCM。"];
}

- (NSData *)processedPCMDataFromPCMData:(NSData *)inputData sourceLabel:(NSString *)sourceLabel {
    if (inputData.length < sizeof(int16_t)) {
        [self appendLog:@"PCM 数据为空。"];
        return nil;
    }

    NSData *processedData = [WRNNoiseProcessor processPCMData:inputData];
    [self appendLog:[NSString stringWithFormat:@"PCM处理完成: %@, %.2f sec",
                     sourceLabel ?: @"raw pcm", (double)(inputData.length / sizeof(int16_t)) / kRecorderSampleRate]];
    [self appendLog:@"调用封装: [WRNNoiseProcessor processPCMData:pcmData]"];
    return processedData;
}

- (BOOL)processOriginalRecording {
    self.processedURL = [self documentsURLWithFilename:@"processed_16k_mono_s16.pcm"];
    [[NSFileManager defaultManager] removeItemAtURL:self.processedURL error:nil];

    NSError *error = nil;
    NSData *pcmData = [self pcmDataFromPCMURL:self.originalURL error:&error];
    if (!pcmData) {
        [self appendLog:[NSString stringWithFormat:@"读取录音失败: %@", error.localizedDescription ?: @"PCM 为空"]];
        return NO;
    }

    NSData *processedData = [WRNNoiseProcessor processPCMData:pcmData];
    if (![processedData writeToURL:self.processedURL options:NSDataWritingAtomic error:&error]) {
        [self appendLog:[NSString stringWithFormat:@"写入处理后 PCM 失败: %@", error.localizedDescription]];
        return NO;
    }

    [self appendLog:@"处理完成: [WRNNoiseProcessor processPCMData:pcmData]"];
    [self appendLog:self.processedURL.path];
    return YES;
}

@end

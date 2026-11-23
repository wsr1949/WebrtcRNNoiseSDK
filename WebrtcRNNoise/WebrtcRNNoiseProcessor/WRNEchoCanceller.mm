//
//  WRNEchoCanceller.mm
//  WebrtcRNNoise
//

#import "WRNEchoCanceller.h"
#import <os/lock.h>
#import <mach/mach_time.h>
#include <math.h>
#include <stdlib.h>
#include <string.h>

enum {
    kAECRate = 16000,
    kAECFrame = 160,                         // 10 ms，统计和增益按这个节拍更新
    kAECFilter = 640,                        // 40 ms，覆盖喇叭到眼镜麦的拖尾
    kAECLead = 64,                           // 相关峰再往前 4 ms，避免主径落在滤波器外面
    kAECMinDelay = 1600,                     // 100 ms。蓝牙加编码不会只有几十毫秒，31 ms 是假峰
    kAECMaxDelay = 19200,                    // 1200 ms，盖住蓝牙缓冲
    kAECCorr = 1600,                         // 100 ms 相关窗
    kAECDecim = 8,
    kAECRingCap = 65536,                     // 4.096 s
    kAECRingMask = 65535,
    kAECChunk = 4800,
    kAECSnapMax = 1600 + 19200 + 640 + 4800 + 64,
    kAECDecN = 1600 / 8,
    kAECFarBins = (19200 + 1600) / 8,
    kAECLagBins = ((19200 - 1600) / 8) + 4
};

typedef struct {
    os_unfair_lock ringLock;
    os_unfair_lock stateLock;

    float ring[kAECRingCap];
    int hasFar;
    int64_t minIndex;
    int64_t maxIndex;
    int64_t renderHotUntil;
    int64_t renderClockIndex;
    uint64_t renderClockNs;

    float snapshot[kAECSnapMax];
    int64_t snapStart;
    int snapCount;
    int snapHasFar;

    float w[kAECFilter];
    float mu;
    int adapt;

    float nearHist[kAECCorr];
    int nearHistPos;
    int nearHistCount;
    int64_t nearHistEnd;

    int captureStarted;
    int64_t captureEnd;

    int delaySamples;
    int filterDelay;
    int delayLocked;
    int pendingDelay;
    int pendingCount;
    int framesSinceLock;
    int frameIndex;

    int sinceControl;
    int accN;
    float accMic;
    float accErr;
    float accY;
    float accFar;
    float accDot;
    float accDotY;

    float outputGain;
    float cancelGain;
    float echoFloor;
    int suppressHold;
    int dtHold;
    float coupling;
    int farActive;
    int doubleTalk;
    float lastNcc;
    float lastSearchRaw;
    float lastFarDb;
    float lastNearDb;
    int misalignedFrames;
    float linearErleDb;
    int linearErleInit;
    double linearMicEnergy;
    double linearErrEnergy;

    int searchCount;
    float searchNear[kAECCorr];
    float searchNDiff[kAECDecN];
    float searchFEnv[kAECFarBins];
    float searchFDiff[kAECFarBins];
    float searchNcc[kAECLagBins];

    int logSamples;
    int gateEnabled;
    int16_t *alignedFar;
    int alignedFarIndex;
} LWAECState;

static uint64_t LWAECNowNs(void) {
    static mach_timebase_info_data_t timebase;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        mach_timebase_info(&timebase);
    });
    uint64_t ticks = mach_absolute_time();
    return ticks * timebase.numer / timebase.denom;
}

static int64_t LWAECHostToIndex(uint64_t hostNs) {
    uint64_t sec = hostNs / 1000000000ull;
    uint64_t rem = hostNs % 1000000000ull;
    return (int64_t)(sec * (uint64_t)kAECRate + rem * (uint64_t)kAECRate / 1000000000ull);
}

static int16_t LWAECFloatToInt16(float x) {
    float scaled = x * 32768.f;
    if (scaled > 32767.f) return 32767;
    if (scaled < -32768.f) return -32768;
    return (int16_t)rintf(scaled);
}

static float LWAECDb(float meanSquare) {
    return 10.f * log10f(meanSquare + 1e-12f);
}

static void LWAECClearRuntime(LWAECState *s) {
    memset(s->ring, 0, sizeof(s->ring));
    memset(s->w, 0, sizeof(s->w));
    memset(s->nearHist, 0, sizeof(s->nearHist));
    s->hasFar = 0;
    s->minIndex = 0;
    s->maxIndex = 0;
    s->renderHotUntil = 0;
    s->renderClockIndex = 0;
    s->renderClockNs = 0;
    s->snapStart = 0;
    s->snapCount = 0;
    s->snapHasFar = 0;
    s->mu = 0.45f;
    s->adapt = 0;
    s->nearHistPos = 0;
    s->nearHistCount = 0;
    s->nearHistEnd = -1;
    s->captureStarted = 0;
    s->captureEnd = 0;
    s->delaySamples = 0;
    s->filterDelay = 0;
    s->delayLocked = 0;
    s->pendingDelay = 0;
    s->pendingCount = 0;
    s->framesSinceLock = 0;
    s->frameIndex = 0;
    s->sinceControl = 0;
    s->accN = 0;
    s->accMic = 0;
    s->accErr = 0;
    s->accY = 0;
    s->accFar = 0;
    s->accDot = 0;
    s->accDotY = 0;
    s->outputGain = 1.f;
    s->cancelGain = 0.f;
    s->echoFloor = -1.f;
    s->suppressHold = 0;
    s->dtHold = 0;
    s->coupling = -1.f;
    s->farActive = 0;
    s->doubleTalk = 0;
    s->lastNcc = 0;
    s->lastSearchRaw = 0;
    s->lastFarDb = -120.f;
    s->lastNearDb = -120.f;
    s->misalignedFrames = 0;
    s->linearErleDb = 0;
    s->linearErleInit = 0;
    s->linearMicEnergy = 0;
    s->linearErrEnergy = 0;
    s->logSamples = 0;
    s->gateEnabled = 1;
    s->alignedFar = NULL;
    s->alignedFarIndex = 0;
}

static LWAECState *LWAECStateCreate(void) {
    LWAECState *s = (LWAECState *)calloc(1, sizeof(LWAECState));
    if (!s) return NULL;
    s->ringLock = OS_UNFAIR_LOCK_INIT;
    s->stateLock = OS_UNFAIR_LOCK_INIT;
    LWAECClearRuntime(s);
    return s;
}

static float LWAECReadFarLocked(const LWAECState *s, int64_t index) {
    if (!s->hasFar || index < s->minIndex || index >= s->maxIndex) return 0.f;
    return s->ring[(uint64_t)index & (uint64_t)kAECRingMask];
}

static void LWAECWriteReference(LWAECState *s, const int16_t *samples, int count, uint64_t hostNs) {
    // 播放回调大约 60 ms 一次，而且每次都会重新带上 mHostTime。这个时间会停住几秒再跳，
    // 用它摆放时，后面的样本盖住前面的，播放头不再前进，延迟就锁不上。这里只按播出顺序往后接。
    (void)hostNs;
    if (!s || count <= 0 || !samples) return;
    os_unfair_lock_lock(&s->ringLock);
    if (!s->hasFar) {
        s->hasFar = 1;
        s->minIndex = 0;
        s->maxIndex = 0;
    }
    int64_t start = s->maxIndex;
    float energy = 0.f;
    for (int i = 0; i < count; i++) {
        float sample = (float)samples[i] * (1.f / 32768.f);
        s->ring[(uint64_t)(start + i) & (uint64_t)kAECRingMask] = sample;
        energy += sample * sample;
    }
    if (energy / (float)count > 1e-5f) {
        // 回声还要再走完蓝牙延迟。最后一声之后 0.6 s 内算播报还在路上，避免播完后把人声继续压住。
        int64_t until = start + count + (int64_t)kAECRate * 3 / 5;
        if (until > s->renderHotUntil) s->renderHotUntil = until;
    }
    s->maxIndex = start + count;
    if (s->maxIndex - s->minIndex > kAECRingCap) {
        s->minIndex = s->maxIndex - kAECRingCap;
    }
    // 记下这次写出时的真实时间。采集按这个钟往回对，不再用会停住的 mHostTime。
    s->renderClockIndex = s->maxIndex;
    s->renderClockNs = LWAECNowNs();
    os_unfair_lock_unlock(&s->ringLock);
}

static void LWAECFillSnapshot(LWAECState *s, int64_t from, int count) {
    if (count > kAECSnapMax) count = kAECSnapMax;
    if (count < 0) count = 0;
    os_unfair_lock_lock(&s->ringLock);
    for (int i = 0; i < count; i++) {
        s->snapshot[i] = LWAECReadFarLocked(s, from + i);
    }
    s->snapStart = from;
    s->snapCount = count;
    s->snapHasFar = s->hasFar;
    os_unfair_lock_unlock(&s->ringLock);
}

static float LWAECFarAt(const LWAECState *s, int64_t index) {
    int64_t offset = index - s->snapStart;
    if (offset < 0 || offset >= s->snapCount) return 0.f;
    return s->snapshot[offset];
}

static void LWAECShiftWeights(LWAECState *s, int step) {
    if (step == 0) return;
    float shifted[kAECFilter];
    if (step > 0) {
        for (int k = 0; k < kAECFilter; k++) {
            int source = k + step;
            shifted[k] = (source < kAECFilter) ? s->w[source] : 0.f;
        }
    } else {
        int skip = -step;
        for (int k = 0; k < kAECFilter; k++) {
            int source = k - skip;
            shifted[k] = (source >= 0) ? s->w[source] : 0.f;
        }
    }
    memcpy(s->w, shifted, sizeof(shifted));
}

static void LWAECApplyDelay(LWAECState *s, int peak) {
    if (peak < kAECMinDelay) peak = kAECMinDelay;
    if (peak > kAECMaxDelay) peak = kAECMaxDelay;
    if (!s->delayLocked) {
        s->delayLocked = 1;
        s->delaySamples = peak;
        s->filterDelay = peak - kAECLead;
        if (s->filterDelay < 0) s->filterDelay = 0;
        memset(s->w, 0, sizeof(s->w));
        s->framesSinceLock = 0;
        s->pendingCount = 0;
        s->farActive = 1;
        return;
    }

    int diff = peak - s->delaySamples;
    int distance = diff < 0 ? -diff : diff;
    // 同一段播放里延迟会漂。40 ms 以内直接采用，让 AEC3 拿到当前延迟。
    if (distance <= 640) {
        s->delaySamples = peak;
        s->filterDelay = peak - kAECLead;
        if (s->filterDelay < 0) s->filterDelay = 0;
        s->pendingCount = 0;
        return;
    }
    // 换一段 TTS 时延迟会跳一大截。连续两次落在附近再改，避免单帧假峰。
    if (s->pendingCount > 0 && abs(peak - s->pendingDelay) <= 16) {
        s->pendingCount += 1;
    } else {
        s->pendingDelay = peak;
        s->pendingCount = 1;
    }
    if (s->pendingCount < 2) return;

    s->delaySamples = peak;
    s->filterDelay = peak - kAECLead;
    if (s->filterDelay < 0) s->filterDelay = 0;
    memset(s->w, 0, sizeof(s->w));
    s->framesSinceLock = 0;
    s->pendingCount = 0;
    s->coupling = -1.f;
}

static void LWAECSearchDelay(LWAECState *s) {
    if (s->nearHistCount < kAECCorr || !s->snapHasFar) return;

    int64_t nearEnd = s->nearHistEnd;
    int64_t nearAbs0 = nearEnd - kAECCorr;
    for (int i = 0; i < kAECCorr; i++) {
        int pos = s->nearHistPos + i;
        if (pos >= kAECCorr) pos -= kAECCorr;
        s->searchNear[i] = s->nearHist[pos];
    }

    float prev = 0.f;
    float nearEnergy = 0.f;
    for (int i = 0; i < kAECDecN; i++) {
        float sum = 0.f;
        int base = i * kAECDecim;
        for (int k = 0; k < kAECDecim; k++) sum += fabsf(s->searchNear[base + k]);
        float diff = sum - prev;
        prev = sum;
        s->searchNDiff[i] = diff;
        if (i > 0) nearEnergy += diff * diff;
    }
    if (nearEnergy < 1e-8f) return;

    int64_t farBase = nearAbs0 - kAECMaxDelay;
    prev = 0.f;
    for (int j = 0; j < kAECFarBins; j++) {
        int64_t absIndex = farBase + (int64_t)j * kAECDecim;
        float sum = 0.f;
        for (int k = 0; k < kAECDecim; k++) sum += fabsf(LWAECFarAt(s, absIndex + k));
        s->searchFEnv[j] = sum;
        s->searchFDiff[j] = sum - prev;
        prev = sum;
    }

    int lagCount = 0;
    float best = -1.f;
    int bestLag = -1;
    for (int lag = kAECMinDelay; lag <= kAECMaxDelay; lag += kAECDecim) {
        int j0 = (kAECMaxDelay - lag) / kAECDecim;
        float dot = 0.f;
        float farEnergy = 0.f;
        if (j0 < 0 || j0 + kAECDecN > kAECFarBins) {
            s->searchNcc[lagCount++] = -1.f;
            continue;
        }
        for (int i = 1; i < kAECDecN; i++) {
            float far = s->searchFDiff[j0 + i];
            dot += s->searchNDiff[i] * far;
            farEnergy += far * far;
        }
        float ncc = dot / (sqrtf(nearEnergy * farEnergy) + 1e-8f);
        s->searchNcc[lagCount] = ncc;
        if (ncc > best) {
            best = ncc;
            bestLag = lag;
        }
        lagCount += 1;
        if (lagCount >= kAECLagBins) break;
    }
    if (bestLag < 0) return;
    // 没锁上时日志里的 ncc 是帧相关，参考还是空的，一直是 0。这里留下搜索峰，方便看是没搜到还是没锁上。
    s->lastSearchRaw = best;
    if (best < 0.42f) return;

    float second = -1.f;
    for (int i = 0; i < lagCount; i++) {
        int lag = kAECMinDelay + i * kAECDecim;
        int distance = lag - bestLag;
        if (distance < 0) distance = -distance;
        if (distance <= 64) continue;
        if (s->searchNcc[i] > second) second = s->searchNcc[i];
    }
    if (second > 0.f && best < second + 0.04f) return;

    float alignedEnergy = 0.f;
    int energyCount = 0;
    for (int i = 0; i < kAECCorr; i += kAECDecim) {
        float far = LWAECFarAt(s, nearAbs0 + i - bestLag);
        alignedEnergy += far * far;
        energyCount += 1;
    }
    if (energyCount == 0 || alignedEnergy / (float)energyCount < 1e-5f) return;

    // 包络峰常常偏出十几毫秒。只在 ±0.5 ms 里对波形的话，锁住的延迟喂给 AEC3 仍然是错位的。
    int refined = bestLag;
    float bestRaw = -2.f;
    int radius = 640;
    int coarse = 8;
    int from = bestLag - radius;
    int to = bestLag + radius;
    if (from < kAECMinDelay) from = kAECMinDelay;
    if (to > kAECMaxDelay) to = kAECMaxDelay;
    int refineStart = kAECCorr - 640;
    int64_t refineAbs = nearAbs0 + refineStart;
    for (int lag = from; lag <= to; lag += coarse) {
        float dot = 0.f;
        float nearEnergyRaw = 0.f;
        float farEnergyRaw = 0.f;
        for (int i = 0; i < 640; i++) {
            float near = s->searchNear[refineStart + i];
            float far = LWAECFarAt(s, refineAbs + i - lag);
            dot += near * far;
            nearEnergyRaw += near * near;
            farEnergyRaw += far * far;
        }
        float ncc = dot / (sqrtf(nearEnergyRaw * farEnergyRaw) + 1e-8f);
        if (ncc > bestRaw) {
            bestRaw = ncc;
            refined = lag;
        }
    }
    int fineFrom = refined - coarse;
    int fineTo = refined + coarse;
    if (fineFrom < kAECMinDelay) fineFrom = kAECMinDelay;
    if (fineTo > kAECMaxDelay) fineTo = kAECMaxDelay;
    for (int lag = fineFrom; lag <= fineTo; lag++) {
        float dot = 0.f;
        float nearEnergyRaw = 0.f;
        float farEnergyRaw = 0.f;
        for (int i = 0; i < 640; i++) {
            float near = s->searchNear[refineStart + i];
            float far = LWAECFarAt(s, refineAbs + i - lag);
            dot += near * far;
            nearEnergyRaw += near * near;
            farEnergyRaw += far * far;
        }
        float ncc = dot / (sqrtf(nearEnergyRaw * farEnergyRaw) + 1e-8f);
        if (ncc > bestRaw) {
            bestRaw = ncc;
            refined = lag;
        }
    }
    // 包络峰可以落在搜索下沿，原始波形对不上就不要锁。31 ms 就是这样锁上去的。
    s->lastSearchRaw = bestRaw;
    if (bestRaw < 0.18f) return;
    if (bestLag < kAECMinDelay + 256 && bestRaw < 0.55f) return;
    int chosen = (bestRaw > 0.25f) ? refined : bestLag;
    if (s->delayLocked) {
        int distance = chosen - s->delaySamples;
        if (distance < 0) distance = -distance;
        if (distance > 16) {
            float dot = 0.f;
            float nearEnergyRaw = 0.f;
            float farEnergyRaw = 0.f;
            for (int i = 0; i < 640; i++) {
                float near = s->searchNear[refineStart + i];
                float far = LWAECFarAt(s, refineAbs + i - s->delaySamples);
                dot += near * far;
                nearEnergyRaw += near * near;
                farEnergyRaw += far * far;
            }
            float currentRaw = dot / (sqrtf(nearEnergyRaw * farEnergyRaw) + 1e-8f);
            // 新位置没有更像就留在原地。弱峰把 419 ms 带去 379 ms 时，AEC3 会对错参考，回声整段漏出去。
            if (bestRaw <= currentRaw) return;
        }
    }
    // 蓝牙回声大约 150–800 ms。200 ms 上出现过 0.71 的真相关，不能再把下沿卡在 250 ms。
    if (!s->delayLocked && bestRaw < 0.55f && (chosen < 2400 || chosen > 12800)) return;
    s->lastNcc = bestRaw > best ? bestRaw : best;
    LWAECApplyDelay(s, chosen);
}

static void LWAECFinishFrame(LWAECState *s) {
    int haveFrame = (s->accN == kAECFrame);
    if (haveFrame) {
        float micE = s->accMic / (float)kAECFrame;
        float yE = s->accY / (float)kAECFrame;
        float farE = s->accFar / (float)kAECFrame;
        float nccF = 0.f;
        float nccY = 0.f;
        if (s->accMic > 1e-8f && s->accFar > 1e-8f) {
            nccF = fabsf(s->accDot / sqrtf(s->accMic * s->accFar));
        }
        if (s->accMic > 1e-8f && s->accY > 1e-8f) {
            nccY = fabsf(s->accDotY / sqrtf(s->accMic * s->accY));
        }
        s->lastNcc = nccF > nccY ? nccF : nccY;
        s->lastFarDb = LWAECDb(farE);
        s->lastNearDb = LWAECDb(micE);
        int64_t renderHotUntil = 0;
        os_unfair_lock_lock(&s->ringLock);
        renderHotUntil = s->renderHotUntil;
        os_unfair_lock_unlock(&s->ringLock);
        int renderInFlight = (s->nearHistEnd > 0 && s->nearHistEnd < renderHotUntil);
        // 对齐上的参考短暂停，或者喇叭声还在缓冲里，都继续压。
        if (farE > 1e-5f) s->suppressHold = 40;
        else if (s->suppressHold > 0) s->suppressHold -= 1;
        s->farActive = (farE > 1e-5f) || renderInFlight || (s->delayLocked && s->suppressHold > 0);

        // 只在能量像回声、波形也像时抬高底。安静帧不能把底噪压垮，否则普通回声会被当成插话。
        if (s->farActive && nccF > 0.45f && micE > 1e-5f && micE < 2e-3f) {
            if (s->echoFloor < 0.f) s->echoFloor = micE;
            else if (micE > s->echoFloor) s->echoFloor = 0.70f * s->echoFloor + 0.30f * micE;
            else s->echoFloor = 0.98f * s->echoFloor + 0.02f * micE;
        }
        int doubleTalk = 0;
        // 很响、而且和喇叭差不多大，才是贴着喇叭插话。
        int overSpeaker = farE > 1e-5f && micE > 2.5e-3f && micE > farE * 0.1f && nccF < 0.55f;
        // 播报过程中人声往往只有 -32 dB 左右，但和参考不像。回声在这个响度上相关会更高。
        int barge = farE > 1e-5f && nccF < 0.15f && micE > 2.5e-4f;
        int loudUser = !renderInFlight && farE <= 1e-5f && micE > 2.5e-3f && nccF < 0.35f;
        if (s->delayLocked && s->farActive && (overSpeaker || barge || loudUser)) {
            doubleTalk = 1;
            s->dtHold = 30;
        } else if (s->dtHold > 0) {
            s->dtHold -= 1;
            doubleTalk = 1;
        }
        s->doubleTalk = doubleTalk;

        if (s->farActive && !doubleTalk && nccF > 0.20f && s->accFar > 1e-6f) {
            float tap = s->accDot / s->accFar;
            if (tap > 2.f) tap = 2.f;
            if (tap < -2.f) tap = -2.f;
            s->cancelGain = 0.6f * s->cancelGain + 0.4f * tap;
        }
        if (s->accErr > s->accMic * 1.10f && s->accMic > 1e-6f) {
            s->cancelGain *= 0.5f;
        }

        if (s->delayLocked && s->farActive && s->framesSinceLock > 8) {
            float gated = s->accErr * s->outputGain * s->outputGain;
            s->linearMicEnergy += s->accMic;
            s->linearErrEnergy += gated;
            float erle = 10.f * log10f((s->accMic + 1e-8f) / (gated + 1e-8f));
            if (!s->linearErleInit) {
                s->linearErleDb = erle;
                s->linearErleInit = 1;
            } else {
                s->linearErleDb = 0.9f * s->linearErleDb + 0.1f * erle;
            }
        }

        if (!s->gateEnabled) {
            s->doubleTalk = 0;
            s->outputGain = 1.f;
        } else {
            float target = 1.f;
            if (doubleTalk || !s->farActive) target = 1.f;
            else target = 0.07f;
            if (doubleTalk && target > s->outputGain) s->outputGain = target;
            else if (target < s->outputGain) s->outputGain = target;
            else s->outputGain += 0.45f * (target - s->outputGain);
        }
        (void)yE;
    }

    s->accN = 0;
    s->accMic = 0.f;
    s->accErr = 0.f;
    s->accY = 0.f;
    s->accFar = 0.f;
    s->accDot = 0.f;
    s->accDotY = 0.f;

    s->frameIndex += 1;
    if (!s->delayLocked || (s->frameIndex % 4) == 0) {
        LWAECSearchDelay(s);
    }
    if (s->delayLocked) s->framesSinceLock += 1;
    s->mu = (s->framesSinceLock < 80) ? 0.45f : 0.18f;
    s->adapt = (s->delayLocked && s->farActive && !s->doubleTalk) ? 1 : 0;
}

static void LWAECPushNear(LWAECState *s, float mic, int64_t index) {
    // 包和包之间差几个采样很常见。差一格就清空的话，100 ms 的窗永远攒不满，搜索不会跑。
    if (s->nearHistEnd >= 0 && index != s->nearHistEnd) {
        int64_t gap = index - s->nearHistEnd;
        if (gap > 800 || gap < -800) {
            s->nearHistCount = 0;
            s->nearHistPos = 0;
        }
    }
    s->nearHist[s->nearHistPos] = mic;
    s->nearHistPos += 1;
    if (s->nearHistPos >= kAECCorr) s->nearHistPos = 0;
    if (s->nearHistCount < kAECCorr) s->nearHistCount += 1;
    s->nearHistEnd = index + 1;
}

static void LWAECCancelSample(LWAECState *s, float mic, int64_t index, int16_t *outSample) {
    float farPeak = LWAECFarAt(s, index - s->delaySamples);
    float y = s->cancelGain * farPeak;
    float error = mic;
    s->accMic += mic * mic;
    s->accErr += error * error;
    s->accY += y * y;
    s->accFar += farPeak * farPeak;
    s->accDot += mic * farPeak;
    s->accDotY += mic * y;
    s->accN += 1;
    *outSample = LWAECFloatToInt16(mic * s->outputGain);
}

static void LWAECWriteAlignedFar(LWAECState *s, int64_t index) {
    if (!s->alignedFar) return;
    float far = 0.f;
    if (s->delayLocked) far = LWAECFarAt(s, index - s->delaySamples);
    s->alignedFar[s->alignedFarIndex] = LWAECFloatToInt16(far);
    s->alignedFarIndex += 1;
}

static void LWAECAbsorb(LWAECState *s, int16_t input, int16_t *output, int64_t index) {
    float mic = (float)input * (1.f / 32768.f);
    LWAECPushNear(s, mic, index);
    if (!s->delayLocked) {
        if (s->outputGain >= 0.999f) *output = input;
        else *output = LWAECFloatToInt16(mic * s->outputGain);
        s->accMic += mic * mic;
        s->accN += 1;
        LWAECWriteAlignedFar(s, index);
    } else {
        LWAECCancelSample(s, mic, index, output);
        LWAECWriteAlignedFar(s, index);
    }
    s->sinceControl += 1;
    if (s->sinceControl >= kAECFrame) {
        LWAECFinishFrame(s);
        s->sinceControl = 0;
    }
}

static void LWAECResetNearHistory(LWAECState *s) {
    s->nearHistCount = 0;
    s->nearHistPos = 0;
    s->nearHistEnd = -1;
    s->sinceControl = 0;
    s->accN = 0;
}

/// 麦从录音开始就一直有，TTS 是中途才来。播放中的这一包按「到达时刻」对到播放队列上，整包都要给出参考。
/// 之前播放头没往前走就把整包丢掉，参考变成静音，AEC3 对不掉回声。
static void LWAECPlaceCapture(LWAECState *s, int count, uint64_t arrivalNs, int64_t *outStart) {
    os_unfair_lock_lock(&s->ringLock);
    int hasFar = s->hasFar;
    int64_t renderHead = s->maxIndex;
    int64_t clockIndex = s->renderClockIndex;
    uint64_t clockNs = s->renderClockNs;
    os_unfair_lock_unlock(&s->ringLock);

    int live = 0;
    int64_t end = renderHead;
    if (hasFar && arrivalNs == 0 && clockIndex > 0) {
        // 自测没有采集时间，末尾就放在刚写出的播放头上。
        end = clockIndex;
        live = 1;
    } else if (hasFar && clockNs != 0 && arrivalNs != 0) {
        // 麦比最后一次播出还晚 200 ms 以上，说明喇叭停了。不要把人声对到旧的 TTS 上。
        int playbackIdle = arrivalNs > clockNs && (arrivalNs - clockNs) > 200000000ull;
        if (!playbackIdle) {
            int64_t deltaNs = (int64_t)clockNs - (int64_t)arrivalNs;
            int64_t deltaSamples = deltaNs * (int64_t)kAECRate / 1000000000LL;
            end = clockIndex - deltaSamples;
            live = 1;
        }
    }

    if (!live) {
        if (!s->captureStarted) {
            s->captureStarted = 1;
            s->captureEnd = 0;
        }
        if (!hasFar) {
            *outStart = s->captureEnd;
            s->captureEnd += count;
            return;
        }
        // 喇叭停了就贴着播放头放。顺着往前接的话，停播一两秒麦会超到播放前面，恢复时整段对空。
        if (s->captureEnd - renderHead > 800 || renderHead - s->captureEnd > 800) {
            LWAECResetNearHistory(s);
        }
        *outStart = renderHead;
        s->captureEnd = renderHead + count;
        return;
    }

    int64_t start = end - count;
    if (!s->captureStarted) {
        s->captureStarted = 1;
        LWAECResetNearHistory(s);
    } else {
        int64_t gap = start - s->captureEnd;
        if (gap > 800 || gap < -800) LWAECResetNearHistory(s);
    }
    s->captureEnd = end;
    *outStart = start;
}

static void LWAECProcess(LWAECState *s, const int16_t *input, int16_t *output, int count, uint64_t arrivalNs) {
    if (!s || count <= 0) return;
    os_unfair_lock_lock(&s->stateLock);
    int64_t start = 0;
    LWAECPlaceCapture(s, count, arrivalNs, &start);
    int offset = 0;
    while (offset < count) {
        int length = count - offset;
        if (length > kAECChunk) length = kAECChunk;
        int64_t from = start + offset - (int64_t)kAECCorr - kAECMaxDelay - kAECFilter - 8;
        int snapCount = kAECCorr + kAECMaxDelay + kAECFilter + length + 16;
        LWAECFillSnapshot(s, from, snapCount);
        for (int i = 0; i < length; i++) {
            LWAECAbsorb(s, input[offset + i], &output[offset + i], start + offset + i);
        }
        offset += length;
    }
    s->logSamples += count;
    os_unfair_lock_unlock(&s->stateLock);
}

@interface WRNEchoCanceller ()
- (NSData *)processCapturePCM:(NSData *)pcmData arrivalHostTimeNs:(uint64_t)arrivalHostTimeNs;
- (void)debugResetLinearEnergy;
- (void)debugCopyDelay:(int *)delaySamples
                locked:(int *)locked
             linearMic:(double *)linearMic
             linearErr:(double *)linearErr;
@end

enum { kWRNResFFT = 512, kWRNResWin = 320, kWRNResHop = 160, kWRNResBins = 257 };

typedef struct {
    float micHist[kWRNResWin];
    float farHist[kWRNResWin];
    float ola[kWRNResHop];
    float window[kWRNResWin];
    float erl[kWRNResBins];
} WRNResState;

static void WRNFft(float *re, float *im, int n, int sign) {
    for (int i = 1, j = 0; i < n; i++) {
        int bit = n >> 1;
        for (; j & bit; bit >>= 1) j ^= bit;
        j ^= bit;
        if (i < j) {
            float tr = re[i];
            re[i] = re[j];
            re[j] = tr;
            float ti = im[i];
            im[i] = im[j];
            im[j] = ti;
        }
    }
    for (int len = 2; len <= n; len <<= 1) {
        float ang = (float)sign * 2.f * 3.14159265f / (float)len;
        float wlenRe = cosf(ang);
        float wlenIm = sinf(ang);
        for (int i = 0; i < n; i += len) {
            float wRe = 1.f;
            float wIm = 0.f;
            for (int j = 0; j < len / 2; j++) {
                int u = i + j;
                int v = u + len / 2;
                float vr = re[v] * wRe - im[v] * wIm;
                float vi = re[v] * wIm + im[v] * wRe;
                re[v] = re[u] - vr;
                im[v] = im[u] - vi;
                re[u] += vr;
                im[u] += vi;
                float nextRe = wRe * wlenRe - wIm * wlenIm;
                wIm = wRe * wlenIm + wIm * wlenRe;
                wRe = nextRe;
            }
        }
    }
    if (sign > 0) {
        float inv = 1.f / (float)n;
        for (int i = 0; i < n; i++) {
            re[i] *= inv;
            im[i] *= inv;
        }
    }
}

static WRNResState *WRNResCreate(void) {
    WRNResState *r = (WRNResState *)calloc(1, sizeof(WRNResState));
    if (!r) return NULL;
    for (int i = 0; i < kWRNResWin; i++) {
        r->window[i] = 0.5f * (1.f - cosf(2.f * 3.14159265f * (float)i / (float)kWRNResWin));
    }
    for (int k = 0; k < kWRNResBins; k++) r->erl[k] = 0.056f;
    return r;
}

static void WRNResResetStream(WRNResState *r) {
    if (!r) return;
    memset(r->micHist, 0, sizeof(r->micHist));
    memset(r->farHist, 0, sizeof(r->farHist));
    memset(r->ola, 0, sizeof(r->ola));
}

static void WRNResResetAll(WRNResState *r) {
    if (!r) return;
    WRNResResetStream(r);
    for (int k = 0; k < kWRNResBins; k++) r->erl[k] = 0.056f;
}

static void WRNResApplyGain(float *re, float *im, const float *gain) {
    re[0] *= gain[0];
    im[0] *= gain[0];
    re[256] *= gain[256];
    im[256] *= gain[256];
    for (int k = 1; k < 256; k++) {
        re[k] *= gain[k];
        im[k] *= gain[k];
        re[kWRNResFFT - k] *= gain[k];
        im[kWRNResFFT - k] *= gain[k];
    }
}

static void WRNResProcessFrame(WRNResState *r, const float *mic, const float *far, float *out) {
    memmove(r->micHist, r->micHist + kWRNResHop, kWRNResHop * sizeof(float));
    memmove(r->farHist, r->farHist + kWRNResHop, kWRNResHop * sizeof(float));
    memcpy(r->micHist + kWRNResHop, mic, kWRNResHop * sizeof(float));
    memcpy(r->farHist + kWRNResHop, far, kWRNResHop * sizeof(float));

    float farPow = 0.f;
    for (int i = 0; i < kWRNResHop; i++) farPow += far[i] * far[i];
    farPow /= (float)kWRNResHop;
    int farActive = farPow > 10000.f;

    float micRe[kWRNResFFT];
    float micIm[kWRNResFFT];
    float farRe[kWRNResFFT];
    float farIm[kWRNResFFT];
    memset(micRe, 0, sizeof(micRe));
    memset(micIm, 0, sizeof(micIm));
    memset(farRe, 0, sizeof(farRe));
    memset(farIm, 0, sizeof(farIm));
    for (int i = 0; i < kWRNResWin; i++) {
        micRe[i] = r->micHist[i] * r->window[i];
        farRe[i] = r->farHist[i] * r->window[i];
    }
    WRNFft(micRe, micIm, kWRNResFFT, -1);
    WRNFft(farRe, farIm, kWRNResFFT, -1);

    float gain[kWRNResBins];
    for (int k = 0; k < kWRNResBins; k++) {
        float micMag = hypotf(micRe[k], micIm[k]);
        float farMag = hypotf(farRe[k], farIm[k]);
        float g = 1.f;
        if (farActive && farMag > 2500.f && micMag > 1.f) {
            float inst = micMag / farMag;
            // 传递比可以大于 1：眼镜麦里的回声经常比数字参考更响。
            // 比参考响出四倍以上的频点不当成回声，避免把插话学进去。
            if (inst <= 4.f) {
                r->erl[k] = 0.97f * r->erl[k] + 0.03f * inst;
                if (r->erl[k] > 4.f) r->erl[k] = 4.f;
                if (r->erl[k] < 0.015f) r->erl[k] = 0.015f;
            }
            float echo = r->erl[k] * farMag;
            float power = micMag * micMag - 2.f * echo * echo;
            if (power < 0.f) power = 0.f;
            g = sqrtf(power) / micMag;
            if (g < 0.05f) g = 0.05f;
        }
        gain[k] = g;
    }
    WRNResApplyGain(micRe, micIm, gain);
    WRNFft(micRe, micIm, kWRNResFFT, 1);
    for (int i = 0; i < kWRNResHop; i++) {
        out[i] = r->ola[i] + micRe[i];
        r->ola[i] = micRe[i + kWRNResHop];
    }
}

@implementation WRNEchoCanceller {
    LWAECState *_state;
    WRNResState *_res;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _state = LWAECStateCreate();
        _res = WRNResCreate();
    }
    return self;
}

- (void)dealloc {
    free(_res);
    if (_state) {
        free(_state);
    }
}

- (void)reset {
    if (!_state) return;
    os_unfair_lock_lock(&_state->stateLock);
    os_unfair_lock_lock(&_state->ringLock);
    LWAECClearRuntime(_state);
    os_unfair_lock_unlock(&_state->ringLock);
    os_unfair_lock_unlock(&_state->stateLock);
    WRNResResetAll(_res);
}

- (void)applyResidualSuppressionToSamples:(int16_t *)samples
                                reference:(const int16_t *)reference
                                    count:(int)count
                                  enabled:(BOOL)enabled {
    if (!_res || !samples || count <= 0) return;
    if (!enabled || !reference) {
        WRNResResetStream(_res);
        return;
    }
    float *mic = (float *)malloc((size_t)count * sizeof(float));
    float *far = (float *)malloc((size_t)count * sizeof(float));
    float *out = (float *)malloc((size_t)count * sizeof(float));
    if (!mic || !far || !out) {
        free(mic);
        free(far);
        free(out);
        return;
    }
    for (int i = 0; i < count; i++) {
        mic[i] = (float)samples[i];
        far[i] = (float)reference[i];
    }
    int offset = 0;
    while (offset + kWRNResHop <= count) {
        float frame[kWRNResHop];
        WRNResProcessFrame(_res, mic + offset, far + offset, frame);
        for (int i = 0; i < kWRNResHop; i++) {
            float sample = frame[i];
            if (sample > 32767.f) sample = 32767.f;
            if (sample < -32768.f) sample = -32768.f;
            out[offset + i] = sample;
        }
        offset += kWRNResHop;
    }
    for (int i = 0; i < offset; i++) samples[i] = (int16_t)lrintf(out[i]);
    free(mic);
    free(far);
    free(out);
}

- (void)writeReferenceBytes:(const void *)bytes length:(NSUInteger)length hostTimeNs:(uint64_t)hostTimeNs {
    if (!_state || bytes == NULL || length < sizeof(int16_t) || hostTimeNs == 0) return;
    int count = (int)(length / sizeof(int16_t));
    LWAECWriteReference(_state, (const int16_t *)bytes, count, hostTimeNs);
}

- (NSData *)processCapturePCM:(NSData *)pcmData {
    return [self processCapturePCM:pcmData arrivalHostTimeNs:LWAECNowNs()];
}

- (NSData *)processCapturePCM:(NSData *)pcmData arrivalHostTimeNs:(uint64_t)arrivalHostTimeNs {
    if (!_state || pcmData.length < sizeof(int16_t)) return pcmData ?: NSData.data;
    int count = (int)(pcmData.length / sizeof(int16_t));
    int16_t *output = (int16_t *)malloc((size_t)count * sizeof(int16_t));
    if (!output) return pcmData;
    LWAECProcess(_state, (const int16_t *)pcmData.bytes, output, count, arrivalHostTimeNs);
    os_unfair_lock_lock(&_state->stateLock);
    if (_state->logSamples >= kAECRate) _state->logSamples -= kAECRate;
    os_unfair_lock_unlock(&_state->stateLock);
    return [NSData dataWithBytesNoCopy:output length:(NSUInteger)count * sizeof(int16_t) freeWhenDone:YES];
}

- (void)debugResetLinearEnergy {
    if (!_state) return;
    os_unfair_lock_lock(&_state->stateLock);
    _state->linearMicEnergy = 0;
    _state->linearErrEnergy = 0;
    os_unfair_lock_unlock(&_state->stateLock);
}

- (void)debugCopyDelay:(int *)delaySamples
                locked:(int *)locked
             linearMic:(double *)linearMic
             linearErr:(double *)linearErr {
    if (!_state) return;
    os_unfair_lock_lock(&_state->stateLock);
    if (delaySamples) *delaySamples = _state->delaySamples;
    if (locked) *locked = _state->delayLocked;
    if (linearMic) *linearMic = _state->linearMicEnergy;
    if (linearErr) *linearErr = _state->linearErrEnergy;
    os_unfair_lock_unlock(&_state->stateLock);
}

- (void)setDelayAlignerOnly:(BOOL)alignerOnly {
    if (!_state) return;
    os_unfair_lock_lock(&_state->stateLock);
    _state->gateEnabled = alignerOnly ? 0 : 1;
    if (alignerOnly) {
        _state->outputGain = 1.f;
        _state->doubleTalk = 0;
    }
    os_unfair_lock_unlock(&_state->stateLock);
}

- (BOOL)fillAlignedReference:(int16_t *)reference
                       count:(int)count
                  forCapture:(const int16_t *)capture
           arrivalHostTimeNs:(uint64_t)arrivalHostTimeNs {
    if (!_state || !reference || !capture || count <= 0) return NO;
    if (arrivalHostTimeNs == 0) arrivalHostTimeNs = LWAECNowNs();
    int16_t *discard = (int16_t *)calloc((size_t)count, sizeof(int16_t));
    if (!discard) return NO;
    os_unfair_lock_lock(&_state->stateLock);
    int locked = _state->delayLocked;
    _state->alignedFar = reference;
    _state->alignedFarIndex = 0;
    os_unfair_lock_unlock(&_state->stateLock);
    LWAECProcess(_state, capture, discard, count, arrivalHostTimeNs);
    os_unfair_lock_lock(&_state->stateLock);
    _state->alignedFar = NULL;
    os_unfair_lock_unlock(&_state->stateLock);
    free(discard);
    return locked != 0;
}

- (int)lockedDelayMs {
    if (!_state) return -1;
    os_unfair_lock_lock(&_state->stateLock);
    int delayMs = _state->delayLocked ? (_state->delaySamples * 1000 / kAECRate) : -1;
    os_unfair_lock_unlock(&_state->stateLock);
    return delayMs;
}

- (NSString *)diagnostics {
    if (!_state) return @"delay=0ms locked=0 ncc=0.00 aec3=0 far=-120dB near=-120dB";
    os_unfair_lock_lock(&_state->stateLock);
    int delayMs = _state->delaySamples * 1000 / kAECRate;
    NSString *text;
    if (_state->gateEnabled) {
        text = [NSString stringWithFormat:
                @"delay=%dms locked=%d ncc=%.2f erle=%.1fdB dt=%d far=%.0fdB near=%.0fdB gain=%.2f",
                delayMs, _state->delayLocked, _state->lastNcc, _state->linearErleDb,
                _state->doubleTalk, _state->lastFarDb, _state->lastNearDb, _state->outputGain];
    } else {
        os_unfair_lock_lock(&_state->ringLock);
        int64_t renderEnd = _state->maxIndex;
        int hasFar = _state->hasFar;
        os_unfair_lock_unlock(&_state->ringLock);
        int skewMs = (hasFar && _state->captureEnd > 0)
                         ? (int)((_state->captureEnd - renderEnd) * 1000 / kAECRate)
                         : 0;
        int winMs = _state->nearHistCount * 1000 / kAECRate;
        text = [NSString stringWithFormat:
                @"delay=%dms locked=%d ncc=%.2f peak=%.2f win=%dms aec3=1 far=%.0fdB near=%.0fdB skew=%dms",
                delayMs, _state->delayLocked, _state->lastNcc, _state->lastSearchRaw, winMs,
                _state->lastFarDb, _state->lastNearDb, skewMs];
    }
    os_unfair_lock_unlock(&_state->stateLock);
    return text;
}

@end

#ifdef WRN_ECHO_SELFTEST

#include <stdio.h>

static uint64_t LWAECHostForSample(int64_t index) {
    return (uint64_t)index * 62500ull;
}

static float LWAECTestNoise(uint32_t *rng, float *lowpass) {
    *rng = (*rng) * 1664525u + 1013904223u;
    float white = ((float)(*rng >> 8) * (1.f / 16777216.f)) * 2.f - 1.f;
    *lowpass = 0.75f * (*lowpass) + 0.25f * white;
    return *lowpass;
}

static int LWAECSelfTest(void) {
    int failed = 0;
    for (int i = 0; i < 20000; i += 7) {
        if (LWAECHostToIndex(LWAECHostForSample(i)) != i) {
            printf("host time mapping failed at %d\n", i);
            return 1;
        }
    }

    const int64_t base = 16000;
    const int total = kAECRate * 36 / 10;
    const int acoustic = 80;
    const int ble = 5600;
    const int jumpAt = (int)(2.4f * kAECRate);
    const int jump = 320;
    const int sine0 = (int)(1.6f * kAECRate);
    const int sine1 = (int)(2.3f * kAECRate);
    const int erle0 = (int)(1.0f * kAECRate);
    const int erle1 = (int)(1.5f * kAECRate);
    const int sineMeasure0 = (int)(1.75f * kAECRate);
    const int sineMeasure1 = (int)(2.15f * kAECRate);

    int16_t *far = (int16_t *)calloc((size_t)total, sizeof(int16_t));
    int16_t *mic = (int16_t *)calloc((size_t)total, sizeof(int16_t));
    int16_t *out = (int16_t *)calloc((size_t)total, sizeof(int16_t));
    float *farF = (float *)calloc((size_t)total, sizeof(float));
    float *sine = (float *)calloc((size_t)total, sizeof(float));
    if (!far || !mic || !out || !farF || !sine) return 1;

    uint32_t rng = 1;
    float lowpass = 0;
    for (int i = 0; i < total; i++) {
        float sample = LWAECTestNoise(&rng, &lowpass) * 0.55f;
        farF[i] = sample;
        float scaled = sample * 32768.f;
        if (scaled > 32767.f) scaled = 32767.f;
        if (scaled < -32768.f) scaled = -32768.f;
        far[i] = (int16_t)rintf(scaled);
    }

    WRNEchoCanceller *processor = [WRNEchoCanceller new];
    [processor reset];
    const int packet = 320;

    for (int i = 0; i < total; i++) {
        // 参考按播出顺序排队后，延迟只存在于信号里。蓝牙那段不再靠把采集时间戳往后推。
        int delay = acoustic + ble + ((i >= jumpAt) ? jump : 0);
        float echo = 0.f;
        if (i - delay >= 0) echo += 0.32f * farF[i - delay];
        if (i - delay - 5 >= 0) echo += 0.10f * farF[i - delay - 5];
        if (i - delay - 17 >= 0) echo += 0.04f * farF[i - delay - 17];
        echo = tanhf(echo * 1.2f);
        float tone = 0.f;
        if (i >= sine0 && i < sine1) {
            tone = 0.22f * sinf((float)(2.0 * 3.141592653589793 * 440.0 * i / kAECRate));
            sine[i] = tone;
        }
        float noise = LWAECTestNoise(&rng, &lowpass) * 0.004f;
        float mixed = echo + tone + noise;
        float scaled = mixed * 32768.f;
        if (scaled > 32767.f) scaled = 32767.f;
        if (scaled < -32768.f) scaled = -32768.f;
        mic[i] = (int16_t)rintf(scaled);
    }

    int earlyDelay = 0;
    int earlyLocked = 0;
    double linearMic = 0;
    double linearErr = 0;
    int scored = 0;
    for (int offset = 0; offset < total; offset += packet) {
        int length = packet;
        if (offset + length > total) length = total - offset;
        uint64_t host = LWAECHostForSample(base + offset);
        [processor writeReferenceBytes:far + offset length:(NSUInteger)length * sizeof(int16_t) hostTimeNs:host];
        if (offset == erle0) [processor debugResetLinearEnergy];
        NSData *pcm = [NSData dataWithBytes:mic + offset length:(NSUInteger)length * sizeof(int16_t)];
        NSData *processed = [processor processCapturePCM:pcm arrivalHostTimeNs:0];
        memcpy(out + offset, processed.bytes, (size_t)length * sizeof(int16_t));
        if (!scored && offset + length >= erle1) {
            [processor debugCopyDelay:&earlyDelay locked:&earlyLocked linearMic:&linearMic linearErr:&linearErr];
            scored = 1;
        }
        if (offset % (kAECRate / 2) == 0) {
            printf("t=%.2f %s\n", (double)offset / kAECRate, processor.diagnostics.UTF8String);
        }
    }
    printf("t=end %s\n", processor.diagnostics.UTF8String);

    double micEnergy = 0;
    double outEnergy = 0;
    for (int i = erle0; i < erle1; i++) {
        double m = (double)mic[i] / 32768.0;
        double o = (double)out[i] / 32768.0;
        micEnergy += m * m;
        outEnergy += o * o;
    }
    double outputErle = 10.0 * log10((micEnergy + 1e-12) / (outEnergy + 1e-12));
    double linearErle = 10.0 * log10((linearMic + 1e-12) / (linearErr + 1e-12));

    double sineDot = 0;
    double sineEnergy = 0;
    for (int i = sineMeasure0; i < sineMeasure1; i++) {
        double sample = (double)out[i] / 32768.0;
        sineDot += sample * (double)sine[i];
        sineEnergy += (double)sine[i] * (double)sine[i];
    }
    double sineGain = sineDot / (sineEnergy + 1e-12);

    int delaySamples = 0;
    int locked = 0;
    [processor debugCopyDelay:&delaySamples locked:&locked linearMic:NULL linearErr:NULL];
    int expectedEarly = acoustic + ble;
    int expectedDelay = expectedEarly + jump;
    int earlyError = earlyDelay - expectedEarly;
    int delayError = delaySamples - expectedDelay;
    if (earlyError < 0) earlyError = -earlyError;
    if (delayError < 0) delayError = -delayError;

    printf("outputERLE=%.1f dB linearERLE=%.1f dB sineGain=%.3f\n", outputErle, linearErle, sineGain);
    printf("earlyDelay=%d expected=%d err=%d locked=%d\n", earlyDelay, expectedEarly, earlyDelay - expectedEarly, earlyLocked);
    printf("finalDelay=%d expected=%d err=%d locked=%d\n", delaySamples, expectedDelay, delaySamples - expectedDelay, locked);

    if (!earlyLocked || earlyError > 24 || !locked || delayError > 24) {
        printf("FAIL delay lock\n");
        failed = 1;
    }
    if (outputErle < 18.0) {
        printf("FAIL output ERLE\n");
        failed = 1;
    }
    if (linearMic < 0.2 || linearErle < 12.0) {
        printf("FAIL gated ERLE\n");
        failed = 1;
    }
    if (sineGain < 0.45) {
        printf("FAIL near-end retention\n");
        failed = 1;
    }
    free(far);
    free(mic);
    free(out);
    free(farF);
    free(sine);
    return failed;
}

/// 31 ms 在搜索范围下面。这段不能被锁成延迟，否则后面的真回声会整段漏出去。
static int LWAECRejectShortDelay(void) {
    const int64_t base = 16000;
    const int total = kAECRate;
    const int shortDelay = 496;
    int16_t *far = (int16_t *)calloc((size_t)total, sizeof(int16_t));
    int16_t *mic = (int16_t *)calloc((size_t)total, sizeof(int16_t));
    float *farF = (float *)calloc((size_t)total, sizeof(float));
    if (!far || !mic || !farF) return 1;
    uint32_t rng = 7;
    float lowpass = 0;
    for (int i = 0; i < total; i++) {
        float sample = LWAECTestNoise(&rng, &lowpass) * 0.55f;
        farF[i] = sample;
        far[i] = (int16_t)rintf(fmaxf(-32768.f, fminf(32767.f, sample * 32768.f)));
    }
    for (int i = 0; i < total; i++) {
        float echo = (i >= shortDelay) ? 0.40f * farF[i - shortDelay] : 0.f;
        mic[i] = (int16_t)rintf(fmaxf(-32768.f, fminf(32767.f, echo * 32768.f)));
    }
    WRNEchoCanceller *processor = [WRNEchoCanceller new];
    const int packet = 320;
    for (int offset = 0; offset < total; offset += packet) {
        int length = packet;
        if (offset + length > total) length = total - offset;
        [processor writeReferenceBytes:far + offset
                                 length:(NSUInteger)length * sizeof(int16_t)
                             hostTimeNs:LWAECHostForSample(base + offset)];
        NSData *pcm = [NSData dataWithBytes:mic + offset length:(NSUInteger)length * sizeof(int16_t)];
        [processor processCapturePCM:pcm arrivalHostTimeNs:0];
    }
    int delaySamples = 0;
    int locked = 0;
    [processor debugCopyDelay:&delaySamples locked:&locked linearMic:NULL linearErr:NULL];
    printf("shortDelay locked=%d delay=%d\n", locked, delaySamples);
    free(far);
    free(mic);
    free(farF);
    if (locked && delaySamples < kAECMinDelay) {
        printf("FAIL short delay lock\n");
        return 1;
    }
    if (locked && delaySamples < 4000) {
        printf("FAIL locked onto a short false peak\n");
        return 1;
    }
    return 0;
}

/// 播放回调把同一个 mHostTime 重复送进来时，参考仍要按样本往后接，延迟还能锁上。
static int LWAECStuckHostTimeStillLocks(void) {
    const int total = kAECRate * 2;
    const int delay = 5600;
    const int packet = 960;
    int16_t *far = (int16_t *)calloc((size_t)total, sizeof(int16_t));
    int16_t *mic = (int16_t *)calloc((size_t)total, sizeof(int16_t));
    float *farF = (float *)calloc((size_t)total, sizeof(float));
    if (!far || !mic || !farF) return 1;
    uint32_t rng = 3;
    float lowpass = 0;
    for (int i = 0; i < total; i++) {
        float sample = LWAECTestNoise(&rng, &lowpass) * 0.55f;
        farF[i] = sample;
        far[i] = (int16_t)rintf(fmaxf(-32768.f, fminf(32767.f, sample * 32768.f)));
    }
    for (int i = 0; i < total; i++) {
        float echo = (i >= delay) ? 0.35f * farF[i - delay] : 0.f;
        mic[i] = (int16_t)rintf(fmaxf(-32768.f, fminf(32767.f, echo * 32768.f)));
    }
    WRNEchoCanceller *processor = [WRNEchoCanceller new];
    uint64_t stuck = LWAECHostForSample(16000);
    for (int offset = 0; offset < total; offset += packet) {
        int length = packet;
        if (offset + length > total) length = total - offset;
        [processor writeReferenceBytes:far + offset length:(NSUInteger)length * sizeof(int16_t) hostTimeNs:stuck];
        NSData *pcm = [NSData dataWithBytes:mic + offset length:(NSUInteger)length * sizeof(int16_t)];
        [processor processCapturePCM:pcm arrivalHostTimeNs:0];
    }
    int delaySamples = 0;
    int locked = 0;
    [processor debugCopyDelay:&delaySamples locked:&locked linearMic:NULL linearErr:NULL];
    int error = delaySamples - delay;
    if (error < 0) error = -error;
    printf("stuckHost locked=%d delay=%d err=%d\n", locked, delaySamples, delaySamples - delay);
    free(far);
    free(mic);
    free(farF);
    if (!locked || error > 24) {
        printf("FAIL stuck host time\n");
        return 1;
    }
    return 0;
}

static int LWAECResidualSuppressesEcho(void) {
    const int total = kAECRate;
    const int hop = 160;
    int16_t *far = (int16_t *)calloc((size_t)total, sizeof(int16_t));
    int16_t *mic = (int16_t *)calloc((size_t)total, sizeof(int16_t));
    int16_t *out = (int16_t *)calloc((size_t)total, sizeof(int16_t));
    float *clean = (float *)calloc((size_t)total, sizeof(float));
    if (!far || !mic || !out || !clean) return 1;
    uint32_t rng = 11;
    float lowpass = 0;
    for (int i = 0; i < total; i++) {
        float sample = LWAECTestNoise(&rng, &lowpass) * 0.45f;
        far[i] = (int16_t)rintf(fmaxf(-32768.f, fminf(32767.f, sample * 32768.f)));
        float echo = 0.06f * (float)far[i];
        float tone = 0.f;
        if (i >= total / 2) {
            tone = 0.28f * 32767.f * sinf(2.f * 3.14159265f * 440.f * (float)i / (float)kAECRate);
            clean[i] = tone;
        }
        mic[i] = (int16_t)rintf(fmaxf(-32768.f, fminf(32767.f, echo + tone)));
    }
    memcpy(out, mic, (size_t)total * sizeof(int16_t));
    WRNEchoCanceller *processor = [WRNEchoCanceller new];
    [processor applyResidualSuppressionToSamples:out reference:far count:total enabled:YES];

    double micE = 0;
    double outE = 0;
    for (int i = hop * 4; i < total / 2; i++) {
        micE += (double)mic[i] * (double)mic[i];
        outE += (double)out[i] * (double)out[i];
    }
    double erle = 10.0 * log10((micE + 1e-12) / (outE + 1e-12));
    double sineDot = 0;
    double sineE = 0;
    // 重叠相加固定晚一帧。插话保留按这一帧对齐来量。
    for (int i = total / 2 + hop * 4; i < total; i++) {
        sineDot += ((double)out[i]) * (double)clean[i - hop];
        sineE += (double)clean[i - hop] * (double)clean[i - hop];
    }
    double sineGain = sineDot / (sineE + 1e-12);
    printf("residualERLE=%.1f dB sineGain=%.3f\n", erle, sineGain);
    free(far);
    free(mic);
    free(out);
    free(clean);
    if (erle < 12.0 || sineGain < 0.45) {
        printf("FAIL residual suppressor\n");
        return 1;
    }
    return 0;
}

int main(void) {
    @autoreleasepool {
        int failed = LWAECSelfTest();
        failed |= LWAECRejectShortDelay();
        failed |= LWAECStuckHostTimeStillLocks();
        failed |= LWAECResidualSuppressesEcho();
        printf("%s\n", failed ? "FAIL" : "PASS");
        return failed;
    }
}

#endif

#include "WebRTCAPM.h"

#include <memory>
#include <optional>
#include <vector>

#include "api/audio/audio_processing.h"
#include "api/audio/echo_canceller3_config.h"
#include "api/environment/environment_factory.h"
#include "api/make_ref_counted.h"
#include "modules/audio_processing/audio_processing_impl.h"
#include "modules/audio_processing/include/audio_processing.h"
#include "modules/audio_processing/vad/voice_activity_detector.h"

namespace {

using webrtc::AudioProcessing;
using webrtc::CreateEnvironment;
using webrtc::EchoCanceller3Config;
using webrtc::scoped_refptr;
using webrtc::StreamConfig;
using webrtc::VoiceActivityDetector;

AudioProcessing::Config::NoiseSuppression::Level ToWebRTCLevel(
    WebRTCAPMNoiseSuppressionLevel level) {
  switch (level) {
    case WebRTCAPMNoiseSuppressionLevelLow:
      return AudioProcessing::Config::NoiseSuppression::Level::kLow;
    case WebRTCAPMNoiseSuppressionLevelModerate:
      return AudioProcessing::Config::NoiseSuppression::Level::kModerate;
    case WebRTCAPMNoiseSuppressionLevelHigh:
      return AudioProcessing::Config::NoiseSuppression::Level::kHigh;
    case WebRTCAPMNoiseSuppressionLevelVeryHigh:
      return AudioProcessing::Config::NoiseSuppression::Level::kVeryHigh;
  }
  return AudioProcessing::Config::NoiseSuppression::Level::kHigh;
}

AudioProcessing::Config ToWebRTCConfig(const WebRTCAPMConfig& config) {
  AudioProcessing::Config webrtc_config;
  webrtc_config.high_pass_filter.enabled = config.enable_high_pass_filter != 0;

  webrtc_config.echo_canceller.enabled = config.enable_echo_canceller != 0;
  if (config.echo_enforce_high_pass_filtering >= 0) {
    webrtc_config.echo_canceller.enforce_high_pass_filtering =
        config.echo_enforce_high_pass_filtering != 0;
  }
  if (config.echo_export_linear_aec_output >= 0) {
    webrtc_config.echo_canceller.export_linear_aec_output =
        config.echo_export_linear_aec_output != 0;
  }

  webrtc_config.noise_suppression.enabled =
      config.enable_noise_suppression != 0;
  webrtc_config.noise_suppression.level =
      ToWebRTCLevel(config.noise_suppression_level);

  webrtc_config.gain_controller1.enabled =
      config.enable_gain_controller != 0;
  webrtc_config.gain_controller1.mode =
      AudioProcessing::Config::GainController1::Mode::kAdaptiveDigital;
  webrtc_config.gain_controller1.target_level_dbfs =
      config.gain_target_level_dbfs;
  webrtc_config.gain_controller1.compression_gain_db =
      config.gain_compression_db;
  webrtc_config.gain_controller1.enable_limiter =
      config.gain_enable_limiter != 0;

  return webrtc_config;
}

EchoCanceller3Config BuildEchoCanceller3Config(
    const WebRTCAPMEchoCanceller3Tuning& tuning) {
  EchoCanceller3Config aec3;
  if (tuning.apply_mask & WEBRTC_APM_AEC3_TUNING_DELAY_DEFAULT_DELAY) {
    aec3.delay.default_delay =
        static_cast<size_t>(tuning.delay_default_delay);
  }
  if (tuning.apply_mask &
      WEBRTC_APM_AEC3_TUNING_DELAY_FIXED_CAPTURE_DELAY_SAMPLES) {
    aec3.delay.fixed_capture_delay_samples =
        static_cast<size_t>(tuning.delay_fixed_capture_delay_samples);
  }
  if (tuning.apply_mask &
      WEBRTC_APM_AEC3_TUNING_DELAY_USE_EXTERNAL_DELAY_ESTIMATOR) {
    aec3.delay.use_external_delay_estimator =
        tuning.delay_use_external_delay_estimator != 0;
  }
  if (tuning.apply_mask & WEBRTC_APM_AEC3_TUNING_DELAY_ESTIMATE_SMOOTHING) {
    aec3.delay.delay_estimate_smoothing = tuning.delay_estimate_smoothing;
  }
  if (tuning.apply_mask &
      WEBRTC_APM_AEC3_TUNING_DELAY_ESTIMATE_SMOOTHING_DELAY_FOUND) {
    aec3.delay.delay_estimate_smoothing_delay_found =
        tuning.delay_estimate_smoothing_delay_found;
  }
  if (tuning.apply_mask &
      WEBRTC_APM_AEC3_TUNING_FILTER_COARSE_INITIAL_LENGTH_BLOCKS) {
    aec3.filter.coarse_initial.length_blocks =
        static_cast<size_t>(tuning.filter_coarse_initial_length_blocks);
  }
  EchoCanceller3Config::Validate(&aec3);
  return aec3;
}

scoped_refptr<AudioProcessing> CreateAudioProcessingInstance(
    const WebRTCAPMConfig& config,
    const std::optional<EchoCanceller3Config>& aec3_config) {
  const AudioProcessing::Config webrtc_config = ToWebRTCConfig(config);
  return webrtc::make_ref_counted<webrtc::AudioProcessingImpl>(
      CreateEnvironment(), webrtc_config, aec3_config, std::nullopt, nullptr,
      nullptr, nullptr, webrtc::scoped_refptr<webrtc::EchoDetector>(), nullptr,
      nullptr);
}

}  // namespace

struct WebRTCAPM {
  WebRTCAPMConfig config;
  scoped_refptr<AudioProcessing> apm;
  std::vector<int16_t> render_buffer;
  std::unique_ptr<VoiceActivityDetector> vad;
  float last_capture_vad_probability = 0.0f;
  int stream_delay_ms = -1;
  bool use_custom_aec3_config = false;
  WebRTCAPMEchoCanceller3Tuning aec3_tuning = {};
  std::optional<EchoCanceller3Config> aec3_config;
};

namespace {

void FillCaptureVAD(const WebRTCAPM* apm, WebRTCAPMCaptureVAD* out_vad) {
  if (!out_vad) {
    return;
  }
  out_vad->speech_probability = 0.f;
  out_vad->voice_detected = 0;
  if (!apm) {
    return;
  }
  out_vad->speech_probability = apm->last_capture_vad_probability;
  out_vad->voice_detected = apm->last_capture_vad_probability >= 0.5f ? 1 : 0;
}

void ApplyStreamDelayIfNeeded(WebRTCAPM* apm) {
  if (!apm || !apm->apm || apm->stream_delay_ms < 0) {
    return;
  }
  apm->apm->set_stream_delay_ms(apm->stream_delay_ms);
}

void RebuildAec3ConfigLocked(WebRTCAPM* apm) {
  if (!apm) {
    return;
  }
  if (!apm->use_custom_aec3_config || apm->aec3_tuning.apply_mask == 0) {
    apm->aec3_config.reset();
    return;
  }
  apm->aec3_config = BuildEchoCanceller3Config(apm->aec3_tuning);
}

}  // namespace

WebRTCAPMConfig WebRTCAPMDefaultConfig(void) {
  WebRTCAPMConfig config = {};
  config.sample_rate_hz = 48000;
  config.channels = 1;
  config.enable_high_pass_filter = 1;
  config.enable_echo_canceller = 1;
  config.enable_noise_suppression = 1;
  config.noise_suppression_level = WebRTCAPMNoiseSuppressionLevelHigh;
  config.enable_gain_controller = 1;
  config.gain_target_level_dbfs = 3;
  config.gain_compression_db = 9;
  config.gain_enable_limiter = 1;
  config.enable_voice_detection = 0;
  config.stream_delay_ms = -1;
  config.echo_enforce_high_pass_filtering = -1;
  config.echo_export_linear_aec_output = -1;
  return config;
}

WebRTCAPMEchoCanceller3Tuning WebRTCAPMEchoCanceller3TuningDefault(void) {
  WebRTCAPMEchoCanceller3Tuning tuning = {};
  tuning.apply_mask = 0;
  tuning.delay_default_delay = 5;
  tuning.delay_fixed_capture_delay_samples = 0;
  tuning.delay_use_external_delay_estimator = 0;
  tuning.delay_estimate_smoothing = 0.7f;
  tuning.delay_estimate_smoothing_delay_found = 0.7f;
  tuning.filter_coarse_initial_length_blocks = 12;
  return tuning;
}

WebRTCAPM *WebRTCAPMCreate(const WebRTCAPMConfig *config) {
  if (!config || config->sample_rate_hz <= 0 || config->channels <= 0) {
    return nullptr;
  }

  std::unique_ptr<WebRTCAPM> wrapper(new WebRTCAPM());
  wrapper->config = *config;
  wrapper->stream_delay_ms = config->stream_delay_ms;

  if (WebRTCAPMReset(wrapper.get()) != 0) {
    return nullptr;
  }

  return wrapper.release();
}

void WebRTCAPMDestroy(WebRTCAPM *apm) {
  delete apm;
}

int WebRTCAPMReset(WebRTCAPM *apm) {
  if (!apm) {
    return -1;
  }

  RebuildAec3ConfigLocked(apm);
  apm->apm = CreateAudioProcessingInstance(
      apm->config, apm->aec3_config);

  if (!apm->apm) {
    return -2;
  }

  apm->render_buffer.clear();
  apm->last_capture_vad_probability = 0.0f;
  if (apm->config.enable_voice_detection) {
    apm->vad = std::make_unique<VoiceActivityDetector>();
  } else {
    apm->vad.reset();
  }
  return 0;
}

int WebRTCAPMSetStreamDelayMs(WebRTCAPM *apm, int delay_ms) {
  if (!apm) {
    return -1;
  }
  apm->stream_delay_ms = delay_ms;
  apm->config.stream_delay_ms = delay_ms;
  return 0;
}

int WebRTCAPMGetStreamDelayMs(const WebRTCAPM *apm) {
  if (!apm) {
    return -1;
  }
  return apm->stream_delay_ms;
}

int WebRTCAPMSetEchoCanceller3Tuning(WebRTCAPM *apm,
                                     const WebRTCAPMEchoCanceller3Tuning *tuning) {
  if (!apm) {
    return -1;
  }
  if (!tuning || tuning->apply_mask == 0) {
    apm->use_custom_aec3_config = false;
    apm->aec3_tuning = WebRTCAPMEchoCanceller3TuningDefault();
    apm->aec3_config.reset();
    return WebRTCAPMReset(apm);
  }

  apm->use_custom_aec3_config = true;
  apm->aec3_tuning = *tuning;
  return WebRTCAPMReset(apm);
}

int WebRTCAPMGetEchoCanceller3Tuning(const WebRTCAPM *apm,
                                      WebRTCAPMEchoCanceller3Tuning *out_tuning) {
  if (!apm || !out_tuning) {
    return -1;
  }
  *out_tuning = apm->aec3_tuning;
  if (!apm->use_custom_aec3_config) {
    out_tuning->apply_mask = 0;
  }
  return 0;
}

int WebRTCAPMProcessCapture(WebRTCAPM *apm, int16_t *pcm, int frame_count) {
  return WebRTCAPMProcessCaptureWithVAD(apm, pcm, frame_count, nullptr);
}

int WebRTCAPMProcessCaptureWithVAD(WebRTCAPM *apm,
                                   int16_t *pcm,
                                   int frame_count,
                                   WebRTCAPMCaptureVAD *out_vad) {
  if (!apm || !apm->apm || !pcm) {
    return -1;
  }
  if (frame_count != WebRTCAPMExpectedFrameCount(apm)) {
    return -2;
  }

  if (apm->vad) {
    apm->vad->ProcessChunk(pcm, static_cast<size_t>(frame_count),
                           apm->config.sample_rate_hz);
    apm->last_capture_vad_probability = apm->vad->last_voice_probability();
  } else {
    apm->last_capture_vad_probability = 0.0f;
  }

  ApplyStreamDelayIfNeeded(apm);

  StreamConfig config(apm->config.sample_rate_hz, apm->config.channels);
  const int result = apm->apm->ProcessStream(pcm, config, config, pcm);
  FillCaptureVAD(apm, out_vad);
  return result;
}

int WebRTCAPMProcessRender(WebRTCAPM *apm, const int16_t *pcm, int frame_count) {
  if (!apm || !apm->apm || !pcm) {
    return -1;
  }
  if (frame_count != WebRTCAPMExpectedFrameCount(apm)) {
    return -2;
  }

  apm->render_buffer.assign(pcm, pcm + frame_count);
  StreamConfig config(apm->config.sample_rate_hz, apm->config.channels);
  return apm->apm->ProcessReverseStream(apm->render_buffer.data(),
                                        config,
                                        config,
                                        apm->render_buffer.data());
}

float WebRTCAPMLastCaptureVADProbability(const WebRTCAPM *apm) {
  if (!apm) {
    return 0.0f;
  }
  return apm->last_capture_vad_probability;
}

int WebRTCAPMExpectedFrameCount(const WebRTCAPM *apm) {
  if (!apm || apm->config.sample_rate_hz <= 0 || apm->config.channels <= 0) {
    return 0;
  }
  return (apm->config.sample_rate_hz / 100) * apm->config.channels;
}

int WebRTCAPMSupportsCaptureVAD(void) {
  return 1;
}

const char *WebRTCAPMVersion(void) {
  return "webrtc-apm-wrapper/4";
}

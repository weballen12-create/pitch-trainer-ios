// Engine + audio I/O for the iPhone test app. Objective-C++ because miniaudio's iOS backend needs it.
#include "pt_engine.h"

#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

#include <atomic>
#include <chrono>
#include <vector>

#include "analysis_window.h"
#include "audio_config.h"
#include "gain_step.h"
#include "half_rate_decimator.h"
#include "mpm_pitch_detector.h"
#include "note_utils.h"
#include "reference_tone.h"
#include "sine_generator.h"
#include "target_note.h"

#define MINIAUDIO_IMPLEMENTATION
#include "miniaudio.h"

namespace {

using Clock = std::chrono::steady_clock;
constexpr uint32_t kChunk = kMicChunkFrames;  // 480 frames = 10 ms at 48 kHz, like the board
constexpr float kRate = static_cast<float>(kMicSampleRateHz);

// Headphones are far more sensitive than the board's speaker or exciter: start very quiet, cap low.
constexpr float kStartGain = 0.00316f;  // -50 dBFS
constexpr float kMaxGain = 0.0631f;     // -24 dBFS (was -36; raised because it was too quiet)
constexpr uint32_t kReleaseStepMs = 15;
constexpr uint32_t kReleaseStart = 120;  // ms; the board's 15 ms makes the tone blip

// Chromatic order from A, like the page's key buttons.
constexpr int kKeyOrder[12] = {9, 10, 11, 0, 1, 2, 3, 4, 5, 6, 7, 8};

struct Shared {
  std::atomic<bool> muted{true};
  std::atomic<float> gain{kStartGain};
  std::atomic<int> key_slot{3};  // C
  std::atomic<bool> chromatic{false};
  std::atomic<bool> tonic{false};
  std::atomic<uint32_t> release_ms{kReleaseStart};
  std::atomic<float> hz{0}, rms{0}, cents{0};
  std::atomic<bool> valid{false};
  std::atomic<int> target{-1};
  std::atomic<uint32_t> det_last_us{0}, det_max_us{0}, chunk_max_us{0};
  std::atomic<uint64_t> det_total_us{0}, det_count{0}, over_budget{0};
};

class Engine {
 public:
  bool begin() {
    if (!decimator_.begin(kDecimatorTaps, kDecimatorCutoffHz, kRate)) return false;
    window_.begin(kAnalysisWindowFrames);
    if (!detector_.begin(kAnalysisWindowFrames)) return false;
    detector_.setClarityThreshold(kMpmK);
    detector_.setMinVolumeRms(kMinVolumeRms);
    tracker_.begin({kTargetHysteresisCents, kReleaseStart, kTargetSwitchHoldMs, kTargetOctaveDownHoldMs,
                    kTargetHoldMaxJumpSemitones},
                   majorKey(kKeyOrder[3]));
    analysis_.assign(kAnalysisWindowFrames, 0.0f);
    decimated_.assign(kChunk / 2, 0.0f);
    pending_.reserve(kChunk * 4);
    sine_.begin(kRate, kToneFadeMs);
    sine_.setGain(kStartGain);
    return true;
  }

  void process(const float* in, float* out, size_t n, Shared& sh) {
    if (in != nullptr) pending_.insert(pending_.end(), in, in + n);
    size_t used = 0;
    while (pending_.size() - used >= kChunk) {
      const auto t0 = Clock::now();
      chunk(pending_.data() + used, sh);
      const uint32_t us =
          static_cast<uint32_t>(std::chrono::duration_cast<std::chrono::microseconds>(Clock::now() - t0).count());
      if (us > sh.chunk_max_us.load()) sh.chunk_max_us.store(us);
      if (us > 10000) sh.over_budget.fetch_add(1);
      used += kChunk;
    }
    pending_.erase(pending_.begin(), pending_.begin() + used);

    const MusicalKey& key = tracker_.key();
    float hz = 0.0f;
    if (sh.tonic.load()) {
      hz = midiToFrequency(static_cast<float>(60 + key.tonic_pitch_class));
    } else if (!sh.muted.load() && tracker_.hasTarget()) {
      hz = referenceToneHz(midiToFrequency(static_cast<float>(tracker_.targetMidi())), ReferenceMode::Shift, 0.0f, 0);
    }
    sine_.setGain(sh.gain.load());
    sine_.setFrequency(hz);
    sine_.setOn(hz > 0.0f);
    pcm_.resize(n);
    sine_.render(pcm_.data(), n);
    for (size_t i = 0; i < n; ++i) out[i] = pcm_[i] / 32768.0f;
  }

 private:
  void chunk(const float* x, Shared& sh) {
    tracker_.setChromatic(sh.chromatic.load());
    tracker_.setReleaseMs(sh.release_ms.load());
    const int slot = sh.key_slot.load();
    if (slot != slot_) {
      slot_ = slot;
      tracker_.setKey(majorKey(kKeyOrder[slot]));
    }
    const size_t m = decimator_.process(x, kChunk, decimated_.data());
    window_.push(decimated_.data(), m);
    now_ms_ += 10;
    if (!window_.isFull()) return;

    const auto t0 = Clock::now();
    window_.copyDcRemoved(analysis_.data());
    const PitchResult r = detector_.findPitch(analysis_.data(), kRate / 2.0f);
    const uint32_t us =
        static_cast<uint32_t>(std::chrono::duration_cast<std::chrono::microseconds>(Clock::now() - t0).count());

    float sq = 0.0f;
    for (float v : analysis_) sq += v * v;
    const bool valid = isValidPitch(r, kMinValidClarity, kMinValidPitchHz, kMaxValidPitchHz);
    const float exact = valid ? frequencyToMidi(r.frequency_hz) : 0.0f;
    tracker_.update(valid, exact, now_ms_);

    sh.det_last_us.store(us);
    if (us > sh.det_max_us.load()) sh.det_max_us.store(us);
    sh.det_total_us.fetch_add(us);
    sh.det_count.fetch_add(1);
    sh.hz.store(r.frequency_hz);
    sh.rms.store(sqrtf(sq / static_cast<float>(analysis_.size())));
    sh.valid.store(valid);
    sh.target.store(tracker_.hasTarget() ? tracker_.targetMidi() : -1);
    sh.cents.store(valid && tracker_.hasTarget() ? (exact - static_cast<float>(tracker_.targetMidi())) * 100.0f : 0.0f);
  }

  HalfRateDecimator decimator_;
  AnalysisWindow window_;
  MpmPitchDetector detector_;
  TargetNoteTracker tracker_;
  SineGenerator sine_;
  std::vector<float> analysis_, decimated_, pending_;
  std::vector<int16_t> pcm_;
  uint32_t now_ms_ = 0;
  int slot_ = 3;
};

Engine g_engine;
Shared g_shared;
ma_context g_ctx;
ma_device g_dev;
bool g_running = false;
float g_in_ms = 0, g_out_ms = 0;
char g_err[160] = "";
char g_dev_in[64] = "", g_dev_out[64] = "";

void dataCallback(ma_device*, void* output, const void* input, ma_uint32 frames) {
  g_engine.process(static_cast<const float*>(input), static_cast<float*>(output), frames, g_shared);
}

}  // namespace

extern "C" {

int pt_start(void) {
  if (g_running) return 0;
  g_err[0] = 0;
  if (!g_engine.begin()) {
    snprintf(g_err, sizeof(g_err), "engine setup failed");
    return 1;
  }
  ma_context_config cc = ma_context_config_init();
  cc.coreaudio.sessionCategory = ma_ios_session_category_play_and_record;
  if (ma_context_init(nullptr, 0, &cc, &g_ctx) != MA_SUCCESS) {
    snprintf(g_err, sizeof(g_err), "could not start the audio system");
    return 2;
  }
  ma_device_config cfg = ma_device_config_init(ma_device_type_duplex);
  cfg.sampleRate = kMicSampleRateHz;
  cfg.periodSizeInFrames = kChunk;
  cfg.performanceProfile = ma_performance_profile_low_latency;
  cfg.dataCallback = dataCallback;
  cfg.capture.format = ma_format_f32;
  cfg.capture.channels = 1;
  cfg.playback.format = ma_format_f32;
  cfg.playback.channels = 1;
  if (ma_device_init(&g_ctx, &cfg, &g_dev) != MA_SUCCESS) {
    snprintf(g_err, sizeof(g_err), "could not open the microphone / headphones (allow the microphone?)");
    ma_context_uninit(&g_ctx);
    return 3;
  }
  snprintf(g_dev_in, sizeof(g_dev_in), "%s", g_dev.capture.name);
  snprintf(g_dev_out, sizeof(g_dev_out), "%s", g_dev.playback.name);
  g_in_ms = 1000.0f * g_dev.capture.internalPeriodSizeInFrames * g_dev.capture.internalPeriods / g_dev.capture.internalSampleRate;
  g_out_ms = 1000.0f * g_dev.playback.internalPeriodSizeInFrames * g_dev.playback.internalPeriods / g_dev.playback.internalSampleRate;
  if (ma_device_start(&g_dev) != MA_SUCCESS) {
    snprintf(g_err, sizeof(g_err), "could not start audio");
    ma_device_uninit(&g_dev);
    ma_context_uninit(&g_ctx);
    return 4;
  }
  g_running = true;
  return 0;
}

void pt_stop(void) {
  if (!g_running) return;
  ma_device_uninit(&g_dev);
  ma_context_uninit(&g_ctx);
  g_running = false;
}

const char* pt_error(void) { return g_err; }
void pt_set_muted(int muted) { g_shared.muted.store(muted != 0); }
void pt_gain_step(int up) { g_shared.gain.store(stepGain(g_shared.gain.load(), up != 0, kMaxGain)); }
void pt_set_key_slot(int slot) { g_shared.key_slot.store(((slot % 12) + 12) % 12); }
void pt_set_chromatic(int on) { g_shared.chromatic.store(on != 0); }
void pt_set_tonic(int on) { g_shared.tonic.store(on != 0); }
void pt_release_step(int up) {
  uint32_t r = g_shared.release_ms.load();
  r = up ? r + kReleaseStepMs : (r > kReleaseStepMs ? r - kReleaseStepMs : kReleaseStepMs);
  if (r < kReleaseStepMs) r = kReleaseStepMs;
  if (r > 600) r = 600;
  g_shared.release_ms.store(r);
}

void pt_get_status(PtStatus* o) {
  memset(o, 0, sizeof(*o));
  o->hz = g_shared.hz.load();
  o->cents = g_shared.cents.load();
  o->rms = g_shared.rms.load();
  o->gain_db = 20.0f * log10f(g_shared.gain.load());
  o->valid = g_shared.valid.load();
  o->target = g_shared.target.load();
  o->muted = g_shared.muted.load();
  o->chromatic = g_shared.chromatic.load();
  o->tonic = g_shared.tonic.load();
  o->key_slot = g_shared.key_slot.load();
  o->release_ms = g_shared.release_ms.load();
  o->det_last_us = g_shared.det_last_us.load();
  const uint64_t n = g_shared.det_count.load();
  o->det_avg_us = n ? static_cast<unsigned>(g_shared.det_total_us.load() / n) : 0;
  o->det_max_us = g_shared.det_max_us.load();
  o->chunk_max_us = g_shared.chunk_max_us.load();
  o->over_budget = g_shared.over_budget.load();
  o->chunks = n;
  o->in_buf_ms = g_in_ms;
  o->out_buf_ms = g_out_ms;
  if (o->target >= 0) midiToNoteName(o->target, o->target_name, sizeof(o->target_name));
  else snprintf(o->target_name, sizeof(o->target_name), "-");
  snprintf(o->key_name, sizeof(o->key_name), "%s", majorKey(kKeyOrder[o->key_slot]).name);
  snprintf(o->device_in, sizeof(o->device_in), "%s", g_dev_in);
  snprintf(o->device_out, sizeof(o->device_out), "%s", g_dev_out);
}

}  // extern "C"

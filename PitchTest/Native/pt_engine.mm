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
constexpr float kMaxGain = 0.0631f;     // -24 dBFS
constexpr uint32_t kReleaseStepMs = 15;
constexpr uint32_t kReleaseStart = 120;  // ms; the board's 15 ms makes the tone blip

constexpr int kRing = 16;
constexpr int kLeakOffChunks = 220;  // 2.2 s, first 0.2 s ignored
constexpr int kLeakOnChunks = 230;   // 2.3 s, first 0.3 s ignored

struct Event {
  uint32_t ms;
  char text[28];
};

struct Shared {
  std::atomic<bool> muted{true};
  std::atomic<float> gain{kStartGain};
  std::atomic<int> key_slot{3};  // C
  std::atomic<bool> chromatic{false};
  std::atomic<bool> tonic{false};
  std::atomic<uint32_t> release_ms{kReleaseStart};
  std::atomic<float> hz{0}, rms{0}, cents{0}, clarity{0};
  std::atomic<bool> valid{false};
  std::atomic<int> target{-1};
  std::atomic<uint32_t> det_last_us{0}, det_max_us{0}, chunk_max_us{0};
  std::atomic<uint64_t> det_total_us{0}, det_count{0}, over_budget{0};

  std::atomic<uint64_t> valid_n{0}, invalid_n{0}, flips{0}, target_changes{0}, tone_on_events{0}, tone_off_events{0};
  std::atomic<uint64_t> pow_on_sum{0}, pow_on_n{0}, pow_off_sum{0}, pow_off_n{0};   // mean-square * 1e9
  std::atomic<uint64_t> cb_count{0}, cb_late{0};
  std::atomic<uint32_t> cb_frames_min{0xFFFFFFFFu}, cb_frames_max{0}, cb_gap_max_us{0};
  std::atomic<int> leak_state{0};
  std::atomic<float> leak_off_db{-120.0f}, leak_on_db{-120.0f};
  std::atomic<bool> reset_requested{false};
  Event ring[kRing];
  std::atomic<uint32_t> ring_n{0};

  void logEvent(uint32_t ms, const char* text) {
    const uint32_t i = ring_n.fetch_add(1) % kRing;
    ring[i].ms = ms;
    snprintf(ring[i].text, sizeof(ring[i].text), "%s", text);
  }
};

inline float toDb(double meanSquare) { return meanSquare > 1e-14 ? 10.0f * static_cast<float>(log10(meanSquare)) : -120.0f; }

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
                   majorKey(0));
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
    const int ls = sh.leak_state.load();
    if (ls == 1) hz = 0.0f;          // leak test: tone off, then a fixed 440 Hz tone
    else if (ls == 2) hz = 440.0f;
    const bool audible = hz > 0.0f;
    if (audible != audible_) {
      audible_ = audible;
      (audible ? sh.tone_on_events : sh.tone_off_events).fetch_add(1);
      sh.logEvent(now_ms_, audible ? "tone ON" : "tone OFF");
    }
    sine_.setGain(sh.gain.load());
    sine_.setFrequency(hz);
    sine_.setOn(audible);
    pcm_.resize(n);
    sine_.render(pcm_.data(), n);
    for (size_t i = 0; i < n; ++i) out[i] = pcm_[i] / 32768.0f;
  }

  void resetMetrics(Shared& sh) {
    sh.valid_n = 0; sh.invalid_n = 0; sh.flips = 0; sh.target_changes = 0; sh.tone_on_events = 0; sh.tone_off_events = 0;
    sh.pow_on_sum = 0; sh.pow_on_n = 0; sh.pow_off_sum = 0; sh.pow_off_n = 0;
    sh.cb_count = 0; sh.cb_late = 0; sh.cb_frames_min = 0xFFFFFFFFu; sh.cb_frames_max = 0; sh.cb_gap_max_us = 0;
    sh.det_max_us = 0; sh.det_total_us = 0; sh.det_count = 0; sh.chunk_max_us = 0; sh.over_budget = 0;
    sh.ring_n = 0;
    sh.leak_state = 0;
  }

 private:
  void chunk(const float* x, Shared& sh) {
    if (sh.reset_requested.exchange(false)) resetMetrics(sh);
    tracker_.setChromatic(sh.chromatic.load());
    tracker_.setReleaseMs(sh.release_ms.load());
    const int slot = sh.key_slot.load();
    if (slot != slot_) {
      slot_ = slot;
      tracker_.setKey(majorKey(keyFor(slot)));
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

    double sq = 0.0;
    for (float v : analysis_) sq += static_cast<double>(v) * v;
    const double meanSq = sq / static_cast<double>(analysis_.size());
    const bool valid = isValidPitch(r, kMinValidClarity, kMinValidPitchHz, kMaxValidPitchHz);
    const float exact = valid ? frequencyToMidi(r.frequency_hz) : 0.0f;
    tracker_.update(valid, exact, now_ms_);

    // ---- diagnostics ----
    (valid ? sh.valid_n : sh.invalid_n).fetch_add(1);
    if (valid != prev_valid_) {
      prev_valid_ = valid;
      sh.flips.fetch_add(1);
      sh.logEvent(now_ms_, valid ? "pitch found" : "pitch lost");
    }
    const int tgt = tracker_.hasTarget() ? tracker_.targetMidi() : -1;
    if (tgt != prev_target_) {
      prev_target_ = tgt;
      sh.target_changes.fetch_add(1);
      char b[28];
      if (tgt >= 0) {
        char nm[8];
        midiToNoteName(tgt, nm, sizeof(nm));
        snprintf(b, sizeof(b), "target %s", nm);
      } else {
        snprintf(b, sizeof(b), "target none");
      }
      sh.logEvent(now_ms_, b);
    }
    const uint64_t scaled = static_cast<uint64_t>(meanSq * 1e9);
    if (audible_) {
      sh.pow_on_sum.fetch_add(scaled);
      sh.pow_on_n.fetch_add(1);
    } else {
      sh.pow_off_sum.fetch_add(scaled);
      sh.pow_off_n.fetch_add(1);
    }
    // leak test: stay silent; measure the mic with the tone off, then on
    const int ls = sh.leak_state.load();
    if (ls == 1) {
      ++leak_n_;
      if (leak_n_ > 20) { leak_sum_ += meanSq; ++leak_cnt_; }
      if (leak_n_ >= kLeakOffChunks) {
        sh.leak_off_db.store(toDb(leak_cnt_ ? leak_sum_ / static_cast<double>(leak_cnt_) : 0.0));
        leak_n_ = 0; leak_sum_ = 0; leak_cnt_ = 0;
        sh.leak_state.store(2);
        sh.logEvent(now_ms_, "leak test: tone on");
      }
    } else if (ls == 2) {
      ++leak_n_;
      if (leak_n_ > 30) { leak_sum_ += meanSq; ++leak_cnt_; }
      if (leak_n_ >= kLeakOnChunks) {
        sh.leak_on_db.store(toDb(leak_cnt_ ? leak_sum_ / static_cast<double>(leak_cnt_) : 0.0));
        sh.leak_state.store(3);
        sh.logEvent(now_ms_, "leak test: done");
      }
    } else {
      leak_n_ = 0; leak_sum_ = 0; leak_cnt_ = 0;
    }

    sh.det_last_us.store(us);
    if (us > sh.det_max_us.load()) sh.det_max_us.store(us);
    sh.det_total_us.fetch_add(us);
    sh.det_count.fetch_add(1);
    sh.hz.store(r.frequency_hz);
    sh.clarity.store(r.clarity);
    sh.rms.store(static_cast<float>(sqrt(meanSq)));
    sh.valid.store(valid);
    sh.target.store(tgt);
    sh.cents.store(valid && tgt >= 0 ? (exact - static_cast<float>(tgt)) * 100.0f : 0.0f);
  }

  static int keyFor(int slot) {
    static const int order[12] = {9, 10, 11, 0, 1, 2, 3, 4, 5, 6, 7, 8};
    return order[((slot % 12) + 12) % 12];
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
  bool prev_valid_ = false, audible_ = false;
  int prev_target_ = -1;
  int leak_n_ = 0, leak_cnt_ = 0;
  double leak_sum_ = 0.0;
};

Engine g_engine;
Shared g_shared;
ma_context g_ctx;
ma_device g_dev;
bool g_running = false;
float g_in_ms = 0, g_out_ms = 0;
char g_err[160] = "";
char g_dev_in[64] = "", g_dev_out[64] = "";
Clock::time_point g_last_cb;
bool g_have_last_cb = false;

void dataCallback(ma_device*, void* output, const void* input, ma_uint32 frames) {
  const auto now = Clock::now();
  Shared& sh = g_shared;
  sh.cb_count.fetch_add(1);
  if (frames < sh.cb_frames_min.load()) sh.cb_frames_min.store(frames);
  if (frames > sh.cb_frames_max.load()) sh.cb_frames_max.store(frames);
  if (g_have_last_cb) {
    const uint32_t gap = static_cast<uint32_t>(std::chrono::duration_cast<std::chrono::microseconds>(now - g_last_cb).count());
    if (gap > sh.cb_gap_max_us.load()) sh.cb_gap_max_us.store(gap);
    // expected spacing = frames / rate; "late" if more than 1.5x that
    if (gap > static_cast<uint32_t>(1.5e6 * frames / kRate)) sh.cb_late.fetch_add(1);
  }
  g_last_cb = now;
  g_have_last_cb = true;
  g_engine.process(static_cast<const float*>(input), static_cast<float*>(output), frames, sh);
}

}  // namespace

extern "C" {

int pt_start(void) {
  if (g_running) return 0;
  g_err[0] = 0;
  g_have_last_cb = false;
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
void pt_leak_test(void) {
  g_shared.leak_off_db.store(-120.0f);
  g_shared.leak_on_db.store(-120.0f);
  g_shared.leak_state.store(1);
}
void pt_reset_metrics(void) { g_shared.reset_requested.store(true); }

void pt_get_status(PtStatus* o) {
  memset(o, 0, sizeof(*o));
  Shared& s = g_shared;
  o->hz = s.hz.load();
  o->cents = s.cents.load();
  o->rms = s.rms.load();
  o->clarity = s.clarity.load();
  o->gain_db = 20.0f * log10f(s.gain.load());
  o->valid = s.valid.load();
  o->target = s.target.load();
  o->muted = s.muted.load();
  o->chromatic = s.chromatic.load();
  o->tonic = s.tonic.load();
  o->key_slot = s.key_slot.load();
  o->release_ms = s.release_ms.load();
  o->det_last_us = s.det_last_us.load();
  const uint64_t n = s.det_count.load();
  o->det_avg_us = n ? static_cast<unsigned>(s.det_total_us.load() / n) : 0;
  o->det_max_us = s.det_max_us.load();
  o->chunk_max_us = s.chunk_max_us.load();
  o->over_budget = s.over_budget.load();
  o->chunks = n;
  o->in_buf_ms = g_in_ms;
  o->out_buf_ms = g_out_ms;

  o->valid_n = s.valid_n.load();
  o->invalid_n = s.invalid_n.load();
  o->flips = s.flips.load();
  o->target_changes = s.target_changes.load();
  o->tone_on_events = s.tone_on_events.load();
  o->tone_off_events = s.tone_off_events.load();
  const uint64_t pon = s.pow_on_n.load(), poff = s.pow_off_n.load();
  o->rms_db_tone_on = pon ? toDb(static_cast<double>(s.pow_on_sum.load()) / 1e9 / static_cast<double>(pon)) : -120.0f;
  o->rms_db_tone_off = poff ? toDb(static_cast<double>(s.pow_off_sum.load()) / 1e9 / static_cast<double>(poff)) : -120.0f;
  o->cb_count = s.cb_count.load();
  const uint32_t fmin = s.cb_frames_min.load();
  o->cb_frames_min = fmin == 0xFFFFFFFFu ? 0 : fmin;
  o->cb_frames_max = s.cb_frames_max.load();
  o->cb_gap_max_ms = static_cast<float>(s.cb_gap_max_us.load()) / 1000.0f;
  o->cb_late = s.cb_late.load();
  o->leak_state = s.leak_state.load();
  o->leak_off_db = s.leak_off_db.load();
  o->leak_on_db = s.leak_on_db.load();

  if (o->target >= 0) midiToNoteName(o->target, o->target_name, sizeof(o->target_name));
  else snprintf(o->target_name, sizeof(o->target_name), "-");
  static const int order[12] = {9, 10, 11, 0, 1, 2, 3, 4, 5, 6, 7, 8};
  snprintf(o->key_name, sizeof(o->key_name), "%s", majorKey(order[o->key_slot]).name);
  snprintf(o->device_in, sizeof(o->device_in), "%s", g_dev_in);
  snprintf(o->device_out, sizeof(o->device_out), "%s", g_dev_out);
}

int pt_event(int index, char* buf, int len) {
  const uint32_t total = g_shared.ring_n.load();
  if (index < 0 || static_cast<uint32_t>(index) >= total || index >= kRing || len < 8) return 0;
  const uint32_t i = (total - 1 - static_cast<uint32_t>(index)) % kRing;
  const Event e = g_shared.ring[i];
  snprintf(buf, static_cast<size_t>(len), "%u.%02u s  %s", e.ms / 1000u, (e.ms % 1000u) / 10u, e.text);
  return 1;
}

}  // extern "C"

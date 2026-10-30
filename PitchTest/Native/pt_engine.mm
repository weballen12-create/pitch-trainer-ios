// Engine + audio I/O for the iPhone test app. Objective-C++ because miniaudio's iOS backend needs it.
//
// Audio thread rules: no allocation, no locks, no Objective-C calls inside dataCallback()/Engine::process().
// Every buffer is allocated in Engine::begin(). The callback's real frame count is always used.
#include "pt_engine.h"

#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

#include <atomic>
#include <string>
#include <chrono>
#include <thread>
#include <vector>

#include "analysis_window.h"
#include "audio_config.h"
#include "gain_step.h"
#include "half_rate_decimator.h"
#include "mpm_pitch_detector.h"
#include "note_utils.h"
#include "phone_tuning.h"
#include "reference_tone.h"
#include "sine_generator.h"
#include "target_note.h"

#define MINIAUDIO_IMPLEMENTATION
#include "miniaudio.h"

namespace {

using Clock = std::chrono::steady_clock;
constexpr float kRate = static_cast<float>(kMicSampleRateHz);
constexpr size_t kWinDec = kPhWindowSamples / kDecimationFactor;   // analysis window at 24 kHz
constexpr size_t kHopDec = kPhHopSamples / kDecimationFactor;      // hop at 24 kHz
constexpr size_t kMaxBlock = 4096;                                 // longest callback handled in one go (longer ones are split)
static_assert(kPhWindowSamples % kDecimationFactor == 0 && kPhHopSamples % kDecimationFactor == 0, "decimation must be even");

// Headphones are far more sensitive than the board's speaker or exciter: start very quiet, cap low.
constexpr float kStartGain = 0.00316f;  // -50 dBFS
constexpr float kMaxGain = 0.0631f;     // -24 dBFS
constexpr uint32_t kReleaseStepMs = 15;

constexpr int kRing = 16;

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
  std::atomic<uint32_t> release_ms{kPhReleaseMs};
  std::atomic<float> gate_db{kPhGateDbDefault};
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

  // latency probe (microseconds)
  std::atomic<uint64_t> lat_n{0}, lat_missed{0}, lat_of_sum_us{0}, lat_ft_sum_us{0};
  std::atomic<uint32_t> lat_of_last_us{0}, lat_ft_last_us{0}, lat_of_max_us{0}, lat_ft_max_us{0};

  Event ring[kRing];
  std::atomic<uint32_t> ring_n{0};

  void logEvent(uint32_t ms, const char* text) {
    const uint32_t i = ring_n.fetch_add(1) % kRing;
    ring[i].ms = ms;
    snprintf(ring[i].text, sizeof(ring[i].text), "%s", text);
  }
};

// ---- recorder -------------------------------------------------------------------------------------------------
// The audio thread only copies into two preallocated single-producer / single-consumer rings. A writer thread
// drains them to disk: <base>.wav (16-bit mono 48 kHz, the raw microphone input) and <base>.csv (one row per
// detector run). Nothing here allocates, locks or touches files on the audio thread.
struct Row {
  int64_t sample_end;   // input sample index at the end of the analysis window
  float hz, clarity, rms_db, cents;
  int16_t target;       // MIDI note, -1 = none
  uint8_t found, usable, tone_on, muted;
};

class Recorder {
 public:
  void begin() {
    audio_.assign(kAudioCap, 0.0f);
    rows_.assign(kRowCap, Row{});
  }

  bool start(const char* base) {
    if (active_.load()) return false;
    std::string b(base);
    wav_ = fopen((b + ".wav").c_str(), "wb");
    csv_ = fopen((b + ".csv").c_str(), "wb");
    if (!wav_ || !csv_) {
      closeFiles();
      return false;
    }
    uint8_t hdr[44] = {0};
    fwrite(hdr, 1, sizeof(hdr), wav_);   // patched with the real sizes in stop()
    fputs("sample_end,time_s,hz,clarity,mic_db,found,usable,target_midi,cents,tone_on,muted\n", csv_);
    a_head_ = 0; a_tail_ = 0; r_head_ = 0; r_tail_ = 0;
    samples_ = 0;
    dropped_ = 0;
    run_.store(true);
    active_.store(true);
    writer_ = std::thread([this] { loop(); });
    return true;
  }

  void stop() {
    if (!run_.load()) return;
    active_.store(false);
    run_.store(false);
    if (writer_.joinable()) writer_.join();
    // WAV header: 16-bit mono PCM at the input rate.
    const uint32_t data_bytes = static_cast<uint32_t>(samples_ * 2);
    const uint32_t rate = kMicSampleRateHz;
    uint8_t h[44];
    memcpy(h, "RIFF", 4);
    put32(h + 4, 36 + data_bytes);
    memcpy(h + 8, "WAVEfmt ", 8);
    put32(h + 16, 16);
    put16(h + 20, 1);          // PCM
    put16(h + 22, 1);          // mono
    put32(h + 24, rate);
    put32(h + 28, rate * 2);   // byte rate
    put16(h + 32, 2);          // block align
    put16(h + 34, 16);
    memcpy(h + 36, "data", 4);
    put32(h + 40, data_bytes);
    if (wav_) {
      fseek(wav_, 0, SEEK_SET);
      fwrite(h, 1, sizeof(h), wav_);
    }
    closeFiles();
  }

  bool active() const { return active_.load(std::memory_order_acquire); }
  uint64_t samples() const { return samples_.load(); }
  uint64_t dropped() const { return dropped_.load(); }

  // ---- audio thread ----
  void pushAudio(const float* x, size_t n) {
    const size_t head = a_head_.load(std::memory_order_relaxed);
    const size_t tail = a_tail_.load(std::memory_order_acquire);
    if (kAudioCap - (head - tail) < n) {
      dropped_.fetch_add(n);
      return;
    }
    for (size_t i = 0; i < n; ++i) audio_[(head + i) & (kAudioCap - 1)] = x[i];
    a_head_.store(head + n, std::memory_order_release);
  }

  void pushRow(const Row& r) {
    const size_t head = r_head_.load(std::memory_order_relaxed);
    const size_t tail = r_tail_.load(std::memory_order_acquire);
    if (kRowCap - (head - tail) < 1) return;
    rows_[head & (kRowCap - 1)] = r;
    r_head_.store(head + 1, std::memory_order_release);
  }

 private:
  static constexpr size_t kAudioCap = 1u << 20;   // 1,048,576 samples = 21.8 s of buffer
  static constexpr size_t kRowCap = 1u << 12;

  static void put32(uint8_t* p, uint32_t v) { p[0] = v & 255; p[1] = (v >> 8) & 255; p[2] = (v >> 16) & 255; p[3] = (v >> 24) & 255; }
  static void put16(uint8_t* p, uint16_t v) { p[0] = v & 255; p[1] = (v >> 8) & 255; }

  bool drain() {
    bool did = false;
    {
      const size_t head = a_head_.load(std::memory_order_acquire);
      size_t tail = a_tail_.load(std::memory_order_relaxed);
      int16_t buf[2048];
      while (tail != head) {
        size_t n = head - tail;
        if (n > 2048) n = 2048;
        for (size_t i = 0; i < n; ++i) {
          float v = audio_[(tail + i) & (kAudioCap - 1)];
          v = v > 1.0f ? 1.0f : (v < -1.0f ? -1.0f : v);
          buf[i] = static_cast<int16_t>(lrintf(v * 32767.0f));
        }
        fwrite(buf, sizeof(int16_t), n, wav_);
        tail += n;
        samples_.fetch_add(n);
        did = true;
      }
      a_tail_.store(tail, std::memory_order_release);
    }
    {
      const size_t head = r_head_.load(std::memory_order_acquire);
      size_t tail = r_tail_.load(std::memory_order_relaxed);
      while (tail != head) {
        const Row& r = rows_[tail & (kRowCap - 1)];
        fprintf(csv_, "%lld,%.4f,%.2f,%.3f,%.1f,%d,%d,%d,%.1f,%d,%d\n", static_cast<long long>(r.sample_end),
                static_cast<double>(r.sample_end) / kMicSampleRateHz, r.hz, r.clarity, r.rms_db, r.found, r.usable, r.target, r.cents,
                r.tone_on, r.muted);
        ++tail;
        did = true;
      }
      r_tail_.store(tail, std::memory_order_release);
    }
    return did;
  }

  void loop() {
    for (;;) {
      const bool did = drain();
      if (!run_.load() && !did) break;
      if (!did) std::this_thread::sleep_for(std::chrono::milliseconds(10));
    }
    fflush(wav_);
    fflush(csv_);
  }

  void closeFiles() {
    if (wav_) { fclose(wav_); wav_ = nullptr; }
    if (csv_) { fclose(csv_); csv_ = nullptr; }
  }

  std::vector<float> audio_;
  std::vector<Row> rows_;
  std::atomic<size_t> a_head_{0}, a_tail_{0}, r_head_{0}, r_tail_{0};
  std::atomic<uint64_t> samples_{0}, dropped_{0};
  std::atomic<bool> active_{false}, run_{false};
  std::thread writer_;
  FILE* wav_ = nullptr;
  FILE* csv_ = nullptr;
};

Recorder g_rec;

inline float toDb(double meanSquare) { return meanSquare > 1e-14 ? 10.0f * static_cast<float>(log10(meanSquare)) : -120.0f; }

class Engine {
 public:
  bool begin() {
    g_rec.begin();
    if (!decimator_.begin(kDecimatorTaps, kDecimatorCutoffHz, kRate)) return false;
    window_.begin(kWinDec);
    if (!detector_.begin(kWinDec)) return false;
    detector_.setClarityThreshold(kMpmK);
    gate_applied_db_ = 1000.0f;   // forces the first block to apply the gate
    tracker_.begin({kTargetHysteresisCents, kPhReleaseMs, kTargetSwitchHoldMs, kTargetOctaveDownHoldMs,
                    kTargetHoldMaxJumpSemitones},
                   majorKey(0));
    analysis_.assign(kWinDec, 0.0f);
    dec_.assign(kMaxBlock / kDecimationFactor + 8, 0.0f);
    pcm_.assign(kMaxBlock, 0);
    sine_.begin(kRate, kPhFadeOutMs);
    sine_.setFadeMs(kPhAttackMs, kPhFadeOutMs);
    sine_.setGlideMs(kPhGlideMs);
    sine_.setGain(kStartGain);
    clock_ = 0;
    since_hop_ = 0;
    return true;
  }

  // Any number of frames; split into blocks the preallocated buffers can hold.
  void process(const float* in, float* out, size_t n, Shared& sh) {
    size_t done = 0;
    while (done < n) {
      const size_t k = (n - done) < kMaxBlock ? (n - done) : kMaxBlock;
      block(in != nullptr ? in + done : nullptr, out + done, k, sh);
      done += k;
    }
  }

  void resetMetrics(Shared& sh) {
    sh.valid_n = 0; sh.invalid_n = 0; sh.flips = 0; sh.target_changes = 0; sh.tone_on_events = 0; sh.tone_off_events = 0;
    sh.pow_on_sum = 0; sh.pow_on_n = 0; sh.pow_off_sum = 0; sh.pow_off_n = 0;
    sh.cb_count = 0; sh.cb_late = 0; sh.cb_frames_min = 0xFFFFFFFFu; sh.cb_frames_max = 0; sh.cb_gap_max_us = 0;
    sh.det_max_us = 0; sh.det_total_us = 0; sh.det_count = 0; sh.chunk_max_us = 0; sh.over_budget = 0;
    sh.lat_n = 0; sh.lat_missed = 0; sh.lat_of_sum_us = 0; sh.lat_ft_sum_us = 0;
    sh.lat_of_last_us = 0; sh.lat_ft_last_us = 0; sh.lat_of_max_us = 0; sh.lat_ft_max_us = 0;
    sh.ring_n = 0;
    sh.leak_state = 0;
    pending_ = false;
  }

 private:
  void block(const float* in, float* out, size_t k, Shared& sh) {
    if (sh.reset_requested.exchange(false)) resetMetrics(sh);
    block_end_ = clock_ + static_cast<int64_t>(k);
    const float gate_db = sh.gate_db.load();
    if (gate_db != gate_applied_db_) {
      gate_applied_db_ = gate_db;
      gate_rms_ = powf(10.0f, gate_db / 20.0f);
      detector_.setMinVolumeRms(gate_rms_);   // the detector refuses windows quieter than this
    }
    tracker_.setChromatic(sh.chromatic.load());
    tracker_.setReleaseMs(sh.release_ms.load());
    const int slot = sh.key_slot.load();
    if (slot != slot_) {
      slot_ = slot;
      tracker_.setKey(majorKey(keyFor(slot)));
    }

    if (in != nullptr) {
      if (g_rec.active()) g_rec.pushAudio(in, k);
      onsetScan(in, k, sh);
      const size_t m = decimator_.process(in, k, dec_.data());
      size_t used = 0;
      while (used < m) {
        const size_t room = kHopDec - since_hop_;
        const size_t take = (m - used) < room ? (m - used) : room;
        window_.push(dec_.data() + used, take);
        used += take;
        since_hop_ += take;
        if (since_hop_ == kHopDec) {
          since_hop_ = 0;
          detect(clock_ + static_cast<int64_t>(used * kDecimationFactor), sh);
        }
      }
    }

    // The tone: leak test > tonic button > target note; silent when muted or no target.
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
      sh.logEvent(nowMs(clock_), audible ? "tone ON" : "tone OFF");
    }
    sine_.setGain(sh.gain.load());
    sine_.setFrequency(hz);
    sine_.setOn(audible);
    sine_.render(pcm_.data(), k);
    bool first_nonzero_seen = false;
    for (size_t i = 0; i < k; ++i) {
      out[i] = pcm_[i] / 32768.0f;
      if (!first_nonzero_seen && pending_ && found_ && pcm_[i] != 0) {
        first_nonzero_seen = true;
        recordLatency(block_end_ + static_cast<int64_t>(i), sh);
      }
    }
    clock_ = block_end_;
  }

  uint32_t nowMs(int64_t samples) const { return static_cast<uint32_t>(samples / (kMicSampleRateHz / 1000)); }

  // Input level in 64-sample blocks: a note onset is a rise above kPhOnsetDb after a quiet stretch while no tone is playing.
  void onsetScan(const float* in, size_t k, Shared& sh) {
    const int64_t quiet_needed = static_cast<int64_t>(kPhQuietMs) * (kMicSampleRateHz / 1000);
    for (size_t off = 0; off < k; off += kPhProbeBlock) {
      const size_t n = (k - off) < kPhProbeBlock ? (k - off) : kPhProbeBlock;
      double sq = 0.0;
      for (size_t i = 0; i < n; ++i) sq += static_cast<double>(in[off + i]) * in[off + i];
      const float db = toDb(sq / static_cast<double>(n));
      const int64_t t = clock_ + static_cast<int64_t>(off);
      if (pending_ && t > deadline_) {
        pending_ = false;
        sh.lat_missed.fetch_add(1);
      }
      if (db < kPhQuietDb) quiet_ += static_cast<int64_t>(n); else quiet_ = 0;
      if (!pending_ && quiet_ >= quiet_needed) armed_ = true;
      if (armed_ && !pending_ && db >= kPhOnsetDb && sine_.isSilent()) {
        pending_ = true;
        found_ = false;
        armed_ = false;
        onset_ = t;
        deadline_ = t + static_cast<int64_t>(kPhProbeTimeoutMs) * (kMicSampleRateHz / 1000);
      }
    }
  }

  void recordLatency(int64_t tone_t, Shared& sh) {
    const double per_ms = static_cast<double>(kMicSampleRateHz) / 1000.0;
    const uint32_t of_us = static_cast<uint32_t>(1000.0 * static_cast<double>(found_t_ - onset_) / per_ms);
    const uint32_t ft_us = static_cast<uint32_t>(1000.0 * static_cast<double>(tone_t - found_t_) / per_ms);
    sh.lat_of_last_us.store(of_us);
    sh.lat_ft_last_us.store(ft_us);
    if (of_us > sh.lat_of_max_us.load()) sh.lat_of_max_us.store(of_us);
    if (ft_us > sh.lat_ft_max_us.load()) sh.lat_ft_max_us.store(ft_us);
    sh.lat_of_sum_us.fetch_add(of_us);
    sh.lat_ft_sum_us.fetch_add(ft_us);
    sh.lat_n.fetch_add(1);
    pending_ = false;
  }

  // One detector run (every hop). `t` = input sample position at the end of the window.
  void detect(int64_t t, Shared& sh) {
    if (!window_.isFull()) return;
    const uint32_t now_ms = nowMs(t);

    const auto t0 = Clock::now();
    window_.copyDcRemoved(analysis_.data());
    const PitchResult r = detector_.findPitch(analysis_.data(), kRate / 2.0f);
    const uint32_t us =
        static_cast<uint32_t>(std::chrono::duration_cast<std::chrono::microseconds>(Clock::now() - t0).count());

    double sq = 0.0;
    for (float v : analysis_) sq += static_cast<double>(v) * v;
    const double meanSq = sq / static_cast<double>(analysis_.size());
    const float rms = static_cast<float>(sqrt(meanSq));

    // Asymmetric gate: ONE good window starts "found"; a weaker one keeps it; "lost" only after kPhLostHoldMs of nothing.
    const bool range_ok = r.frequency_hz >= kPhMinHz && r.frequency_hz <= kPhMaxHz;
    const bool level_ok = rms >= gate_rms_;
    const bool start_ok = range_ok && level_ok && r.clarity >= kPhStartClarity;
    const bool stay_ok = range_ok && level_ok && r.clarity >= kPhStayClarity;
    bool usable = false;
    if (!gate_) {
      if (start_ok) {
        gate_ = true;
        usable = true;
        last_good_ms_ = now_ms;
        sh.flips.fetch_add(1);
        sh.logEvent(now_ms, "found");
        if (pending_ && !found_ && t >= onset_) {
          found_ = true;
          found_t_ = block_end_;   // the callback that finished this window is the earliest the tone can react
        }
      }
    } else if (stay_ok) {
      usable = true;
      last_good_ms_ = now_ms;
    } else if (now_ms - last_good_ms_ >= kPhLostHoldMs) {
      gate_ = false;
      sh.flips.fetch_add(1);
      sh.logEvent(now_ms, "lost");
    }
    const float exact = usable ? frequencyToMidi(r.frequency_hz) : 0.0f;
    tracker_.update(usable, exact, now_ms);

    // ---- diagnostics ----
    (usable ? sh.valid_n : sh.invalid_n).fetch_add(1);
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
      sh.logEvent(now_ms, b);
    }
    const uint64_t scaled = static_cast<uint64_t>(meanSq * 1e9);
    if (audible_) {
      sh.pow_on_sum.fetch_add(scaled);
      sh.pow_on_n.fetch_add(1);
    } else {
      sh.pow_off_sum.fetch_add(scaled);
      sh.pow_off_n.fetch_add(1);
    }
    // leak test: stay silent; measure the mic with the tone off, then on (counted in detector runs)
    const int ls = sh.leak_state.load();
    if (ls == 1) {
      ++leak_n_;
      if (leak_n_ > kLeakSkipRuns) { leak_sum_ += meanSq; ++leak_cnt_; }
      if (leak_n_ >= kLeakRunsPerPhase) {
        sh.leak_off_db.store(toDb(leak_cnt_ ? leak_sum_ / static_cast<double>(leak_cnt_) : 0.0));
        leak_n_ = 0; leak_sum_ = 0; leak_cnt_ = 0;
        sh.leak_state.store(2);
        sh.logEvent(now_ms, "leak test: tone on");
      }
    } else if (ls == 2) {
      ++leak_n_;
      if (leak_n_ > kLeakSkipRuns) { leak_sum_ += meanSq; ++leak_cnt_; }
      if (leak_n_ >= kLeakRunsPerPhase) {
        sh.leak_on_db.store(toDb(leak_cnt_ ? leak_sum_ / static_cast<double>(leak_cnt_) : 0.0));
        sh.leak_state.store(3);
        sh.logEvent(now_ms, "leak test: done");
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
    sh.rms.store(rms);
    sh.valid.store(gate_);
    sh.target.store(tgt);
    const float cents = usable && tgt >= 0 ? (exact - static_cast<float>(tgt)) * 100.0f : 0.0f;
    sh.cents.store(cents);
    if (g_rec.active()) {
      Row row;
      row.sample_end = t;
      row.hz = r.frequency_hz;
      row.clarity = r.clarity;
      row.rms_db = 20.0f * log10f(rms > 1e-6f ? rms : 1e-6f);
      row.cents = cents;
      row.target = static_cast<int16_t>(tgt);
      row.found = gate_ ? 1 : 0;
      row.usable = usable ? 1 : 0;
      row.tone_on = audible_ ? 1 : 0;
      row.muted = sh.muted.load() ? 1 : 0;
      g_rec.pushRow(row);
    }
  }

  static int keyFor(int slot) {
    static const int order[12] = {9, 10, 11, 0, 1, 2, 3, 4, 5, 6, 7, 8};
    return order[((slot % 12) + 12) % 12];
  }

  // The leak test counts detector runs: 2 s of runs per phase (hop = 5.33 ms), the first 0.3 s ignored.
  static constexpr int kLeakRunsPerPhase = static_cast<int>(2300.0 * kMicSampleRateHz / 1000.0 / kPhHopSamples);
  static constexpr int kLeakSkipRuns = static_cast<int>(300.0 * kMicSampleRateHz / 1000.0 / kPhHopSamples);

  HalfRateDecimator decimator_;
  AnalysisWindow window_;
  MpmPitchDetector detector_;
  TargetNoteTracker tracker_;
  SineGenerator sine_;
  std::vector<float> analysis_, dec_;
  std::vector<int16_t> pcm_;
  int64_t clock_ = 0;        // input sample index of the start of the current block
  int64_t block_end_ = 0;    // ... and of its end
  size_t since_hop_ = 0;     // decimated samples since the last detector run
  int slot_ = 3;
  bool gate_ = false;
  float gate_applied_db_ = 1000.0f, gate_rms_ = 0.0f;
  uint32_t last_good_ms_ = 0;
  bool audible_ = false;
  int prev_target_ = -1;
  int leak_n_ = 0, leak_cnt_ = 0;
  double leak_sum_ = 0.0;
  // latency probe state
  bool armed_ = false, pending_ = false, found_ = false;
  int64_t quiet_ = 0, onset_ = 0, found_t_ = 0, deadline_ = 0;
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
  const uint32_t spent = static_cast<uint32_t>(std::chrono::duration_cast<std::chrono::microseconds>(Clock::now() - now).count());
  if (spent > sh.chunk_max_us.load()) sh.chunk_max_us.store(spent);
  if (spent > static_cast<uint32_t>(1e6 * frames / kRate)) sh.over_budget.fetch_add(1);
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
  cfg.periodSizeInFrames = kPhIoPeriodFrames;   // a request; the callback's real frame count is always used
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
void pt_gate_step(int less_sensitive) {
  float g = g_shared.gate_db.load() + (less_sensitive ? kPhGateStepDb : -kPhGateStepDb);
  if (g < kPhGateDbMin) g = kPhGateDbMin;
  if (g > kPhGateDbMax) g = kPhGateDbMax;
  g_shared.gate_db.store(g);
}
void pt_leak_test(void) {
  g_shared.leak_off_db.store(-120.0f);
  g_shared.leak_on_db.store(-120.0f);
  g_shared.leak_state.store(1);
}
void pt_reset_metrics(void) { g_shared.reset_requested.store(true); }
double pt_io_buffer_seconds(void) { return kPhIoBufferSeconds; }
int pt_record_start(const char* base_path) { return g_rec.start(base_path) ? 0 : 1; }
void pt_record_stop(void) { g_rec.stop(); }

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
  o->gate_db = s.gate_db.load();
  o->rec_on = g_rec.active() ? 1 : 0;
  o->rec_seconds = static_cast<float>(static_cast<double>(g_rec.samples()) / kRate);
  o->rec_dropped = g_rec.dropped();
  o->window_ms = 1000.0f * kPhWindowSamples / kRate;
  o->hop_ms = 1000.0f * kPhHopSamples / kRate;

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

  const uint64_t ln = s.lat_n.load();
  o->lat_n = ln;
  o->lat_missed = s.lat_missed.load();
  o->lat_of_last_ms = static_cast<float>(s.lat_of_last_us.load()) / 1000.0f;
  o->lat_ft_last_ms = static_cast<float>(s.lat_ft_last_us.load()) / 1000.0f;
  o->lat_of_avg_ms = ln ? static_cast<float>(static_cast<double>(s.lat_of_sum_us.load()) / static_cast<double>(ln) / 1000.0) : 0.0f;
  o->lat_ft_avg_ms = ln ? static_cast<float>(static_cast<double>(s.lat_ft_sum_us.load()) / static_cast<double>(ln) / 1000.0) : 0.0f;
  o->lat_of_max_ms = static_cast<float>(s.lat_of_max_us.load()) / 1000.0f;
  o->lat_ft_max_ms = static_cast<float>(s.lat_ft_max_us.load()) / 1000.0f;

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

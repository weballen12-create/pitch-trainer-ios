#pragma once

// Continuous sine tone generator (mono, int16).
//
// - 32-bit phase accumulator (DDS): frequency resolution fs / 2^32, no drift.
// - Frequency changes keep the phase continuous, so retargeting never clicks.
//   By default they take effect on the next sample (no glide). With a glide
//   time set (D78) an audible tone slides to the new frequency in exactly that
//   time, however far the jump is (constant duration, geometric slide, so each
//   semitone takes the same share). A silent tone jumps straight to the new
//   frequency.
// - Amplitude ramps linearly toward its target (gain when on, 0 when off);
//   a full fade in takes onset_ms and a full fade out offset_ms at any gain
//   (D78; 0 = instant, which may click).
//
// Pure computation: no hardware, no threading. Not thread-safe by itself.

#include <stddef.h>
#include <stdint.h>

class SineGenerator {
 public:
  // fade_ms sets both the onset and the offset time.
  void begin(float sample_rate_hz, float fade_ms);

  void setFadeMs(float onset_ms, float offset_ms);
  void setGlideMs(float glide_ms);  // 0 = no glide

  void setFrequency(float hz);
  void setGain(float gain);  // clamped to [0, 1]; 1 = int16 full scale
  void setOn(bool on);

  void render(int16_t* out, size_t n);

  // True when off and the fade-out has fully completed.
  bool isSilent() const { return !on_ && amp_ == 0.0f; }
  float frequency() const { return freq_hz_; }  // instantaneous (mid-glide: where the slide is now)
  float targetFrequency() const { return target_hz_; }
  float currentAmplitude() const { return amp_; }

 private:
  void applyFrequency(float hz);

  float sample_rate_hz_ = 48000.0f;
  float ramp_up_ = 1.0f;    // 1 / onset length in samples (scaled by gain)
  float ramp_down_ = 1.0f;  // 1 / offset length in samples (scaled by gain)
  float glide_samples_ = 0.0f;
  float phase_per_hz_ = 89478.485f;  // 2^32 / fs, for the glide loop
  float freq_hz_ = 0.0f;    // instantaneous frequency
  float target_hz_ = 0.0f;  // where the glide is heading
  float glide_ratio_ = 1.0f;  // per-sample multiplier while gliding
  uint32_t glide_left_ = 0;
  uint32_t phase_ = 0;
  uint32_t phase_inc_ = 0;
  float gain_ = 0.0f;
  float amp_ = 0.0f;
  bool on_ = false;
};

#include "sine_generator.h"

#include <math.h>

namespace {
constexpr double kPhaseScale = 4294967296.0;  // 2^32
constexpr float kTwoPiOverPhase = static_cast<float>(6.283185307179586 / 4294967296.0);

float rampFor(float ms, float sample_rate_hz) {
  const float samples = ms * sample_rate_hz / 1000.0f;
  return samples >= 1.0f ? 1.0f / samples : 1.0f;
}
}  // namespace

void SineGenerator::begin(float sample_rate_hz, float fade_ms) {
  sample_rate_hz_ = sample_rate_hz;
  setFadeMs(fade_ms, fade_ms);
  phase_per_hz_ = static_cast<float>(kPhaseScale / sample_rate_hz);
  glide_samples_ = 0.0f;
  glide_left_ = 0;
  phase_ = 0;
  amp_ = 0.0f;
  on_ = false;
}

void SineGenerator::setFadeMs(float onset_ms, float offset_ms) {
  ramp_up_ = rampFor(onset_ms, sample_rate_hz_);
  ramp_down_ = rampFor(offset_ms, sample_rate_hz_);
}

void SineGenerator::setGlideMs(float glide_ms) {
  glide_samples_ = glide_ms > 0.0f ? glide_ms * sample_rate_hz_ / 1000.0f : 0.0f;
}

// Exact (double) for a settled frequency, set once per block at most.
void SineGenerator::applyFrequency(float hz) {
  freq_hz_ = hz;
  phase_inc_ = static_cast<uint32_t>(static_cast<double>(hz) / sample_rate_hz_ * kPhaseScale + 0.5);
}

void SineGenerator::setFrequency(float hz) {
  if (hz < 0.0f) hz = 0.0f;
  if (hz > sample_rate_hz_ / 2) hz = sample_rate_hz_ / 2;
  if (hz == target_hz_) return;  // called every block with the same value
  target_hz_ = hz;
  // Glide only an audible tone with a real previous and next frequency; a
  // silent one jumps (nothing to slide from, and the fade-in covers the start).
  if (glide_samples_ >= 1.0f && amp_ > 0.0f && freq_hz_ > 0.0f && hz > 0.0f) {
    glide_left_ = static_cast<uint32_t>(glide_samples_);
    glide_ratio_ = powf(hz / freq_hz_, 1.0f / static_cast<float>(glide_left_));
    return;
  }
  glide_left_ = 0;
  applyFrequency(hz);
}

void SineGenerator::setGain(float gain) {
  gain_ = gain < 0.0f ? 0.0f : (gain > 1.0f ? 1.0f : gain);
}

// Starting from silence restarts the phase at zero (a click-free, repeatable onset); a tone that is already
// sounding keeps its phase.
void SineGenerator::setOn(bool on) {
  if (on && !on_ && amp_ == 0.0f) phase_ = 0;
  on_ = on;
}

void SineGenerator::render(int16_t* out, size_t n) {
  const float target = on_ ? gain_ : 0.0f;
  // Scale the step by the gain so a full fade takes its time at any volume
  // (a fixed full-scale step would make quiet fades near-instant clicks).
  const float gain_scale = gain_ > 0.0f ? gain_ : 1.0f;
  const float up = gain_scale * ramp_up_;
  const float down = gain_scale * ramp_down_;
  for (size_t i = 0; i < n; ++i) {
    if (amp_ < target) {
      amp_ += up;
      if (amp_ > target) amp_ = target;
    } else if (amp_ > target) {
      amp_ -= down;
      if (amp_ < target) amp_ = target;
    }
    if (glide_left_ > 0) {
      --glide_left_;
      if (glide_left_ == 0) {
        applyFrequency(target_hz_);  // land exactly on the target
      } else {
        // Float only in the per-sample loop (the ESP32 FPU has no double, D51).
        freq_hz_ *= glide_ratio_;
        phase_inc_ = static_cast<uint32_t>(freq_hz_ * phase_per_hz_ + 0.5f);
      }
    }
    const float s = amp_ * sinf(static_cast<float>(phase_) * kTwoPiOverPhase);
    out[i] = static_cast<int16_t>(lrintf(s * 32767.0f));
    phase_ += phase_inc_;  // wraps mod 2^32 by design
  }
}

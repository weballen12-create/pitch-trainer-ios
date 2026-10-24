#pragma once

// 3 dB gain steps for the reference tone, clamped to [min_gain, max_gain].
// Pure and host-tested: the volume cap (kToneMaxGain) is enforced HERE, so no
// client (serial key or BLE command) can raise the tone above it.

inline float stepGain(float gain, bool up, float max_gain, float min_gain = 0.001f) {
  const float g = up ? gain * 1.41254f : gain / 1.41254f;
  if (g > max_gain) return max_gain;
  if (g < min_gain) return min_gain;
  return g;
}

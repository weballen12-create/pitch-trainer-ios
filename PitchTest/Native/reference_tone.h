#pragma once

// Maps the target note to the frequency the reference tone actually plays.
//
// The target note itself never changes (it's what the singer should sing).
// Only the reference tone is moved: targets below `raise_below_hz` are played
// whole octaves higher until they reach it. Reason (D34/D54): the current
// speaker buzzes so badly below ~200 Hz at the cheek that low references are
// hard to use. A reference an octave up still beats against the voice's 2nd
// harmonic and goes quiet at true unison, so tuning by ear should still
// work (to be confirmed by ear in Stage 5).
//
// raise_below_hz <= 0 disables the shift (reference = target pitch).

#include <math.h>
#include <stdint.h>

inline float referenceToneHz(float target_hz, float raise_below_hz) {
  if (raise_below_hz <= 0.0f || target_hz <= 0.0f) return target_hz;
  float hz = target_hz;
  while (hz < raise_below_hz) hz *= 2.0f;
  return hz;
}

// ---- Switchable reference mapping (D58, trial) -----------------------------
//
// Which pitch the reference tone plays for a given target note. Octave is the
// D54 rule above (the default, reproduces it exactly). Shift plays a constant
// number of whole octaves above the target. (Fifth and Unison modes were tried
// and removed, see D58.)
enum class ReferenceMode : uint8_t {
  Octave = 0,  // D54: raise only, to at least floor_hz (drops an octave where a note crosses the floor)
  Shift,       // a constant number of whole octaves up, for every note (never drops as you sing higher)
  kCount
};

inline const char* referenceModeName(ReferenceMode m) {
  switch (m) {
    case ReferenceMode::Octave: return "Octave";
    case ReferenceMode::Shift: return "Shift";
    default: return "?";
  }
}

// shift_octaves is used only by Shift mode (0 = the true pitch, 1 = an octave
// up, ...); floor_hz is used by Octave mode.
inline float referenceToneHz(float target_hz, ReferenceMode mode, float floor_hz, int shift_octaves = 0) {
  if (target_hz <= 0.0f) return target_hz;
  if (mode == ReferenceMode::Shift) {
    float hz = target_hz;
    for (int i = 0; i < shift_octaves; ++i) hz *= 2.0f;
    return hz;
  }
  return referenceToneHz(target_hz, floor_hz);  // Octave
}

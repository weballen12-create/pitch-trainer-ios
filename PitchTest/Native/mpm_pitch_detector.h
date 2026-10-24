#pragma once

// McLeod Pitch Method (MPM) pitch detector.
//
// A C++ port of the PitchDetector/Autocorrelator classes from the `pitchy`
// JavaScript library (https://github.com/ianprime0509/pitchy, 0BSD license,
// Copyright Ian Johnson) — the same implementation the iOS prototype used.
// Algorithm: P. McLeod & G. Wyvill, "A Smarter Way to Find Pitch" (2005).
//
// Port notes (behavior is kept identical to pitchy unless listed here):
// - Sample buffers are float (pitchy's Float32Array mode). The parabolic
//   refinement is done in double (it cancels large terms and is wrong in
//   float; it's only a few operations). The per-sample loops (NSDF
//   normalizer, energy sum) are float, with Kahan compensation for the NSDF
//   normalizer: the ESP32 FPU is float-only and emulated doubles there made
//   detection too slow for the 10 ms chunk budget. Re-verified against real
//   pitchy after the change (see docs/DECISIONS.md D51).
// - Volume gate is set as an absolute RMS (pitchy's minVolumeAbsolute).
//   pitchy's minVolumeDecibels converts with 10^(dB/10), not 10^(dB/20), so
//   the prototype's "-45 dB" was an RMS of 10^-4.5 ~= 3.16e-5 (-90 dBFS).
// - Refinement falls back to the unrefined peak if the three points are
//   exactly collinear (pitchy would divide by zero there).
//
// No allocations after begin().

#include <stddef.h>
#include <stdint.h>

#include <vector>

#include "complex_fft.h"

struct PitchResult {
  float frequency_hz;  // 0 if no pitch could be determined
  float clarity;       // 0..1; 0 if no pitch could be determined
};

// The project's rule for when a detector result counts as a real sung pitch:
// clarity at/above min_clarity and frequency inside [min_hz, max_hz].
inline bool isValidPitch(const PitchResult& r, float min_clarity, float min_hz, float max_hz) {
  return r.frequency_hz >= min_hz && r.frequency_hz <= max_hz && r.clarity >= min_clarity;
}

class MpmPitchDetector {
 public:
  // input_length = samples per findPitch() call (the analysis window).
  bool begin(size_t input_length);

  // MPM constant k: choose the first key maximum >= k * highest key maximum.
  // Range (0, 1]; pitchy default 0.9.
  void setClarityThreshold(float k) { clarity_threshold_ = k; }

  // Inputs with RMS below this return {0, 0}. 0 disables the gate.
  void setMinVolumeRms(float rms) { min_volume_rms_ = rms; }

  // input must hold inputLength() samples, nominally in [-1, 1], zero-mean.
  PitchResult findPitch(const float* input, float sample_rate_hz);

  size_t inputLength() const { return input_length_; }
  size_t fftSize() const { return fft_.size(); }

 private:
  bool belowMinimumVolume(const float* input) const;
  void autocorrelate(const float* input);  // -> nsdf_ (as raw r'(tau))
  void computeNsdf(const float* input);    // -> nsdf_
  size_t findKeyMaxima();                  // -> key_indices_, returns count

  size_t input_length_ = 0;
  float clarity_threshold_ = 0.9f;
  float min_volume_rms_ = 0.0f;
  ComplexFft fft_;
  std::vector<float> nsdf_;
  std::vector<uint32_t> key_indices_;
};

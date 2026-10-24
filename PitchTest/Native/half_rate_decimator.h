#pragma once

// Anti-aliased 2:1 downsampler: linear-phase FIR low-pass (Blackman-windowed
// sinc), keeping every second output.
//
// Why: the SPH0645 needs BCLK >= 2.048 MHz (32-64 kHz sample rates), so the
// mic is captured at 48 kHz, while the pitch detector's window/FFT sizing is
// built around 24 kHz. Filtering before dropping samples stops content in
// 12-24 kHz (fricatives, hiss) folding down into the analysed band.
//
// Streaming: filter state carries across process() calls, so chunk
// boundaries are seamless. Pure computation; no allocation after begin().

#include <stddef.h>

#include <vector>

class HalfRateDecimator {
 public:
  // num_taps must be odd (symmetric, integer group delay of (taps-1)/2 input
  // samples). cutoff_hz is the -6 dB point of the windowed sinc.
  bool begin(size_t num_taps, float cutoff_hz, float input_rate_hz);

  // Consumes n input samples (n must be even); writes n/2 outputs to out.
  // Returns the number written.
  size_t process(const float* in, size_t n, float* out);

  void reset();

  const std::vector<float>& taps() const { return taps_; }

 private:
  std::vector<float> taps_;
  std::vector<float> delay_;  // mirrored circular buffer (2 x taps), newest at head_
  size_t head_ = 0;
  bool odd_ = false;  // parity of the next input sample
};

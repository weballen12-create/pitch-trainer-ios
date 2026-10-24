#include "half_rate_decimator.h"

#include <math.h>

bool HalfRateDecimator::begin(size_t num_taps, float cutoff_hz, float input_rate_hz) {
  if (num_taps < 3 || (num_taps % 2) == 0 || cutoff_hz <= 0 || cutoff_hz >= input_rate_hz / 2) return false;

  // Windowed-sinc low-pass: h[n] = w[n] * sin(2*pi*fc*(n-M)) / (pi*(n-M)),
  // w = Blackman, then normalized to unity DC gain.
  taps_.assign(num_taps, 0.0f);
  const double fc = static_cast<double>(cutoff_hz) / input_rate_hz;  // cycles/sample
  const double m = (num_taps - 1) / 2.0;
  double sum = 0.0;
  for (size_t i = 0; i < num_taps; ++i) {
    const double k = static_cast<double>(i) - m;
    const double sinc = k == 0.0 ? 2.0 * fc : sin(2.0 * M_PI * fc * k) / (M_PI * k);
    const double w = 0.42 - 0.5 * cos(2.0 * M_PI * i / (num_taps - 1)) + 0.08 * cos(4.0 * M_PI * i / (num_taps - 1));
    const double h = sinc * w;
    taps_[i] = static_cast<float>(h);
    sum += h;
  }
  for (float& t : taps_) t = static_cast<float>(t / sum);

  delay_.assign(2 * num_taps, 0.0f);  // mirrored, see process()
  head_ = 0;
  odd_ = false;
  return true;
}

void HalfRateDecimator::reset() {
  for (float& v : delay_) v = 0.0f;
  head_ = 0;
  odd_ = false;
}

size_t HalfRateDecimator::process(const float* in, size_t n, float* out) {
  const size_t taps = taps_.size();
  size_t written = 0;
  const size_t half = taps / 2;  // taps is odd: centre tap at index half
  const float* h = taps_.data();
  for (size_t i = 0; i < n; ++i) {
    // Mirrored delay line: each sample is stored twice, taps apart, so the
    // most recent 	aps samples are always contiguous at &delay_[head_]
    // (w[k] = x[now - k]) with no wrap-around indexing in the inner loop.
    head_ = head_ == 0 ? taps - 1 : head_ - 1;
    delay_[head_] = in[i];
    delay_[head_ + taps] = in[i];
    const bool compute = !odd_;
    odd_ = !odd_;
    if (!compute) continue;

    // Linear-phase FIR: h[k] == h[taps-1-k], so pair up the symmetric taps
    // and halve the multiplies.
    const float* w = &delay_[head_];
    float acc = h[half] * w[half];
    for (size_t k = 0; k < half; ++k) acc += h[k] * (w[k] + w[taps - 1 - k]);
    out[written++] = acc;
  }
  return written;
}

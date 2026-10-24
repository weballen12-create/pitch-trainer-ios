#pragma once

// In-place forward complex FFT over interleaved (re, im) float data.
//
// On the ESP32 this wraps esp-dsp's optimized radix-2 FFT. Everywhere else
// (native unit tests on the dev machine) it uses a plain iterative radix-2
// implementation. Both compute the same standard forward DFT:
//   X[k] = sum_n x[n] * exp(-2*pi*i*k*n/N), output in natural order.

#include <stddef.h>

class ComplexFft {
 public:
  ComplexFft() = default;
  ~ComplexFft();
  ComplexFft(const ComplexFft&) = delete;
  ComplexFft& operator=(const ComplexFft&) = delete;

  // n = number of complex points; must be a power of two.
  bool begin(size_t n);

  // Transforms data() in place.
  void forward();

  // Work buffer of 2 * size() floats (re, im interleaved), 16-byte aligned.
  float* data() { return data_; }
  size_t size() const { return n_; }

 private:
  size_t n_ = 0;
  float* data_ = nullptr;
  float* twiddles_ = nullptr;  // portable path only: n/2 (cos, -sin) pairs
};

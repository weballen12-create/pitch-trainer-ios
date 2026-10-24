#include "complex_fft.h"

#include <math.h>
#include <stdlib.h>

#if defined(ESP_PLATFORM)
#include "dsps_fft2r.h"
#include "esp_heap_caps.h"
#include "sdkconfig.h"
#endif

namespace {

bool isPowerOfTwo(size_t n) { return n >= 2 && (n & (n - 1)) == 0; }

float* allocAligned(size_t floats) {
#if defined(ESP_PLATFORM)
  return static_cast<float*>(heap_caps_aligned_alloc(16, floats * sizeof(float), MALLOC_CAP_8BIT));
#else
  return new float[floats];
#endif
}

void freeAligned(float* p) {
#if defined(ESP_PLATFORM)
  heap_caps_free(p);
#else
  delete[] p;
#endif
}

}  // namespace

ComplexFft::~ComplexFft() {
  freeAligned(data_);
  delete[] twiddles_;
}

bool ComplexFft::begin(size_t n) {
  if (data_ != nullptr || !isPowerOfTwo(n)) return false;
  n_ = n;
  data_ = allocAligned(2 * n);
  if (data_ == nullptr) return false;

#if defined(ESP_PLATFORM)
  if (n > CONFIG_DSP_MAX_FFT_SIZE) return false;
  // Allocates and fills esp-dsp's shared twiddle table (no-op if already done).
  return dsps_fft2r_init_fc32(nullptr, CONFIG_DSP_MAX_FFT_SIZE) == ESP_OK;
#else
  twiddles_ = new float[n];  // n/2 complex values
  for (size_t k = 0; k < n / 2; ++k) {
    const double angle = 2.0 * M_PI * static_cast<double>(k) / static_cast<double>(n);
    twiddles_[2 * k] = static_cast<float>(cos(angle));
    twiddles_[2 * k + 1] = static_cast<float>(-sin(angle));
  }
  return true;
#endif
}

void ComplexFft::forward() {
#if defined(ESP_PLATFORM)
  dsps_fft2r_fc32(data_, static_cast<int>(n_));
  dsps_bit_rev_fc32(data_, static_cast<int>(n_));
#else
  float* a = data_;
  const size_t n = n_;

  // Bit-reversal permutation.
  for (size_t i = 1, j = 0; i < n; ++i) {
    size_t bit = n >> 1;
    for (; j & bit; bit >>= 1) j ^= bit;
    j ^= bit;
    if (i < j) {
      float t = a[2 * i];
      a[2 * i] = a[2 * j];
      a[2 * j] = t;
      t = a[2 * i + 1];
      a[2 * i + 1] = a[2 * j + 1];
      a[2 * j + 1] = t;
    }
  }

  // Iterative radix-2 butterflies.
  for (size_t len = 2; len <= n; len <<= 1) {
    const size_t half = len / 2;
    const size_t step = n / len;
    for (size_t start = 0; start < n; start += len) {
      for (size_t k = 0; k < half; ++k) {
        const float wr = twiddles_[2 * k * step];
        const float wi = twiddles_[2 * k * step + 1];
        float* u = &a[2 * (start + k)];
        float* v = &a[2 * (start + k + half)];
        const float vr = v[0] * wr - v[1] * wi;
        const float vi = v[0] * wi + v[1] * wr;
        v[0] = u[0] - vr;
        v[1] = u[1] - vi;
        u[0] += vr;
        u[1] += vi;
      }
    }
  }
#endif
}

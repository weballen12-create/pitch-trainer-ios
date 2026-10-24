#include "mpm_pitch_detector.h"

#include <math.h>

namespace {

size_t ceilPow2(size_t v) {
  size_t p = 1;
  while (p < v) p <<= 1;
  return p;
}

}  // namespace

bool MpmPitchDetector::begin(size_t input_length) {
  if (input_length < 3 || input_length_ != 0) return false;
  input_length_ = input_length;
  // Zero-padding to >= 2x the input makes the FFT's circular autocorrelation
  // equal to the linear one for every lag.
  if (!fft_.begin(ceilPow2(2 * input_length))) return false;
  nsdf_.assign(input_length, 0.0f);
  // Key maxima are separated by zero crossings, so there are at most ~n/2.
  key_indices_.assign(input_length / 2 + 1, 0);
  return true;
}

PitchResult MpmPitchDetector::findPitch(const float* input, float sample_rate_hz) {
  if (belowMinimumVolume(input)) return {0.0f, 0.0f};
  computeNsdf(input);

  const size_t count = findKeyMaxima();
  // No key maxima: not enough data, or flawed data (e.g. all zeros).
  if (count == 0) return {0.0f, 0.0f};

  float n_max = -INFINITY;
  for (size_t j = 0; j < count; ++j) {
    const float v = nsdf_[key_indices_[j]];
    if (v > n_max) n_max = v;
  }

  // First key maximum >= k * n_max. Always exists (the one that gave n_max).
  size_t result_index = key_indices_[0];
  for (size_t j = 0; j < count; ++j) {
    if (nsdf_[key_indices_[j]] >= clarity_threshold_ * n_max) {
      result_index = key_indices_[j];
      break;
    }
  }

  // Parabolic interpolation through the peak and its neighbors (MPM paper
  // section 5), same closed form as pitchy. key maxima are always in
  // [1, n-2], so both neighbors exist.
  const double x0 = static_cast<double>(result_index) - 1.0;
  const double x1 = static_cast<double>(result_index);
  const double x2 = static_cast<double>(result_index) + 1.0;
  const double y0 = nsdf_[result_index - 1];
  const double y1 = nsdf_[result_index];
  const double y2 = nsdf_[result_index + 1];

  const double a = y0 / 2 - y1 + y2 / 2;
  const double b = -(y0 / 2) * (x1 + x2) + y1 * (x0 + x2) - (y2 / 2) * (x0 + x1);
  const double c = (y0 * x1 * x2) / 2 - y1 * x0 * x2 + (y2 * x0 * x1) / 2;

  double x_max = x1;
  double y_max = y1;
  if (a != 0.0) {
    x_max = -b / (2 * a);
    y_max = a * x_max * x_max + b * x_max + c;
  }

  // Floating-point error can push clarity slightly over 1.
  const double clarity = y_max < 1.0 ? y_max : 1.0;
  return {static_cast<float>(sample_rate_hz / x_max), static_cast<float>(clarity)};
}

bool MpmPitchDetector::belowMinimumVolume(const float* input) const {
  if (min_volume_rms_ == 0.0f) return false;
  // Float sum: over ~1000 samples its rounding error is far below anything
  // that matters for a volume threshold, and the ESP32 FPU is float-only.
  float square_sum = 0.0f;
  for (size_t i = 0; i < input_length_; ++i) square_sum += input[i] * input[i];
  return sqrtf(square_sum / input_length_) < min_volume_rms_;
}

void MpmPitchDetector::autocorrelate(const float* input) {
  float* buf = fft_.data();
  const size_t n = fft_.size();

  // Step 0: zero-padded real input as complex.
  for (size_t i = 0; i < n; ++i) {
    buf[2 * i] = i < input_length_ ? input[i] : 0.0f;
    buf[2 * i + 1] = 0.0f;
  }
  // Step 1: DFT.
  fft_.forward();
  // Step 2: power spectrum |X|^2 (real).
  for (size_t i = 0; i < n; ++i) {
    const float re = buf[2 * i];
    const float im = buf[2 * i + 1];
    buf[2 * i] = re * re + im * im;
    buf[2 * i + 1] = 0.0f;
  }
  // Step 3: inverse DFT. The power spectrum of a real signal is real and
  // even, so its inverse DFT equals its forward DFT divided by n — reuse the
  // forward transform rather than needing a separate inverse.
  fft_.forward();
  const float inv_n = 1.0f / static_cast<float>(n);
  for (size_t i = 0; i < input_length_; ++i) {
    nsdf_[i] = buf[2 * i] * inv_n;
  }
}

void MpmPitchDetector::computeNsdf(const float* input) {
  // NSDF, equation (9) of the MPM paper: n'(tau) = 2 r'(tau) / m'(tau).
  autocorrelate(input);
  // m'(0) = 2 r'(0); each next m' drops x[tau]^2 and x[W-1-tau]^2. m never
  // increases, so stop once it reaches 0 (or goes slightly negative through
  // rounding) and zero the rest, as pitchy does.
  //
  // pitchy keeps m in a JS double. The ESP32 FPU is float-only (double is
  // software-emulated and made this loop the main cost), so m is a float
  // with Kahan compensation, which keeps the running difference accurate to
  // about double precision at float speed.
  float m = 2.0f * nsdf_[0];
  float m_comp = 0.0f;  // Kahan compensation term
  size_t i = 0;
  for (; i < input_length_ && m > 0.0f; ++i) {
    nsdf_[i] = (2.0f * nsdf_[i]) / m;
    const float a = input[i];
    const float b = input[input_length_ - i - 1];
    const float y = -(a * a + b * b) - m_comp;
    const float t = m + y;
    m_comp = (t - m) - y;
    m = t;
  }
  for (; i < input_length_; ++i) nsdf_[i] = 0.0f;
}

size_t MpmPitchDetector::findKeyMaxima() {
  // A key maximum is the highest point between a positively sloped zero
  // crossing and the following negatively sloped one. A trailing positive
  // region with no closing crossing is not counted (same as pitchy).
  size_t count = 0;
  bool looking_for_max = false;
  float max = -INFINITY;
  long max_index = -1;

  for (size_t i = 1; i + 1 < input_length_; ++i) {
    const float prev = nsdf_[i - 1];
    const float cur = nsdf_[i];
    if (prev <= 0 && cur > 0) {
      looking_for_max = true;
      max_index = static_cast<long>(i);
      max = cur;
    } else if (prev > 0 && cur <= 0) {
      looking_for_max = false;
      if (max_index != -1 && count < key_indices_.size()) {
        key_indices_[count++] = static_cast<uint32_t>(max_index);
      }
    } else if (looking_for_max && cur > max) {
      max = cur;
      max_index = static_cast<long>(i);
    }
  }
  return count;
}

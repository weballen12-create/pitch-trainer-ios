#pragma once

// Sliding window over the most recent `length` samples.
//
// Small tap chunks are pushed in as they arrive from capture; the pitch
// detector then runs over the whole window after each push. Same shift-left-
// and-append scheme as the prototype's pushSamples().

#include <stddef.h>
#include <string.h>

#include <vector>

class AnalysisWindow {
 public:
  void begin(size_t length) {
    buf_.assign(length, 0.0f);
    filled_ = 0;
  }

  void reset() {
    for (float& v : buf_) v = 0.0f;
    filled_ = 0;
  }

  void push(const float* samples, size_t n) {
    const size_t len = buf_.size();
    if (n >= len) {
      memcpy(buf_.data(), samples + (n - len), len * sizeof(float));
    } else {
      memmove(buf_.data(), buf_.data() + n, (len - n) * sizeof(float));
      memcpy(buf_.data() + (len - n), samples, n * sizeof(float));
    }
    filled_ = filled_ + n < len ? filled_ + n : len;
  }

  // True once every slot holds real audio (no startup zeros).
  bool isFull() const { return filled_ == buf_.size(); }

  size_t length() const { return buf_.size(); }
  const float* data() const { return buf_.data(); }

  // Copies the window into out (length() floats) with its mean removed and
  // returns that mean. The SPH0645 has a DC offset; left in, it biases the
  // autocorrelation positive and can erase the zero crossings MPM relies on.
  float copyDcRemoved(float* out) const {
    const size_t len = buf_.size();
    // Float sum (the ESP32 FPU is float-only; rounding error over ~1000
    // samples is negligible for a mean).
    float sum = 0.0f;
    for (size_t i = 0; i < len; ++i) sum += buf_[i];
    const float mean = sum / len;
    for (size_t i = 0; i < len; ++i) out[i] = buf_[i] - mean;
    return mean;
  }

 private:
  std::vector<float> buf_;
  size_t filled_ = 0;
};

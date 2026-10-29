// Tunables for the phone app's latency work. Change them here; nothing else in the engine hard-codes these.
// Sample counts are at the 48 kHz input rate unless noted. The analysis itself runs at 24 kHz (2:1 decimation).
#pragma once

#include <stdint.h>

// ---- analysis window and hop -------------------------------------------------------------------------------
constexpr uint32_t kPhWindowSamples = 1024;  // 21.3 ms. Needs ~2 periods: lowest reliable note is about 94 Hz.
constexpr uint32_t kPhHopSamples = 256;      // the detector runs every hop (5.3 ms), not once per callback

// ---- found / lost gate (asymmetric) ------------------------------------------------------------------------
constexpr float kPhStartClarity = 0.85f;     // ONE window at or above this (and in range, and loud enough) starts "found"
constexpr float kPhStayClarity = 0.60f;      // while found, windows at or above this keep it
constexpr float kPhMinHz = 75.0f;            // valid pitch range
constexpr float kPhMaxHz = 1500.0f;
constexpr uint32_t kPhLostHoldMs = 100;      // "lost" only after this long without a stay-valid window

// ---- tone shape ---------------------------------------------------------------------------------------------
constexpr float kPhAttackMs = 0.0f;          // fade-in: 0 = the tone starts at full level on its first sample (the phase
                                             // restarts at zero, so it starts on a zero crossing; a hard start may still tick)
constexpr float kPhFadeOutMs = 10.0f;        // fade-out once the tone is released
constexpr float kPhGlideMs = 0.0f;           // 0 = no smoothing: a new note is the new frequency on the next sample
constexpr uint32_t kPhReleaseMs = 120;       // tracker release hold (adjustable on screen)

// ---- audio I/O ----------------------------------------------------------------------------------------------
constexpr uint32_t kPhIoPeriodFrames = 256;  // REQUESTED period. The callback's real frame count is always used.
constexpr double kPhIoBufferSeconds = 0.005; // requested AVAudioSession IO buffer; the granted value is logged

// ---- latency probe ------------------------------------------------------------------------------------------
constexpr uint32_t kPhProbeBlock = 64;       // input level is checked in 64-sample blocks (1.3 ms)
constexpr float kPhOnsetDb = -45.0f;         // input level that counts as a note onset (mean-square, dBFS)
constexpr float kPhQuietDb = -55.0f;         // input must stay below this for kPhQuietMs before the next onset counts
constexpr uint32_t kPhQuietMs = 100;
constexpr uint32_t kPhProbeTimeoutMs = 1000; // give up on a measurement if no tone appears within this

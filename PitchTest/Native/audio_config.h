#pragma once

#include <stdint.h>

// ---- Stage 1: mic capture -----------------------------------------------

// Mic capture rate. SPH0645 datasheet: BCLK 2.048-4.096 MHz (3.072 typ),
// i.e. 32-64 kHz with 64 BCLK per frame. 48 kHz = 3.072 MHz, the datasheet's
// own test condition, mid-range — so the ESP32's fractional clock divider
// jitter can't push individual BCLK periods out of spec (32 kHz would sit
// exactly on the 2.048 MHz minimum). Below ~900 kHz the mic sleeps.
constexpr uint32_t kMicSampleRateHz = 48000;

// Tap chunk: frames per DMA buffer, i.e. per MicCapture::read().
// 480 frames @ 48 kHz = 10 ms — the granularity at which new audio becomes
// available (target was 8-16 ms). This is NOT the pitch analysis window;
// that is a separate, larger sliding buffer (Stage 2).
constexpr uint32_t kMicChunkFrames = 480;

// DMA descriptors (ring of chunk-sized buffers). 4 x 10 ms = 40 ms of slack
// before the driver starts dropping data if the loop stalls.
constexpr uint32_t kMicDmaDescNum = 4;

// SPH0645 power-up time is up to 50 ms (datasheet); discard this much audio
// after starting the clocks so the first readings aren't garbage.
constexpr uint32_t kMicStartupDiscardMs = 60;

// Which I2S slot carries the mic. SEL=GND -> mic drives the slot where WS is
// low (the "left" slot). If Stage 1 shows the signal on R instead (slot order
// on the ESP32 differs from expectation), set this to true — no other change.
constexpr bool kMicUseRightSlot = false;

// Stage 1 only: how often aggregated signal stats are printed to serial.
constexpr uint32_t kStatsReportIntervalMs = 250;

// ---- Stage 2: pitch detection -------------------------------------------

// The detector runs at half the capture rate: 48 kHz is low-pass filtered
// and decimated 2:1 (lib/decimator). 24 kHz keeps the analysis window within
// esp-dsp's 4096-point FFT limit; Nyquist 12 kHz is far above any sung
// fundamental.
constexpr uint32_t kDecimationFactor = 2;
constexpr uint32_t kAnalysisSampleRateHz = kMicSampleRateHz / kDecimationFactor;
constexpr uint32_t kAnalysisChunkFrames = kMicChunkFrames / kDecimationFactor;

// Decimation filter: Blackman-windowed sinc, 63 taps, -6 dB at 7 kHz.
// Stopband (>= ~70 dB) starts below 12 kHz, so nothing aliases into the
// analysed band; group delay is 31 samples @ 48 kHz = 0.65 ms.
constexpr uint32_t kDecimatorTaps = 63;
constexpr float kDecimatorCutoffHz = 7000.0f;

// Lowest note the detector must lock onto: G2 (decided 2026-10-14, D57; the
// singer's real floor). Was C2 = 65.406 Hz (decided 2026-09-26): change this
// one constant back to restore the 1101-sample window and the old floor.
constexpr float kLowestNoteHz = 97.999f;

// Periods of the lowest note the analysis window must span (2-3 needed to
// lock reliably; 3 for margin).
constexpr float kAnalysisPeriods = 3.0f;

// Sliding analysis window: 3 periods of G2 @ 24 kHz = 735 samples (30.6 ms)
// (C2 would be 1101 samples, 45.9 ms).
// The detector re-runs over this whole window after every tap chunk.
constexpr uint32_t kAnalysisWindowFrames =
    static_cast<uint32_t>(kAnalysisPeriods * kAnalysisSampleRateHz / kLowestNoteHz) + 1;

// MPM constant k (pitchy's clarityThreshold; pitchy default 0.9, which the
// prototype used).
constexpr float kMpmK = 0.9f;

// A reading counts as a real sung pitch only at or above this clarity.
// Prototype value.
constexpr float kMinValidClarity = 0.85f;

// ...and only inside this frequency range: the lowest note (accepted up to
// ~35 c flat) up to F6. Rejects confident-but-useless readings (e.g. a
// two-tone mixture's common period, sub-audio periodicities, vocal-fry
// octave-down blips) that would retarget the tone to a note outside the
// range the device is built for. 0.98 = 35 c below the lowest note.
// History: B1 (61.7 Hz) was raised to 64 Hz for C2 after junk readings at
// 61.9 and 63.3 Hz slipped through on hardware (Stage 5). (D23, D57)
constexpr float kMinValidPitchHz = kLowestNoteHz * 0.98f;
constexpr float kMaxValidPitchHz = 1396.91f;  // F6

// RMS gate (window scaled to [-1, 1)); below it, no pitch is reported.
// Starts at the prototype's value: pitchy minVolumeDecibels = -45, which
// pitchy converts as 10^(-45/10) = 3.16e-5 (about -90 dBFS RMS — at the
// SPH0645's own noise floor, so effectively OFF).
//
// MUST be calibrated in Stage 4: with the reference tone playing and the
// singer silent, the mic hears the tone itself; unless this gate is above
// that level, the detector reads the tone as "singing", the target never
// releases, and the tone sustains itself forever. Set it ~6 dB above the
// silent-with-tone `rms` from Stage 4:  kMinVolumeRms = 10^(dBFS / 20).
// Calibrated 2026-10-14 (D20/D40): silent-with-tone -60.6 dBFS (Stage 4,
// tone -20 dBFS), singing -28 dBFS at 340 Hz and -40 dBFS at 169 Hz at the
// cheek; set to -56 dBFS (was -50, too high for low notes).
constexpr float kMinVolumeRms = 1.5849e-3f;

// Stage 2 only: serial print interval for the latest pitch reading.
constexpr uint32_t kPitchReportIntervalMs = 100;

// ---- Stage 3: amp / reference tone ----------------------------------------

// Amp sample rate. The MAX98357A only accepts LRCLK of 8/16/32/44.1/48/88.2/
// 96 kHz — the datasheet explicitly lists 24 kHz as NOT supported. Runs on
// its own I2S peripheral, independent of the mic.
constexpr uint32_t kAmpSampleRateHz = 48000;

// TX DMA: 128 frames (2.67 ms) x 4 buffers = 10.7 ms of queued audio. That
// queue length is the delay between a target change and hearing it.
constexpr uint32_t kAmpDmaFrameNum = 128;
constexpr uint32_t kAmpDmaDescNum = 4;

// Fade in/out time for tone start/stop (avoids clicks).
constexpr float kToneFadeMs = 10.0f;

// Starting tone gain (fraction of digital full scale). Deliberately quiet:
// at 9 dB amp gain, full scale is ~3.6 V RMS (clipped by the battery), far
// too loud against a cheek. 0.1 = -20 dBFS (D73; was 0.05 = -26 dBFS, set for
// the 8 ohm speaker, raised for the 4 ohm exciter). Adjust at runtime with
// +/-, capped at 0.25 = -12 dBFS for hearing safety.
constexpr float kToneDefaultGain = 0.1f;
constexpr float kToneMaxGain = 0.25f;

// Tone task: core 0 keeps it off the Arduino loop's core (1), where capture
// and detection run. Priority above the loop so the amp is always fed.
constexpr int kToneTaskCore = 0;
constexpr unsigned kToneTaskPriority = 5;

// ---- Stage 5: target note / key lock -------------------------------------

// The voice must go this far past the midpoint between the current target
// and another in-key note before the target switches (anti-flicker).
// 25 c flickered when hovering at a boundary (natural voice wobble ~±35 c,
// Stage 5 hover test). The user chose a moderate widening plus a very short
// hold over a long hold (D39).
constexpr float kTargetHysteresisCents = 15.0f;  // was 35; 15 for all notes, chosen by the user after trying it chromatic (D75)

// ...and stay past it, toward the same new note, for this long (filters
// one-reading spikes). ~3 readings at 10 ms each. 0 = no hold. (D39)
constexpr uint32_t kTargetSwitchHoldMs = 30;

// The switch hold applies only to jumps of at most this many semitones from
// the current target; larger jumps switch at once (still past the margin).
// A half-step boundary (E/F, B/C) is only 50 c from either note, so hovering
// there is plausible; a whole-step boundary is 100 c from each note. 0 = the
// hold applies to every jump (old behaviour). (D57)
constexpr int kTargetHoldMaxJumpSemitones = 1;

// Vocal fry (D41): a valid reading about one octave below the previous
// accepted reading is ignored unless it lasts this long. Octave leaps keep
// the same played pitch class (D54), so the delay on a real octave-down leap
// is inaudible. 0 = off.
constexpr uint32_t kTargetOctaveDownHoldMs = 100;

// Release the target (tone fades out) after this long with no valid pitch.
// Short gaps like breaths keep the tone. 0 = never release.
// 150 ms (was 1000; D38): the singer found the tone lingered too long after
// stopping. Short gaps (consonants, fast breaths) may now cut the tone.
// 15 ms (D76, user choice): about one reading gap; breaths and consonants cut the tone at once.
constexpr uint32_t kTargetReleaseMs = 15;

// Reference tones for targets below this play whole octaves higher until
// they reach it (the target note itself is unchanged). The current speaker
// buzzes badly at the cheek on low notes (Stage 3); the user chose "at least
// 400ish Hz for now". 0 disables the shift. See D54.
constexpr float kReferenceRaiseBelowHz = 400.0f;

// Switchable reference mapping (D58, trial; keys 'o' = next mode, 'b' = next
// floor in Stage 5). Mode index: 0 Octave (the D54 rule above),
// 1 Shift (constant octave offset, default: +0 = the target's true pitch, D64).
// Octave raises to at least the floor.
constexpr int kReferenceModeDefault = 1;
// Floors the 'b' key steps through (Hz), low to high: raise one if a low
// reference buzzes. Octave starts at kReferenceRaiseBelowHz and steps up
// from there (wrapping to the first entry).
constexpr float kReferenceFloorsHz[] = {130.0f, 165.0f, 200.0f, 260.0f, 330.0f, 400.0f};
constexpr int kReferenceFloorCount = sizeof(kReferenceFloorsHz) / sizeof(kReferenceFloorsHz[0]);

// ---- compile-time checks ---------------------------------------------------

// ESP-IDF limit: one DMA buffer must be <= 4092 bytes.
// Capture runs in stereo (2 slots) x 32-bit words.
static_assert(kMicChunkFrames * 2 * sizeof(int32_t) <= 4092,
              "DMA buffer exceeds ESP-IDF 4092-byte limit");
// Amp: stereo x 16-bit.
static_assert(kAmpDmaFrameNum * 2 * sizeof(int16_t) <= 4092,
              "DMA buffer exceeds ESP-IDF 4092-byte limit");
static_assert(kMicChunkFrames % kDecimationFactor == 0, "chunk must decimate evenly");
static_assert(kMicSampleRateHz >= 32000 && kMicSampleRateHz <= 64000,
              "SPH0645 supports 32-64 kHz only (BCLK 2.048-4.096 MHz)");

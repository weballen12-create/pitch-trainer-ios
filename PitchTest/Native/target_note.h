#pragma once

// Target-note selection: snap a detected pitch to the nearest note of the
// selected key, with hysteresis so a voice sitting near the boundary between
// two in-key notes doesn't make the target flicker.
//
// Works in (fractional) MIDI note numbers; see note_utils for Hz <-> MIDI.
// Pure logic, no hardware or timing dependencies (time is passed in).

#include <stdint.h>

struct MusicalKey {
  const char* name;
  int tonic_pitch_class;  // 0 = C, 1 = C#, ... 11 = B
  uint16_t scale_mask;    // bit n set = (tonic + n semitones) is in the scale
};

// Major scale: whole, whole, half, whole, whole, whole, half.
constexpr uint16_t kMajorScaleMask =
    (1u << 0) | (1u << 2) | (1u << 4) | (1u << 5) | (1u << 7) | (1u << 9) | (1u << 11);

constexpr MusicalKey kKeyCMajor = {"C major", 0, kMajorScaleMask};
constexpr MusicalKey kKeyGMajor = {"G major", 7, kMajorScaleMask};
constexpr MusicalKey kKeyFMajor = {"F major", 5, kMajorScaleMask};

// Any of the 12 major keys, by tonic pitch class (0 = C ... 11 = B). Flat names for the flat keys.
inline MusicalKey majorKey(int tonic) {
  static const char* const kNames[12] = {"C major", "Db major", "D major", "Eb major", "E major", "F major",
                                         "F# major", "G major", "Ab major", "A major", "Bb major", "B major"};
  const int t = ((tonic % 12) + 12) % 12;
  return {kNames[t], t, kMajorScaleMask};
}

bool isInKey(int midi, const MusicalKey& key);

// Nearest in-key MIDI note to exact_midi. An exact tie goes to the lower note.
int nearestInKeyMidi(float exact_midi, const MusicalKey& key);

class TargetNoteTracker {
 public:
  struct Config {
    // How far past the midpoint between the current target and a different
    // in-key note the voice must go before the target switches, in cents.
    float hysteresis_cents;
    // After this long with no valid reading the target is released (tone
    // stops). 0 = hold the last target indefinitely.
    uint32_t release_ms;
    // A switch only happens once the voice has stayed past the margin, toward
    // the same new note, for this long. Filters one-reading spikes. 0 =
    // switch on the first qualifying reading.
    uint32_t switch_hold_ms;
    // Vocal-fry filter (D41): a reading about one octave below the previous
    // accepted reading (within 50 c) is ignored unless it persists this long.
    // A real octave-down leap is accepted after this delay; the reference
    // tone does not change for an octave leap (same pitch class, D54), so
    // the delay is inaudible. 0 = off (every valid reading counts).
    uint32_t octave_down_hold_ms = 0;
    // switch_hold_ms applies only when the candidate is at most this many
    // semitones from the current target; bigger jumps switch immediately
    // (the margin still applies). 0 = the hold applies to every jump.
    int hold_max_jump_semitones = 0;
    // Hysteresis used instead of hysteresis_cents while chromatic mode is on
    // (D74), so the target follows half-step movement faster.
    float chromatic_hysteresis_cents = 15.0f;
  };

  void begin(const Config& config, const MusicalKey& key);

  // Changing key drops the current target; the next valid reading picks a
  // fresh one in the new key.
  void setKey(const MusicalKey& key);
  const MusicalKey& key() const { return key_; }

  // Chromatic mode (D74, the Accidental button): snap to all 12 semitones
  // instead of the key's notes, with chromatic_hysteresis_cents. Turning it
  // off drops a target that is not in the key; the next reading picks again.
  void setChromatic(bool on);
  bool chromatic() const { return chromatic_; }

  // Change the release hold at run time (D77).
  void setReleaseMs(uint32_t ms) { config_.release_ms = ms; }
  uint32_t releaseMs() const { return config_.release_ms; }

  // Call once per detection result. valid = reading passed the clarity
  // threshold; exact_midi is ignored when !valid.
  void update(bool valid, float exact_midi, uint32_t now_ms);

  bool hasTarget() const { return has_target_; }
  int targetMidi() const { return target_midi_; }

 private:
  Config config_{};
  MusicalKey key_ = kKeyCMajor;
  bool chromatic_ = false;
  bool has_target_ = false;
  int target_midi_ = 0;
  uint32_t last_valid_ms_ = 0;
  float last_accepted_midi_ = 0.0f;   // exact pitch of the last accepted reading
  uint32_t last_accepted_ms_ = 0;
  bool octave_down_pending_ = false;  // an octave-down reading is waiting out its hold
  uint32_t octave_down_since_ms_ = 0;
  bool pending_ = false;       // a qualifying switch is waiting out the hold
  int pending_midi_ = 0;
  uint32_t pending_since_ms_ = 0;
};

#include "target_note.h"

#include <math.h>

bool isInKey(int midi, const MusicalKey& key) {
  const int degree = (((midi - key.tonic_pitch_class) % 12) + 12) % 12;
  return (key.scale_mask >> degree) & 1u;
}

int nearestInKeyMidi(float exact_midi, const MusicalKey& key) {
  // Closest in-key note at or below, and strictly above, exact_midi. Any
  // non-empty scale mask guarantees each search ends within 12 steps.
  int below = static_cast<int>(floorf(exact_midi));
  while (!isInKey(below, key)) --below;
  int above = static_cast<int>(floorf(exact_midi)) + 1;
  while (!isInKey(above, key)) ++above;
  return (exact_midi - below) <= (above - exact_midi) ? below : above;
}

void TargetNoteTracker::begin(const Config& config, const MusicalKey& key) {
  config_ = config;
  key_ = key;
  has_target_ = false;
}

void TargetNoteTracker::setKey(const MusicalKey& key) {
  key_ = key;
  has_target_ = false;
  pending_ = false;
  octave_down_pending_ = false;
}

void TargetNoteTracker::setChromatic(bool on) {
  if (on == chromatic_) return;
  chromatic_ = on;
  pending_ = false;
  if (!on && has_target_ && !isInKey(target_midi_, key_)) has_target_ = false;
}

void TargetNoteTracker::update(bool valid, float exact_midi, uint32_t now_ms) {
  if (!valid) {
    pending_ = false;
    octave_down_pending_ = false;
    if (has_target_ && config_.release_ms > 0 && now_ms - last_valid_ms_ >= config_.release_ms) {
      has_target_ = false;
    }
    return;
  }

  // Vocal fry reads one octave below the sung note for a reading or two.
  // Ignore such a reading unless it persists (D41). Only applies against a
  // recently accepted reading, so a fresh start or a long gap is not delayed.
  constexpr uint32_t kOctaveDownLookbackMs = 250;
  constexpr float kOctaveDownToleranceSemitones = 0.5f;
  const bool octave_down = has_target_ && config_.octave_down_hold_ms > 0 &&
                           now_ms - last_accepted_ms_ <= kOctaveDownLookbackMs &&
                           fabsf(exact_midi - (last_accepted_midi_ - 12.0f)) <= kOctaveDownToleranceSemitones;
  if (octave_down) {
    if (!octave_down_pending_) {
      octave_down_pending_ = true;
      octave_down_since_ms_ = now_ms;
    }
    if (now_ms - octave_down_since_ms_ < config_.octave_down_hold_ms) return;  // ignored for now
  }
  octave_down_pending_ = false;
  last_valid_ms_ = now_ms;
  last_accepted_midi_ = exact_midi;
  last_accepted_ms_ = now_ms;

  static const MusicalKey kAllNotes = {"chromatic", 0, 0x0FFF};
  const int candidate = nearestInKeyMidi(exact_midi, chromatic_ ? kAllNotes : key_);
  if (!has_target_) {
    // First target (or after release): no previous note to hold against.
    target_midi_ = candidate;
    has_target_ = true;
    pending_ = false;
    return;
  }
  if (candidate == target_midi_) {
    pending_ = false;
    return;
  }

  // Distance past the midpoint between the current target and the candidate:
  // (|m - T| - |m - C|) / 2 semitones, i.e. * 50 in cents. Zero exactly at
  // the midpoint, growing as the voice moves toward the candidate.
  const float past_midpoint_cents =
      (fabsf(exact_midi - target_midi_) - fabsf(exact_midi - candidate)) * 50.0f;
  const float hysteresis = chromatic_ ? config_.chromatic_hysteresis_cents : config_.hysteresis_cents;
  if (past_midpoint_cents < hysteresis) {
    pending_ = false;
    return;
  }

  // Past the margin. Switch once it has stayed past it, toward this same
  // note, for switch_hold_ms (a different candidate restarts the hold).
  if (!pending_ || pending_midi_ != candidate) {
    pending_ = true;
    pending_midi_ = candidate;
    pending_since_ms_ = now_ms;
  }
  // Large jumps are far from any boundary: no hold.
  const int jump = candidate > target_midi_ ? candidate - target_midi_ : target_midi_ - candidate;
  const uint32_t hold = (config_.hold_max_jump_semitones > 0 && jump > config_.hold_max_jump_semitones)
                            ? 0
                            : config_.switch_hold_ms;
  if (now_ms - pending_since_ms_ >= hold) {
    target_midi_ = candidate;
    pending_ = false;
  }
}

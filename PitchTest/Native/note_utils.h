#pragma once

// Frequency <-> MIDI note helpers (A4 = 440 Hz = MIDI 69, 12-TET).
// Ported from the prototype's src/lib/pitch/note-utils.ts (tag expo-prototype).

#include <stddef.h>

struct PitchDescription {
  float frequency_hz;
  float exact_midi;   // fractional MIDI note number
  int nearest_midi;   // nearest whole semitone
  float cents_off;    // deviation from nearest_midi, -50..+50
};

float frequencyToMidi(float frequency_hz);
float midiToFrequency(float midi);

// Writes e.g. "C#4" into out (needs >= 5 bytes; 8 is always enough).
void midiToNoteName(int midi, char* out, size_t out_len);

PitchDescription describePitch(float frequency_hz);

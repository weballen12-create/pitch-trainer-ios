#include "note_utils.h"

#include <math.h>
#include <stdio.h>

namespace {
const char* const kNoteNames[12] = {"C", "C#", "D", "D#", "E", "F",
                                    "F#", "G", "G#", "A", "A#", "B"};
}  // namespace

float frequencyToMidi(float frequency_hz) {
  return 69.0f + 12.0f * log2f(frequency_hz / 440.0f);
}

float midiToFrequency(float midi) { return 440.0f * powf(2.0f, (midi - 69.0f) / 12.0f); }

void midiToNoteName(int midi, char* out, size_t out_len) {
  // Floor division so negative MIDI numbers still map correctly.
  const int octave = (midi >= 0 ? midi / 12 : (midi - 11) / 12) - 1;
  const int pitch_class = ((midi % 12) + 12) % 12;
  snprintf(out, out_len, "%s%d", kNoteNames[pitch_class], octave);
}

PitchDescription describePitch(float frequency_hz) {
  const float exact_midi = frequencyToMidi(frequency_hz);
  const int nearest_midi = static_cast<int>(lroundf(exact_midi));
  return {frequency_hz, exact_midi, nearest_midi, (exact_midi - nearest_midi) * 100.0f};
}

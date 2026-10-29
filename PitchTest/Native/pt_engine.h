// C interface to the pitch trainer engine, called from Swift. Same pipeline as the board and the Windows test:
// mic -> decimate 48k->24k -> MPM pitch -> snap to key -> sine to the output.
#pragma once

#ifdef __cplusplus
extern "C" {
#endif

typedef struct {
  float hz;            // detected pitch (0 if none)
  float cents;         // distance from the target note, cents
  float rms;           // mic level of the analysis window, full scale = 1
  float clarity;       // detector clarity of the last window
  float gain_db;       // tone level, dBFS
  int valid;           // "found": the gate is on
  int target;          // target MIDI note, -1 if none
  int muted;
  int chromatic;
  int tonic;
  int key_slot;        // 0..11, chromatic from A
  unsigned release_ms; // how long the tone keeps going after the voice drops out
  unsigned det_last_us;
  unsigned det_avg_us;
  unsigned det_max_us;
  unsigned chunk_max_us;
  unsigned long long over_budget;   // callbacks whose processing took longer than the callback period
  unsigned long long chunks;        // detector runs
  float in_buf_ms;     // miniaudio buffer capacity (period x periods). NOT a latency.
  float out_buf_ms;
  int rec_on;                       // recording is running
  float rec_seconds;                // audio written so far
  unsigned long long rec_dropped;   // samples lost because the disk writer fell behind (should stay 0)
  float window_ms;     // analysis window length
  float hop_ms;        // time between detector runs

  // ---- diagnostics (since Start) ----
  unsigned long long valid_n, invalid_n;      // detector runs with / without a usable pitch
  unsigned long long flips;                   // found <-> lost changes
  unsigned long long target_changes;          // target note changes (incl. appearing/vanishing)
  unsigned long long tone_on_events, tone_off_events;   // tone audible <-> silent changes
  float rms_db_tone_on, rms_db_tone_off;      // average mic level while the tone was / was not playing
  unsigned long long cb_count;                // audio callbacks
  unsigned cb_frames_min, cb_frames_max;      // frames per callback
  float cb_gap_max_ms;                        // longest time between two callbacks
  unsigned long long cb_late;                 // callbacks more than 1.5x the expected spacing after the last
  int leak_state;                             // 0 idle, 1 measuring tone OFF, 2 measuring tone ON, 3 done
  float leak_off_db, leak_on_db;              // mic level in each phase of the leak test (dBFS)

  // ---- latency probe: onset -> found -> tone, in the engine's own sample clock ----
  unsigned long long lat_n;                   // completed measurements
  unsigned long long lat_missed;              // onsets where no tone appeared in time (muted, or no pitch)
  float lat_of_last_ms, lat_ft_last_ms;       // onset->found, found->tone (last)
  float lat_of_avg_ms, lat_ft_avg_ms;         // averages
  float lat_of_max_ms, lat_ft_max_ms;

  char target_name[8];
  char key_name[16];
  char device_in[64];
  char device_out[64];
} PtStatus;

int pt_start(void);                 // 0 = running; otherwise see pt_error()
void pt_stop(void);
const char* pt_error(void);
void pt_set_muted(int muted);
void pt_gain_step(int up);          // 3 dB step, capped
void pt_set_key_slot(int slot);     // 0..11
void pt_set_chromatic(int on);
void pt_set_tonic(int on);
void pt_release_step(int up);       // release hold +/- 15 ms (15..600)
void pt_leak_test(void);            // stay silent: 2 s tone off, then 2 s of a 440 Hz tone at the current level
void pt_reset_metrics(void);
int pt_record_start(const char* base_path);   // writes <base>.wav (raw mic, 16-bit mono 48 kHz) and <base>.csv (one row per detector run); 0 = ok
void pt_record_stop(void);
double pt_io_buffer_seconds(void);   // the IO buffer duration the app asks iOS for (phone_tuning.h)
void pt_get_status(PtStatus* out);
int pt_event(int index, char* buf, int len);   // recent events, 0 = newest; returns 0 if none

#ifdef __cplusplus
}
#endif

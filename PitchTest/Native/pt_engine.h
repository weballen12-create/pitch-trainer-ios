// C interface to the pitch trainer engine, called from Swift. Same pipeline as the board and the Windows test:
// mic -> decimate 48k->24k -> MPM pitch -> snap to key -> sine to the output.
#pragma once

#ifdef __cplusplus
extern "C" {
#endif

typedef struct {
  float hz;            // detected pitch (0 if none)
  float cents;         // distance from the target note, cents
  float rms;
  float gain_db;       // tone level, dBFS
  int valid;           // a pitch was found in this window
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
  unsigned long long over_budget;   // 10 ms chunks that took longer than 10 ms
  unsigned long long chunks;
  float in_buf_ms;     // device buffers Windows/iOS report
  float out_buf_ms;
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
void pt_get_status(PtStatus* out);

#ifdef __cplusplus
}
#endif

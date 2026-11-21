// C API over the shared core for the Swift app: plain C, opaque handles and POD structs only.
// No C++ types or exceptions cross this boundary.
#ifndef NMR_COREC_H
#define NMR_COREC_H

#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// Version from config/product.env, e.g. "1.0.0". Static storage.
const char* nmr_version(void);
// Product display name, e.g. "NEMURA Stereometer". Static storage.
const char* nmr_product_name(void);

// ---- System-output capture probe -------------------------------------------------------------
// Captures the system output through a process tap for a while and reports what arrived. Used to
// verify that the audio-capture permission is granted (a denied grant yields only zeros).

typedef struct nmr_tap_probe_result {
  int32_t status;           // 0 if the tap started; otherwise the OSStatus of failed_step
  const char* failed_step;  // static string; "" on success
  double start_seconds;     // time to create and start the tap (includes a permission prompt)
  double sample_rate;
  uint32_t channels;
  bool interleaved;
  uint64_t io_cycles;          // IO proc calls
  uint64_t skipped_cycles;     // IO proc calls with an unexpected buffer layout
  uint64_t frames;             // frames read back from the ring
  uint64_t nonzero_frames;     // frames with at least one non-zero sample
  uint64_t lapped_frames;      // frames lost because the reader fell behind
  uint64_t nonfinite_samples;  // NaN/Inf samples (dropped from peak/rms)
  float peak;                  // max |sample|
  float rms;
} nmr_tap_probe_result;

// Blocks the calling thread (not the main thread of a running UI) for about `seconds` plus the
// tap start time. Returns true if the tap started; `result` is filled either way.
bool nmr_tap_probe_run(double seconds, nmr_tap_probe_result* result);

// ---- Rendering --------------------------------------------------------------------------------

// Creates the meter view (an NSView*, returned retained: +1) of the given size in points.
// `rgba` is the premultiplied background color; alpha 0 is fully transparent. Main thread only.
void* nmr_render_view_create(double width, double height, const float rgba[4]);

#ifdef __cplusplus
}  // extern "C"
#endif

#endif  // NMR_COREC_H

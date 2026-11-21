// C API over the shared core for the Swift app: plain C, opaque handles and POD structs only.
// No C++ types or exceptions cross this boundary; running out of memory gives NULL, false or
// ENOMEM, as each call says.
#ifndef NMR_COREC_H
#define NMR_COREC_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// Version from config/product.env, e.g. "1.0.0". Static storage.
const char* nmr_version(void);
// Product display name, e.g. "NEMURA Stereometer". Static storage.
const char* nmr_product_name(void);

// ---- Settings schema ---------------------------------------------------------------------------
// The shared settings schema (Sources/Core/include/nmr/settings.h): every setting with its key,
// type, range, default, group and label, in a fixed order. Strings are static NUL-terminated
// UTF-8. Indexes out of range give false or NULL.

typedef enum nmr_setting_type {
  NMR_SETTING_BOOL,
  NMR_SETTING_INT,
  NMR_SETTING_FLOAT,
  NMR_SETTING_CHOICE,
  NMR_SETTING_COLOR,  // 0xRRGGBBAA
  NMR_SETTING_TEXT,
} nmr_setting_type;

typedef enum nmr_setting_scope {
  NMR_SCOPE_SHARED,  // the app and the plugin
  NMR_SCOPE_APP,
  NMR_SCOPE_PLUGIN,
} nmr_setting_scope;

typedef struct nmr_setting_spec {
  const char* key;  // stable JSON key, snake_case
  const char* label;
  const char* unit;  // "" when unitless
  uint32_t group;    // for nmr_settings_group_key / _label
  nmr_setting_type type;
  nmr_setting_scope scope;
  bool preset;  // stored in presets
  double min;   // int and float; choice 0 ... count - 1; color 0 ... 0xFFFFFFFF
  double max;
  double step;           // the UI's step
  double default_value;  // bool 0/1, choice index, color 0xRRGGBBAA
  const char* default_text;  // text
  uint32_t max_length;       // text: bytes of UTF-8
  uint32_t choice_count;
  uint32_t stop_count;  // named values (the trail time's response presets)
} nmr_setting_spec;

uint32_t nmr_settings_count(void);
bool nmr_settings_spec(uint32_t index, nmr_setting_spec* spec);
// Choice `choice` of entry `index`.
const char* nmr_settings_choice_key(uint32_t index, uint32_t choice);
const char* nmr_settings_choice_label(uint32_t index, uint32_t choice);
// Named value `stop` of entry `index`.
bool nmr_settings_stop(uint32_t index, uint32_t stop, const char** label, double* value);

uint32_t nmr_settings_group_count(void);
const char* nmr_settings_group_key(uint32_t group);
const char* nmr_settings_group_label(uint32_t group);

// The index of the entry with this key, or -1.
int32_t nmr_settings_index(const char* key);

// ---- Setting values ----------------------------------------------------------------------------
// A value for every schema entry, addressed by index, each kept valid: setters clamp, round or
// refuse what they are given. Any number of threads may read a handle at once; changing or
// destroying it needs exclusive access.

typedef struct nmr_settings nmr_settings;

typedef enum nmr_change {
  NMR_CHANGE_SET,       // taken as given
  NMR_CHANGE_ADJUSTED,  // clamped into the range or rounded to an integer
  NMR_CHANGE_REJECTED,  // the wrong type, NaN, not a choice, or no such entry: the value stays
} nmr_change;

// Every entry at its default; NULL only when memory runs out. Free with nmr_settings_destroy.
nmr_settings* nmr_settings_create(void);
nmr_settings* nmr_settings_copy(const nmr_settings* settings);  // NULL for NULL
void nmr_settings_destroy(nmr_settings* settings);               // NULL is ignored
bool nmr_settings_equal(const nmr_settings* a, const nmr_settings* b);  // false if either is NULL

// Bool 0/1, int, float, choice index or color 0xRRGGBBAA; 0 for a text entry, a bad index or NULL.
double nmr_settings_number(const nmr_settings* settings, uint32_t index);
// A text entry's value ("" for other entries; NULL for a bad index or NULL), owned by `settings`:
// valid until that entry changes or the handle is destroyed.
const char* nmr_settings_text(const nmr_settings* settings, uint32_t index);

nmr_change nmr_settings_set_number(nmr_settings* settings, uint32_t index, double value);
nmr_change nmr_settings_set_choice(nmr_settings* settings, uint32_t index, const char* key);
// Valid UTF-8 of at most the entry's max_length bytes, without control characters. Running out of
// memory leaves the value as it was and gives NMR_CHANGE_REJECTED.
nmr_change nmr_settings_set_text(nmr_settings* settings, uint32_t index, const char* text);
// Back to the entry's default (running out of memory leaves the value as it was).
void nmr_settings_reset(nmr_settings* settings, uint32_t index);

// ---- Settings as JSON --------------------------------------------------------------------------
// Versioned JSON with every entry (Sources/Core/include/nmr/settings_json.h): the plugin's state,
// and how the app keeps its settings. Documents are untrusted: decoding never stops half-way, and
// the report counts what it dropped or changed.

typedef enum nmr_json_status {
  NMR_JSON_OK,
  NMR_JSON_NOT_JSON,      // not JSON
  NMR_JSON_NOT_SETTINGS,  // JSON without a positive integer "version" and a "settings" object
  NMR_JSON_TOO_LARGE,     // over 256 KiB
  NMR_JSON_UNREADABLE,    // a file that could not be read; also when memory runs out
} nmr_json_status;

typedef struct nmr_json_report {
  nmr_json_status status;
  int32_t version;    // the document's version
  bool newer;         // written by a newer version: loaded as far as this one understands it
  uint32_t ignored;   // keys the document may not set: unknown, or not stored in presets
  uint32_t invalid;   // values of the wrong type or not among the choices: defaults used
  uint32_t adjusted;  // numbers clamped or rounded, or a preset name cleaned
} nmr_json_report;

// Every entry as JSON; NULL for NULL or when memory runs out. Free with nmr_string_free.
char* nmr_settings_encode(const nmr_settings* settings);
// Settings from `length` bytes of JSON (no NUL needed): the defaults unless the report's status
// is NMR_JSON_OK. NULL only when memory runs out (the report then says NMR_JSON_UNREADABLE).
// `report` may be NULL.
nmr_settings* nmr_settings_decode(const char* json, size_t length, nmr_json_report* report);

// Frees a string the C API allocated; NULL is ignored.
void nmr_string_free(char* text);

// ---- User files --------------------------------------------------------------------------------
// Presets and colormaps the user keeps in Application Support, shared with the plugin. Paths are
// absolute UTF-8 paths (NULL, "" or a relative path fails with EINVAL, or reads as missing).
// `error` (may be NULL) receives an errno value, 0 on success. Writes block until the file reaches
// the drive: keep them off the main thread.

typedef struct nmr_file_list nmr_file_list;

uint32_t nmr_file_list_count(const nmr_file_list* list);  // 0 for NULL
// The name shown (the file name without its extension, control characters and invalid UTF-8) and
// the path of file `index`, owned by the list; NULL past the end.
const char* nmr_file_list_name(const nmr_file_list* list, uint32_t index);
const char* nmr_file_list_path(const nmr_file_list* list, uint32_t index);
void nmr_file_list_destroy(nmr_file_list* list);  // NULL is ignored

// ---- Presets -----------------------------------------------------------------------------------
// The factory presets and the user's preset files (Sources/Core/include/nmr/presets.h). A preset
// is a name and settings of which only the preset entries matter.

uint32_t nmr_presets_factory_count(void);
const char* nmr_presets_factory_name(uint32_t index);        // static storage; NULL past the end
nmr_settings* nmr_presets_factory_settings(uint32_t index);  // a new handle; NULL past the end
// `current` with every preset entry taken from `preset`: a new handle; NULL for NULL.
nmr_settings* nmr_presets_apply(const nmr_settings* current, const nmr_settings* preset);

// The user's preset folder (nothing is created); "" without a home. Free with nmr_string_free.
char* nmr_presets_directory(void);
// The preset files in `folder`, sorted by name ignoring case; NULL only when memory runs out.
// Free with nmr_file_list_destroy.
nmr_file_list* nmr_presets_list(const char* folder);
// The preset in `path`, named after its file (`*name`, free with nmr_string_free); NULL, and
// `*name` NULL, when it cannot be read: the report says why (NMR_JSON_UNREADABLE also when memory
// runs out). `name` and `report` may be NULL.
nmr_settings* nmr_presets_load(const char* path, char** name, nmr_json_report* report);
// Saves a preset into `folder` (created if needed) as nmr_presets_file_name(name), replacing a
// file of that name: the file's path (free with nmr_string_free), or NULL and `error` (ENOMEM can
// come after the file was written).
char* nmr_presets_save(const char* folder, const char* name, const nmr_settings* settings,
                       int32_t* error);
// Deletes a preset file: one ending in .json in any case. Anything else, a folder included, is
// left alone and fails (EINVAL or EPERM).
bool nmr_presets_remove(const char* path, int32_t* error);
// The file name a preset name is saved under ("Mix" gives "Mix.json"). Free with nmr_string_free.
char* nmr_presets_file_name(const char* name);
// A preset as JSON, for exporting it. Free with nmr_string_free.
char* nmr_presets_encode(const char* name, const nmr_settings* settings);

// ---- Colormaps ---------------------------------------------------------------------------------
// The original colormaps and the user's colormaps imported from MiniMeters `.map` files
// (Sources/Core/include/nmr/colormap.h). The colormap setting holds a built-in key ("iris") or
// "user:<listed name>".

enum { NMR_COLORMAP_TABLE_SIZE = 256 };

typedef enum nmr_colormap_status {
  NMR_COLORMAP_OK,
  NMR_COLORMAP_NO_STOPS,    // nothing but malformed entries
  NMR_COLORMAP_TOO_LARGE,   // over 64 KiB
  NMR_COLORMAP_UNREADABLE,  // missing, not a regular file, or unreadable
} nmr_colormap_status;

typedef struct nmr_colormap_report {
  nmr_colormap_status status;
  uint32_t skipped;   // bracketed entries that are not stops, and stops past 256
  uint32_t adjusted;  // components above 255 or positions above 1, clamped
} nmr_colormap_report;

uint32_t nmr_colormaps_builtin_count(void);
const char* nmr_colormaps_builtin_key(uint32_t index);    // static storage; NULL past the end
const char* nmr_colormaps_builtin_label(uint32_t index);  // static storage; NULL past the end

// The user's colormap folder (nothing is created); "" without a home. Free with nmr_string_free.
char* nmr_colormaps_directory(void);
// The colormap files in `folder`, sorted by name ignoring case; NULL only when memory runs out.
// Free with nmr_file_list_destroy.
nmr_file_list* nmr_colormaps_list(const char* folder);
// The setting key of the user colormap listed as `name` (NULL for NULL). Free with
// nmr_string_free.
char* nmr_colormaps_user_key(const char* name);
// Fills `rgba` (NMR_COLORMAP_TABLE_SIZE colors of 4 bytes: r, g, b and straight alpha; entry i at
// t = i / 255) with the colormap `key` names, reading user colormaps from `folder` (NULL or "":
// built-ins only). Returns whether `key` named one; the table is Iris otherwise. A NULL `rgba`
// gives false and writes nothing. A user key reads a file: call it when the setting changes, not
// per frame.
bool nmr_colormaps_table(const char* key, const char* folder, uint8_t* rgba);
// Imports a `.map` file into `folder` (created if needed) under the source's name, replacing a
// colormap of that name: the new file's path (free with nmr_string_free), or NULL and `error`.
// When the source holds no colormap, the report's status says why and `error` matches it: EFTYPE
// (no stops), EFBIG (over 64 KiB) or EIO (unreadable). Otherwise `error` tells why the folder
// could not be written, or EINVAL for a missing or relative path (ENOMEM can come after the file
// was written). `report` may be NULL.
char* nmr_colormaps_import(const char* folder, const char* source, nmr_colormap_report* report,
                           int32_t* error);
// Deletes a colormap file: one ending in .map in any case. Anything else, a folder included, is
// left alone and fails (EINVAL or EPERM).
bool nmr_colormaps_remove(const char* path, int32_t* error);

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

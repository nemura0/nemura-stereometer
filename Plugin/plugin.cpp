#include "plugin.h"

#include <nmr/frame_ring.h>
#include <nmr/presets.h>
#include <nmr/product_config.h>
#include <nmr/settings_json.h>

#include <algorithm>
#include <cstdio>
#include <cstring>
#include <memory>
#include <string>
#include <string_view>

#include "editor.h"

#if defined(__x86_64__)
#include <xmmintrin.h>
#endif

namespace nmr::plugin {

namespace {

// ---------------------------------------------------------------------------------------------
// Descriptor

const char* const kFeatures[] = {
    CLAP_PLUGIN_FEATURE_AUDIO_EFFECT,
    CLAP_PLUGIN_FEATURE_ANALYZER,
    CLAP_PLUGIN_FEATURE_UTILITY,
    CLAP_PLUGIN_FEATURE_STEREO,
    CLAP_PLUGIN_FEATURE_MONO,
    nullptr,
};

const clap_plugin_descriptor_t kDescriptor = {
    CLAP_VERSION_INIT,
    NMR_CLAP_ID,
    NMR_PRODUCT_NAME,
    NMR_VENDOR,
    NMR_URL,
    NMR_URL,
    NMR_URL "/issues",
    NMR_VERSION,
    NMR_DESCRIPTION,
    kFeatures,
};

// The state the first builds saved (no settings yet): it loads as the first-run settings.
constexpr std::string_view kFirstBuildsState =
    R"({"format":"nemura-stereometer-state","version":1})";

// ---------------------------------------------------------------------------------------------
// Denormals: the x86_64 slice runs under Rosetta in some DAWs; keep FTZ/DAZ on while processing.

#if defined(__x86_64__)
class DenormalScope {
 public:
  DenormalScope() noexcept : saved_(_mm_getcsr()) { _mm_setcsr(saved_ | 0x8040u); }
  ~DenormalScope() { _mm_setcsr(saved_); }
  DenormalScope(const DenormalScope&) = delete;
  DenormalScope& operator=(const DenormalScope&) = delete;

 private:
  unsigned int saved_;
};
#else
class DenormalScope {};
#endif

// ---------------------------------------------------------------------------------------------
// Plugin instance

// What the editor reads: 1.3 s at 48 kHz, more than the playhead ever trails.
constexpr uint32_t kEditorRingFrames = 1 << 16;
constexpr double kDefaultSampleRate = 48000;

struct Instance {
  clap_plugin_t clap{};
  const clap_host_t* host = nullptr;
  LocalFrameRing editor_ring{kEditorRingFrames};  // outlives the editor (declared first)
  FrameRingView ring_writer = editor_ring.view();  // audio thread only
  double sample_rate = kDefaultSampleRate;          // main thread
  std::unique_ptr<Editor> editor;
  uint32_t editor_width = Editor::kDefaultWidth;
  uint32_t editor_height = Editor::kDefaultHeight;
  settings::Settings settings = presets::firstRun();  // main thread
  uint32_t channels = 2;  // both ports: mono or stereo, changed only while inactive
  bool active = false;    // main thread
};

Instance* self(const clap_plugin_t* plugin) { return static_cast<Instance*>(plugin->plugin_data); }

// ---------------------------------------------------------------------------------------------
// Audio thread

// The editor's copy of what passes through: a wait-free write into the local ring (memcpy and
// atomics). Reads the output, which holds every frame (a constant input is filled out).
void feedEditor(Instance& instance, const clap_audio_buffer_t& out, uint32_t frames) noexcept {
  if (out.channel_count == 0 || out.data32 == nullptr) return;
  const float* left = out.data32[0];
  const float* right = out.data32[out.channel_count > 1 ? 1 : 0];  // mono: both sides
  if (left == nullptr || right == nullptr) return;
  instance.ring_writer.writeSplit(left, right, frames);
}

clap_process_status process(const clap_plugin_t* plugin, const clap_process_t* process) {
  [[maybe_unused]] const DenormalScope denormals;  // x86_64 only; arm64 keeps FZ = 0
  const uint32_t frames = process->frames_count;
  if (process->audio_outputs_count == 0) return CLAP_PROCESS_CONTINUE;

  clap_audio_buffer_t& out = process->audio_outputs[0];
  const clap_audio_buffer_t* in =
      process->audio_inputs_count > 0 ? &process->audio_inputs[0] : nullptr;
  const uint32_t in_channels = (in != nullptr && in->data32 != nullptr) ? in->channel_count : 0;

  // Bit-exact pass-through: copy (or leave in place) every sample, never touch its value.
  for (uint32_t channel = 0; channel < out.channel_count; ++channel) {
    float* dst = out.data32 != nullptr ? out.data32[channel] : nullptr;
    if (dst == nullptr) continue;
    if (in_channels == 0) {
      std::memset(dst, 0, sizeof(float) * frames);
      continue;
    }
    const uint32_t source = channel < in_channels ? channel : in_channels - 1;
    const float* src = in->data32[source];
    if (src == nullptr) {
      std::memset(dst, 0, sizeof(float) * frames);
    } else if (source < 64 && (in->constant_mask & (uint64_t{1} << source)) != 0) {
      // A constant channel is only valid at its first sample (CLAP audio-buffer.h).
      if (frames > 0) std::fill(dst, dst + frames, src[0]);
    } else if (src != dst) {
      std::memcpy(dst, src, sizeof(float) * frames);
    }
  }
  out.constant_mask = 0;
  feedEditor(*self(plugin), out, frames);  // reads the output only
  return CLAP_PROCESS_CONTINUE;
}

// ---------------------------------------------------------------------------------------------
// clap.audio-ports

uint32_t audioPortsCount(const clap_plugin_t*, bool) { return 1; }

const char* portType(uint32_t channels) { return channels == 1 ? CLAP_PORT_MONO : CLAP_PORT_STEREO; }

bool audioPortsGet(const clap_plugin_t* plugin, uint32_t index, bool is_input,
                   clap_audio_port_info_t* info) {
  if (index != 0) return false;
  const uint32_t channels = self(plugin)->channels;
  info->id = 0;
  std::snprintf(info->name, sizeof(info->name), "%s", is_input ? "Input" : "Output");
  info->flags = CLAP_AUDIO_PORT_IS_MAIN;
  info->channel_count = channels;
  info->port_type = portType(channels);
  info->in_place_pair = 0;
  return true;
}

const clap_plugin_audio_ports_t kAudioPorts = {audioPortsCount, audioPortsGet};

// ---------------------------------------------------------------------------------------------
// clap.configurable-audio-ports: a mono or a stereo track, the same on both sides (main thread,
// inactive only)

// The channel count both ports would have after `requests`, or 0 when it is not a layout this
// plugin takes.
uint32_t requestedChannels(const Instance& instance,
                           const clap_audio_port_configuration_request_t* requests,
                           uint32_t count) {
  if (instance.active || (count > 0 && requests == nullptr)) return 0;
  uint32_t sides[2] = {instance.channels, instance.channels};  // input, output
  for (uint32_t i = 0; i < count; ++i) {
    const clap_audio_port_configuration_request_t& request = requests[i];
    const uint32_t channels = request.channel_count;
    if (request.port_index != 0 || (channels != 1 && channels != 2)) return 0;
    if (request.port_type != nullptr && std::strcmp(request.port_type, portType(channels)) != 0) {
      return 0;
    }
    sides[request.is_input ? 0 : 1] = channels;
  }
  return sides[0] == sides[1] ? sides[0] : 0;
}

bool canApplyConfiguration(const clap_plugin_t* plugin,
                           const clap_audio_port_configuration_request_t* requests,
                           uint32_t count) {
  return requestedChannels(*self(plugin), requests, count) != 0;
}

bool applyConfiguration(const clap_plugin_t* plugin,
                        const clap_audio_port_configuration_request_t* requests, uint32_t count) {
  Instance* instance = self(plugin);
  const uint32_t channels = requestedChannels(*instance, requests, count);
  if (channels == 0) return false;
  instance->channels = channels;
  return true;
}

const clap_plugin_configurable_audio_ports_t kConfigurablePorts = {canApplyConfiguration,
                                                                   applyConfiguration};

// ---------------------------------------------------------------------------------------------
// clap.latency

uint32_t latencyGet(const clap_plugin_t*) { return 0; }

const clap_plugin_latency_t kLatency = {latencyGet};

// ---------------------------------------------------------------------------------------------
// clap.state

bool stateSave(const clap_plugin_t* plugin, const clap_ostream_t* stream) {
  try {
    const std::string state = settings::encodeState(self(plugin)->settings);
    size_t written = 0;
    while (written < state.size()) {
      const int64_t n = stream->write(stream, state.data() + written, state.size() - written);
      if (n <= 0) return false;
      written += static_cast<size_t>(n);
    }
    return true;
  } catch (...) {  // out of memory: nothing may cross the C boundary
    return false;
  }
}

// A settings document replaces every setting; anything else is refused and changes nothing.
bool stateLoad(const clap_plugin_t* plugin, const clap_istream_t* stream) {
  try {
    std::string data;
    char buffer[4096];
    for (;;) {
      const int64_t n = stream->read(stream, buffer, sizeof(buffer));
      if (n < 0) return false;
      if (n == 0) break;
      data.append(buffer, static_cast<size_t>(n));
      if (data.size() > settings::kMaxDocumentBytes) return false;
    }
    settings::Report report;
    settings::Settings loaded = settings::decodeState(data, report);
    if (data == kFirstBuildsState) {
      loaded = presets::firstRun();
    } else if (report.status != settings::Status::kOk) {
      return false;
    }
    self(plugin)->settings = std::move(loaded);
    return true;
  } catch (...) {
    return false;
  }
}

const clap_plugin_state_t kState = {stateSave, stateLoad};

// ---------------------------------------------------------------------------------------------
// clap.gui (main thread)

bool guiIsApiSupported(const clap_plugin_t*, const char* api, bool is_floating) {
  return api != nullptr && std::strcmp(api, CLAP_WINDOW_API_COCOA) == 0 && !is_floating;
}

bool guiGetPreferredApi(const clap_plugin_t*, const char** api, bool* is_floating) {
  *api = CLAP_WINDOW_API_COCOA;
  *is_floating = false;
  return true;
}

bool guiCreate(const clap_plugin_t* plugin, const char* api, bool is_floating) {
  if (!guiIsApiSupported(plugin, api, is_floating)) return false;
  Instance* instance = self(plugin);
  if (!instance->editor) {
    instance->editor = std::make_unique<Editor>(instance->editor_width, instance->editor_height);
    instance->editor->setSource(instance->editor_ring.view(), instance->sample_rate);
  }
  return true;
}

void guiDestroy(const clap_plugin_t* plugin) { self(plugin)->editor.reset(); }

bool guiSetScale(const clap_plugin_t*, double) {
  return false;  // macOS: the OS handles backing scale.
}

bool guiGetSize(const clap_plugin_t* plugin, uint32_t* width, uint32_t* height) {
  *width = self(plugin)->editor_width;
  *height = self(plugin)->editor_height;
  return true;
}

bool guiCanResize(const clap_plugin_t*) { return true; }

bool guiGetResizeHints(const clap_plugin_t*, clap_gui_resize_hints_t* hints) {
  hints->can_resize_horizontally = true;
  hints->can_resize_vertically = true;
  hints->preserve_aspect_ratio = false;
  hints->aspect_ratio_width = 0;
  hints->aspect_ratio_height = 0;
  return true;
}

bool guiAdjustSize(const clap_plugin_t*, uint32_t* width, uint32_t* height) {
  Editor::clampSize(*width, *height);
  return true;
}

bool guiSetSize(const clap_plugin_t* plugin, uint32_t width, uint32_t height) {
  Editor::clampSize(width, height);
  Instance* instance = self(plugin);
  instance->editor_width = width;
  instance->editor_height = height;
  if (instance->editor) instance->editor->setSize(width, height);
  return true;
}

bool guiSetParent(const clap_plugin_t* plugin, const clap_window_t* window) {
  Instance* instance = self(plugin);
  if (!instance->editor || window == nullptr || window->api == nullptr ||
      std::strcmp(window->api, CLAP_WINDOW_API_COCOA) != 0) {
    return false;
  }
  return instance->editor->attach(window->cocoa);
}

bool guiSetTransient(const clap_plugin_t*, const clap_window_t*) { return false; }

void guiSuggestTitle(const clap_plugin_t*, const char*) {}

bool guiShow(const clap_plugin_t* plugin) {
  Instance* instance = self(plugin);
  if (!instance->editor) return false;
  instance->editor->setVisible(true);
  return true;
}

bool guiHide(const clap_plugin_t* plugin) {
  Instance* instance = self(plugin);
  if (!instance->editor) return false;
  instance->editor->setVisible(false);
  return true;
}

const clap_plugin_gui_t kGui = {
    guiIsApiSupported, guiGetPreferredApi, guiCreate,     guiDestroy,      guiSetScale,
    guiGetSize,        guiCanResize,       guiGetResizeHints, guiAdjustSize, guiSetSize,
    guiSetParent,      guiSetTransient,    guiSuggestTitle,   guiShow,       guiHide,
};

// ---------------------------------------------------------------------------------------------
// clap_plugin

bool pluginInit(const clap_plugin_t*) { return true; }

void pluginDestroy(const clap_plugin_t* plugin) { delete self(plugin); }

bool pluginActivate(const clap_plugin_t* plugin, double sample_rate, uint32_t, uint32_t) {
  Instance* instance = self(plugin);
  instance->active = true;
  instance->sample_rate = sample_rate;
  if (instance->editor) instance->editor->setSource(instance->editor_ring.view(), sample_rate);
  return true;
}

void pluginDeactivate(const clap_plugin_t* plugin) { self(plugin)->active = false; }

bool pluginStartProcessing(const clap_plugin_t*) { return true; }

void pluginStopProcessing(const clap_plugin_t*) {}

void pluginReset(const clap_plugin_t*) {}

const void* pluginGetExtension(const clap_plugin_t*, const char* id) {
  if (std::strcmp(id, CLAP_EXT_AUDIO_PORTS) == 0) return &kAudioPorts;
  if (std::strcmp(id, CLAP_EXT_CONFIGURABLE_AUDIO_PORTS) == 0 ||
      std::strcmp(id, CLAP_EXT_CONFIGURABLE_AUDIO_PORTS_COMPAT) == 0) {
    return &kConfigurablePorts;
  }
  if (std::strcmp(id, CLAP_EXT_LATENCY) == 0) return &kLatency;
  if (std::strcmp(id, CLAP_EXT_STATE) == 0) return &kState;
  if (std::strcmp(id, CLAP_EXT_GUI) == 0) return &kGui;
  return nullptr;
}

void pluginOnMainThread(const clap_plugin_t*) {}

}  // namespace

const clap_plugin_descriptor_t* descriptor() noexcept { return &kDescriptor; }

const clap_plugin_t* create(const clap_host_t* host) {
  Instance* instance = nullptr;
  try {
    instance = new Instance();  // its members allocate too
  } catch (...) {
    return nullptr;
  }
  instance->host = host;
  instance->clap.desc = &kDescriptor;
  instance->clap.plugin_data = instance;
  instance->clap.init = pluginInit;
  instance->clap.destroy = pluginDestroy;
  instance->clap.activate = pluginActivate;
  instance->clap.deactivate = pluginDeactivate;
  instance->clap.start_processing = pluginStartProcessing;
  instance->clap.stop_processing = pluginStopProcessing;
  instance->clap.reset = pluginReset;
  instance->clap.process = process;
  instance->clap.get_extension = pluginGetExtension;
  instance->clap.on_main_thread = pluginOnMainThread;
  return &instance->clap;
}

}  // namespace nmr::plugin

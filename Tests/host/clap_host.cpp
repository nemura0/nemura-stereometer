#include "clap_host.h"

#include <dlfcn.h>
#include <nmr/shm_transport.h>
#include <unistd.h>

#include <algorithm>
#include <utility>
#include <cstdio>
#include <cstring>
#include <string>

namespace nmr::test {

namespace {

bool trackInfo(const clap_host_t* host, clap_track_info_t* info) {
  const auto* instance = static_cast<const ClapInstance*>(host->host_data);
  *info = clap_track_info_t{};
  info->flags = CLAP_TRACK_INFO_HAS_TRACK_NAME;
  std::snprintf(info->name, sizeof(info->name), "%s", instance->trackName().c_str());
  return true;
}

const clap_host_track_info_t kTrackInfo = {trackInfo};

void markDirty(const clap_host_t* host) {
  static_cast<ClapInstance*>(host->host_data)->markDirty();
}

const clap_host_state_t kHostState = {markDirty};

const void* hostExtension(const clap_host_t* host, const char* id) {
  const auto* instance = static_cast<const ClapInstance*>(host->host_data);
  if (std::strcmp(id, CLAP_EXT_STATE) == 0) return &kHostState;
  if (std::strcmp(id, CLAP_EXT_TRACK_INFO) == 0 && !instance->trackName().empty()) {
    return &kTrackInfo;
  }
  return nullptr;
}
void hostRequest(const clap_host_t*) {}

uint32_t eventsSize(const clap_input_events_t*) { return 0; }
const clap_event_header_t* eventsGet(const clap_input_events_t*, uint32_t) { return nullptr; }
bool eventsPush(const clap_output_events_t*, const clap_event_header_t*) { return false; }

const clap_input_events_t kNoInput = {nullptr, eventsSize, eventsGet};
const clap_output_events_t kNoOutput = {nullptr, eventsPush};

struct Reader {
  const std::string* data;
  size_t chunk;
  size_t at = 0;
};

int64_t readChunk(const clap_istream_t* stream, void* buffer, uint64_t size) {
  auto* reader = static_cast<Reader*>(stream->ctx);
  const size_t n = std::min({static_cast<size_t>(size), reader->chunk,
                             reader->data->size() - reader->at});
  std::memcpy(buffer, reader->data->data() + reader->at, n);
  reader->at += n;
  return static_cast<int64_t>(n);
}

struct Writer {
  std::string* data;
  size_t chunk;
};

int64_t writeChunk(const clap_ostream_t* stream, const void* buffer, uint64_t size) {
  auto* writer = static_cast<Writer*>(stream->ctx);
  const size_t n = std::min(static_cast<size_t>(size), writer->chunk);
  writer->data->append(static_cast<const char*>(buffer), n);
  return static_cast<int64_t>(n);
}

}  // namespace

ClapLibrary& ClapLibrary::shared() {
  static ClapLibrary library;
  return library;
}

ClapLibrary::ClapLibrary() {
  send_prefix_ = "/nmr.t" + std::to_string(::getpid()) + ".h";
  shm::unlinkAll(send_prefix_);
  ::setenv("NMR_TEST_SHM_PREFIX", send_prefix_.c_str(), 1);
  handle_ = dlopen(NMR_TEST_CLAP_BINARY, RTLD_NOW | RTLD_LOCAL);
  if (handle_ == nullptr) {
    error_ = dlerror();
    return;
  }
  entry_ = static_cast<const clap_plugin_entry_t*>(dlsym(handle_, "clap_entry"));
  if (entry_ == nullptr || !entry_->init(NMR_TEST_CLAP_BUNDLE)) {
    error_ = "no clap_entry, or its init failed";
    entry_ = nullptr;
    return;
  }
  factory_ = static_cast<const clap_plugin_factory_t*>(entry_->get_factory(CLAP_PLUGIN_FACTORY_ID));
  if (factory_ == nullptr) error_ = "no plugin factory";
}

ClapLibrary::~ClapLibrary() {
  if (entry_ != nullptr) entry_->deinit();
  shm::unlinkAll(send_prefix_);
  // The library stays loaded: its ObjC classes cannot be unloaded.
}

ClapInstance::ClapInstance(std::string track_name) : track_name_(std::move(track_name)) {
  host_.host_data = this;
  host_.clap_version = CLAP_VERSION;
  host_.name = "nmr test host";
  host_.vendor = "test";
  host_.url = "";
  host_.version = "1";
  host_.get_extension = hostExtension;
  host_.request_restart = hostRequest;
  host_.request_process = hostRequest;
  host_.request_callback = hostRequest;
  const clap_plugin_factory_t* factory = ClapLibrary::shared().factory();
  if (factory == nullptr || factory->get_plugin_count(factory) != 1) return;
  const clap_plugin_descriptor_t* descriptor = factory->get_plugin_descriptor(factory, 0);
  const clap_plugin_t* plugin = factory->create_plugin(factory, &host_, descriptor->id);
  if (plugin == nullptr) return;
  if (!plugin->init(plugin)) {
    plugin->destroy(plugin);
    return;
  }
  plugin_ = plugin;
}

ClapInstance::~ClapInstance() {
  if (plugin_ == nullptr) return;
  deactivate();
  plugin_->destroy(plugin_);
}

bool ClapInstance::activate(double sample_rate, uint32_t max_frames) {
  if (active_) return true;
  active_ = plugin_->activate(plugin_, sample_rate, 1, max_frames);
  if (active_) processing_ = plugin_->start_processing(plugin_);
  return active_ && processing_;
}

void ClapInstance::deactivate() {
  if (processing_) plugin_->stop_processing(plugin_);
  processing_ = false;
  if (active_) plugin_->deactivate(plugin_);
  active_ = false;
}

clap_process_status ClapInstance::process(Channels& in, Channels& out, bool in_place,
                                          uint64_t constant_mask) {
  Channels& outputs = in_place ? in : out;
  const uint32_t frames = outputs.empty() ? 0 : static_cast<uint32_t>(outputs[0].size());
  std::vector<float*> in_pointers;
  std::vector<float*> out_pointers;
  for (auto& channel : in) in_pointers.push_back(channel.data());
  for (auto& channel : outputs) out_pointers.push_back(channel.data());

  clap_audio_buffer_t input{};
  input.data32 = in_pointers.data();
  input.channel_count = static_cast<uint32_t>(in_pointers.size());
  input.constant_mask = constant_mask;
  clap_audio_buffer_t output{};
  output.data32 = out_pointers.data();
  output.channel_count = static_cast<uint32_t>(out_pointers.size());

  clap_process_t process{};
  process.steady_time = -1;
  process.frames_count = frames;
  process.audio_inputs = &input;
  process.audio_outputs = &output;
  process.audio_inputs_count = 1;
  process.audio_outputs_count = 1;
  process.in_events = &kNoInput;
  process.out_events = &kNoOutput;
  return plugin_->process(plugin_, &process);
}

void ClapInstance::renameTrack(std::string name) {
  track_name_ = std::move(name);
  const auto* ext = extension<clap_plugin_track_info_t>(CLAP_EXT_TRACK_INFO);
  if (ext != nullptr) ext->changed(plugin_);
}

bool ClapInstance::save(std::string& state, size_t chunk) const {
  const auto* ext = extension<clap_plugin_state_t>(CLAP_EXT_STATE);
  if (ext == nullptr) return false;
  state.clear();
  Writer writer{&state, chunk};
  const clap_ostream_t stream{&writer, writeChunk};
  return ext->save(plugin_, &stream);
}

bool ClapInstance::load(const std::string& state, size_t chunk) {
  const auto* ext = extension<clap_plugin_state_t>(CLAP_EXT_STATE);
  if (ext == nullptr) return false;
  Reader reader{&state, chunk};
  const clap_istream_t stream{&reader, readChunk};
  return ext->load(plugin_, &stream);
}

}  // namespace nmr::test

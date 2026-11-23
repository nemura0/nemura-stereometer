// A minimal CLAP host for tests: loads the built plugin binary, creates an instance and runs
// process() on caller-owned buffers. Main thread only; nothing here is real-time safe.
#pragma once

#include <clap/clap.h>

#include <cstdint>
#include <string>
#include <vector>

namespace nmr::test {

// The plugin library, loaded once per process (clap_entry init/deinit balanced).
class ClapLibrary {
 public:
  static ClapLibrary& shared();
  [[nodiscard]] const clap_plugin_factory_t* factory() const noexcept { return factory_; }
  [[nodiscard]] const std::string& error() const noexcept { return error_; }

 private:
  ClapLibrary();
  ~ClapLibrary();
  void* handle_ = nullptr;
  const clap_plugin_entry_t* entry_ = nullptr;
  const clap_plugin_factory_t* factory_ = nullptr;
  std::string error_;
};

// Planar float32 audio: one vector per channel.
using Channels = std::vector<std::vector<float>>;

class ClapInstance {
 public:
  ClapInstance();  // created and initialized; valid() says whether it worked
  ~ClapInstance();
  ClapInstance(const ClapInstance&) = delete;
  ClapInstance& operator=(const ClapInstance&) = delete;

  [[nodiscard]] bool valid() const noexcept { return plugin_ != nullptr; }
  [[nodiscard]] const clap_plugin_t* plugin() const noexcept { return plugin_; }
  template <typename T>
  [[nodiscard]] const T* extension(const char* id) const {
    return static_cast<const T*>(plugin_->get_extension(plugin_, id));
  }

  bool activate(double sample_rate = 48000, uint32_t max_frames = 4096);
  void deactivate();

  // Runs one block. `in_place` passes the output buffers as the input too (in holds the signal
  // and is overwritten). `constant_mask` marks input channels as constant.
  clap_process_status process(Channels& in, Channels& out, bool in_place = false,
                              uint64_t constant_mask = 0);

  // The plugin's state, written in chunks of at most `chunk` bytes.
  [[nodiscard]] bool save(std::string& state, size_t chunk = 1 << 20) const;
  // Loads `state`, read in chunks of at most `chunk` bytes.
  [[nodiscard]] bool load(const std::string& state, size_t chunk = 1 << 20);

 private:
  clap_host_t host_{};
  const clap_plugin_t* plugin_ = nullptr;
  bool active_ = false;
  bool processing_ = false;
};

}  // namespace nmr::test

// Plugin editor: the shared meter view embedded in the host's window. Main thread only.
// Pure C++ interface so plugin.cpp stays free of Objective-C.
#pragma once

#include <nmr/frame_ring.h>

#include <cstdint>
#include <memory>

namespace nmr::plugin {

class Editor {
 public:
  static constexpr uint32_t kDefaultWidth = 480;
  static constexpr uint32_t kDefaultHeight = 480;
  static constexpr uint32_t kMinSize = 200;
  static constexpr uint32_t kMaxSize = 4096;

  Editor(uint32_t width, uint32_t height);
  ~Editor();
  Editor(const Editor&) = delete;
  Editor& operator=(const Editor&) = delete;

  // `parent` is the host's NSView*.
  bool attach(void* parent);
  void setSize(uint32_t width, uint32_t height);
  void setVisible(bool visible);
  // What the meter shows: the plugin's input (the ring outlives the editor).
  void setSource(FrameRingView ring, double sample_rate);
  [[nodiscard]] uint32_t width() const noexcept { return width_; }
  [[nodiscard]] uint32_t height() const noexcept { return height_; }

  // Clamps a requested size to the editor's limits.
  static void clampSize(uint32_t& width, uint32_t& height) noexcept;

 private:
  struct Impl;
  std::unique_ptr<Impl> impl_;
  uint32_t width_;
  uint32_t height_;
};

}  // namespace nmr::plugin

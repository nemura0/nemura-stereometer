// Plugin editor: the shared meter view under a slim top bar ("Send to app" with its status dot,
// mode, preset, response, and a gear for the settings panel generated from the schema), embedded
// in the host's window. Main thread only. Pure C++ interface so plugin.cpp stays free of
// Objective-C.
#pragma once

#include <nmr/frame_ring.h>
#include <nmr/instance_sender.h>
#include <nmr/settings.h>

#include <cstdint>
#include <memory>

namespace nmr::plugin {

class Editor {
 public:
  // What the editor needs from its plugin instance. Main thread.
  class Host {
   public:
    [[nodiscard]] virtual const settings::Settings& settings() const = 0;
    // The user changed something: the instance takes `changed`, applies it and marks the
    // project changed. The editor shows it afterwards.
    virtual void changeSettings(const settings::Settings& changed) = 0;
    // Where sending stands (also claims a slot again after one was lost).
    [[nodiscard]] virtual InstanceSender::State sendState() = 0;

   protected:
    ~Host() = default;
  };

  static constexpr uint32_t kDefaultWidth = 480;
  static constexpr uint32_t kDefaultHeight = 480;
  static constexpr uint32_t kMinSize = 200;
  static constexpr uint32_t kMaxSize = 4096;
  static constexpr uint32_t kBarHeight = 28;

  Editor(Host& host, uint32_t width, uint32_t height);
  ~Editor();
  Editor(const Editor&) = delete;
  Editor& operator=(const Editor&) = delete;

  // `parent` is the host's NSView*.
  bool attach(void* parent);
  void setSize(uint32_t width, uint32_t height);
  void setVisible(bool visible);
  // What the meter shows: the plugin's input (the ring outlives the editor).
  void setSource(FrameRingView ring, double sample_rate);
  // The instance's settings changed (a state was loaded): show them.
  void settingsChanged();
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

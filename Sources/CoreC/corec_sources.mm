// Plugin instances as meter sources, for the app's source picker.
#include "nmr_corec.h"

#import <nmr/render_view.h>
#include <nmr/instance_source.h>
#include <nmr/monotonic_clock.h>
#include <nmr/product_config.h>
#include <nmr/shm_transport.h>

#include <libproc.h>
#include <unistd.h>

#include <memory>
#include <vector>

#include "corec_internal.h"

#if !__has_feature(objc_arc)
#error "Sources/CoreC is compiled with ARC (-fobjc-arc) in every build"
#endif

struct nmr_sources {
  std::unique_ptr<nmr::shm::Registry> registry;
  nmr::MonotonicClock clock;
  std::vector<nmr::shm::SlotInfo> live;  // the latest poll's
};

struct nmr_instance_feed {
  NMR_OBJC(RenderView) * view;
  nmr_sources* sources;
  nmr::shm::InstanceFollower follower;
};

nmr_sources* nmr_sources_open(const char* prefix) {
  return nmr::corec::guarded<nmr_sources*>(nullptr, [&]() -> nmr_sources* {
    nmr::shm::Status status = nmr::shm::Status::kFailed;
    auto registry = nmr::shm::Registry::open(prefix != nullptr ? prefix : NMR_SHM_PREFIX, status);
    if (registry == nullptr) return nullptr;
    return new nmr_sources{std::move(registry), {}, {}};
  });
}

void nmr_sources_close(nmr_sources* sources) {
  if (sources == nullptr) return;
  sources->registry->appStopped(static_cast<int32_t>(::getpid()));
  delete sources;
}

uint32_t nmr_sources_poll(nmr_sources* sources, nmr_source_info* out, uint32_t max) {
  if (sources == nullptr || (out == nullptr && max > 0)) return 0;
  return nmr::corec::guarded<uint32_t>(0, [&]() -> uint32_t {
    nmr::shm::Registry& registry = *sources->registry;
    const uint64_t now = sources->clock.nowNs();
    registry.appBeat(now, static_cast<int32_t>(::getpid()));
    registry.reclaimDead(now);
    sources->live = registry.live(now);
    uint32_t count = 0;
    for (const nmr::shm::SlotInfo& slot : sources->live) {
      if (count == max) break;
      nmr_source_info& info = out[count++];
      info = {};
      info.instance_id = slot.instance_id;
      info.sample_rate = slot.sample_rate;
      info.channels = slot.channels;
      nmr::shm::copyName(slot.name, info.name, sizeof info.name);
      char host[2 * MAXCOMLEN + 1] = {};
      if (slot.pid > 0 && proc_name(slot.pid, host, sizeof host) > 0) {  // pid from shm
        nmr::shm::copyName(host, info.host, sizeof info.host);
      }
    }
    return count;
  });
}

nmr_instance_feed* nmr_instance_feed_create(void* view, nmr_sources* sources,
                                            uint64_t instance_id) {
  if (view == nullptr || sources == nullptr) return nullptr;
  return nmr::corec::guarded<nmr_instance_feed*>(nullptr, [&] {
    auto* feed = new nmr_instance_feed{(__bridge NMR_OBJC(RenderView)*)view, sources,
                                       nmr::shm::InstanceFollower(instance_id)};
    [feed->view setSource:nmr::FrameRingView{} sampleRate:0];
    return feed;
  });
}

nmr_instance_state nmr_instance_feed_update(nmr_instance_feed* feed) {
  if (feed == nullptr) return NMR_INSTANCE_WAITING;
  return nmr::corec::guarded(NMR_INSTANCE_WAITING, [&] {
    nmr::shm::InstanceFollower& follower = feed->follower;
    if (follower.update(*feed->sources->registry, feed->sources->live)) {
      // Before the next update unmaps the ring the view read until now.
      [feed->view setSource:follower.view() sampleRate:follower.sampleRate()];
    }
    switch (follower.state()) {
      case nmr::shm::InstanceFollower::State::kSending: return NMR_INSTANCE_SENDING;
      case nmr::shm::InstanceFollower::State::kQuiet: return NMR_INSTANCE_QUIET;
      case nmr::shm::InstanceFollower::State::kWaiting: return NMR_INSTANCE_WAITING;
    }
    return NMR_INSTANCE_WAITING;
  });
}

void nmr_instance_feed_destroy(nmr_instance_feed* feed) {
  if (feed == nullptr) return;
  [feed->view setSource:nmr::FrameRingView{} sampleRate:0];  // returns once nothing reads it
  delete feed;
}

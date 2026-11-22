// Stands in for a plugin instance: claims a slot in the app's registry and sends the test mix
// (nmr/test_mix.h) in real time, as the plugin's audio thread would, then releases the slot.
//
//   nmr_fake_instance [--seconds S] [--name NAME] [--rate HZ] [--prefix /nmr.xyz]
//
// Defaults: 10 s, "Fake instance", 48 kHz, the product's prefix. Exits 0 after sending, 2 for
// bad arguments, 3 when no slot or ring could be had. SIGINT and SIGTERM end it early, cleanly.
#include <nmr/monotonic_clock.h>
#include <nmr/product_config.h>
#include <nmr/shm_transport.h>
#include <nmr/test_mix.h>

#include <chrono>
#include <csignal>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <optional>
#include <string>
#include <thread>
#include <vector>

namespace {

constexpr uint32_t kBlock = 256;  // frames per "process" call

volatile std::sig_atomic_t stopping = 0;

void onSignal(int) { stopping = 1; }

struct Options {
  double seconds = 10;
  double rate = 48000;
  std::string name = "Fake instance";
  std::string prefix = NMR_SHM_PREFIX;
};

bool parse(int argc, char** argv, Options& o) {
  for (int i = 1; i + 1 < argc; i += 2) {
    const std::string key = argv[i];
    const std::string value = argv[i + 1];
    if (key == "--seconds") o.seconds = std::atof(value.c_str());
    else if (key == "--rate") o.rate = std::atof(value.c_str());
    else if (key == "--name") o.name = value;
    else if (key == "--prefix") o.prefix = value;
    else return false;
  }
  return argc % 2 == 1 && o.seconds > 0 && o.seconds <= 3600 && o.rate >= 8000 &&
         o.rate <= 384000 && o.prefix.size() <= 24 && o.prefix.rfind('/', 0) == 0;
}

}  // namespace

int main(int argc, char** argv) {
  Options options;
  if (!parse(argc, argv, options)) {
    std::fprintf(stderr,
                 "usage: nmr_fake_instance [--seconds S] [--name NAME] [--rate HZ] "
                 "[--prefix /nmr.xyz]\n");
    return 2;
  }
  std::signal(SIGINT, onSignal);
  std::signal(SIGTERM, onSignal);
  namespace shm = nmr::shm;
  shm::Status status = shm::Status::kFailed;
  const auto registry = shm::Registry::open(options.prefix, status);
  const nmr::MonotonicClock clock;
  const uint64_t id = shm::newInstanceId();
  const auto slot = registry != nullptr
                        ? registry->claim(id, options.rate, 2, options.name, clock, status)
                        : std::nullopt;
  const auto ring =
      slot ? shm::Ring::create(*registry, *slot, id, options.rate, status) : nullptr;
  if (ring == nullptr) {
    std::fprintf(stderr, "no slot or ring (status %u)\n", static_cast<unsigned>(status));
    if (slot) registry->release(*slot, id);
    return 3;
  }

  nmr::TestMix mix(options.rate);
  std::vector<float> block(size_t{kBlock} * 2);
  const uint64_t total = static_cast<uint64_t>(options.seconds * options.rate);
  const uint64_t start = clock.nowNs();
  uint64_t sent = 0;
  while (sent < total && stopping == 0) {
    const auto due = static_cast<uint64_t>(
        static_cast<double>(clock.nowNs() - start) * 1e-9 * options.rate);
    // Past a stall (a debugger, App Nap) a host goes on from now, with no burst of old blocks.
    if (due > sent + static_cast<uint64_t>(options.rate / 2)) sent = due - due % kBlock;
    while (sent + kBlock <= due && sent < total) {
      mix.fill(block.data(), kBlock);
      ring->view().write(block.data(), kBlock);
      sent += kBlock;
      if (!registry->beat(*slot, id, clock.nowNs())) stopping = 1;  // the slot was taken away
    }
    std::this_thread::sleep_for(std::chrono::milliseconds(2));
  }
  registry->release(*slot, id);
  std::printf("sent %llu frames as \"%s\" in slot %u\n", static_cast<unsigned long long>(sent),
              options.name.c_str(), *slot);
  return 0;
}

// NEMURA Stereometer CLAP plugin: a zero-latency, bit-exact pass-through insert with a meter
// editor. No host-automatable parameters; settings live in versioned JSON state.
#pragma once

#include <clap/clap.h>

namespace nmr::plugin {

const clap_plugin_descriptor_t* descriptor() noexcept;

// Returns nullptr on failure. The host owns the returned plugin (destroy() frees it).
const clap_plugin_t* create(const clap_host_t* host);

}  // namespace nmr::plugin

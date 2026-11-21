// The exported clap_entry. Compiled into each format's binary (CLAP, VST3, AUv2); the clap-wrapper
// VST3/AU wrappers find it in their own bundle.
#include <clap/clap.h>

#include <cstring>

#include "plugin.h"

namespace {

uint32_t factoryPluginCount(const clap_plugin_factory_t*) { return 1; }

const clap_plugin_descriptor_t* factoryDescriptor(const clap_plugin_factory_t*, uint32_t index) {
  return index == 0 ? nmr::plugin::descriptor() : nullptr;
}

const clap_plugin_t* factoryCreate(const clap_plugin_factory_t*, const clap_host_t* host,
                                   const char* plugin_id) {
  if (host == nullptr || plugin_id == nullptr) return nullptr;
  if (!clap_version_is_compatible(host->clap_version)) return nullptr;
  if (std::strcmp(plugin_id, nmr::plugin::descriptor()->id) != 0) return nullptr;
  return nmr::plugin::create(host);
}

const clap_plugin_factory_t kFactory = {factoryPluginCount, factoryDescriptor, factoryCreate};

bool entryInit(const char*) { return true; }

void entryDeinit() {}

const void* entryGetFactory(const char* factory_id) {
  if (factory_id != nullptr && std::strcmp(factory_id, CLAP_PLUGIN_FACTORY_ID) == 0) {
    return &kFactory;
  }
  return nullptr;
}

}  // namespace

extern "C" CLAP_EXPORT const clap_plugin_entry_t clap_entry = {
    CLAP_VERSION_INIT,
    entryInit,
    entryDeinit,
    entryGetFactory,
};

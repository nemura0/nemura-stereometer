#include <nmr/version.h>

#include <nmr/product_config.h>

namespace nmr {

const char* versionString() noexcept { return NMR_VERSION; }

const char* productName() noexcept { return NMR_PRODUCT_NAME; }

}  // namespace nmr

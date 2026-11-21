#pragma once

namespace nmr {

// Semantic version from config/product.env, e.g. "1.0.0".
const char* versionString() noexcept;

// Display name from config/product.env, e.g. "NEMURA Stereometer".
const char* productName() noexcept;

}  // namespace nmr

#include <doctest/doctest.h>
#include <nmr/product_config.h>
#include <nmr/version.h>

#include <cstring>
#include <string>

TEST_CASE("the version string matches the numeric version parts") {
  const std::string expected = std::to_string(NMR_VERSION_MAJOR) + "." +
                               std::to_string(NMR_VERSION_MINOR) + "." +
                               std::to_string(NMR_VERSION_PATCH);
  CHECK(expected == NMR_VERSION);
  CHECK(std::strcmp(nmr::versionString(), NMR_VERSION) == 0);
  CHECK(std::strcmp(nmr::productName(), NMR_PRODUCT_NAME) == 0);
}

TEST_CASE("shared-memory names fit the macOS limit of 31 characters") {
  const std::string prefix = NMR_SHM_PREFIX;
  REQUIRE_FALSE(prefix.empty());
  CHECK(prefix.front() == '/');
  CHECK((prefix + ".reg").size() <= 31);
  CHECK((prefix + ".r999").size() <= 31);  // ring names: one per slot
}

TEST_CASE("Audio Unit codes are four-character codes") {
  const auto fourcc = [](uint32_t code) {
    std::string s;
    for (int shift = 24; shift >= 0; shift -= 8) s += static_cast<char>((code >> shift) & 0xff);
    return s;
  };
  CHECK(fourcc(NMR_AU_TYPE_CODE) == "aufx");
  CHECK(fourcc(NMR_AU_SUBTYPE_CODE).size() == 4);
  CHECK(fourcc(NMR_AU_MANUFACTURER_CODE).size() == 4);
}

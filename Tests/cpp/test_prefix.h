// Shared-memory segments of a test's own: each TestPrefix names segments no other test case (or
// the other architecture's run) uses, removed before and after.
#pragma once

#include <nmr/shm_transport.h>

#include <unistd.h>

#include <cstdio>
#include <string>

namespace nmr::test {

inline constexpr const char* kTestPrefixStart = "/nmr.t";

class TestPrefix {
 public:
  TestPrefix() {
    static int next = 0;
    char text[shm::kShmNameBytes];
    std::snprintf(text, sizeof text, "%s%d.%d", kTestPrefixStart, static_cast<int>(::getpid()),
                  next++);
    prefix_ = text;
    shm::unlinkAll(prefix_);
  }
  ~TestPrefix() { shm::unlinkAll(prefix_); }
  TestPrefix(const TestPrefix&) = delete;
  TestPrefix& operator=(const TestPrefix&) = delete;

  [[nodiscard]] const std::string& str() const { return prefix_; }

 private:
  std::string prefix_;
};

}  // namespace nmr::test

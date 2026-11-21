// The writer half of the cross-process transport tests. The test binary runs it as a child
// process (`nmr_tests --nmr-shm-writer <prefix> <frames>`), also under the other architecture.
#pragma once

namespace nmr::test {

inline constexpr const char* kShmWriterFlag = "--nmr-shm-writer";

// Claims a slot under `prefix` once the parent's app heartbeat shows, writes the frames, waits
// for the parent to stop its heartbeat, releases the slot. Returns the process exit code.
int shmWriterMain(int argc, char** argv);

}  // namespace nmr::test

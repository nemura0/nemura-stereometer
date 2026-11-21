#define DOCTEST_CONFIG_IMPLEMENT
#include <doctest/doctest.h>

#include <cstring>

#include "shm_writer.h"

int main(int argc, char** argv) {
  if (argc > 1 && std::strcmp(argv[1], nmr::test::kShmWriterFlag) == 0) {
    return nmr::test::shmWriterMain(argc, argv);
  }
  return doctest::Context(argc, argv).run();
}

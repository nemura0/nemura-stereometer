# C++ unit tests (doctest). The binary is built for every architecture in CMAKE_OSX_ARCHITECTURES;
# on Apple Silicon the x86_64 slice also runs under Rosetta, so shared-memory layouts and atomics
# are checked on both architectures.
add_executable(nmr_tests
  test_main.cpp
  frame_ring_test.cpp
  product_config_test.cpp)
target_include_directories(nmr_tests PRIVATE "${CMAKE_CURRENT_SOURCE_DIR}/third_party")
target_link_libraries(nmr_tests PRIVATE nmr_core nmr_warnings)

add_test(NAME cpp.native COMMAND nmr_tests)

if("x86_64" IN_LIST CMAKE_OSX_ARCHITECTURES AND CMAKE_HOST_SYSTEM_PROCESSOR STREQUAL "arm64")
  execute_process(COMMAND /usr/bin/arch -x86_64 /usr/bin/true
    RESULT_VARIABLE nmr_rosetta_result OUTPUT_QUIET ERROR_QUIET)
  if(nmr_rosetta_result EQUAL 0)
    add_test(NAME cpp.x86_64 COMMAND /usr/bin/arch -x86_64 $<TARGET_FILE:nmr_tests>)
  else()
    message(WARNING "Rosetta is not installed: the x86_64 test run is skipped")
  endif()
endif()

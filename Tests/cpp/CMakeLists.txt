# C++ unit tests (doctest). The binary is built for every architecture in CMAKE_OSX_ARCHITECTURES;
# on Apple Silicon the x86_64 slice also runs under Rosetta, so shared-memory layouts and atomics
# are checked on both architectures.
add_executable(nmr_tests
  test_main.cpp
  colormap_test.cpp
  dsp_test.cpp
  file_player_test.cpp
  files_test.cpp
  frame_ring_test.cpp
  frame_rate_test.cpp
  guides_test.cpp
  idle_test.cpp
  instance_sender_test.cpp
  instance_source_test.cpp
  layout_test.cpp
  meter_bars_test.cpp
  playhead_test.cpp
  presets_test.cpp
  product_config_test.cpp
  readouts_test.cpp
  scope_style_test.cpp
  settings_test.cpp
  shm_transport_test.cpp
  signal_watch_test.cpp
  test_mix_test.cpp
  wav_file_test.cpp)
# Core-internal headers (settings_migration.h) and nlohmann/json, which the migration tests use.
target_include_directories(nmr_tests PRIVATE
  "${CMAKE_CURRENT_SOURCE_DIR}/third_party"
  "${CMAKE_SOURCE_DIR}/Sources/Core"
  "${CMAKE_SOURCE_DIR}/Sources/Core/third_party")
target_link_libraries(nmr_tests PRIVATE nmr_core nmr_warnings)

add_test(NAME cpp.native COMMAND nmr_tests)

if("x86_64" IN_LIST CMAKE_OSX_ARCHITECTURES AND CMAKE_HOST_SYSTEM_PROCESSOR STREQUAL "arm64")
  execute_process(COMMAND /usr/bin/arch -x86_64 /usr/bin/true
    RESULT_VARIABLE nmr_rosetta_result OUTPUT_QUIET ERROR_QUIET)
  if(nmr_rosetta_result EQUAL 0)
    add_test(NAME cpp.x86_64 COMMAND /usr/bin/arch -x86_64 $<TARGET_FILE:nmr_tests>)
    if("arm64" IN_LIST CMAKE_OSX_ARCHITECTURES)
      # Both slices run here, so each run also spawns a writer under the other architecture.
      target_compile_definitions(nmr_tests PRIVATE NMR_TEST_CROSS_ARCH=1)
    endif()
  else()
    message(WARNING "Rosetta is not installed: the x86_64 test run is skipped")
  endif()
endif()

# Host-side tests.
#
# nmr_plugin_tests loads the built CLAP binary through a test host (ctest runs it on both
# architectures). nmr_au_oop_host needs the installed AU, so scripts/validate.sh runs it.
add_executable(nmr_plugin_tests
  plugin_test.cpp plugin_send_test.cpp plugin_editor_test.mm clap_host.cpp)
target_compile_options(nmr_plugin_tests PRIVATE $<$<COMPILE_LANGUAGE:OBJCXX>:-fobjc-arc>)
target_include_directories(nmr_plugin_tests PRIVATE "${CMAKE_SOURCE_DIR}/Tests/cpp/third_party")
target_compile_definitions(nmr_plugin_tests PRIVATE
  NMR_TEST_CLAP_BINARY="$<TARGET_FILE:nmr_plugin_clap>"
  NMR_TEST_CLAP_BUNDLE="$<TARGET_BUNDLE_DIR:nmr_plugin_clap>")
target_link_libraries(nmr_plugin_tests PRIVATE nmr_core clap nmr_warnings "-framework AppKit")
add_dependencies(nmr_plugin_tests nmr_plugin_clap)

add_test(NAME plugin.native COMMAND nmr_plugin_tests)
if("x86_64" IN_LIST CMAKE_OSX_ARCHITECTURES AND CMAKE_HOST_SYSTEM_PROCESSOR STREQUAL "arm64")
  execute_process(COMMAND /usr/bin/arch -x86_64 /usr/bin/true
    RESULT_VARIABLE nmr_plugin_rosetta OUTPUT_QUIET ERROR_QUIET)
  if(nmr_plugin_rosetta EQUAL 0)
    add_test(NAME plugin.x86_64 COMMAND /usr/bin/arch -x86_64 $<TARGET_FILE:nmr_plugin_tests>)
  else()
    message(WARNING "Rosetta is not installed: the plugin's x86_64 test run is skipped")
  endif()
endif()

add_executable(nmr_au_oop_host au_oop_host.mm)
target_compile_options(nmr_au_oop_host PRIVATE -fobjc-arc)
target_link_libraries(nmr_au_oop_host PRIVATE nmr_core nmr_warnings
  "-framework Foundation" "-framework AudioToolbox" "-framework CoreFoundation")

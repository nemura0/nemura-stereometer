# Host-side tests that need the installed plugins (run by scripts/validate.sh, not ctest).
add_executable(nmr_au_oop_host au_oop_host.mm)
target_compile_options(nmr_au_oop_host PRIVATE -fobjc-arc)
target_link_libraries(nmr_au_oop_host PRIVATE nmr_core nmr_warnings
  "-framework Foundation" "-framework AudioToolbox" "-framework CoreFoundation")

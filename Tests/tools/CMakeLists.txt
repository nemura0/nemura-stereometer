# Developer tools for tests, baselines and snapshots (not shipped).
add_executable(nmr_make_test_wav make_test_wav.cpp)
target_link_libraries(nmr_make_test_wav PRIVATE nmr_warnings)

# Renders a WAV through the meter renderer to a PNG (scripts/snapshots.sh).
if(TARGET nmr_render_test)
  add_executable(nmr_snapshot snapshot.mm)
  target_compile_options(nmr_snapshot PRIVATE -fobjc-arc)
  target_link_libraries(nmr_snapshot PRIVATE nmr_render_test nmr_warnings
    "-framework CoreGraphics" "-framework ImageIO")
endif()

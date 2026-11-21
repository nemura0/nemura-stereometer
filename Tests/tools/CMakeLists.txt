# Developer tools for tests, baselines and snapshots (not shipped).
add_executable(nmr_make_test_wav make_test_wav.cpp)
target_link_libraries(nmr_make_test_wav PRIVATE nmr_warnings)

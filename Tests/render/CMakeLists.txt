# GPU smoke tests for the Metal renderer (skipped where no Metal device exists).
add_executable(nmr_gpu_tests render_main.mm meter_renderer_test.mm)
target_include_directories(nmr_gpu_tests PRIVATE "${CMAKE_SOURCE_DIR}/Tests/cpp/third_party")
target_compile_options(nmr_gpu_tests PRIVATE -fobjc-arc)
target_link_libraries(nmr_gpu_tests PRIVATE nmr_render_test nmr_warnings)
add_test(NAME gpu.native COMMAND nmr_gpu_tests)

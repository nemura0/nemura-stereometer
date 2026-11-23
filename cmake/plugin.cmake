# Plugin formats: one CLAP, wrapped to VST3 and AUv2 by clap-wrapper (pinned in
# scripts/fetch-deps.sh). Each format compiles its own copy of the plugin and renderer sources so
# its ObjC classes get a per-format suffix (_Clap, _Vst3, _Au): hosts may load all three formats
# into one process. See docs/DECISIONS.md.

set(CLAP_SDK_ROOT "${NMR_EXTERNAL_DIR}/clap" CACHE PATH "CLAP SDK" FORCE)
set(VST3_SDK_ROOT "${NMR_EXTERNAL_DIR}/vst3sdk" CACHE PATH "VST3 SDK (3.8+, MIT)" FORCE)
set(AUDIOUNIT_SDK_ROOT "${NMR_EXTERNAL_DIR}/AudioUnitSDK" CACHE PATH "AudioUnitSDK" FORCE)
set(CLAP_WRAPPER_DOWNLOAD_DEPENDENCIES OFF CACHE BOOL "Never download SDKs" FORCE)
set(CLAP_WRAPPER_COPY_AFTER_BUILD OFF CACHE BOOL "Install with scripts/install-plugins.sh" FORCE)

foreach(required IN ITEMS
    "${CLAP_SDK_ROOT}/include/clap/clap.h"
    "${VST3_SDK_ROOT}/public.sdk/source/main/pluginfactory.cpp"
    "${AUDIOUNIT_SDK_ROOT}/src/AudioUnitSDK/AUBase.cpp"
    "${NMR_EXTERNAL_DIR}/clap-wrapper/CMakeLists.txt")
  if(NOT EXISTS "${required}")
    message(FATAL_ERROR "Missing ${required}. Run scripts/fetch-deps.sh first.")
  endif()
endforeach()

add_subdirectory("${NMR_EXTERNAL_DIR}/clap-wrapper" "${CMAKE_BINARY_DIR}/clap-wrapper" EXCLUDE_FROM_ALL)

set(NMR_PLUGIN_OUTPUT_DIR "${CMAKE_BINARY_DIR}/plugins")
set(NMR_PLUGIN_SOURCES
  "${CMAKE_CURRENT_SOURCE_DIR}/Plugin/entry.cpp"
  "${CMAKE_CURRENT_SOURCE_DIR}/Plugin/plugin.cpp"
  "${CMAKE_CURRENT_SOURCE_DIR}/Plugin/editor.mm"
  "${CMAKE_CURRENT_SOURCE_DIR}/Plugin/editor_controls.mm")

# nmr_add_plugin_module(<target> <objc-suffix>): an empty MODULE that links this format's own copy
# of the plugin code (an OBJECT library, so clap_entry is always linked in) and renderer. The
# wrapper functions add their sources to the MODULE; project warnings stay on our code only, but
# the deployment-target guard covers the wrapper sources too, since they ship in the same binary.
function(nmr_add_plugin_module target suffix)
  nmr_add_render(${target}_render ${suffix})

  add_library(${target}_code OBJECT ${NMR_PLUGIN_SOURCES})
  target_include_directories(${target}_code PRIVATE "${CMAKE_CURRENT_SOURCE_DIR}/Plugin")
  target_compile_options(${target}_code PRIVATE $<$<COMPILE_LANGUAGE:OBJCXX,OBJC>:-fobjc-arc>)
  target_link_libraries(${target}_code PUBLIC ${target}_render clap PRIVATE nmr_warnings)

  add_library(${target} MODULE)
  target_link_libraries(${target} PRIVATE ${target}_code)
  target_compile_options(${target} PRIVATE -Werror=unguarded-availability-new)
  set_target_properties(${target} PROPERTIES LIBRARY_OUTPUT_DIRECTORY "${NMR_PLUGIN_OUTPUT_DIR}")
endfunction()

# ---- CLAP ---------------------------------------------------------------------------------------
nmr_add_plugin_module(nmr_plugin_clap _Clap)
target_add_clap_configuration(
  TARGET nmr_plugin_clap
  OUTPUT_NAME "${NMR_PRODUCT_NAME}"
  BUNDLE_IDENTIFIER "${NMR_PLUGIN_BUNDLE_ID}.clap"
  BUNDLE_VERSION "${NMR_VERSION}")

# ---- VST3 ---------------------------------------------------------------------------------------
nmr_add_plugin_module(nmr_plugin_vst3 _Vst3)
target_add_vst3_wrapper(
  TARGET nmr_plugin_vst3
  OUTPUT_NAME "${NMR_PRODUCT_NAME}"
  BUNDLE_IDENTIFIER "${NMR_PLUGIN_BUNDLE_ID}.vst3"
  BUNDLE_VERSION "${NMR_VERSION}")

# ---- AUv2 ---------------------------------------------------------------------------------------
# "fromclap" mode: the build helper reads name/description from the built CLAP; the codes come
# from config/product.env.
nmr_add_plugin_module(nmr_plugin_auv2 _Au)
target_add_auv2_wrapper(
  TARGET nmr_plugin_auv2
  OUTPUT_NAME "${NMR_PRODUCT_NAME}"
  BUNDLE_IDENTIFIER "${NMR_PLUGIN_BUNDLE_ID}.component"
  BUNDLE_VERSION "${NMR_VERSION}"
  MANUFACTURER_NAME "${NMR_VENDOR}"
  MANUFACTURER_CODE "${NMR_AU_MANUFACTURER}"
  SUBTYPE_CODE "${NMR_AU_SUBTYPE}"
  INSTRUMENT_TYPE "${NMR_AU_TYPE}"
  CLAP_TARGET_FOR_CONFIG nmr_plugin_clap)

# clap-wrapper copies its generated Info.plist (with AudioComponents) into the bundle PRE_BUILD,
# that is only when the AU relinks; a CMake reconfigure under Ninja rewrites the bundle's
# Info.plist with CMake's default (BNDL code APPL, no AudioComponents), which then stays until the
# next relink and the AU is not registered. Copy the generated one on every build.
add_custom_target(nmr_plugin_auv2_plist ALL
  COMMAND "${CMAKE_COMMAND}" -E copy_if_different
    "${CMAKE_CURRENT_BINARY_DIR}/nmr_plugin_auv2-build-helper-output/auv2_Info.plist"
    "$<TARGET_FILE_DIR:nmr_plugin_auv2>/../Info.plist"
  DEPENDS nmr_plugin_auv2
  VERBATIM)

add_custom_target(nmr_plugins ALL
  DEPENDS nmr_plugin_clap nmr_plugin_vst3 nmr_plugin_auv2 nmr_plugin_auv2_plist)

# NEMURA Stereometer: core, renderer, plugin (CLAP + VST3 + AUv2 via clap-wrapper) and C++ tests.
# The app is built by SwiftPM (Package.swift) from the same Sources/{Core,Render,CoreC} files;
# scripts/check-sources.sh keeps the two builds in sync. Entry point: scripts/build.sh.
cmake_minimum_required(VERSION 3.28)

# ---- Product identity from config/product.env (single source of truth) -----------------------
file(STRINGS "${CMAKE_CURRENT_SOURCE_DIR}/config/product.env" NMR_CONFIG_LINES REGEX "^NMR_[A-Z_]+=")
foreach(line IN LISTS NMR_CONFIG_LINES)
  if(line MATCHES "^(NMR_[A-Z_]+)=\"([^\"]*)\"")
    set(${CMAKE_MATCH_1} "${CMAKE_MATCH_2}")
  endif()
endforeach()
if(NOT NMR_VERSION OR NOT NMR_CLAP_ID)
  message(FATAL_ERROR "config/product.env could not be parsed")
endif()

# ---- Platform: macOS 14.2+, plugins Universal 2 ----------------------------------------------
set(CMAKE_OSX_DEPLOYMENT_TARGET "14.2" CACHE STRING "Minimum macOS version" FORCE)
if(NOT DEFINED CMAKE_OSX_ARCHITECTURES)
  set(CMAKE_OSX_ARCHITECTURES "arm64;x86_64" CACHE STRING "Plugin architectures")
endif()

project(nemura_stereometer VERSION ${NMR_VERSION} LANGUAGES C CXX OBJC OBJCXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)
set(CMAKE_OBJCXX_STANDARD 20)
set(CMAKE_OBJCXX_STANDARD_REQUIRED ON)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)
set(CMAKE_C_VISIBILITY_PRESET hidden)
set(CMAKE_CXX_VISIBILITY_PRESET hidden)
set(CMAKE_OBJC_VISIBILITY_PRESET hidden)
set(CMAKE_OBJCXX_VISIBILITY_PRESET hidden)
set(CMAKE_VISIBILITY_INLINES_HIDDEN ON)
set(CMAKE_EXPORT_COMPILE_COMMANDS ON)

option(NMR_BUILD_PLUGIN "Build the CLAP/VST3/AUv2 plugins (needs scripts/fetch-deps.sh)" ON)
option(NMR_BUILD_TESTS "Build the C++ tests" ON)
option(NMR_WERROR "Treat warnings in project code as errors" OFF)
set(NMR_EXTERNAL_DIR "${CMAKE_CURRENT_SOURCE_DIR}/external" CACHE PATH "Fetched SDKs")

# Warnings and the deployment-target guard for project code only (never for SDK sources).
add_library(nmr_warnings INTERFACE)
target_compile_options(nmr_warnings INTERFACE
  -Wall -Wextra -Wno-unused-parameter
  -Werror=unguarded-availability-new
  -Werror=return-type
  $<$<BOOL:${NMR_WERROR}>:-Werror>)

# ---- Sources/Core: C++20 -----------------------------------------------------------------------
file(GLOB NMR_CORE_SOURCES CONFIGURE_DEPENDS "${CMAKE_CURRENT_SOURCE_DIR}/Sources/Core/*.cpp")
add_library(nmr_core STATIC ${NMR_CORE_SOURCES})
target_include_directories(nmr_core
  PUBLIC "${CMAKE_CURRENT_SOURCE_DIR}/Sources/Core/include"
  PRIVATE "${CMAKE_CURRENT_SOURCE_DIR}/Sources/Core/third_party")
target_link_libraries(nmr_core PRIVATE nmr_warnings)

# ---- Sources/Render: ObjC++ (compiled once per target for per-target ObjC class names) --------
file(GLOB NMR_RENDER_SOURCES CONFIGURE_DEPENDS
  "${CMAKE_CURRENT_SOURCE_DIR}/Sources/Render/*.mm"
  "${CMAKE_CURRENT_SOURCE_DIR}/Sources/Render/*.cpp")

# nmr_add_render(<target> <objc-suffix>): a static renderer library whose ObjC classes end in
# <objc-suffix>. Every binary that can share a process with another gets its own suffix.
function(nmr_add_render target suffix)
  add_library(${target} STATIC ${NMR_RENDER_SOURCES})
  target_include_directories(${target} PUBLIC "${CMAKE_CURRENT_SOURCE_DIR}/Sources/Render/include")
  target_compile_definitions(${target} PUBLIC NMR_OBJC_SUFFIX=${suffix})
  target_compile_options(${target} PRIVATE $<$<COMPILE_LANGUAGE:OBJCXX,OBJC>:-fobjc-arc>)
  target_link_libraries(${target}
    PUBLIC nmr_core
    "-framework Foundation" "-framework AppKit" "-framework Metal" "-framework QuartzCore"
    "-framework CoreAudio" "-framework AudioToolbox"
    PRIVATE nmr_warnings)
endfunction()

# ---- Sources/CoreC: the C API Swift uses (built here too so both builds compile it) ----------
file(GLOB NMR_COREC_SOURCES CONFIGURE_DEPENDS
  "${CMAKE_CURRENT_SOURCE_DIR}/Sources/CoreC/*.mm"
  "${CMAKE_CURRENT_SOURCE_DIR}/Sources/CoreC/*.cpp")
if(NMR_COREC_SOURCES)
  nmr_add_render(nmr_render_test _Test)
  add_library(nmr_corec STATIC ${NMR_COREC_SOURCES})
  target_include_directories(nmr_corec PUBLIC "${CMAKE_CURRENT_SOURCE_DIR}/Sources/CoreC/include")
  target_compile_options(nmr_corec PRIVATE $<$<COMPILE_LANGUAGE:OBJCXX,OBJC>:-fobjc-arc>)
  target_link_libraries(nmr_corec PUBLIC nmr_render_test PRIVATE nmr_warnings)
endif()

# ---- Plugin -------------------------------------------------------------------------------------
if(NMR_BUILD_PLUGIN)
  include(cmake/plugin.cmake)
endif()

# ---- Tests --------------------------------------------------------------------------------------
if(NMR_BUILD_TESTS)
  enable_testing()
  add_subdirectory(Tests/cpp)
  if(NMR_BUILD_PLUGIN)
    add_subdirectory(Tests/host)
  endif()
endif()

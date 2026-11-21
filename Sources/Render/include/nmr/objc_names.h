// Per-target Objective-C class names.
//
// A host can load the AU, VST3 and CLAP builds of the plugin into one process, and Objective-C
// class names are global to a process: two binaries defining the same class name make the
// runtime pick one arbitrarily. Every ObjC class in shared or plugin code is therefore declared
// as NMR_OBJC(Name), which expands to <prefix><Name><suffix>, e.g. NMRStmRenderView_Vst3.
// NMR_OBJC_SUFFIX is set per build target (_Clap, _Vst3, _Au, _App, _Test).
#pragma once

#include <nmr/product_config.h>

#ifndef NMR_OBJC_SUFFIX
#error "NMR_OBJC_SUFFIX must be defined by the build target (e.g. _Clap, _Vst3, _Au, _App)"
#endif

#define NMR_OBJC_CAT_(a, b) a##b
#define NMR_OBJC_CAT(a, b) NMR_OBJC_CAT_(a, b)
#define NMR_OBJC(name) NMR_OBJC_CAT(NMR_OBJC_CAT(NMR_OBJC_PREFIX_TOKEN, name), NMR_OBJC_SUFFIX)

#define NMR_OBJC_STR_(x) #x
#define NMR_OBJC_STR(x) NMR_OBJC_STR_(x)
// The expanded class name as a C string, for logging and tests.
#define NMR_OBJC_NAME(name) NMR_OBJC_STR(NMR_OBJC(name))

// rlottie reads its feature switches from "config.h", which its CMake build
// generates. This is the hand-written equivalent for the SwiftPM build.
#pragma once

// Every deployment target of this package has thread-local storage, so the
// renderer can use its worker threads.
#define LOTTIE_THREAD_SUPPORT

// RapidJSON asserts would abort on malformed animation files; parse errors
// are reported through the normal error path instead.
#define RAPIDJSON_ASSERT(x)

// Not enabled: LOTTIE_LOGGING_SUPPORT, LOTTIE_IMAGE_MODULE_SUPPORT,
// LOTTIE_CACHE_SUPPORT.

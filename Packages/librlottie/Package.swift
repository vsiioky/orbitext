// swift-tools-version:5.9

import PackageDescription

// Compiles the vendored rlottie renderer (rlottie/) as a static library for
// Orbitext. Build settings that rlottie normally gets from CMake live in
// Support/; the C API headers Swift imports live in PublicHeaders/.

let rlottieSources = "rlottie/src"

let notCompiled = [
    "rlottie/src/lottie/rapidjson/msinttypes", // MSVC-only headers
    "rlottie/src/vector/pixman", // replaced by Support/neon_fallback.cpp
    "rlottie/src/vector/vdrawhelper_neon.cpp",
]

let headerDirs = [
    "Support",
    "rlottie/inc",
    "rlottie/src/vector",
    "rlottie/src/vector/freetype",
]

let package = Package(
    name: "librlottie",
    platforms: [.watchOS(.v10), .iOS(.v17), .macOS(.v13)],
    products: [.library(name: "librlottie", targets: ["librlottie"])],
    targets: [
        .target(
            name: "librlottie",
            path: ".",
            exclude: notCompiled,
            sources: [rlottieSources, "Support"],
            publicHeadersPath: "PublicHeaders",
            cSettings: headerDirs.map { .headerSearchPath($0) } + [
                // Third-party code: keep its warnings out of the app build.
                .unsafeFlags(["-w"]),
            ],
            cxxSettings: [.unsafeFlags(["-w"])]
        ),
    ],
    cLanguageStandard: .gnu11,
    cxxLanguageStandard: .gnucxx14
)

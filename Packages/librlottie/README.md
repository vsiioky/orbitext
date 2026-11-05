# librlottie

Vendored copy of the rlottie vector animation renderer, built through
Swift Package Manager. Used by the app to render Lottie (TGS) stickers.

## Provenance

- Upstream: https://github.com/Samsung/rlottie
- Commit: 3cd00151cfb961e8dc4b55cdaa9b35b95c86879e ("0.2")
- Vendored under `rlottie/`, with the local changes listed below.

## What was removed from upstream

Everything not needed to build the library:

- `example/` (sample animations and demo apps), `.Gifs/`, `test/`
- `vs2019/` (including prebuilt Windows binaries), `src/wasm/`, `packaging/`
- CI and cross-build files (`.travis.yml`, `.appveyor.yml`, `arm_*`, `wasm_*`)
- CMake and meson build files (`CMakeLists.txt`, `meson.build`,
  `meson_options.txt`, `cmake/`); SwiftPM does not use them

`rlottie/src/vector/pixman` stays in the tree for its license and
sources but is not compiled (see `Package.swift`).

## Local modifications

Security fixes backported from upstream pull requests #571 and #572. These
notes also serve as the change documentation required by the FreeType License.

- `rlottie/src/lottie/lottieitem.cpp`
- `rlottie/src/lottie/lottiemodel.cpp`
- `rlottie/src/lottie/lottiemodel.h`
- `rlottie/src/lottie/lottieparser.cpp`
  Hardening of the Lottie model and parser against malformed input
  (upstream PRs #571 and #572).
- `rlottie/src/vector/freetype/v_ft_raster.cpp`
  - `gray_render_line()` stops when a coordinate delta exceeds 10000000.
  - `gray_render_conic()` stops when the arc stack reaches 32 levels.

## Licenses

| Component | Path | License |
|-----------|------|---------|
| rlottie | `rlottie/` | MIT (`rlottie/licenses/COPYING.MIT`) |
| FreeType rasterizer | `rlottie/src/vector/freetype` | FreeType License, FTL (`COPYING.FTL`) |
| RapidJSON | `rlottie/src/lottie/rapidjson` | MIT (`COPYING.RPD`) |
| stb | `rlottie/src/vector/stb` | public domain / MIT (`COPYING.STB`) |
| Skia | parts of `rlottie/src/vector` | BSD-3-Clause (`COPYING.SKIA`) |
| Mozilla SMIL key spline | `rlottie/src/vector/vinterpolator.cpp` | MPL-2.0 (`COPYING.MPL`) |
| pixman | `rlottie/src/vector/pixman` | MIT (`COPYING.PIX`), not compiled |

Note: the upstream `rlottie/COPYING` map does not list `vinterpolator.cpp`
(MPL-2.0); the table above does. Upstream `COPYING` is left unmodified.

## Project files

Written for this project and covered by the project license (GPL-3.0-only):
`Package.swift`, `Support/config.h`, `Support/neon_fallback.cpp` and
`PublicHeaders/librlottie.h`. `PublicHeaders/rlottie_capi.h` and
`PublicHeaders/rlottiecommon.h` are unchanged copies of the rlottie MIT headers
from `rlottie/inc/`.

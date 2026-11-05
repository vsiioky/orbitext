# Third-Party Notices

Orbitext is licensed under the GNU General Public License, version 3 only
(GPL-3.0-only, see LICENSE).
It contains or links the third-party software listed below. Each component remains
under its own license; full texts are in the files referenced for each entry.
The app shows this file and every license text it references in
Settings -> Open-Source Licenses.
"App" marks code compiled into the Orbitext app; "source only" marks code present
in this repository but not part of the app.

"Telegram" is a trademark of Telegram FZ-LLC. Orbitext is an unofficial client that
uses the Telegram API and is not affiliated with, endorsed by or sponsored by Telegram.

## TDLib (Telegram Database Library) - app
- Version: 1.8.64, commit 89ebded9571b7bb589ec1bd05e585fffa4c580e2
- Modified: yes, see native-patches/tdlib-darwin-http-memory.patch and native-patches/tdlib-token-invalidated.patch
- License: BSL-1.0 - LICENSES/BSL-1.0.txt
- Copyright Aliaksei Levin (levlam@telegram.org), Arseny Smirnov (arseny30@gmail.com) 2014-2026
- Upstream: https://github.com/tdlib/td
- Also derived from TDLib: scripts/td_api.tl (verbatim copy of td/generate/scheme/td_api.tl)
  and the Swift bindings generated from it in Orbitext/Telegram/Generated/

### SQLite (bundled in TDLib) - app
- Version: 3.31.0
- License: public domain - https://sqlite.org/copyright.html

### SQLCipher (bundled in TDLib) - app
- License: BSD-3-Clause - LICENSES/BSD-3-Clause-SQLCipher.txt
- Copyright (c) 2008, ZETETIC LLC. All rights reserved.
- Upstream: https://github.com/sqlcipher/sqlcipher

## OpenSSL - app (used by TDLib)
- Version: 3.4.0
- License: Apache-2.0 - LICENSES/Apache-2.0.txt
- Copyright (c) 1998-2024 The OpenSSL Project Authors
- Copyright (c) 1995-1998 Eric A. Young, Tim J. Hudson
- Upstream: https://www.openssl.org

## rlottie - app
- Version: commit 3cd00151cfb961e8dc4b55cdaa9b35b95c86879e (0.2), in Packages/librlottie/rlottie
- Modified: security fixes backported from upstream pull requests #571 and #572 in
  src/lottie/lottieitem.cpp, src/lottie/lottiemodel.cpp, src/lottie/lottiemodel.h,
  src/lottie/lottieparser.cpp and src/vector/freetype/v_ft_raster.cpp
  (details in Packages/librlottie/README.md)
- License: MIT - Packages/librlottie/rlottie/licenses/COPYING.MIT
- Copyright 2020 the rlottie authors (Packages/librlottie/rlottie/AUTHORS)
- Copyright (c) 2020 Samsung Electronics Co., Ltd.
- Upstream: https://github.com/Samsung/rlottie

rlottie contains code under the following licenses (map: Packages/librlottie/rlottie/COPYING):

### FreeType (src/vector/freetype) - app
- License: FTL - Packages/librlottie/rlottie/licenses/COPYING.FTL
- Copyright 1996-2014 by David Turner, Robert Wilhelm, and Werner Lemberg
- Portions of this software are copyright (c) 2014 The FreeType Project (https://www.freetype.org).
  All rights reserved.
- This software is based in part on the work of the FreeType Team.
- Changes: adapted by the rlottie project from ftgrays.c, ftstroke.c, fttrigon.c and ftimage.h
  (renamed v_ft_*, SW_FT_ prefixes). Orbitext changes in v_ft_raster.cpp: gray_render_line()
  stops on coordinate deltas above 10000000; gray_render_conic() stops when the arc stack
  reaches 32 levels.

### RapidJSON (src/lottie/rapidjson) - app
- License: MIT - Packages/librlottie/rlottie/licenses/COPYING.RPD
- Copyright (C) 2015 THL A29 Limited, a Tencent company, and Milo Yip. All rights reserved.
- Upstream: https://github.com/Tencent/rapidjson
- src/lottie/rapidjson/msinttypes (source only): BSD-3-Clause,
  Copyright (c) 2006-2013 Alexander Chemeris (text in COPYING.RPD)

### stb_image 2.19 (src/vector/stb) - app
- License: public domain or MIT - Packages/librlottie/rlottie/licenses/COPYING.STB
- Copyright (c) 2017 Sean Barrett
- Upstream: https://github.com/nothings/stb

### Skia arena allocator (src/vector/varenaalloc.cpp, src/vector/varenaalloc.h) - app
- License: BSD-3-Clause - Packages/librlottie/rlottie/licenses/COPYING.SKIA
- Copyright 2016 Google Inc.
- Upstream: https://skia.org

### Mozilla SMIL key spline (src/vector/vinterpolator.cpp) - app
- License: MPL-2.0 - Packages/librlottie/rlottie/licenses/COPYING.MPL
- Source Code Form: Packages/librlottie/rlottie/src/vector/vinterpolator.cpp in this repository
- Upstream: https://hg.mozilla.org/mozilla-central (dom/smil)

### pixman (src/vector/pixman) - source only, not compiled
- License: MIT - Packages/librlottie/rlottie/licenses/COPYING.PIX
- Copyright 1987-2010 The Open Group, Digital Equipment Corporation, Keith Packard,
  SuSE, Inc., Red Hat, Inc., Nicholas Miell and the other holders listed in COPYING.PIX
- Upstream: https://gitlab.freedesktop.org/pixman/pixman

## Swift QR Code generator (Orbitext/Vendor/QRCodeGenerator) - app
- License: MIT - LICENSES/MIT-QRCodeGenerator.txt (also in each file header)
- Copyright (c) Project Nayuki
- Copyright (c) 2020 fwcd
- Upstream: https://github.com/fwcd/swift-qrcode-generator
  (Swift port of https://www.nayuki.io/page/qr-code-generator-library)

## System libraries (not redistributed)
- zlib (Zlib license) and the C++ standard library are linked from the Apple SDK.

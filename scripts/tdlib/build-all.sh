#!/usr/bin/env bash
# Builds every TDLib/OpenSSL archive the app links, for all slices, from one
# pinned TDLib commit and one OpenSSL release, with the patches in
# native-patches/ applied. Inputs are copied, never modified.
#
#   scripts/tdlib/build-all.sh --td <tdlib checkout> --openssl <openssl source> \
#       [--work DIR] [--jobs N] [--install]
#
#   --td        TDLib git checkout at TD_COMMIT (clean)
#   --openssl   OpenSSL source tree of OPENSSL_VERSION
#   --work      scratch directory (default build/tdlib-work); results land in
#               <work>/out/lib-device and <work>/out/lib-simulator
#   --install   replace TDLib/lib-device and TDLib/lib-simulator with the new
#               archives and re-pin scripts/tdlib/libs.sha256
#
# Slices: watchOS device arm64 and arm64_32 (merged with lipo into
# lib-device; the App Store requires arm64_32 even though the app runs only
# on arm64 watches) and watchOS simulator arm64 (lib-simulator).
set -euo pipefail

TD_COMMIT=89ebded9571b7bb589ec1bd05e585fffa4c580e2 # TDLib 1.8.64
OPENSSL_VERSION=3.4.0
WATCHOS_MIN=26.0
ARCHIVES=(libtdactor libtdapi libtdclient libtdcore libtddb libtde2e libtdjson_private libtdjson_static
  libtdmtproto libtdnet libtdsqlite libtdutils)

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
td_src="" openssl_src="" work="$ROOT/build/tdlib-work" jobs="$(sysctl -n hw.ncpu)" install=0
while (( $# )); do
  case "$1" in
    --td) td_src="$(cd "$2" && pwd)"; shift 2 ;;
    --openssl) openssl_src="$(cd "$2" && pwd)"; shift 2 ;;
    --work) work="$2"; shift 2 ;;
    --jobs) jobs="$2"; shift 2 ;;
    --install) install=1; shift ;;
    -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done
[[ -n "$td_src" && -n "$openssl_src" ]] || { sed -n '2,20p' "$0" >&2; exit 2; }

log() { printf '\n==== %s ====\n' "$*"; }

# Same toolchain as the app build (scripts/verify.sh): the release Xcode, not
# whatever xcode-select points at.
if [[ -z "${DEVELOPER_DIR:-}" && -d /Applications/Xcode.app/Contents/Developer ]]; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi

log "check inputs"
[[ "$(git -C "$td_src" rev-parse HEAD)" == "$TD_COMMIT" ]] || { echo "TDLib must be at $TD_COMMIT" >&2; exit 1; }
[[ -z "$(git -C "$td_src" status --porcelain --untracked-files=no)" ]] || { echo "TDLib checkout has local changes" >&2; exit 1; }
# shellcheck disable=SC1091
source "$openssl_src/VERSION.dat"
[[ "$MAJOR.$MINOR.$PATCH" == "$OPENSSL_VERSION" ]] || { echo "OpenSSL source is $MAJOR.$MINOR.$PATCH, need $OPENSSL_VERSION" >&2; exit 1; }

rm -rf "$work"
mkdir -p "$work"
work="$(cd "$work" && pwd)"

log "copy TDLib $TD_COMMIT and apply native patches"
mkdir "$work/td"
git -C "$td_src" archive --format=tar "$TD_COMMIT" | tar -x -C "$work/td"
for patch in "$ROOT"/native-patches/*.patch; do
  patch --batch --forward --fuzz=0 -p1 -d "$work/td" -i "$patch"
done

log "host build: TL generators and generated sources"
cmake -S "$work/td" -B "$work/host" -DCMAKE_BUILD_TYPE=Release -DTD_ENABLE_LTO=OFF > "$work/host-configure.log"
cmake --build "$work/host" --target prepare_cross_compiling --parallel "$jobs" > "$work/host-build.log"

build_openssl() { # slice sdk arch triple
  local slice="$1" sdk_name="$2" arch="$3" triple="$4"
  local src="$work/openssl-src-$slice" prefix="$work/openssl-$slice" sdk
  sdk="$(xcrun --sdk "$sdk_name" --show-sdk-path)"
  cp -R "$openssl_src" "$src"
  (
    cd "$src"
    make distclean > /dev/null 2>&1 || true
    # OpenSSL has no watchOS target; iphoneos-cross gives Darwin conventions
    # and the flags below retarget it. no-asm: the aarch64 assembly assumes
    # 64-bit pointers (arm64_32). Deprecated APIs stay: TDLib's SQLCipher uses
    # HMAC_CTX_new and friends.
    ./Configure iphoneos-cross no-shared no-asm no-engine no-dso no-tests no-ui-console no-srp no-cmp no-comp \
      --prefix="$prefix" --openssldir="$prefix/etc/openssl" \
      CC="$(xcrun --sdk "$sdk_name" --find clang)" \
      CROSS_TOP="$(dirname "$(dirname "$sdk")")" CROSS_SDK="$(basename "$sdk")" > "$work/openssl-$slice.log"
    local flags="-arch $arch -target $triple -isysroot $sdk -O3 -fPIC"
    # build_libs would also link apps/, which calls fork() (unavailable on
    # watchOS); build the generated headers and the two archives only.
    make -j"$jobs" build_generated CFLAGS="$flags" CNF_CFLAGS="$flags" LDFLAGS="$flags" >> "$work/openssl-$slice.log"
    make -j"$jobs" libcrypto.a libssl.a CFLAGS="$flags" CNF_CFLAGS="$flags" LDFLAGS="$flags" >> "$work/openssl-$slice.log"
    mkdir -p "$prefix/lib" "$prefix/include"
    cp libcrypto.a libssl.a "$prefix/lib/"
    cp -R include/openssl "$prefix/include/"
  )
  rm -rf "$src"
}

build_tdlib() { # slice platform arch
  local slice="$1" platform="$2" arch="$3"
  local ssl="$work/openssl-$slice" build="$work/build-$slice"
  cmake -S "$work/td" -B "$build" -G "Unix Makefiles" \
    -DIOS_PLATFORM="$platform" -DIOS_ARCH="$arch" -DIOS_DEPLOYMENT_TARGET="$WATCHOS_MIN" \
    -DCMAKE_TOOLCHAIN_FILE="$work/td/CMake/iOS.cmake" -DCMAKE_MAKE_PROGRAM=/usr/bin/make \
    -DCMAKE_BUILD_TYPE=Release -DTD_ENABLE_LTO=OFF \
    -DCMAKE_C_FLAGS="-I$ssl/include" -DCMAKE_CXX_FLAGS="-I$ssl/include" \
    -DOPENSSL_FOUND=1 -DOPENSSL_INCLUDE_DIR="$ssl/include" \
    -DOPENSSL_CRYPTO_LIBRARY="$ssl/lib/libcrypto.a" -DOPENSSL_SSL_LIBRARY="$ssl/lib/libssl.a" \
    -DOPENSSL_LIBRARIES="$ssl/lib/libcrypto.a;$ssl/lib/libssl.a" > "$work/tdlib-$slice-configure.log"
  ZERO_AR_DATE=1 cmake --build "$build" --target tdjson_static --parallel "$jobs" > "$work/tdlib-$slice-build.log"
  mkdir -p "$work/slices/$slice"
  local name found
  for name in "${ARCHIVES[@]}"; do
    found="$(find "$build" -name "$name.a" -type f | head -1)"
    [[ -n "$found" ]] || { echo "missing $name.a in $build" >&2; exit 1; }
    cp "$found" "$work/slices/$slice/"
  done
  cp "$ssl/lib/libcrypto.a" "$ssl/lib/libssl.a" "$work/slices/$slice/"
}

for spec in \
  "device-arm64 watchos arm64 arm64-apple-watchos$WATCHOS_MIN WATCHOS" \
  "device-arm64_32 watchos arm64_32 arm64_32-apple-watchos$WATCHOS_MIN WATCHOS" \
  "simulator-arm64 watchsimulator arm64 arm64-apple-watchos$WATCHOS_MIN-simulator WATCHSIMULATOR"; do
  read -r slice sdk_name arch triple platform <<< "$spec"
  log "$slice: OpenSSL $OPENSSL_VERSION"
  build_openssl "$slice" "$sdk_name" "$arch" "$triple"
  log "$slice: TDLib"
  build_tdlib "$slice" "$platform" "$arch"
done

log "assemble"
mkdir -p "$work/out/lib-device" "$work/out/lib-simulator"
for archive in "$work"/slices/device-arm64/*.a; do
  name="$(basename "$archive")"
  lipo -create "$archive" "$work/slices/device-arm64_32/$name" -output "$work/out/lib-device/$name"
  [[ "$(lipo -archs "$work/out/lib-device/$name")" == "arm64 arm64_32" ]] || { echo "bad slices in $name" >&2; exit 1; }
  cp "$work/slices/simulator-arm64/$name" "$work/out/lib-simulator/$name"
  [[ "$(lipo -archs "$work/out/lib-simulator/$name")" == "arm64" ]] || { echo "bad slice in simulator $name" >&2; exit 1; }
done
cat > "$work/out/BUILD-INFO" <<EOF
tdlib_commit=$TD_COMMIT
openssl_version=$OPENSSL_VERSION
watchos_min=$WATCHOS_MIN
patches=$(cd "$ROOT/native-patches" && shasum -a 256 ./*.patch | tr '\n' ' ')
xcode=$(xcodebuild -version | tr '\n' ' ')
EOF
echo "archives in $work/out"

if (( install )); then
  log "install into TDLib/"
  cd "$ROOT"
  rm -rf TDLib/lib-device TDLib/lib-simulator
  cp -R "$work/out/lib-device" "$work/out/lib-simulator" TDLib/
  cp "$work/out/BUILD-INFO" TDLib/BUILD-INFO
  scripts/tdlib/verify-libs.sh --update
fi

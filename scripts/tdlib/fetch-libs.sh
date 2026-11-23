#!/usr/bin/env bash
# Downloads the pinned TDLib/OpenSSL archives and checks every file against
# scripts/tdlib/libs.sha256. Nothing unverified is left in TDLib/.
#
#   scripts/tdlib/fetch-libs.sh
#   TDLIB_LIBS_URL=https://.../tdlib-libs.tar.gz scripts/tdlib/fetch-libs.sh
#
# By default it downloads the GitHub release that matches the committed
# manifest: tag tdlib-libs-<first 12 hex of sha256(libs.sha256)>, published by
# scripts/tdlib/package-libs.sh. TDLIB_LIBS_URL overrides the location.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"
RELEASES="https://github.com/vsiioky/orbitext/releases/download"
manifest_id="$(shasum -a 256 scripts/tdlib/libs.sha256 | cut -c1-12)"
TDLIB_LIBS_URL="${TDLIB_LIBS_URL:-$RELEASES/tdlib-libs-$manifest_id/tdlib-libs.tar.gz}"
echo "TDLib libraries: $TDLIB_LIBS_URL"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
curl --fail --location --silent --show-error --retry 3 -o "$tmp/libs.tar.gz" "$TDLIB_LIBS_URL"
tar -xzf "$tmp/libs.tar.gz" -C "$tmp" TDLib/BUILD-INFO TDLib/lib-device TDLib/lib-simulator

# Verify against the manifest committed here, not the one inside the tarball.
(cd "$tmp" && shasum -a 256 --check --quiet "$ROOT/scripts/tdlib/libs.sha256")
mkdir -p TDLib
rm -rf TDLib/lib-device TDLib/lib-simulator
mv "$tmp/TDLib/lib-device" "$tmp/TDLib/lib-simulator" "$tmp/TDLib/BUILD-INFO" TDLib/
scripts/tdlib/verify-libs.sh

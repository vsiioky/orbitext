#!/usr/bin/env bash
# Downloads the pinned TDLib/OpenSSL archives and checks every file against
# scripts/tdlib/libs.sha256. Nothing unverified is left in TDLib/.
#
#   TDLIB_LIBS_URL=https://.../tdlib-libs.tar.gz scripts/tdlib/fetch-libs.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"
: "${TDLIB_LIBS_URL:?set TDLIB_LIBS_URL to the tarball made by scripts/tdlib/package-libs.sh}"

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

#!/usr/bin/env bash
# Packs the pinned TDLib/OpenSSL archives for CI and other machines.
#
#   scripts/tdlib/package-libs.sh [output.tar.gz]
#
# Publish the tarball once per rebuild as a GitHub release asset, tagged with
# the manifest id this script prints; scripts/tdlib/fetch-libs.sh finds it by
# that tag:
#   gh release create tdlib-libs-<manifest id> build/tdlib-libs.tar.gz --latest=false
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"
out="${1:-build/tdlib-libs.tar.gz}"
mkdir -p "$(dirname "$out")"

scripts/tdlib/verify-libs.sh
# The archive redistributes TDLib, OpenSSL and SQLCipher binaries, so it
# carries their license texts and the notices file.
tar -czf "$out" scripts/tdlib/libs.sha256 TDLib/BUILD-INFO TDLib/lib-device TDLib/lib-simulator \
  LICENSES THIRD_PARTY_NOTICES.md
echo "$out  sha256=$(shasum -a 256 "$out" | awk '{print $1}')"
echo "manifest id: $(shasum -a 256 scripts/tdlib/libs.sha256 | cut -c1-12)"

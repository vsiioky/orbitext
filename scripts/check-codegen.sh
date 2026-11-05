#!/usr/bin/env bash
# Checks that the generated TDLib bindings match the library the app links:
#
#   1. the vendored schema (scripts/td_api.tl.source) was taken from the TDLib
#      commit that scripts/tdlib/build-all.sh builds (TD_COMMIT);
#   2. regenerating from scripts/td_api.tl and scripts/codegen-roots.txt gives
#      exactly the committed files in Orbitext/Telegram/Generated (the generator
#      also verifies that td_api.tl is the file recorded in td_api.tl.source).
#
# Run from scripts/verify.sh. To fix a failure: scripts/codegen.sh.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

# Used only when scripts/tdlib/build-all.sh is absent. Keep it equal to
# TD_COMMIT there (TDLib 1.8.64).
FALLBACK_TD_COMMIT=89ebded9571b7bb589ec1bd05e585fffa4c580e2

BUILD_SCRIPT=scripts/tdlib/build-all.sh
SCHEMA_SOURCE=scripts/td_api.tl.source
GENERATED=Orbitext/Telegram/Generated

failed=0
fail() { echo "FAIL: $*" >&2; failed=1; }

if [[ -f "$BUILD_SCRIPT" ]]; then
  td_commit="$(sed -n 's/^TD_COMMIT=\([0-9a-f]\{40\}\).*/\1/p' "$BUILD_SCRIPT" | head -1)"
  if [[ -z "$td_commit" ]]; then
    echo "check-codegen: no TD_COMMIT=<40 hex digits> line in $BUILD_SCRIPT" >&2
    exit 1
  fi
else
  td_commit="$FALLBACK_TD_COMMIT"
  echo "note: $BUILD_SCRIPT not found, comparing against $FALLBACK_TD_COMMIT"
fi

schema_commit="$(sed -n 's/^commit=//p' "$SCHEMA_SOURCE" | head -1)"
libs_commit="$(sed -n 's/^tdlib_commit=//p' TDLib/BUILD-INFO 2>/dev/null | head -1)"
if [[ -n "$libs_commit" && "$libs_commit" != "$schema_commit" ]]; then
  fail "TDLib/BUILD-INFO says the linked libraries are TDLib $libs_commit, the bindings are generated from $schema_commit"
fi
if [[ "$schema_commit" != "$td_commit" ]]; then
  fail "$SCHEMA_SOURCE records TDLib $schema_commit but the libraries are built from $td_commit; vendor td/generate/scheme/td_api.tl of that commit (see $GENERATED/README.md)"
fi

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
if ! scripts/codegen.sh "$tmp" > "$tmp/codegen.log" 2>&1; then
  cat "$tmp/codegen.log" >&2
  fail "the generator rejected its inputs"
else
  for file in TDLibSchema.swift TDLibDecoders.swift; do
    if ! diff -u "$GENERATED/$file" "$tmp/$file" > "$tmp/$file.diff"; then
      head -40 "$tmp/$file.diff" >&2
      fail "$GENERATED/$file is not what the generator produces: run scripts/codegen.sh"
    fi
  done
fi

if (( failed )); then
  exit 1
fi
echo "generated TDLib bindings match TDLib $td_commit"

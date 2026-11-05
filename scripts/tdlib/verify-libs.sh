#!/usr/bin/env bash
# Checks that the prebuilt TDLib/OpenSSL archives the app links are present
# and are exactly the pinned ones listed in libs.sha256.
#
#   scripts/tdlib/verify-libs.sh            verify
#   scripts/tdlib/verify-libs.sh --update   re-pin after an intentional rebuild
#   scripts/tdlib/verify-libs.sh --http-patch FILE...
#                                           only run the DarwinHttp patch check
#                                           on the given libtdnet.a archives
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"
MANIFEST=scripts/tdlib/libs.sha256
DIRS=(TDLib/lib-device TDLib/lib-simulator)

# native-patches/tdlib-darwin-http-memory.patch wraps DarwinHttp::get/post in an
# @autoreleasepool. Without it every HTTP request leaks on TDLib's pool-less
# threads (about 40 MB/hour on a watch). A hash match proves only that the
# archives are the pinned ones, so also require, for every slice, that the
# DarwinHttp object imports _objc_autoreleasePoolPush. The symbol is looked up
# in that member only: other members of libtdnet.a import it for other reasons.
check_http_patch() {
  local archive arch listing member_pattern status=0
  member_pattern=':DarwinHttp\.mm\.o: '
  for archive in "$@"; do
    if [[ ! -f "$archive" ]]; then
      echo "missing $archive" >&2
      status=1
      continue
    fi
    for arch in $(lipo -archs "$archive"); do
      listing="$(nm -arch "$arch" -A "$archive" 2>/dev/null | grep -E "$member_pattern" || true)"
      if [[ -z "$listing" ]]; then
        echo "$archive [$arch]: no DarwinHttp.mm.o member" >&2
        status=1
      elif ! grep -Eq "${member_pattern} +U _objc_autoreleasePoolPush\$" <<<"$listing"; then
        echo "$archive [$arch]: DarwinHttp.mm.o does not import _objc_autoreleasePoolPush;" >&2
        echo "  native-patches/tdlib-darwin-http-memory.patch is missing from this archive" >&2
        status=1
      fi
    done
  done
  return "$status"
}
HTTP_ARCHIVES=(TDLib/lib-device/libtdnet.a TDLib/lib-simulator/libtdnet.a)

if [[ "${1:-}" == "--http-patch" ]]; then
  shift
  check_http_patch "$@"
  echo "DarwinHttp autorelease pool present in $# archive(s)"
  exit 0
fi

if [[ "${1:-}" == "--update" ]]; then
  check_http_patch "${HTTP_ARCHIVES[@]}"
  { find "${DIRS[@]}" -name '*.a' -type f; echo TDLib/BUILD-INFO; } | LC_ALL=C sort | xargs shasum -a 256 > "$MANIFEST"
  echo "pinned $(wc -l < "$MANIFEST" | tr -d ' ') archives in $MANIFEST"
  exit 0
fi

for dir in "${DIRS[@]}"; do
  if [[ ! -d "$dir" ]]; then
    echo "missing $dir: fetch the pinned archives (scripts/tdlib/fetch-libs.sh) or build them (scripts/tdlib/build-all.sh)" >&2
    exit 1
  fi
done

shasum -a 256 --check --quiet "$MANIFEST"
unexpected="$(comm -13 <(awk '{print $2}' "$MANIFEST" | LC_ALL=C sort) \
  <({ find "${DIRS[@]}" -name '*.a' -type f; echo TDLib/BUILD-INFO; } | LC_ALL=C sort))"
if [[ -n "$unexpected" ]]; then
  echo "archives not in $MANIFEST:" >&2
  echo "$unexpected" >&2
  exit 1
fi
echo "TDLib archives match $MANIFEST"
check_http_patch "${HTTP_ARCHIVES[@]}"
echo "TDLib HTTP transport carries the autorelease pool patch"

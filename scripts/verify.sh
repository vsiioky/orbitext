#!/usr/bin/env bash
# Single entry point for local checks and CI.
#
#   scripts/verify.sh              static checks, build, unit tests, coverage summary
#   scripts/verify.sh --no-tests   static checks and a build only
#                                  (both also build the UI test target)
#   scripts/verify.sh --tsan       unit tests under Thread Sanitizer
#
# Environment:
#   DEVELOPER_DIR    Xcode to use. Defaults to /Applications/Xcode.app: the
#                    test runner hangs under the Xcode 27.0 beta.
#   WATCH_SIM_ID     Simulator to test on. Defaults to the newest available
#                    Apple Watch.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

run_tests=1
tsan=0
for arg in "$@"; do
  case "$arg" in
    --no-tests) run_tests=0 ;;
    --tsan) tsan=1 ;;
    -h|--help) sed -n '2,13p' "$0"; exit 0 ;;
    *) echo "unknown option: $arg" >&2; exit 2 ;;
  esac
done

if [[ -z "${DEVELOPER_DIR:-}" && -d /Applications/Xcode.app/Contents/Developer ]]; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi

OUT="$ROOT/build/verify"
mkdir -p "$OUT"
failures=()

step() { printf '\n==> %s\n' "$*"; }
fail() { echo "FAIL: $*" >&2; failures+=("$*"); }

require() {
  local tool
  for tool in "$@"; do
    command -v "$tool" >/dev/null || { echo "missing tool: $tool (brew install $tool)" >&2; exit 2; }
  done
}
require xcodegen swiftformat rg python3

step "TDLib libraries"
if ! scripts/tdlib/verify-libs.sh; then
  fail "TDLib libraries are missing or differ from scripts/tdlib/libs.sha256"
fi

step "Xcode project matches project.yml"
# Generate into a mirror whose entries link back to the repo, so paths in the
# generated project come out exactly as in the committed one.
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
# xcodegen names the root group after the folder; use the name the committed
# project has, so worktrees and CI checkouts under other names compare equal.
root_group="$(sed -n '/^[[:space:]]*name = .*;$/{N;s/^[[:space:]]*name = "\{0,1\}\([^";]*\)"\{0,1\};\n[[:space:]]*path = \.;$/\1/p;}' Orbitext.xcodeproj/project.pbxproj | head -1)"
mirror="$tmp/${root_group:-$(basename "$ROOT")}"
mkdir "$mirror"
for entry in "$ROOT"/* "$ROOT"/.[!.]*; do
  name="$(basename "$entry")"
  [[ "$name" == "Orbitext.xcodeproj" || "$name" == ".git" ]] && continue
  ln -s "$entry" "$mirror/$name"
done
(cd "$mirror" && xcodegen generate --spec project.yml --quiet)
if ! diff -r -q "$mirror/Orbitext.xcodeproj" Orbitext.xcodeproj \
     -x xcuserdata -x '*.xcuserdatad' -x project.xcworkspace >/dev/null; then
  diff -r "$mirror/Orbitext.xcodeproj" Orbitext.xcodeproj \
    -x xcuserdata -x '*.xcuserdatad' -x project.xcworkspace | head -40 >&2 || true
  fail "Orbitext.xcodeproj is stale: run xcodegen generate"
fi

step "Release checks"
scripts/release/check-identifiers.sh || fail "identifiers"
scripts/release/check-localization-keys.sh || fail "localization keys"

step "Banned APIs"
# UserDefaults.synchronize() is deprecated: the system persists defaults on its
# own, so a call only costs a disk write.
if rg -n '\.synchronize\(\)' Orbitext OrbitextWidget OrbitextStub; then
  fail "UserDefaults.synchronize() is deprecated and unnecessary: remove the call"
fi
# Message text must not reach the system log (private quotes were logged once).
if rg -n "quote text='" Orbitext/Telegram; then
  fail "do not log message or quote text"
fi
# SwiftUI VideoPlayer stalls on watchOS; video goes through the WatchKit
# inline movie player in VideoPlayerView.
if rg -n 'VideoPlayer\(player:' Orbitext/Views; then
  fail "use the WatchKit inline movie player, not SwiftUI VideoPlayer"
fi

step "Transport boundary"
# App code reaches Telegram through the protocols in Orbitext/Telegram
# (TelegramServiceProtocol and the capabilities it inherits). Swift has no
# package-private access inside one module, so this check is the boundary
# until Telegram/ becomes its own module.
if rg -n -w 'TDLibService|TDJsonWrapper|TDClientLifecycleGate' Orbitext OrbitextWidget OrbitextStub \
     --glob '!Orbitext/Telegram/**'; then
  fail "app code names a TDLib transport type: go through TelegramServiceProtocol"
fi

step "Generated TDLib bindings"
if [[ -x scripts/check-codegen.sh ]]; then
  scripts/check-codegen.sh || fail "generated TDLib bindings differ from the generator output"
fi

step "SwiftFormat"
swiftformat Orbitext OrbitextWidget OrbitextTests OrbitextUITests OrbitextStub --lint --quiet \
  || fail "SwiftFormat: run swiftformat on the files listed above"

# A dedicated simulator keeps test runs away from the state of manual runs
# (a signed-in session, cached chats) and vice versa.
VERIFY_SIM_NAME="Orbitext Verify"
simulator_id() {
  if [[ -n "${WATCH_SIM_ID:-}" ]]; then
    echo "$WATCH_SIM_ID"
    return
  fi
  local existing
  existing="$(xcrun simctl list devices available --json | python3 -c '
import json, sys
for runtime, devices in json.load(sys.stdin)["devices"].items():
    for d in devices:
        if d["name"] == sys.argv[1] and d.get("isAvailable"):
            print(d["udid"]); sys.exit()
' "$VERIFY_SIM_NAME")"
  if [[ -n "$existing" ]]; then
    echo "$existing"
    return
  fi
  local runtime devicetype
  read -r runtime devicetype < <(xcrun simctl list runtimes available --json | python3 -c '
import json, sys
rts = [r for r in json.load(sys.stdin)["runtimes"] if r["platform"] == "watchOS" and r.get("isAvailable")]
if not rts: sys.exit("no watchOS simulator runtime")
rt = max(rts, key=lambda r: [int(p) for p in r["version"].split(".")])
series = [d for d in rt["supportedDeviceTypes"] if d["name"].startswith("Apple Watch Series")] or rt["supportedDeviceTypes"]
print(rt["identifier"], series[-1]["identifier"])
')
  xcrun simctl create "$VERIFY_SIM_NAME" "$devicetype" "$runtime"
}

# The targets build in the Swift 6 language mode (project.yml), where a data
# race the compiler can see fails the build. What the mode still reports as a
# warning (SDK declarations imported @preconcurrency, rules that become errors
# in a later language mode) fails the gate here when it is in app code. An
# incremental build shows only the files it compiled, which is where a new
# diagnostic appears; CI builds from scratch.
check_concurrency_diagnostics() {
  local found
  found="$(grep -E "^($ROOT/(Orbitext|OrbitextWidget|OrbitextStub)/[^:]+|<unknown>):[0-9]+(:[0-9]+)?: warning: .*(Sendable|actor|isolat|data race|concurrency-safe|language mode)" "$1" \
    | grep -v '/Generated/' | sort -u || true)"
  if [[ -n "$found" ]]; then
    echo "$found" | sed "s#^$ROOT/##" >&2
    fail "concurrency diagnostics in app code: fix them, do not silence them"
  fi
}

if (( run_tests )); then
  name=tests
  extra=()
  if (( tsan )); then
    name=tests-tsan
    extra+=(-enableThreadSanitizer YES)
  fi
  step "Unit tests ($name)"
  sim="$(simulator_id)"
  xcrun simctl boot "$sim" 2>/dev/null || true
  rm -rf "$OUT/$name.xcresult"
  if xcodebuild test \
      -project Orbitext.xcodeproj -scheme OrbitextWatch \
      -destination "id=$sim" \
      -derivedDataPath "$ROOT/build/DerivedData" \
      -resultBundlePath "$OUT/$name.xcresult" \
      -collect-test-diagnostics never -parallel-testing-enabled NO \
      CODE_SIGNING_ALLOWED=YES ${extra[@]+"${extra[@]}"} \
      -only-testing:OrbitextTests > "$OUT/$name.log" 2>&1; then
    grep -E "Executed [0-9]+ tests" "$OUT/$name.log" | tail -1
  else
    grep -E "error:|Test Case .*failed|Executed [0-9]+ tests|ThreadSanitizer" "$OUT/$name.log" \
      | grep -v 'td_receive\[' | tail -40 >&2 || true
    fail "unit tests (full log: build/verify/$name.log)"
  fi
  check_concurrency_diagnostics "$OUT/$name.log"
  if (( ! tsan )) && [[ -d "$OUT/$name.xcresult" ]]; then
    step "Coverage"
    xcrun xccov view --report --only-targets "$OUT/$name.xcresult" 2>/dev/null || echo "no coverage data"
  fi
else
  step "Build"
  xcodebuild build -project Orbitext.xcodeproj -scheme OrbitextWatch \
    -destination 'generic/platform=watchOS Simulator' \
    -derivedDataPath "$ROOT/build/DerivedData" CODE_SIGNING_ALLOWED=NO \
    > "$OUT/build.log" 2>&1 || { grep -E "error:" "$OUT/build.log" | head -40 >&2; fail "build (build/verify/build.log)"; }
  check_concurrency_diagnostics "$OUT/build.log"
fi

# Swift 6 puts runtime isolation checks into closures and thunks the system may
# call; every baseline site has been reviewed and classified as safe. A site that is not in the
# baseline is new and has to be classified the same way. The tests above built
# the Debug app (a Thread Sanitizer build is not the one the baseline counts).
if (( ! tsan )); then
  step "Runtime isolation checks"
  scripts/executor-checks.sh || fail "new runtime isolation checks: see the header of scripts/executor-checks.sh"
fi

# OrbitextUITests are not part of the unit-test run (live UI smoke only), so
# a formatter rewrite or an API change can break them unnoticed. Build them
# without running, in the same Swift 6 mode as the rest.
step "UI test target builds"
xcodebuild build-for-testing -project Orbitext.xcodeproj -scheme OrbitextLiveQA \
  -destination 'generic/platform=watchOS Simulator' \
  -derivedDataPath "$ROOT/build/DerivedData" CODE_SIGNING_ALLOWED=NO \
  > "$OUT/ui-build.log" 2>&1 || { grep -E "error:" "$OUT/ui-build.log" | head -40 >&2; fail "UI tests do not build (build/verify/ui-build.log)"; }

if (( ${#failures[@]} )); then
  printf '\nverify: %d check(s) failed\n' "${#failures[@]}" >&2
  printf '  - %s\n' "${failures[@]}" >&2
  exit 1
fi
printf '\nverify: all checks passed\n'

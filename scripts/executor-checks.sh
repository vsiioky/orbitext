#!/usr/bin/env bash
# Counts the runtime isolation checks the Swift 6 language mode puts into the
# Debug build of the watch app, per owning function, and compares them with
# scripts/executor-checks.baseline.
#
#   scripts/executor-checks.sh            check against the baseline (exit 1 on a new site)
#   scripts/executor-checks.sh --update   rewrite the baseline after review
#   scripts/executor-checks.sh --print    print the current sites
#
# The mode inserts swift_task_isCurrentExecutor and _checkExpectedExecutor
# calls into synchronous main-actor closures and @objc thunks that code
# without strict checking (the SDK, the standard library) can call. A call
# from the wrong executor stops the process. Every site in the baseline was
# reviewed and classified as safe by construction.
# A new site is a closure or thunk to classify the same way: if the system may
# call it off the main actor, make it @Sendable or nonisolated instead of
# adding it to the baseline.
#
# Needs a built Debug app: run scripts/verify.sh first (or pass the path of
# OrbitextWatch.debug.dylib).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
BASELINE="$ROOT/scripts/executor-checks.baseline"
mode=check
dylib="$ROOT/build/DerivedData/Build/Products/Debug-watchsimulator/OrbitextWatch.app/OrbitextWatch.debug.dylib"
for arg in "$@"; do
  case "$arg" in
    --update) mode=update ;;
    --print) mode=print ;;
    -h|--help) sed -n '2,19p' "$0"; exit 0 ;;
    *) dylib="$arg" ;;
  esac
done
[[ -f "$dylib" ]] || { echo "no Debug build at $dylib: run scripts/verify.sh first" >&2; exit 2; }
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# Calls go through the stubs: find the stub addresses of the two functions.
stubs="$(xcrun otool -Iv "$dylib" \
  | awk '/Indirect symbols for \(__TEXT,__stubs\)/ {on=1; next} /Indirect symbols for/ {on=0} on && /swift_task_isCurrentExecutor|checkExpectedExecutor/ {sub("^0x0*","",$1); print $1}' \
  | paste -sd'|' -)"
if [[ -z "$stubs" ]]; then
  : > "$tmp/addresses"
else
  xcrun llvm-objdump -d --no-show-raw-insn "$dylib" \
    | grep -E "^[[:space:]]+[0-9a-f]+:[[:space:]]+bl[[:space:]]+0x($stubs)[[:space:]]" \
    | awk '{sub(":","",$1); print "0x"$1}' > "$tmp/addresses" || true
fi

python3 - "$dylib" "$tmp/addresses" "$tmp/current" <<'PY'
import collections, re, subprocess, sys

dylib, addresses, out = sys.argv[1:4]
if not open(addresses).read().strip():
    open(out, "w").close()
    sys.exit(0)
symbols = subprocess.run(
    ["xcrun", "atos", "-o", dylib, "-arch", "arm64", "-l", "0", "-f", addresses],
    capture_output=True, text=True, check=True).stdout.splitlines()
counts = collections.Counter()
for line in symbols:
    name = re.sub(r" \(in [^)]*\).*$", "", line)
    # Closure numbers change with every edit of the function around them.
    name = re.sub(r"closure #\d+ in ", "", name)
    name = re.sub(r"\$s[0-9A-Za-z_]+", "$s...", name)
    counts[name.strip()] += 1
with open(out, "w") as f:
    for name, n in sorted(counts.items()):
        f.write(f"{n}\t{name}\n")
PY

total="$(awk -F'\t' '{s+=$1} END {print s+0}' "$tmp/current")"
case "$mode" in
  print) cat "$tmp/current"; echo "total: $total" ;;
  update) cp "$tmp/current" "$BASELINE"; echo "baseline rewritten: $total sites" ;;
  check)
    [[ -f "$BASELINE" ]] || { echo "no baseline: run scripts/executor-checks.sh --update" >&2; exit 2; }
    new="$(python3 - "$BASELINE" "$tmp/current" <<'PY'
import sys
def load(path):
    rows = {}
    for line in open(path):
        n, name = line.rstrip("\n").split("\t", 1)
        rows[name] = int(n)
    return rows
base, cur = load(sys.argv[1]), load(sys.argv[2])
for name, n in sorted(cur.items()):
    if n > base.get(name, 0):
        print(f"+{n - base.get(name, 0)}\t{name}")
PY
)"
    if [[ -n "$new" ]]; then
      echo "new runtime isolation checks (see the header of scripts/executor-checks.sh):" >&2
      echo "$new" >&2
      exit 1
    fi
    echo "isolation checks: $total sites, none new" ;;
esac

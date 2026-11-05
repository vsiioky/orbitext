#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

base="Orbitext/Resources/en.lproj/Localizable.strings"
locales=(
  "Orbitext/Resources/ru.lproj/Localizable.strings"
  "Orbitext/Resources/kk.lproj/Localizable.strings"
)

plutil -lint "$base" >/dev/null
for file in "${locales[@]}"; do
  plutil -lint "$file" >/dev/null
done

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

extract_keys() {
  local file="$1"
  rg -o '^"([^"\\]|\\.)+"' "$file" | sort
}

extract_keys "$base" > "$tmpdir/en.keys"

if [[ "$(sort "$tmpdir/en.keys" | uniq -d | wc -l | tr -d ' ')" != "0" ]]; then
  echo "FAIL: duplicate keys in $base" >&2
  sort "$tmpdir/en.keys" | uniq -d >&2
  exit 1
fi

for file in "${locales[@]}"; do
  name="$(basename "$(dirname "$file")")"
  extract_keys "$file" > "$tmpdir/$name.keys"
  if [[ "$(sort "$tmpdir/$name.keys" | uniq -d | wc -l | tr -d ' ')" != "0" ]]; then
    echo "FAIL: duplicate keys in $file" >&2
    sort "$tmpdir/$name.keys" | uniq -d >&2
    exit 1
  fi
  if ! diff -u "$tmpdir/en.keys" "$tmpdir/$name.keys"; then
    echo "FAIL: localization keys differ for $name" >&2
    exit 1
  fi
done

echo "Localization keys are valid and aligned."

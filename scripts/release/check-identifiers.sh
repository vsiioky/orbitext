#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

active_paths=(
  "project.yml"
  "Orbitext"
  "OrbitextWidget"
  "README.md"
  "REQUIREMENTS.md"
)

failed=0

required_patterns=(
  "com.orbitext.app"
  "com.orbitext.app.watchkitapp"
  "com.orbitext.app.watchkitapp.OrbitextWidget"
  "group.com.orbitext.shared"
)

for pattern in "${required_patterns[@]}"; do
  if ! rg -n --fixed-strings "$pattern" "${active_paths[@]}" >/dev/null; then
    echo "FAIL: required identifier missing: $pattern" >&2
    failed=1
  fi
done

if rg -n 'group\.com\.orbitext(["<])' "${active_paths[@]}"; then
  echo "FAIL: incomplete app group identifier: group.com.orbitext" >&2
  failed=1
fi

exit "$failed"

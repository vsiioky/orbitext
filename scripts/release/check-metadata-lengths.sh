#!/usr/bin/env bash
# Checks the App Store Connect field limits of the metadata drafts:
# name 30, subtitle 30, promotional text 170, keywords 100.
set -euo pipefail

cd "$(dirname "$0")/../.."

python3 - <<'PY'
import glob
import sys

LIMITS = {"Name": 30, "Subtitle": 30, "Promotional Text": 170, "Keywords": 100}
failed = False

for path in sorted(glob.glob("docs/release/metadata/*.md")):
    sections = {}
    current = None
    for line in open(path, encoding="utf-8").read().splitlines():
        if line.startswith("## "):
            current = line[3:].strip()
            sections[current] = []
        elif current is not None and line.strip():
            sections[current].append(line.strip())
    for field, limit in LIMITS.items():
        text = " ".join(sections.get(field, []))
        if not text:
            print(f"{path}: {field} is missing")
            failed = True
        elif len(text) > limit:
            print(f"{path}: {field} is {len(text)} characters, limit {limit}")
            failed = True

sys.exit(1 if failed else 0)
PY

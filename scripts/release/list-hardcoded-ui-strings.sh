#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

rg -n \
  'Text\("[^"]|Button\("[^"]|Label\("[^"]|Section\("[^"]|navigationTitle\("[^"]|alert\("[^"]|ContentUnavailableView\("[^"]|TextField\("[^"]' \
  Orbitext/Views Orbitext/Services Orbitext/App Orbitext/Models Orbitext/Telegram \
  | rg -v 'L10n|stringInterpolation|Text\("\\\(|Text\("\$|Label\("@|Text\(emoji|Text\(folder\.title|Text\(appState\.cacheSizeMB|Text\(connectionLabel'

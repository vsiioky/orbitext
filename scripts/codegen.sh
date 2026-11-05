#!/bin/bash
# Re-generate the TDLib typed Swift bindings from the vendored td_api.tl.
# Generated files are committed to git so this only needs to run when the
# schema (scripts/td_api.tl) or the root types (scripts/codegen-roots.txt)
# change. scripts/check-codegen.sh verifies the committed files are current.
#
#   scripts/codegen.sh [OUTPUT_DIR]    default: Orbitext/Telegram/Generated
set -euo pipefail
cd "$(dirname "$0")/.."
output="${1:-Orbitext/Telegram/Generated}"
python3 -I scripts/codegen-tdlib.py \
    --input scripts/td_api.tl \
    --roots scripts/codegen-roots.txt \
    --output "$output"
echo "Generated TDLib bindings in $output/"

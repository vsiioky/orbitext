#!/usr/bin/env bash
# Archive + export + (optional) upload Orbitext to TestFlight.
#
# Usage:
#   scripts/archive.sh                   # archive + export, no upload
#   scripts/archive.sh --upload          # also upload to App Store Connect
#   scripts/archive.sh --bump            # auto-bump CURRENT_PROJECT_VERSION first
#   scripts/archive.sh --bump --upload   # bump + archive + export + upload
#
# Env for --upload:
#   ASC_USERNAME           Apple ID email (required for password auth)
#   ASC_APP_PASSWORD       app-specific password from appleid.apple.com
#   ASC_API_KEY_ID         (alt) App Store Connect API key id
#   ASC_API_ISSUER_ID      (alt) App Store Connect issuer id
#                          if both API_KEY_ID and ISSUER_ID set, used instead
#                          of username+password. Key file lookup is automatic
#                          via ~/.appstoreconnect/private_keys/.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

BUILD_DIR="$ROOT/build"
ARCHIVE_PATH="$BUILD_DIR/Orbitext.xcarchive"
EXPORT_DIR="$BUILD_DIR/ipa"
EXPORT_OPTS="$ROOT/ExportOptions.plist"

DO_BUMP=0
DO_UPLOAD=0
for arg in "$@"; do
    case "$arg" in
        --bump) DO_BUMP=1 ;;
        --upload) DO_UPLOAD=1 ;;
        -h|--help) sed -n '2,17p' "$0"; exit 0 ;;
        *) echo "unknown arg: $arg" >&2; exit 2 ;;
    esac
done

if [[ "$DO_BUMP" == "1" ]]; then
    current="$(awk '/CURRENT_PROJECT_VERSION:/ {print $2; exit}' project.yml)"
    next=$((current + 1))
    echo ">> bumping CURRENT_PROJECT_VERSION $current -> $next"
    sed -i.bak "s/CURRENT_PROJECT_VERSION: $current/CURRENT_PROJECT_VERSION: $next/g" project.yml
    rm project.yml.bak
    if ! command -v xcodegen >/dev/null 2>&1; then
        echo "xcodegen not found; install with: brew install xcodegen" >&2
        exit 1
    fi
    xcodegen generate
fi

if [[ ! -f "$EXPORT_OPTS" ]]; then
    echo "missing $EXPORT_OPTS: copy ExportOptions.plist.example and set your team ID" >&2
    exit 1
fi

rm -rf "$ARCHIVE_PATH" "$EXPORT_DIR"
mkdir -p "$BUILD_DIR"

echo ">> archiving Release for watchOS device"
xcodebuild \
    -project Orbitext.xcodeproj \
    -scheme Orbitext \
    -destination 'generic/platform=watchOS' \
    -configuration Release \
    -archivePath "$ARCHIVE_PATH" \
    clean archive | xcpretty 2>/dev/null || \
xcodebuild \
    -project Orbitext.xcodeproj \
    -scheme Orbitext \
    -destination 'generic/platform=watchOS' \
    -configuration Release \
    -archivePath "$ARCHIVE_PATH" \
    clean archive

echo ">> exporting .ipa"
xcodebuild \
    -exportArchive \
    -archivePath "$ARCHIVE_PATH" \
    -exportPath "$EXPORT_DIR" \
    -exportOptionsPlist "$EXPORT_OPTS"

IPA="$(find "$EXPORT_DIR" -name '*.ipa' -print -quit)"
if [[ -z "${IPA:-}" ]]; then
    echo "no .ipa produced under $EXPORT_DIR" >&2
    exit 1
fi
echo ">> exported: $IPA"

if [[ "$DO_UPLOAD" != "1" ]]; then
    echo
    echo "skipping upload (pass --upload to send to TestFlight)"
    exit 0
fi

if [[ -n "${ASC_API_KEY_ID:-}" && -n "${ASC_API_ISSUER_ID:-}" ]]; then
    echo ">> uploading via App Store Connect API key $ASC_API_KEY_ID"
    xcrun altool --upload-app \
        --type watchos \
        --file "$IPA" \
        --apiKey "$ASC_API_KEY_ID" \
        --apiIssuer "$ASC_API_ISSUER_ID"
else
    user="${ASC_USERNAME:?set ASC_USERNAME to your Apple ID email}"
    if [[ -z "${ASC_APP_PASSWORD:-}" ]]; then
        echo "set ASC_APP_PASSWORD (app-specific password from appleid.apple.com)" >&2
        echo "or set ASC_API_KEY_ID + ASC_API_ISSUER_ID for API-key auth" >&2
        exit 1
    fi
    echo ">> uploading as $user"
    xcrun altool --upload-app \
        --type watchos \
        --file "$IPA" \
        --username "$user" \
        --password "$ASC_APP_PASSWORD"
fi

echo
echo "done. check App Store Connect -> Orbitext -> TestFlight in ~10-30 min."

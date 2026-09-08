#!/bin/bash
#
# Archives, exports, notarizes, and staples EVA for Developer ID distribution.
#
# Usage:
#   scripts/release.sh [scheme]
#
# scheme defaults to "EVA". Pass "EVAResolve" to release that app instead.
#
# One-time setup (only needed once per machine):
#   xcrun notarytool store-credentials "eva-notary" \
#     --apple-id "your-apple-id@example.com" \
#     --team-id 7V8RRF84QH \
#     --password "app-specific-password"

set -euo pipefail

SCHEME="${1:-EVA}"
TEAM_ID="7V8RRF84QH"
NOTARY_PROFILE="eva-notary"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="$ROOT_DIR/build"
ARCHIVE_PATH="$BUILD_DIR/$SCHEME.xcarchive"
EXPORT_DIR="$BUILD_DIR/export"
EXPORT_OPTIONS="$ROOT_DIR/exportOptions-developerid.plist"
APP_PATH="$EXPORT_DIR/$SCHEME.app"
ZIP_PATH="$EXPORT_DIR/$SCHEME.app.zip"

log() { printf '\n\033[1;34m==>\033[0m %s\n' "$1"; }

if ! security find-identity -v -p codesigning | grep -q "Apple Development"; then
    echo "error: no 'Developer ID Application' signing certificate found in keychain." >&2
    exit 1
fi

if ! xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
    echo "error: notarytool keychain profile '$NOTARY_PROFILE' not found." >&2
    echo "Run this once first:" >&2
    echo "  xcrun notarytool store-credentials \"$NOTARY_PROFILE\" --apple-id \"you@example.com\" --team-id $TEAM_ID --password \"app-specific-password\"" >&2
    exit 1
fi

log "Cleaning previous build output"
rm -rf "$ARCHIVE_PATH" "$EXPORT_DIR"
mkdir -p "$BUILD_DIR"

log "Archiving $SCHEME (Release)"
xcodebuild -project "$ROOT_DIR/EVA.xcodeproj" \
    -scheme "$SCHEME" \
    -configuration Release \
    -archivePath "$ARCHIVE_PATH" \
    archive

log "Exporting Developer ID signed app"
xcodebuild -exportArchive \
    -archivePath "$ARCHIVE_PATH" \
    -exportPath "$EXPORT_DIR" \
    -exportOptionsPlist "$EXPORT_OPTIONS" \
    -allowProvisioningUpdates

if [[ ! -d "$APP_PATH" ]]; then
    echo "error: expected exported app at $APP_PATH but it wasn't found." >&2
    exit 1
fi

log "Zipping for notarization"
ditto -c -k --keepParent "$APP_PATH" "$ZIP_PATH"

log "Submitting to Apple notary service (this can take a few minutes)"
xcrun notarytool submit "$ZIP_PATH" --keychain-profile "$NOTARY_PROFILE" --wait

log "Stapling notarization ticket"
xcrun stapler staple "$APP_PATH"

log "Verifying Gatekeeper acceptance"
spctl -a -vv "$APP_PATH"

log "Done: $APP_PATH is notarized and ready to distribute."

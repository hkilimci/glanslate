#!/bin/bash
# Archives, exports with Developer ID, notarizes, and packages Glanslate.
#
# Requirements:
#   GLANSLATE_DEVELOPMENT_TEAM  your Apple Developer Team ID
#   NOTARY_PROFILE              a notarytool keychain profile, created once with
#                               `xcrun notarytool store-credentials <name>`
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
BUILD_DIR="${PROJECT_ROOT}/build"
ARCHIVE_PATH="${BUILD_DIR}/Glanslate.xcarchive"
EXPORT_PATH="${BUILD_DIR}/export"
APP_PATH="${EXPORT_PATH}/Glanslate.app"
DMG_OUTPUT="${DMG_OUTPUT:-${BUILD_DIR}/Glanslate.dmg}"

: "${GLANSLATE_DEVELOPMENT_TEAM:?Set GLANSLATE_DEVELOPMENT_TEAM to your Team ID}"

if [[ ! -d "${PROJECT_ROOT}/Glanslate.xcodeproj" ]]; then
    echo "Glanslate.xcodeproj not found in ${PROJECT_ROOT}" >&2
    exit 1
fi

echo "==> Archiving"
xcodebuild archive \
    -project "${PROJECT_ROOT}/Glanslate.xcodeproj" \
    -scheme Glanslate \
    -configuration Release \
    -archivePath "${ARCHIVE_PATH}" \
    DEVELOPMENT_TEAM="${GLANSLATE_DEVELOPMENT_TEAM}" \
    CODE_SIGN_IDENTITY="Developer ID Application" \
    CODE_SIGN_STYLE=Manual \
    -quiet

echo "==> Exporting"
rm -rf "${EXPORT_PATH}"
xcodebuild -exportArchive \
    -archivePath "${ARCHIVE_PATH}" \
    -exportPath "${EXPORT_PATH}" \
    -exportOptionsPlist "${SCRIPT_DIR}/export_options.plist" \
    -quiet

if [[ -n "${NOTARY_PROFILE:-}" ]]; then
    echo "==> Notarizing"
    ZIP_PATH="${BUILD_DIR}/Glanslate.zip"
    ditto -c -k --keepParent "${APP_PATH}" "${ZIP_PATH}"
    xcrun notarytool submit "${ZIP_PATH}" --keychain-profile "${NOTARY_PROFILE}" --wait
    xcrun stapler staple "${APP_PATH}"
else
    echo "NOTARY_PROFILE not set; skipping notarization."
fi

echo "==> Creating disk image"
"${SCRIPT_DIR}/make-dmg.sh" "${APP_PATH}" "${DMG_OUTPUT}"
echo "Done: ${DMG_OUTPUT}"

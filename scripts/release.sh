#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
SCHEME="${SCHEME:-Glanslate}"
CONFIGURATION="${CONFIGURATION:-Release}"
DMG_OUTPUT="${DMG_OUTPUT:-${PROJECT_ROOT}/Glanslate.dmg}"

if [[ ! -f "${PROJECT_ROOT}/Glanslate.xcodeproj" ]]; then
    echo "Error: Glanslate.xcodeproj not found in ${PROJECT_ROOT}"
    exit 1
fi

TEAM_ID="${GLANSLATE_DEVELOPMENT_TEAM:-$(security find-certificate -a -k login-keychain -Z | grep 'Developer ID' | head -1 | awk '{print $NF}')}"

echo "=== Glanslate Release Script ==="
echo "Scheme: ${SCHEME}"
echo "Configuration: ${CONFIGURATION}"
echo "Team ID: ${TEAM_ID}"
echo ""

ARCHIVE_PATH="${PROJECT_ROOT}/build/${SCHEME}.xcarchive"

echo "--- Step 1: Cleaning and Archiving ---"
xcodebuild clean \
    -project "${PROJECT_ROOT}/Glanslate.xcodeproj" \
    -scheme "${SCHEME}" \
    -configuration "${CONFIGURATION}" \
    -quiet 2>/dev/null || true

xcodebuild archive \
    -project "${PROJECT_ROOT}/Glanslate.xcodeproj" \
    -scheme "${SCHEME}" \
    -configuration "${CONFIGURATION}" \
    -archivePath "${ARCHIVE_PATH}" \
    -quiet

echo "Archive created at: ${ARCHIVE_PATH}"

echo ""
echo "--- Step 2: Exporting ---"
EXPORT_PATH="${PROJECT_ROOT}/build/export"
rm -rf "${EXPORT_PATH}"

xcodebuild -exportArchive \
    -archivePath "${ARCHIVE_PATH}" \
    -exportPath "${EXPORT_PATH}" \
    -exportOptionsPlist "${SCRIPT_DIR}/export_options.plist" \
    -quiet

echo "Exported to: ${EXPORT_PATH}"

echo ""
echo "--- Step 3: Notarizing ---"
APP_PATH="${EXPORT_PATH}/Glanslate.app"

if [[ -z "${TEAM_ID}" ]]; then
    echo "Warning: No development team ID found. Skipping notarization."
else
    echo "Submitting for notarization..."
    xcrun notarytool submit "${APP_PATH}" \
        --team-id "${TEAM_ID}" \
        --wait \
        --timeout 60

    echo "Stapling ticket..."
    xcrun stapler staple "${APP_PATH}"

    echo "Notarization complete."
fi

echo ""
echo "--- Step 4: Creating DMG ---"
"${SCRIPT_DIR}/make-dmg.sh" "${APP_PATH}" "${DMG_OUTPUT}"

echo ""
echo "=== Release Complete ==="
echo "DMG: ${DMG_OUTPUT}"

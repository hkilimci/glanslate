#!/bin/bash
set -euo pipefail

SOURCE_APP="${1:-}"
OUTPUT_DMG="${2:-./Glanslate.dmg}"
VOLUME_NAME="Glanslate"
DMG_TEMPLATE="${TMPDIR:-/tmp}/glanslate-dmg-$$.plist"

if [[ ! -d "${SOURCE_APP}" ]]; then
    echo "Usage: $0 <path-to-.app> [output-dmg]"
    echo "  Example: $0 ./build/export/Glanslate.app ./Glanslate.dmg"
    exit 1
fi

if ! command -v create-dmg &> /dev/null; then
    echo "Error: create-dmg is not installed."
    echo "Install it with: brew install create-dmg"
    exit 1
fi

WORK_DIR="${TMPDIR:-/tmp}/glanslate-dmg-work-$$"
rm -rf "${WORK_DIR}"
mkdir -p "${WORK_DIR}"

echo "Creating DMG from: ${SOURCE_APP}"
echo "Output: ${OUTPUT_DMG}"

create-dmg \
    --volname "${VOLUME_NAME}" \
    --volicon "${SOURCE_APP}/Contents/Resources/AppIcon.icns" \
    --window-pos 150 100 \
    --window-size 600 450 \
    --icon-size 80 \
    --icon "${SOURCE_APP}" 150 190 \
    --hide-extension "${SOURCE_APP}" \
    --app-drop-link 450 190 \
    --eula "${SOURCE_APP}/Contents/Resources/EULA.rtf" \
    "${OUTPUT_DMG}" \
    "${WORK_DIR}" 2>/dev/null || create-dmg "${OUTPUT_DMG}" "${SOURCE_APP}"

rm -rf "${WORK_DIR}"
rm -f "${DMG_TEMPLATE}"

echo "DMG created: ${OUTPUT_DMG}"

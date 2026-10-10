#!/bin/bash
# Packages Glanslate.app into a compressed disk image with an Applications link.
set -euo pipefail

SOURCE_APP="${1:-}"
OUTPUT_DMG="${2:-./Glanslate.dmg}"

if [[ ! -d "${SOURCE_APP}" ]]; then
    echo "Usage: $0 <path-to-Glanslate.app> [output.dmg]" >&2
    exit 1
fi

STAGING="$(mktemp -d)"
trap 'rm -rf "${STAGING}"' EXIT

cp -R "${SOURCE_APP}" "${STAGING}/"
ln -s /Applications "${STAGING}/Applications"
rm -f "${OUTPUT_DMG}"
hdiutil create -volname "Glanslate" -srcfolder "${STAGING}" -ov -format UDZO "${OUTPUT_DMG}" >/dev/null
echo "Created ${OUTPUT_DMG}"

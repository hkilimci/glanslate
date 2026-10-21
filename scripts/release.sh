#!/bin/bash
# Archives, exports with Developer ID, notarizes, and packages Glanslate as a
# disk image (for people) and a zip (for the in-app updater). Optionally
# publishes both as a GitHub release, which running copies then offer as an update.
#
# Requirements:
#   GLANSLATE_DEVELOPMENT_TEAM  your Apple Developer Team ID
#   NOTARY_PROFILE              a notarytool keychain profile, created once with
#                               `xcrun notarytool store-credentials <name>`
# Optional:
#   PUBLISH=1                   create the GitHub release v<version> with `gh`.
#                               Requires NOTARY_PROFILE, a clean working tree, and
#                               HEAD pushed to the repository, so the tag names
#                               exactly the source the files were built from
#   RELEASE_NOTES               a Markdown file to use as the release notes;
#                               otherwise GitHub generates them from merged changes
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
BUILD_DIR="${PROJECT_ROOT}/build"
ARCHIVE_PATH="${BUILD_DIR}/Glanslate.xcarchive"
EXPORT_PATH="${BUILD_DIR}/export"
APP_PATH="${EXPORT_PATH}/Glanslate.app"

: "${GLANSLATE_DEVELOPMENT_TEAM:?Set GLANSLATE_DEVELOPMENT_TEAM to your Team ID}"

if [[ ! -d "${PROJECT_ROOT}/Glanslate.xcodeproj" ]]; then
    echo "Glanslate.xcodeproj not found in ${PROJECT_ROOT}" >&2
    exit 1
fi

fail() { echo "$1" >&2; exit 1; }

if [[ "${PUBLISH:-}" == "1" ]]; then
    # Users' Macs refuse to open an unnotarized download, and running copies would install it.
    : "${NOTARY_PROFILE:?PUBLISH=1 requires NOTARY_PROFILE; releases must be notarized}"
    command -v gh >/dev/null || fail "PUBLISH=1 requires the GitHub CLI (gh)"

    # Checked before the long build, so a release can't tag source other than what was built.
    [[ -z "$(git -C "${PROJECT_ROOT}" status --porcelain)" ]] \
        || fail "Commit or stash your changes first: a release is built from, and tags, the current commit."
    COMMIT="$(git -C "${PROJECT_ROOT}" rev-parse HEAD)"

    SETTINGS="$(xcodebuild -project "${PROJECT_ROOT}/Glanslate.xcodeproj" -scheme Glanslate -configuration Release -showBuildSettings 2>/dev/null)"
    setting() { awk -F ' = ' -v key="$1" '$1 ~ ("^ *" key "$") { print $2; exit }' <<< "${SETTINGS}"; }
    RELEASE_VERSION="$(setting MARKETING_VERSION)"
    # Publish where the app looks for updates, so the two can't drift apart.
    REPOSITORY="$(setting GLANSLATE_UPDATE_REPOSITORY)"
    [[ -n "${RELEASE_VERSION}" ]] || fail "Couldn't read MARKETING_VERSION."
    [[ -n "${REPOSITORY}" ]] || fail "GLANSLATE_UPDATE_REPOSITORY is empty in Configs/Glanslate.xcconfig; nowhere to publish."

    if gh release view "v${RELEASE_VERSION}" --repo "${REPOSITORY}" >/dev/null 2>&1; then
        fail "v${RELEASE_VERSION} is already released in ${REPOSITORY}. Raise MARKETING_VERSION."
    fi
    if TAGGED="$(gh api "repos/${REPOSITORY}/commits/v${RELEASE_VERSION}" --jq .sha 2>/dev/null)" && [[ "${TAGGED}" != "${COMMIT}" ]]; then
        fail "Tag v${RELEASE_VERSION} in ${REPOSITORY} points to ${TAGGED}, not ${COMMIT}."
    fi
    gh api "repos/${REPOSITORY}/commits/${COMMIT}" >/dev/null 2>&1 || fail "Push ${COMMIT} to ${REPOSITORY} first."
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
    SUBMISSION_ZIP="${BUILD_DIR}/Glanslate-notarization.zip"
    ditto -c -k --keepParent "${APP_PATH}" "${SUBMISSION_ZIP}"
    xcrun notarytool submit "${SUBMISSION_ZIP}" --keychain-profile "${NOTARY_PROFILE}" --wait
    xcrun stapler staple "${APP_PATH}"
    rm -f "${SUBMISSION_ZIP}"
else
    echo "NOTARY_PROFILE not set; skipping notarization."
fi

VERSION="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "${APP_PATH}/Contents/Info.plist")"
DMG_OUTPUT="${DMG_OUTPUT:-${BUILD_DIR}/Glanslate-${VERSION}.dmg}"
ZIP_OUTPUT="${BUILD_DIR}/Glanslate-${VERSION}.zip"

echo "==> Creating update archive"
# Zipped after stapling, so the notarization ticket travels with the app.
rm -f "${ZIP_OUTPUT}"
ditto -c -k --sequesterRsrc --keepParent "${APP_PATH}" "${ZIP_OUTPUT}"

echo "==> Creating disk image"
"${SCRIPT_DIR}/make-dmg.sh" "${APP_PATH}" "${DMG_OUTPUT}"

if [[ "${PUBLISH:-}" == "1" ]]; then
    BUILT_REPOSITORY="$(/usr/libexec/PlistBuddy -c "Print :GlanslateUpdateRepository" "${APP_PATH}/Contents/Info.plist" 2>/dev/null || true)"
    [[ "${VERSION}" == "${RELEASE_VERSION}" && "${BUILT_REPOSITORY}" == "${REPOSITORY}" ]] \
        || fail "The built app (${VERSION}, ${BUILT_REPOSITORY}) doesn't match the build settings (${RELEASE_VERSION}, ${REPOSITORY})."
    [[ "$(git -C "${PROJECT_ROOT}" rev-parse HEAD)" == "${COMMIT}" && -z "$(git -C "${PROJECT_ROOT}" status --porcelain)" ]] \
        || fail "The source changed during the build; run the script again."

    echo "==> Publishing v${VERSION} to ${REPOSITORY}"
    NOTES_ARGS=(--generate-notes)
    if [[ -n "${RELEASE_NOTES:-}" ]]; then NOTES_ARGS=(--notes-file "${RELEASE_NOTES}"); fi
    gh release create "v${VERSION}" "${ZIP_OUTPUT}" "${DMG_OUTPUT}" \
        --repo "${REPOSITORY}" \
        --target "${COMMIT}" \
        --title "Glanslate ${VERSION}" \
        "${NOTES_ARGS[@]}"
fi

echo "Done: ${DMG_OUTPUT}, ${ZIP_OUTPUT}"

#!/bin/bash
# Archives, exports with Developer ID, and notarizes Glanslate, then packages a
# signed, notarized, stapled disk image and a zip for the in-app updater. Optionally
# publishes both as a GitHub release, which running copies then offer as an update.
#
# Requirements:
#   GLANSLATE_DEVELOPMENT_TEAM  your Apple Developer Team ID
#   NOTARY_PROFILE              a notarytool keychain profile, created once with
#                               `xcrun notarytool store-credentials <name>`
#   A valid Developer ID Application certificate and private key for the team
#   must be installed in the keychain.
# Optional:
#   PUBLISH=1                   create the GitHub release v<version> with `gh`.
#                               Requires a clean working tree and
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
: "${NOTARY_PROFILE:?Set NOTARY_PROFILE to your notarytool keychain profile}"

if [[ ! -d "${PROJECT_ROOT}/Glanslate.xcodeproj" ]]; then
    echo "Glanslate.xcodeproj not found in ${PROJECT_ROOT}" >&2
    exit 1
fi

fail() { echo "$1" >&2; exit 1; }

# Choose a local certificate for this team, even if other teams also have
# Developer ID certificates installed. codesign and xcodebuild accept its SHA-1.
SIGNING_IDENTITY="$(security find-identity -v -p codesigning | awk -v team="${GLANSLATE_DEVELOPMENT_TEAM}" \
    '/"Developer ID Application: / && index($0, "(" team ")\"") { print $2; exit }')"
[[ -n "${SIGNING_IDENTITY}" ]] \
    || fail "No valid local Developer ID Application signing identity for team ${GLANSLATE_DEVELOPMENT_TEAM}. Create one in Xcode > Settings > Apple Accounts > Manage Certificates."

# Check authentication before spending time on the build.
xcrun notarytool history --keychain-profile "${NOTARY_PROFILE}" >/dev/null \
    || fail "Can't authenticate with notarization profile ${NOTARY_PROFILE}. Run xcrun notarytool store-credentials to configure it."

notarize() {
    local artifact="$1" result="$2" status
    xcrun notarytool submit "${artifact}" --keychain-profile "${NOTARY_PROFILE}" \
        --wait --output-format plist > "${result}"
    # A completed submission may be Invalid even when notarytool exits zero.
    status="$(/usr/libexec/PlistBuddy -c "Print :status" "${result}")"
    [[ "${status}" == "Accepted" ]] \
        || fail "Notarization of ${artifact} was ${status}; see ${result} for the submission ID."
}

if [[ "${PUBLISH:-}" == "1" ]]; then
    # Users' Macs refuse to open an unnotarized download, and running copies would install it.
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
    CODE_SIGN_IDENTITY="${SIGNING_IDENTITY}" \
    CODE_SIGN_STYLE=Manual \
    -quiet

echo "==> Exporting"
rm -rf "${EXPORT_PATH}"
xcodebuild -exportArchive \
    -archivePath "${ARCHIVE_PATH}" \
    -exportPath "${EXPORT_PATH}" \
    -exportOptionsPlist "${SCRIPT_DIR}/export_options.plist" \
    -quiet

echo "==> Notarizing app"
SUBMISSION_ZIP="${BUILD_DIR}/Glanslate-notarization.zip"
ditto -c -k --keepParent "${APP_PATH}" "${SUBMISSION_ZIP}"
notarize "${SUBMISSION_ZIP}" "${BUILD_DIR}/Glanslate-app-notarization.plist"
xcrun stapler staple "${APP_PATH}"
xcrun stapler validate "${APP_PATH}"
codesign --verify --deep --strict "${APP_PATH}"
spctl --assess --verbose=2 --type execute "${APP_PATH}"
rm -f "${SUBMISSION_ZIP}"

VERSION="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "${APP_PATH}/Contents/Info.plist")"
BUNDLE_IDENTIFIER="$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "${APP_PATH}/Contents/Info.plist")"
DMG_OUTPUT="${DMG_OUTPUT:-${BUILD_DIR}/Glanslate-${VERSION}.dmg}"
ZIP_OUTPUT="${BUILD_DIR}/Glanslate-${VERSION}.zip"

echo "==> Creating update archive"
# Zipped after stapling, so the notarization ticket travels with the app.
rm -f "${ZIP_OUTPUT}"
ditto -c -k --sequesterRsrc --keepParent "${APP_PATH}" "${ZIP_OUTPUT}"

echo "==> Creating disk image"
"${SCRIPT_DIR}/make-dmg.sh" "${APP_PATH}" "${DMG_OUTPUT}"

echo "==> Signing and notarizing disk image"
codesign --sign "${SIGNING_IDENTITY}" --timestamp --identifier "${BUNDLE_IDENTIFIER}.dmg" "${DMG_OUTPUT}"
notarize "${DMG_OUTPUT}" "${BUILD_DIR}/Glanslate-dmg-notarization.plist"
xcrun stapler staple "${DMG_OUTPUT}"

echo "==> Verifying disk image"
xcrun stapler validate "${DMG_OUTPUT}"
codesign --verify --strict "${DMG_OUTPUT}"
spctl --assess --verbose=2 --type open --context context:primary-signature "${DMG_OUTPUT}"

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

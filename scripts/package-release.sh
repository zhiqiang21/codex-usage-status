#!/bin/zsh

# Explicit sh/bash invocation bypasses the shebang; restore the required shell.
if [ -z "${ZSH_VERSION:-}" ]; then
  exec /bin/zsh "$0" "$@"
fi

set -euo pipefail

SCRIPT_DIR="${0:A:h}"
PROJECT_DIR="${SCRIPT_DIR:h}"
PROJECT_PATH="${PROJECT_DIR}/CodexUsageStatus.xcodeproj"
SCHEME="CodexUsageStatus"
PRODUCT_NAME="CodexUsageStatus"
DIST_DIR="${PROJECT_DIR}/dist"
BUILD_DIR="$(mktemp -d "${TMPDIR:-/tmp}/codex-usage-status-release.XXXXXX")"

cleanup() {
  rm -rf "${BUILD_DIR}"
}
trap cleanup EXIT

VERSION="$(
  xcodebuild \
    -project "${PROJECT_PATH}" \
    -scheme "${SCHEME}" \
    -configuration Release \
    -destination "generic/platform=macOS" \
    -derivedDataPath "${BUILD_DIR}" \
    -quiet \
    -showBuildSettings |
    awk '/ MARKETING_VERSION = / { print $3; exit }'
)"

if [[ -z "${VERSION}" ]]; then
  echo "Unable to read MARKETING_VERSION from the Xcode project." >&2
  exit 1
fi

APP_NAME="${PRODUCT_NAME}.app"
BUILT_APP="${BUILD_DIR}/Build/Products/Release/${APP_NAME}"
DIST_APP="${DIST_DIR}/${APP_NAME}"
ARCHIVE_NAME="${PRODUCT_NAME}-${VERSION}-macos-universal.zip"
ARCHIVE_PATH="${DIST_DIR}/${ARCHIVE_NAME}"
CHECKSUM_PATH="${ARCHIVE_PATH}.sha256"

mkdir -p "${DIST_DIR}"
rm -rf "${DIST_APP}"
rm -f "${ARCHIVE_PATH}" "${CHECKSUM_PATH}"

echo "Building ${PRODUCT_NAME} ${VERSION} for Apple silicon and Intel..."
xcodebuild \
  -project "${PROJECT_PATH}" \
  -scheme "${SCHEME}" \
  -configuration Release \
  -destination "generic/platform=macOS" \
  -derivedDataPath "${BUILD_DIR}" \
  -quiet \
  ARCHS="arm64 x86_64" \
  ONLY_ACTIVE_ARCH=NO \
  CODE_SIGNING_ALLOWED=NO \
  build

ditto "${BUILT_APP}" "${DIST_APP}"

if [[ -n "${DEVELOPER_ID_APPLICATION:-}" ]]; then
  echo "Signing with Developer ID: ${DEVELOPER_ID_APPLICATION}"
  codesign \
    --force \
    --deep \
    --options runtime \
    --timestamp \
    --sign "${DEVELOPER_ID_APPLICATION}" \
    "${DIST_APP}"
else
  echo "No DEVELOPER_ID_APPLICATION provided; applying an ad-hoc signature."
  codesign --force --deep --sign - "${DIST_APP}"
fi

codesign --verify --deep --strict --verbose=2 "${DIST_APP}"

if [[ -n "${NOTARYTOOL_PROFILE:-}" ]]; then
  if [[ -z "${DEVELOPER_ID_APPLICATION:-}" ]]; then
    echo "NOTARYTOOL_PROFILE requires DEVELOPER_ID_APPLICATION." >&2
    exit 1
  fi

  NOTARY_ARCHIVE="${BUILD_DIR}/${ARCHIVE_NAME}"
  ditto -c -k --sequesterRsrc --keepParent "${DIST_APP}" "${NOTARY_ARCHIVE}"
  xcrun notarytool submit \
    "${NOTARY_ARCHIVE}" \
    --keychain-profile "${NOTARYTOOL_PROFILE}" \
    --wait
  xcrun stapler staple "${DIST_APP}"
  xcrun stapler validate "${DIST_APP}"
fi

ditto -c -k --sequesterRsrc --keepParent "${DIST_APP}" "${ARCHIVE_PATH}"
ARCHIVE_CHECKSUM="$(shasum -a 256 "${ARCHIVE_PATH}" | awk '{ print $1 }')"
printf '%s  %s\n' "${ARCHIVE_CHECKSUM}" "${ARCHIVE_NAME}" > "${CHECKSUM_PATH}"

echo
echo "Release package:"
echo "  ${ARCHIVE_PATH}"
echo "SHA-256:"
echo "  ${CHECKSUM_PATH}"

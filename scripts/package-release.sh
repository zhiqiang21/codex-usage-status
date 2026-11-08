#!/bin/zsh

# Explicit sh/bash invocation bypasses the shebang; restore the required shell.
if [ -z "${ZSH_VERSION:-}" ]; then
  exec /bin/zsh "$0" "$@"
fi

set -euo pipefail

usage() {
  cat <<'EOF'
Usage: ./scripts/package-release.sh [--arch universal|arm64|x86_64]

  --arch universal  Build for Apple silicon and Intel (default).
  --arch arm64      Build for Apple silicon only.
  --arch x86_64     Build for Intel only.
  -h, --help        Show this help without building.

Optional environment variables:
  DEVELOPER_ID_APPLICATION  Developer ID Application signing identity.
  NOTARYTOOL_PROFILE       Keychain notarization profile (requires signing identity).
EOF
}

TARGET_ARCH="universal"
while (( $# > 0 )); do
  case "$1" in
    --arch)
      if (( $# < 2 )); then
        echo "--arch requires universal, arm64, or x86_64." >&2
        exit 2
      fi
      TARGET_ARCH="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

case "${TARGET_ARCH}" in
  universal) BUILD_ARCHS="arm64 x86_64" ;;
  arm64|x86_64) BUILD_ARCHS="${TARGET_ARCH}" ;;
  *)
    echo "Unsupported architecture: ${TARGET_ARCH}. Use universal, arm64, or x86_64." >&2
    exit 2
    ;;
esac

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
    ARCHS="${BUILD_ARCHS}" \
    ONLY_ACTIVE_ARCH=NO \
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
if [[ "${TARGET_ARCH}" != "universal" ]]; then
  DIST_APP="${DIST_DIR}/${TARGET_ARCH}/${APP_NAME}"
fi
ARCHIVE_NAME="${PRODUCT_NAME}-${VERSION}-macos-${TARGET_ARCH}.zip"
ARCHIVE_PATH="${DIST_DIR}/${ARCHIVE_NAME}"
CHECKSUM_PATH="${ARCHIVE_PATH}.sha256"

mkdir -p "${DIST_APP:h}"
rm -rf "${DIST_APP}"
rm -f "${ARCHIVE_PATH}" "${CHECKSUM_PATH}"

echo "Building ${PRODUCT_NAME} ${VERSION} for ${TARGET_ARCH} (${BUILD_ARCHS})..."
xcodebuild \
  -project "${PROJECT_PATH}" \
  -scheme "${SCHEME}" \
  -configuration Release \
  -destination "generic/platform=macOS" \
  -derivedDataPath "${BUILD_DIR}" \
  -quiet \
  ARCHS="${BUILD_ARCHS}" \
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

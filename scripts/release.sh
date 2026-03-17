#!/bin/bash
set -euo pipefail

# ─────────────────────────────────────────────
# TaskTick Release Script
# Builds arm64 + x86_64 DMGs and uploads to GitHub Release
# Usage: ./scripts/release.sh [version]
#   e.g. ./scripts/release.sh 1.2.0
# ─────────────────────────────────────────────

APP_NAME="TaskTick"
BUNDLE_ID="com.lifedever.TaskTick"
REPO="lifedever/TaskTick"
GITEE_REPO="lifedever/task-tick"
MIN_MACOS="14.0"

# ── Parse version ──
if [ -z "${1:-}" ]; then
  echo "Usage: $0 <version>"
  echo "  e.g. $0 1.2.0"
  exit 1
fi
VERSION="$1"
TAG="v${VERSION}"
BUILD_NUMBER=$(date +%Y%m%d%H%M)

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="${PROJECT_ROOT}/.release"
ICON_PATH="${PROJECT_ROOT}/Sources/Resources/AppIcon.icns"

echo "══════════════════════════════════════════"
echo "  ${APP_NAME} Release ${TAG}"
echo "══════════════════════════════════════════"

# ── Clean ──
rm -rf "${BUILD_DIR}"
mkdir -p "${BUILD_DIR}"

# ── Build function ──
build_arch() {
  local ARCH="$1"
  echo ""
  echo "── Building for ${ARCH} ──"

  local ARCH_BUILD_DIR="${BUILD_DIR}/${ARCH}"
  local APP_BUNDLE="${ARCH_BUILD_DIR}/${APP_NAME}.app"

  # Build with SwiftPM
  swift build \
    --package-path "${PROJECT_ROOT}" \
    --configuration release \
    --arch "${ARCH}" \
    --build-path "${ARCH_BUILD_DIR}/build"

  # Locate binary
  local BIN_PATH
  BIN_PATH=$(find "${ARCH_BUILD_DIR}/build" -name "${APP_NAME}" -type f -perm +111 | grep -v '\.build\|\.dSYM\|\.bundle' | head -1)
  if [ -z "${BIN_PATH}" ]; then
    echo "Error: Could not find built binary for ${ARCH}"
    exit 1
  fi
  echo "  Binary: ${BIN_PATH}"

  # Locate resource bundle
  local RESOURCE_BUNDLE
  RESOURCE_BUNDLE=$(find "${ARCH_BUILD_DIR}/build" -name "${APP_NAME}_${APP_NAME}.bundle" -type d | head -1)

  # Create .app bundle structure
  mkdir -p "${APP_BUNDLE}/Contents/MacOS"
  mkdir -p "${APP_BUNDLE}/Contents/Resources"

  # Copy binary
  cp "${BIN_PATH}" "${APP_BUNDLE}/Contents/MacOS/${APP_NAME}"

  # Copy resource bundle (contains localization files)
  # Bundle.module (SPM-generated) looks at Bundle.main.bundleURL which is the .app root
  if [ -n "${RESOURCE_BUNDLE}" ]; then
    cp -R "${RESOURCE_BUNDLE}" "${APP_BUNDLE}/"
    echo "  Resources: ${RESOURCE_BUNDLE}"
  fi

  # Copy icon
  if [ -f "${ICON_PATH}" ]; then
    cp "${ICON_PATH}" "${APP_BUNDLE}/Contents/Resources/AppIcon.icns"
  fi

  # Generate Info.plist
  cat > "${APP_BUNDLE}/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>${APP_NAME}</string>
    <key>CFBundleDisplayName</key>
    <string>${APP_NAME}</string>
    <key>CFBundleIdentifier</key>
    <string>${BUNDLE_ID}</string>
    <key>CFBundleVersion</key>
    <string>${BUILD_NUMBER}</string>
    <key>CFBundleShortVersionString</key>
    <string>${VERSION}</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleExecutable</key>
    <string>${APP_NAME}</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleIconName</key>
    <string>AppIcon</string>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>LSMinimumSystemVersion</key>
    <string>${MIN_MACOS}</string>
    <key>LSApplicationCategoryType</key>
    <string>public.app-category.developer-tools</string>
    <key>NSMainStoryboardFile</key>
    <string></string>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
    <key>NSSupportsAutomaticTermination</key>
    <true/>
    <key>NSSupportsSuddenTermination</key>
    <false/>
    <key>LSUIElement</key>
    <false/>
    <key>CFBundleLocalizations</key>
    <array>
        <string>en</string>
        <string>zh-Hans</string>
    </array>
</dict>
</plist>
PLIST

  # Ad-hoc code sign (deep sign all nested binaries/frameworks)
  echo "  Signing..."
  codesign --force --deep --no-strict --sign - "${APP_BUNDLE}"
  echo "  Signed: $(codesign -dv "${APP_BUNDLE}" 2>&1 | grep 'Signature')"

  echo "  App bundle: ${APP_BUNDLE}"
}

# ── Create DMG function ──
create_dmg() {
  local ARCH="$1"
  local APP_BUNDLE="${BUILD_DIR}/${ARCH}/${APP_NAME}.app"
  local DMG_NAME="${APP_NAME}-${VERSION}-${ARCH}.dmg"
  local DMG_PATH="${BUILD_DIR}/${DMG_NAME}"
  local DMG_STAGING="${BUILD_DIR}/dmg-staging-${ARCH}"

  echo ""
  echo "── Creating DMG: ${DMG_NAME} ──"

  # Create staging directory with app and Applications symlink
  rm -rf "${DMG_STAGING}"
  mkdir -p "${DMG_STAGING}"
  cp -R "${APP_BUNDLE}" "${DMG_STAGING}/"
  ln -s /Applications "${DMG_STAGING}/Applications"

  # Create DMG
  hdiutil create \
    -volname "${APP_NAME}" \
    -srcfolder "${DMG_STAGING}" \
    -ov \
    -format UDZO \
    "${DMG_PATH}" \
    -quiet

  rm -rf "${DMG_STAGING}"
  echo "  DMG: ${DMG_PATH}"
  echo "  Size: $(du -h "${DMG_PATH}" | cut -f1)"
}

# ── Build both architectures ──
build_arch "arm64"
build_arch "x86_64"

# ── Create DMGs ──
create_dmg "arm64"
create_dmg "x86_64"

# ── Summary ──
echo ""
echo "══════════════════════════════════════════"
echo "  Build complete!"
echo "══════════════════════════════════════════"
echo ""
echo "  ${BUILD_DIR}/${APP_NAME}-${VERSION}-arm64.dmg"
echo "  ${BUILD_DIR}/${APP_NAME}-${VERSION}-x86_64.dmg"
echo ""

# ── Upload to GitHub Release ──
read -p "Upload to GitHub Release ${TAG}? [y/N] " -n 1 -r
echo ""
if [[ $REPLY =~ ^[Yy]$ ]]; then
  echo ""
  echo "── Creating GitHub Release ──"

  # Check if tag exists
  if git rev-parse "${TAG}" >/dev/null 2>&1; then
    echo "  Tag ${TAG} already exists, using it."
  else
    echo "  Creating tag ${TAG}..."
    git tag -a "${TAG}" -m "Release ${TAG}"
    git push origin "${TAG}"
  fi

  # Create release (or upload to existing)
  if gh release view "${TAG}" --repo "${REPO}" >/dev/null 2>&1; then
    echo "  Release ${TAG} already exists, uploading assets..."
    gh release upload "${TAG}" \
      "${BUILD_DIR}/${APP_NAME}-${VERSION}-arm64.dmg" \
      "${BUILD_DIR}/${APP_NAME}-${VERSION}-x86_64.dmg" \
      --repo "${REPO}" \
      --clobber
  else
    gh release create "${TAG}" \
      "${BUILD_DIR}/${APP_NAME}-${VERSION}-arm64.dmg" \
      "${BUILD_DIR}/${APP_NAME}-${VERSION}-x86_64.dmg" \
      --repo "${REPO}" \
      --title "TaskTick ${TAG}" \
      --generate-notes
  fi

  echo ""
  echo "  Release uploaded: https://github.com/${REPO}/releases/tag/${TAG}"
fi

# ── Upload to Gitee Release ──
echo ""
echo "── Publishing to Gitee ${GITEE_REPO} ──"
if [ -n "${GITEE_TOKEN:-}" ]; then
  # Push tag to Gitee
  if git remote get-url gitee >/dev/null 2>&1; then
    git push gitee "${TAG}" 2>/dev/null || echo "  Tag already exists on Gitee"
  fi

  # Create Gitee release
  GITEE_RELEASE_RESP=$(curl -s -X POST \
    "https://gitee.com/api/v5/repos/${GITEE_REPO}/releases" \
    -H "Content-Type: application/json" \
    -d "{
      \"access_token\": \"${GITEE_TOKEN}\",
      \"tag_name\": \"${TAG}\",
      \"name\": \"TaskTick ${TAG}\",
      \"body\": \"## TaskTick ${TAG}\n\n### Download\n- **Apple Silicon (M1/M2/M3/M4)**: TaskTick-${VERSION}-arm64.dmg\n- **Intel**: TaskTick-${VERSION}-x86_64.dmg\",
      \"target_commitish\": \"main\"
    }")

  GITEE_RELEASE_ID=$(echo "$GITEE_RELEASE_RESP" | python3 -c "import sys,json; print(json.load(sys.stdin).get('id',''))" 2>/dev/null || true)

  if [ -n "$GITEE_RELEASE_ID" ] && [ "$GITEE_RELEASE_ID" != "None" ]; then
    for ARCH in arm64 x86_64; do
      DMG_FILE="${BUILD_DIR}/${APP_NAME}-${VERSION}-${ARCH}.dmg"
      echo "  Uploading ${APP_NAME}-${VERSION}-${ARCH}.dmg..."
      curl -s -X POST \
        "https://gitee.com/api/v5/repos/${GITEE_REPO}/releases/${GITEE_RELEASE_ID}/attach_files" \
        -H "Content-Type: multipart/form-data" \
        -F "access_token=${GITEE_TOKEN}" \
        -F "file=@${DMG_FILE}" > /dev/null
      echo "  Uploaded."
    done
    echo "  Gitee release: https://gitee.com/${GITEE_REPO}/releases/tag/${TAG}"
  else
    echo "  Warning: Failed to create Gitee release"
    echo "  Response: ${GITEE_RELEASE_RESP}"
  fi
else
  echo "  Skipped (no GITEE_TOKEN env var)"
  echo "  To enable: export GITEE_TOKEN=your_gitee_personal_access_token"
fi

echo ""
echo "Done."

#!/bin/bash
set -euo pipefail

# ─────────────────────────────────────────────
# TaskTick Dev Build Script
# Builds a dev version that can coexist with the release version
# Usage: ./scripts/build-dev.sh
# ─────────────────────────────────────────────

APP_NAME="TaskTick"
DEV_APP_NAME="TaskTick Dev"
BUNDLE_ID="com.lifedever.TaskTick.dev"
MIN_MACOS="15.0"

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="${PROJECT_ROOT}/.dev-build"
ICON_PATH="${PROJECT_ROOT}/Sources/Resources/AppIcon.icns"
APP_BUNDLE="${BUILD_DIR}/${DEV_APP_NAME}.app"

echo "── Building ${DEV_APP_NAME} ──"

# Build
swift build \
  --package-path "${PROJECT_ROOT}" \
  --configuration debug \
  --build-path "${BUILD_DIR}/build"

# Locate binary
BIN_PATH=$(find "${BUILD_DIR}/build" -name "${APP_NAME}" -type f -perm +111 | grep -v '\.build\|\.dSYM\|\.bundle' | head -1)
if [ -z "${BIN_PATH}" ]; then
  echo "Error: Could not find built binary"
  exit 1
fi

# Locate resource bundle
RESOURCE_BUNDLE=$(find "${BUILD_DIR}/build" -name "${APP_NAME}_${APP_NAME}.bundle" -type d | head -1)

# Create .app bundle
rm -rf "${APP_BUNDLE}"
mkdir -p "${APP_BUNDLE}/Contents/MacOS"
mkdir -p "${APP_BUNDLE}/Contents/Resources"

cp "${BIN_PATH}" "${APP_BUNDLE}/Contents/MacOS/${APP_NAME}"

if [ -n "${RESOURCE_BUNDLE}" ]; then
  cp -R "${RESOURCE_BUNDLE}" "${APP_BUNDLE}/"
fi

if [ -f "${ICON_PATH}" ]; then
  # Create grayscale dev icon
  TEMP_PNG="${BUILD_DIR}/icon_temp.png"
  DEV_ICON="${BUILD_DIR}/DevIcon.icns"
  ICONSET="${BUILD_DIR}/DevIcon.iconset"

  # Convert icns to PNG, then desaturate with sips
  sips -s format png "${ICON_PATH}" --out "${TEMP_PNG}" &>/dev/null
  sips -m "/System/Library/ColorSync/Profiles/Generic Gray Gamma 2.2 Profile.icc" "${TEMP_PNG}" --out "${TEMP_PNG}" &>/dev/null

  if [ -f "${TEMP_PNG}" ]; then
    mkdir -p "${ICONSET}"
    for size in 16 32 128 256 512; do
      sips -z $size $size "${TEMP_PNG}" --out "${ICONSET}/icon_${size}x${size}.png" &>/dev/null
      double=$((size * 2))
      sips -z $double $double "${TEMP_PNG}" --out "${ICONSET}/icon_${size}x${size}@2x.png" &>/dev/null
    done
    iconutil -c icns "${ICONSET}" -o "${DEV_ICON}" 2>/dev/null
    rm -rf "${ICONSET}" "${TEMP_PNG}"
  fi

  if [ -f "${DEV_ICON}" ]; then
    cp "${DEV_ICON}" "${APP_BUNDLE}/Contents/Resources/AppIcon.icns"
    echo "  Icon: grayscale dev icon"
  else
    cp "${ICON_PATH}" "${APP_BUNDLE}/Contents/Resources/AppIcon.icns"
    echo "  Icon: original (grayscale conversion failed)"
  fi
fi

# Info.plist with dev bundle ID
cat > "${APP_BUNDLE}/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>${DEV_APP_NAME}</string>
    <key>CFBundleDisplayName</key>
    <string>${DEV_APP_NAME}</string>
    <key>CFBundleIdentifier</key>
    <string>${BUNDLE_ID}</string>
    <key>CFBundleVersion</key>
    <string>dev.$(date +%Y%m%d%H%M)</string>
    <key>CFBundleShortVersionString</key>
    <string>0.0.0-dev</string>
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

# Sign (--no-strict to allow resource bundle at app root for SPM Bundle.module)
codesign --force --deep --no-strict --sign - "${APP_BUNDLE}"

echo ""
echo "── Done ──"
echo "  ${APP_BUNDLE}"
echo ""

# Kill existing dev app and relaunch
pkill -f "${DEV_APP_NAME}" 2>/dev/null && sleep 0.5
open "${APP_BUNDLE}"

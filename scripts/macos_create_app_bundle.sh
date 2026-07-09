#!/bin/bash
# Creates a .app bundle for Sunshine on macOS.
# This gives the binary a stable TCC identity (com.alkaidlab.sunshine) so that
# Screen Recording / Microphone / System Audio Recording permissions persist
# across rebuilds and don't depend on which terminal launched it.
#
# Usage: ./scripts/macos_create_app_bundle.sh [build_dir] [source_dir]
set -e

BUILD_DIR="${1:-build}"
SOURCE_DIR="${2:-$(pwd)}"
APP_DIR="${BUILD_DIR}/Sunshine.app"

if [ ! -f "${BUILD_DIR}/sunshine" ]; then
    echo "Error: ${BUILD_DIR}/sunshine not found. Build sunshine first."
    exit 1
fi

echo "Creating Sunshine.app bundle..."

# Create bundle structure
mkdir -p "${APP_DIR}/Contents/MacOS"
mkdir -p "${APP_DIR}/Contents/Resources"

# Copy the binary
cp "${BUILD_DIR}/sunshine" "${APP_DIR}/Contents/MacOS/Sunshine"

# Copy web assets if they exist (these are the runtime assets sunshine serves)
if [ -d "${BUILD_DIR}/assets" ]; then
    # Only copy the web/ subdirectory and config files, not build artifacts
    mkdir -p "${APP_DIR}/Contents/Resources/assets"
    if [ -d "${BUILD_DIR}/assets/web" ]; then
        cp -r "${BUILD_DIR}/assets/web" "${APP_DIR}/Contents/Resources/assets/web"
    fi
    # Copy individual config files (not .plist.in or .entitlements)
    for f in apps.json desktop.png desktop-alt.png box.png steam.png abr_prompt.md Info.plist; do
        [ -f "${BUILD_DIR}/assets/$f" ] && cp "${BUILD_DIR}/assets/$f" "${APP_DIR}/Contents/Resources/assets/"
    done
fi

# Copy the sunshine config directory reference (assets are looked up relative to
# the executable's parent on macOS; create a symlink so the .app finds config)
# Note: sunshine looks for assets in the same dir as the binary or ../assets/
# The .app structure puts binary in Contents/MacOS/, assets in Contents/Resources/

# Generate Info.plist from template
# Extract version like "2026.0710.015150" from the binary's version string
RAW_VERSION=$(strings "${BUILD_DIR}/sunshine" | grep -oE '20[0-9]{4}\.[0-9]{6}\.[0-9]{6}' | head -1)
if [ -z "$RAW_VERSION" ]; then
    RAW_VERSION="1.0.0"
fi
# CFBundleVersion can't have more than 3 dot-separated parts; use first 2 fields
VERSION=$(echo "$RAW_VERSION" | cut -d. -f1-2)
echo "  Version: ${VERSION}"
sed "s/@SUNSHINE_VERSION@/${VERSION}/g" \
    "${SOURCE_DIR}/src_assets/macos/assets/SunshineApp.plist.in" > \
    "${APP_DIR}/Contents/Info.plist"

# Sign the bundle with stable identifier + entitlements
ENTITLEMENTS="${SOURCE_DIR}/src_assets/macos/assets/sunshine.entitlements"
codesign --force --deep --sign - --identifier com.alkaidlab.sunshine \
    --entitlements "${ENTITLEMENTS}" \
    "${APP_DIR}"

# Register with LaunchServices so TCC recognizes the bundle identity
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
    -f "${APP_DIR}" 2>/dev/null || true

echo ""
echo "✓ Created ${APP_DIR}"
echo ""
echo "To run Sunshine with proper TCC permissions:"
echo "  open ${APP_DIR}"
echo ""
echo "On first launch, grant these permissions in System Settings → Privacy & Security:"
echo "  1. Screen Recording (for video + SCK audio capture)"
echo "  2. Microphone (for mic streaming)"
echo "  3. System Audio Recording (for audio capture)"
echo ""
echo "These permissions persist across rebuilds because the bundle has a stable identity."

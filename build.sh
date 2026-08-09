#!/bin/bash
# Build KelvinXDR.app without Xcode — needs only the Command Line Tools (swiftc + SDK).
#   ./build.sh          build
#   ./build.sh run      build, then relaunch
set -euo pipefail
cd "$(dirname "$0")"

APP="build/KelvinXDR.app"
BUNDLE_ID="com.kelvin.KelvinXDR"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

swiftc -O \
    -sdk "$(xcrun --show-sdk-path)" \
    -target "$(uname -m)-apple-macos13.1" \
    -import-objc-header KelvinXDR/Bridging.h \
    -framework IOKit \
    -o "$APP/Contents/MacOS/KelvinXDR" \
    KelvinXDR/main.swift KelvinXDR/AppDelegate.swift KelvinXDR/EDRTrigger.swift \
    KelvinXDR/GammaBoost.swift KelvinXDR/DDC.swift KelvinXDR/MediaKeys.swift KelvinXDR/OSD.swift \
    KelvinXDR/AppleBrightness.swift KelvinXDR/Shade.swift KelvinXDR/DisplayControl.swift \
    KelvinXDR/AudioOutput.swift KelvinXDR/Detent.swift

# Start from the repo's Info.plist (LSUIElement) and add the keys Xcode would generate
cp KelvinXDR/Info.plist "$APP/Contents/Info.plist"
for entry in \
    "CFBundleExecutable string KelvinXDR" \
    "CFBundleIdentifier string $BUNDLE_ID" \
    "CFBundleName string KelvinXDR" \
    "CFBundlePackageType string APPL" \
    "CFBundleShortVersionString string 1.0" \
    "CFBundleVersion string 1" \
    "LSMinimumSystemVersion string 13.1" \
    "NSHighResolutionCapable bool true"
do
    /usr/libexec/PlistBuddy -c "Add :$entry" "$APP/Contents/Info.plist" >/dev/null
done

# App icon: iconutil + sips ship with the Command Line Tools, so no Xcode needed
if [ -f KelvinXDR/AppIcon.png ]; then
    ICONSET="$(mktemp -d)/KelvinXDR.iconset"
    mkdir -p "$ICONSET"
    for spec in "16 icon_16x16" "32 icon_16x16@2x" "32 icon_32x32" "64 icon_32x32@2x" \
                "128 icon_128x128" "256 icon_128x128@2x" "256 icon_256x256" \
                "512 icon_256x256@2x" "512 icon_512x512" "1024 icon_512x512@2x"; do
        set -- $spec
        sips -z "$1" "$1" KelvinXDR/AppIcon.png --out "$ICONSET/$2.png" >/dev/null 2>&1
    done
    iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/KelvinXDR.icns"
    /usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string KelvinXDR" "$APP/Contents/Info.plist" >/dev/null
    rm -rf "$(dirname "$ICONSET")"
fi

# Sign with the stable self-signed identity when it exists, so TCC grants (Accessibility
# for the media-key event tap) survive rebuilds. An ad-hoc signature is pinned to the exact
# binary hash, so every rebuild silently revoked the permission.
# Create it once with:  see README
IDENTITY="KelvinXDR Signing"
if security find-identity -v -p codesigning 2>/dev/null | grep -q "$IDENTITY"; then
    codesign --force --sign "$IDENTITY" --identifier "$BUNDLE_ID" "$APP"
    echo "signed with: $IDENTITY"
else
    codesign --force --sign - "$APP"
    echo "signed ad-hoc (no '$IDENTITY' identity found — TCC grants will not persist)"
fi

echo "Built $APP"

if [ "${1:-}" = "run" ]; then
    killall KelvinXDR 2>/dev/null || true
    open "$APP"
fi

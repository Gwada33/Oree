#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="Oree"
EXECUTABLE_NAME="HyperBrowserApp"
BUILD_DIR=".build/release"
# Version shown in « À propos » and compared by the updater: edit the VERSION file before a release.
APP_VERSION="$(tr -d '[:space:]' < VERSION)"
BUILD_NUMBER="$(git rev-list --count HEAD 2>/dev/null || echo 1)"
APP_DIR="${APP_NAME}.app"

echo "==> Building release binary..."
swift build -c release --product "$EXECUTABLE_NAME"
swift build -c release --product OreeDownloader

rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS"
mkdir -p "$APP_DIR/Contents/Resources"
mkdir -p "$APP_DIR/Contents/Resources/Fonts"
cp Resources/Fonts/*.ttf "$APP_DIR/Contents/Resources/Fonts/"
cp "$BUILD_DIR/$EXECUTABLE_NAME" "$APP_DIR/Contents/MacOS/$APP_NAME"
# The download engine runs as its own process (a launchd agent started on demand), so it ships beside the app.
cp "$BUILD_DIR/OreeDownloader" "$APP_DIR/Contents/MacOS/OreeDownloader"

cat > "$APP_DIR/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>Oree</string>
    <key>CFBundleDisplayName</key>
    <string>Oree</string>
    <key>CFBundleIdentifier</key>
    <string>com.nolhan.hyperbrowser</string>
    <key>CFBundleVersion</key>
    <string>${BUILD_NUMBER}</string>
    <key>CFBundleShortVersionString</key>
    <string>${APP_VERSION}</string>
    <key>CFBundleExecutable</key>
    <string>Oree</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>LSMinimumSystemVersion</key>
    <string>15.4</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>LSApplicationCategoryType</key>
    <string>public.app-category.productivity</string>
    <key>NSBluetoothAlwaysUsageDescription</key>
    <string>Orée utilise le Bluetooth pour retrouver vos passkeys sur un appareil à proximité (iPhone, iPad).</string>
    <key>CFBundleURLTypes</key>
    <array>
        <dict>
            <key>CFBundleURLName</key>
            <string>Adresse web</string>
            <key>CFBundleURLSchemes</key>
            <array>
                <string>http</string>
                <string>https</string>
            </array>
        </dict>
    </array>
    <key>CFBundleDocumentTypes</key>
    <array>
        <dict>
            <key>CFBundleTypeName</key>
            <string>Document HTML</string>
            <key>CFBundleTypeRole</key>
            <string>Viewer</string>
            <key>LSItemContentTypes</key>
            <array>
                <string>public.html</string>
                <string>public.xhtml</string>
            </array>
        </dict>
    </array>
    <key>NSAppTransportSecurity</key>
    <dict>
        <!-- A browser must be able to open http:// pages when the user chooses to
             ("Continuer en HTTP", local dev servers). HTTPS-only mode and its
             warning screen are handled by the app itself. -->
        <key>NSAllowsArbitraryLoadsInWebContent</key>
        <true/>
        <key>NSAllowsLocalNetworking</key>
        <true/>
    </dict>
    <key>NSCameraUsageDescription</key>
    <string>Les sites web que vous autorisez peuvent utiliser la caméra (visioconférence, photo).</string>
    <key>NSMicrophoneUsageDescription</key>
    <string>Les sites web que vous autorisez peuvent utiliser le micro (appels, dictée).</string>
    <key>NSLocationWhenInUseUsageDescription</key>
    <string>Les sites web que vous autorisez peuvent connaître votre position (cartes, météo locale).</string>
</dict>
</plist>
PLIST

echo "==> Building app icon from Branding/AppIcon.appiconset..."
# Source art: design/AppIcon.svg (full) and design/AppIcon-small.svg (4 bars, used up to 64 px).
# The PNGs are rendered with rsvg-convert (sips renders SVG gradients badly): see design/README in the commit.
ICONSET="$(cd "$(dirname "$0")" && pwd)/Branding/AppIcon.appiconset"
if [ ! -f "$ICONSET/icon_512x512@2x.png" ]; then echo "missing $ICONSET — render design/AppIcon.svg with rsvg-convert"; exit 1; fi
ICONSET_TMP="${TMPDIR:-/tmp}/Orée.iconset"
rm -rf "$ICONSET_TMP"; mkdir -p "$ICONSET_TMP"
cp "$ICONSET"/icon_*.png "$ICONSET_TMP/"
iconutil -c icns "$ICONSET_TMP" -o "$APP_DIR/Contents/Resources/AppIcon.icns"

echo "==> Code signing (ad-hoc)..."
codesign --force --sign - --identifier com.nolhan.hyperbrowser.downloader "$APP_DIR/Contents/MacOS/OreeDownloader"
codesign --force --sign - "$APP_DIR"

echo "==> Done: $APP_DIR"
echo "    Launch with: open $APP_DIR"

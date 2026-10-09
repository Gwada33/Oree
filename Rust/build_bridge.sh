#!/bin/bash
# Builds the Rust adblock bridge and wires it into the SwiftPM package:
#   - Frameworks/AdblockBridgeFFI.xcframework  (static lib + C header + modulemap)
#   - Sources/AdblockBridge/adblock_bridge.swift  (UniFFI-generated Swift API)
#
# The xcframework is assembled by hand because `xcodebuild -create-xcframework`
# needs full Xcode; the on-disk layout is simple and SwiftPM/Xcode accept it.
set -euo pipefail
cd "$(dirname "$0")/.."

CRATE=Rust/adblock_bridge
OUT_FFI=Frameworks/AdblockBridgeFFI.xcframework
OUT_SWIFT=Sources/AdblockBridge
LIB_ID=macos-arm64
GEN=$(mktemp -d)

echo "==> cargo build --release"
(cd "$CRATE" && cargo build --release)

echo "==> generating Swift bindings"
(cd "$CRATE" && cargo run --release --quiet --bin uniffi-bindgen -- \
    generate --library target/release/libadblock_bridge.dylib \
    --language swift --out-dir "$GEN")

echo "==> assembling xcframework"
rm -rf "$OUT_FFI"
mkdir -p "$OUT_FFI/$LIB_ID/Headers" "$OUT_SWIFT"
cp "$CRATE/target/release/libadblock_bridge.a" "$OUT_FFI/$LIB_ID/"
cp "$GEN/adblock_bridgeFFI.h" "$OUT_FFI/$LIB_ID/Headers/"
cp "$GEN/adblock_bridgeFFI.modulemap" "$OUT_FFI/$LIB_ID/Headers/module.modulemap"
cp "$GEN/adblock_bridge.swift" "$OUT_SWIFT/adblock_bridge.swift"

cat > "$OUT_FFI/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>AvailableLibraries</key>
    <array>
        <dict>
            <key>HeadersPath</key>
            <string>Headers</string>
            <key>LibraryIdentifier</key>
            <string>$LIB_ID</string>
            <key>LibraryPath</key>
            <string>libadblock_bridge.a</string>
            <key>SupportedArchitectures</key>
            <array><string>arm64</string></array>
            <key>SupportedPlatform</key>
            <string>macos</string>
        </dict>
    </array>
    <key>CFBundlePackageType</key>
    <string>XFWK</string>
    <key>XCFrameworkFormatVersion</key>
    <string>1.0</string>
</dict>
</plist>
PLIST

rm -rf "$GEN"
echo "==> done: $OUT_FFI + $OUT_SWIFT/adblock_bridge.swift"

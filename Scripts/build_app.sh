#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_DIR"

if [[ -z "${TARGET_APP_DIR:-}" ]]; then
    if [[ -d "/Volumes/ROG/Applications" && -w "/Volumes/ROG/Applications" ]]; then
        TARGET_APP_DIR="/Volumes/ROG/Applications"
    else
        TARGET_APP_DIR="/Applications"
    fi
fi
APP_NAME="CatHide.app"
BIN_NAME="CatHide"
BUILD_BUNDLE="$PROJECT_DIR/.build/release/$APP_NAME"
INSTALL_BUNDLE="$TARGET_APP_DIR/$APP_NAME"

if [[ ! -d "$TARGET_APP_DIR" || ! -w "$TARGET_APP_DIR" ]]; then
    echo "Error: $TARGET_APP_DIR is not mounted or not writable." >&2
    exit 1
fi

echo "==> Running release build..."
swift build -c release

BIN_PATH="$(swift build -c release --show-bin-path)/$BIN_NAME"
if [[ ! -x "$BIN_PATH" ]]; then
    echo "Error: compiled binary not found at $BIN_PATH" >&2
    exit 1
fi

echo "==> Generating cat + mosaic app icon..."
ICONSET_DIR="$PROJECT_DIR/.build/AppIcon.iconset"
ICNS_PATH="$PROJECT_DIR/.build/AppIcon.icns"
swift "$PROJECT_DIR/Scripts/generate_icon.swift" "$ICONSET_DIR"
iconutil -c icns "$ICONSET_DIR" -o "$ICNS_PATH"

echo "==> Assembling $APP_NAME bundle..."
rm -rf "$BUILD_BUNDLE"
mkdir -p "$BUILD_BUNDLE/Contents/MacOS"
mkdir -p "$BUILD_BUNDLE/Contents/Resources/zh-Hans.lproj"
mkdir -p "$BUILD_BUNDLE/Contents/Resources/en.lproj"

cp "$BIN_PATH" "$BUILD_BUNDLE/Contents/MacOS/$BIN_NAME"
cp "$ICNS_PATH" "$BUILD_BUNDLE/Contents/Resources/AppIcon.icns"

SDK_VER="$(xcrun --show-sdk-version)"
echo "==> Setting Mach-O SDK version to $SDK_VER for native Liquid Glass..."
xcrun vtool -set-build-version macos 14.0 "$SDK_VER" -replace -output "$BUILD_BUNDLE/Contents/MacOS/$BIN_NAME" "$BUILD_BUNDLE/Contents/MacOS/$BIN_NAME"

cat > "$BUILD_BUNDLE/Contents/Resources/zh-Hans.lproj/InfoPlist.strings" << 'STRINGS'
"CFBundleDisplayName" = "猫猫藏藏";
"CFBundleName" = "猫猫藏藏";
STRINGS

cat > "$BUILD_BUNDLE/Contents/Resources/en.lproj/InfoPlist.strings" << 'STRINGS'
"CFBundleDisplayName" = "CatHide";
"CFBundleName" = "CatHide";
STRINGS

cat > "$BUILD_BUNDLE/Contents/Info.plist" << 'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>zh-Hans</string>
    <key>CFBundleDisplayName</key>
    <string>猫猫藏藏</string>
    <key>CFBundleExecutable</key>
    <string>CatHide</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleIdentifier</key>
    <string>com.local.cathide</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleLocalizations</key>
    <array>
        <string>zh-Hans</string>
        <string>en</string>
    </array>
    <key>CFBundleName</key>
    <string>猫猫藏藏</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.2.0</string>
    <key>CFBundleVersion</key>
    <string>3</string>
    <key>CatHideGitHubRepo</key>
    <string>uncat2310/CatHide</string>
    <key>LSHasLocalizedDisplayName</key>
    <true/>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>CFBundleDocumentTypes</key>
    <array>
        <dict>
            <key>CFBundleTypeName</key>
            <string>Image</string>
            <key>CFBundleTypeRole</key>
            <string>Editor</string>
            <key>LSHandlerRank</key>
            <string>Alternate</string>
            <key>LSItemContentTypes</key>
            <array>
                <string>public.image</string>
                <string>com.adobe.pdf</string>
            </array>
        </dict>
    </array>
</dict>
</plist>
PLIST

echo "==> Codesigning bundle..."
codesign --force --deep --sign - "$BUILD_BUNDLE"

echo "==> Installing to $INSTALL_BUNDLE..."
rm -rf "$INSTALL_BUNDLE"
ditto "$BUILD_BUNDLE" "$INSTALL_BUNDLE"

echo "==> Installed successfully: $INSTALL_BUNDLE"

#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="ImmersiveTranslator"
APP_DIR="$ROOT_DIR/dist/$APP_NAME.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"

cd "$ROOT_DIR"
swift build -c release

rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"
cp "$ROOT_DIR/.build/release/$APP_NAME" "$MACOS_DIR/$APP_NAME"

cat > "$CONTENTS_DIR/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>zh_CN</string>
    <key>CFBundleExecutable</key>
    <string>ImmersiveTranslator</string>
    <key>CFBundleIdentifier</key>
    <string>local.immersive-translator.mvp</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>ImmersiveTranslator</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>0.1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
PLIST

if command -v codesign >/dev/null 2>&1; then
    SIGN_IDENTITY="${CODESIGN_IDENTITY:-}"
    if [[ -n "$SIGN_IDENTITY" ]]; then
        codesign --force --sign "$SIGN_IDENTITY" "$MACOS_DIR/$APP_NAME" >/dev/null
        codesign --force --sign "$SIGN_IDENTITY" "$APP_DIR" >/dev/null
    else
        echo "warning: CODESIGN_IDENTITY is not set; using ad-hoc signature. macOS permissions may need re-approval after each rebuild." >&2
        codesign --force --sign - "$MACOS_DIR/$APP_NAME" >/dev/null
        codesign --force --sign - "$APP_DIR" >/dev/null
    fi
fi

echo "$APP_DIR"

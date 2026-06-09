#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="ImmersiveTranslator"
APP_DIR="$ROOT_DIR/dist/$APP_NAME.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
DEFAULT_LOCAL_CODESIGN_IDENTITY="ImmersiveTranslator Local Dev"

resolve_codesign_identity() {
    if ! command -v codesign >/dev/null 2>&1; then
        echo "error: codesign is required to build $APP_NAME.app on macOS." >&2
        exit 1
    fi

    if [[ -n "${CODESIGN_IDENTITY:-}" ]]; then
        if [[ "$CODESIGN_IDENTITY" == "-" ]]; then
            echo "warning: using explicit ad-hoc signing. macOS permissions may need re-approval after rebuilds." >&2
        fi
        printf '%s\n' "$CODESIGN_IDENTITY"
        return
    fi

    if command -v security >/dev/null 2>&1 && security find-identity -v -p codesigning 2>/dev/null | grep -Fq "\"$DEFAULT_LOCAL_CODESIGN_IDENTITY\""; then
        printf '%s\n' "$DEFAULT_LOCAL_CODESIGN_IDENTITY"
        return
    fi

    if [[ "${ALLOW_ADHOC_CODESIGN:-0}" == "1" ]]; then
        echo "warning: no fixed local codesign identity named '$DEFAULT_LOCAL_CODESIGN_IDENTITY' was found; using explicit ad-hoc signing." >&2
        echo "warning: ad-hoc builds may need Accessibility and Screen Recording re-approval after rebuilds." >&2
        printf '%s\n' "-"
        return
    fi

    cat >&2 <<EOF
error: no fixed local codesign identity was found.

Local app builds no longer fall back to ad-hoc signing by default, because ad-hoc
signatures often make macOS ask again for Accessibility and Screen Recording
permissions after rebuilds.

Create a self-signed Code Signing certificate named:
  $DEFAULT_LOCAL_CODESIGN_IDENTITY

Or use an existing stable identity explicitly:
  security find-identity -v -p codesigning
  CODESIGN_IDENTITY="Your Code Signing Identity" ./scripts/build_app.sh

For release packaging or a one-off ad-hoc build, opt in explicitly:
  ALLOW_ADHOC_CODESIGN=1 ./scripts/build_app.sh
EOF
    exit 1
}

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

SIGN_IDENTITY="$(resolve_codesign_identity)"
codesign --force --sign "$SIGN_IDENTITY" "$MACOS_DIR/$APP_NAME" >/dev/null
codesign --force --sign "$SIGN_IDENTITY" "$APP_DIR" >/dev/null

echo "$APP_DIR"

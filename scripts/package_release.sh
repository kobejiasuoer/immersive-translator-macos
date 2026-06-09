#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="ImmersiveTranslator"
VERSION="${1:-0.1.0}"
RELEASE_DIR="$ROOT_DIR/release"
APP_DIR="$ROOT_DIR/dist/$APP_NAME.app"
ZIP_PATH="$RELEASE_DIR/$APP_NAME-$VERSION-macOS.zip"
CHECKSUM_PATH="$ZIP_PATH.sha256"

cd "$ROOT_DIR"

if [[ -n "${CODESIGN_IDENTITY:-}" ]]; then
    "$ROOT_DIR/scripts/build_app.sh"
else
    CODESIGN_IDENTITY="-" "$ROOT_DIR/scripts/build_app.sh"
fi

rm -rf "$RELEASE_DIR"
mkdir -p "$RELEASE_DIR"

ditto -c -k --keepParent "$APP_DIR" "$ZIP_PATH"
shasum -a 256 "$ZIP_PATH" > "$CHECKSUM_PATH"

echo "$ZIP_PATH"
echo "$CHECKSUM_PATH"

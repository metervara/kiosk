#!/bin/bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$PROJECT_DIR"
OUTPUT_APP="$PROJECT_DIR/dist/Kiosk.app"
SIGNING_IDENTITY="${SIGNING_IDENTITY:--}"
UNIVERSAL=false
case "${1:-}" in
    "") ;;
    --universal) UNIVERSAL=true ;;
    *) echo "Usage: ./build.sh [--universal]" >&2; exit 2 ;;
esac
if [ "$#" -gt 1 ]; then echo "Usage: ./build.sh [--universal]" >&2; exit 2; fi

# The plist and icon are editable source assets and are always copied unchanged.
/usr/bin/plutil -lint Assets/Info.plist Model/Defaults.plist
test -f Assets/AppIcon.icns
./scripts/version.sh >/dev/null
if [ "$UNIVERSAL" = true ]; then
    # Build each slice with SwiftPM's native build system, then combine before signing.
    for ARCHITECTURE in arm64 x86_64; do
        SCRATCH_DIR="$PROJECT_DIR/.build/universal/$ARCHITECTURE"
        swift build -c release --arch "$ARCHITECTURE" --scratch-path "$SCRATCH_DIR"
        BIN_PATH="$(swift build -c release --arch "$ARCHITECTURE" --scratch-path "$SCRATCH_DIR" --show-bin-path)"
        cp "$BIN_PATH/Kiosk" "$PROJECT_DIR/.build/universal/Kiosk-$ARCHITECTURE"
    done
    BINARY_PATH="$PROJECT_DIR/.build/universal/Kiosk"
    /usr/bin/lipo -create "$PROJECT_DIR/.build/universal/Kiosk-arm64" \
        "$PROJECT_DIR/.build/universal/Kiosk-x86_64" -output "$BINARY_PATH"
    /usr/bin/lipo "$BINARY_PATH" -verify_arch arm64 x86_64
else
    swift build -c release
    BIN_PATH="$(swift build -c release --show-bin-path)"
    BINARY_PATH="$BIN_PATH/Kiosk"
fi

mkdir -p "$PROJECT_DIR/dist"
STAGING_DIR="$(mktemp -d "$PROJECT_DIR/dist/.kiosk-build.XXXXXX")"
trap 'rm -r "$STAGING_DIR"' EXIT
APP_PATH="$STAGING_DIR/Kiosk.app"
mkdir -p "$APP_PATH/Contents/MacOS" "$APP_PATH/Contents/Resources"
cp "$BINARY_PATH" "$APP_PATH/Contents/MacOS/Kiosk"
cp Assets/Info.plist "$APP_PATH/Contents/Info.plist"
cp Assets/AppIcon.icns "$APP_PATH/Contents/Resources/AppIcon.icns"
cp Assets/MenuBarIconTemplate.png "$APP_PATH/Contents/Resources/MenuBarIconTemplate.png"
cp -R Model "$APP_PATH/Contents/Resources/Model"
chmod 755 "$APP_PATH/Contents/MacOS/Kiosk"
SIGNING_OPTIONS=(--force --sign "$SIGNING_IDENTITY")
if [ "$SIGNING_IDENTITY" != "-" ]; then
    SIGNING_OPTIONS+=(--options runtime --timestamp)
fi
if [ -n "${SIGNING_KEYCHAIN:-}" ]; then
    SIGNING_OPTIONS+=(--keychain "$SIGNING_KEYCHAIN")
fi
/usr/bin/codesign "${SIGNING_OPTIONS[@]}" "$APP_PATH"
/usr/bin/codesign --verify --strict --verbose=2 "$APP_PATH"
# Replace the bundle only after verification, without overwriting a running binary.
if [ -e "$OUTPUT_APP" ]; then
    mv "$OUTPUT_APP" "$STAGING_DIR/Previous.app"
fi
if ! mv "$APP_PATH" "$OUTPUT_APP"; then
    if [ -e "$STAGING_DIR/Previous.app" ]; then mv "$STAGING_DIR/Previous.app" "$OUTPUT_APP"; fi
    exit 1
fi
echo "Built $OUTPUT_APP"

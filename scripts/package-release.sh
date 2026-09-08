#!/bin/bash
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_DIR"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Assets/Info.plist)"
RELEASE_TAG="${1:-v$VERSION}"
if [ "$#" -gt 1 ]; then echo "Usage: ./scripts/package-release.sh [vVERSION]" >&2; exit 2; fi
./scripts/version.sh --check-tag "$RELEASE_TAG"

./build.sh --universal
APP_PATH="$PROJECT_DIR/dist/Kiosk.app"
ARCHIVE_NAME="Kiosk-${RELEASE_TAG#v}-macos-universal.zip"
ARCHIVE_PATH="$PROJECT_DIR/dist/$ARCHIVE_NAME"

make_archive() {
    # ditto preserves executable permissions and the app bundle's macOS metadata.
    /usr/bin/ditto -c -k --sequesterRsrc --keepParent "$APP_PATH" "$ARCHIVE_PATH"
}

make_archive

/usr/bin/codesign --verify --strict --verbose=2 "$APP_PATH"
/usr/bin/lipo "$APP_PATH/Contents/MacOS/Kiosk" -verify_arch arm64 x86_64
(
    cd dist
    /usr/bin/shasum -a 256 "$ARCHIVE_NAME" > "$ARCHIVE_NAME.sha256"
)
cat > dist/release-notes.md <<EOF
<!-- kiosk-build:begin -->
Download **$ARCHIVE_NAME**, unzip it, and move **Kiosk.app** to **/Applications**.

- Requires macOS 13 or later; supports both Apple Silicon and Intel.
- Ad-hoc signed; not notarized. macOS Gatekeeper may block the downloaded app.
- End an active session and quit Kiosk before replacing an existing installation. Saved settings are retained.
- Exit a kiosk session with **Control + Option + Command + K**, then enter the operator passcode if configured.
- Configure Focus / Do Not Disturb and system gestures using the app's **Mac setup** tab.
- A SHA-256 checksum is included alongside the download.
<!-- kiosk-build:end -->

EOF
echo "Packaged $ARCHIVE_PATH"

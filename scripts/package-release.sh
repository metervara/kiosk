#!/bin/bash
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_DIR"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Assets/Info.plist)"
RELEASE_TAG="${1:-v$VERSION}"
if [ "$#" -gt 1 ]; then echo "Usage: ./scripts/package-release.sh [vVERSION]" >&2; exit 2; fi
./scripts/version.sh --check-tag "$RELEASE_TAG"

if [ -n "${NOTARY_PROFILE:-}" ] && [ "${SIGNING_IDENTITY:--}" = "-" ]; then
    echo "Notarization requires a Developer ID Application SIGNING_IDENTITY." >&2
    exit 1
fi

./build.sh --universal
APP_PATH="$PROJECT_DIR/dist/Kiosk.app"
ARCHIVE_NAME="Kiosk-${RELEASE_TAG#v}-macos-universal.zip"
ARCHIVE_PATH="$PROJECT_DIR/dist/$ARCHIVE_NAME"

make_archive() {
    # ditto preserves executable permissions and the app bundle's macOS metadata.
    /usr/bin/ditto -c -k --sequesterRsrc --keepParent "$APP_PATH" "$ARCHIVE_PATH"
}

make_archive
SIGNING_DESCRIPTION="Ad-hoc signed; not notarized. macOS Gatekeeper may block the downloaded app."
if [ "${SIGNING_IDENTITY:--}" != "-" ]; then
    SIGNING_DESCRIPTION="Developer ID signed; not notarized. Complete notarization before general distribution."
fi
if [ -n "${NOTARY_PROFILE:-}" ]; then
    NOTARY_OPTIONS=(--keychain-profile "$NOTARY_PROFILE")
    if [ -n "${SIGNING_KEYCHAIN:-}" ]; then NOTARY_OPTIONS+=(--keychain "$SIGNING_KEYCHAIN"); fi
    xcrun notarytool submit "$ARCHIVE_PATH" "${NOTARY_OPTIONS[@]}" --wait --timeout 30m \
        --output-format json > dist/notarization.json
    STATUS="$(/usr/bin/plutil -extract status raw -o - dist/notarization.json)"
    if [ "$STATUS" != "Accepted" ]; then
        echo "Notarization was not accepted. Inspect dist/notarization.json and the notarytool submission log." >&2
        exit 1
    fi
    xcrun stapler staple "$APP_PATH"
    xcrun stapler validate "$APP_PATH"
    /usr/sbin/spctl --assess --type execute --verbose=2 "$APP_PATH"
    make_archive # Publish the stapled app, not the pre-notarization upload.
    SIGNING_DESCRIPTION="Developer ID signed and notarized by Apple. The notarization ticket is stapled to the app."
fi

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
- $SIGNING_DESCRIPTION
- End an active session and quit Kiosk before replacing an existing installation. Saved settings are retained.
- Exit a kiosk session with **Control + Option + Command + K**, then enter the operator passcode if configured.
- Configure Focus / Do Not Disturb and system gestures using the app's **Mac setup** tab.
- A SHA-256 checksum is included alongside the download.
<!-- kiosk-build:end -->

EOF
echo "Packaged $ARCHIVE_PATH"

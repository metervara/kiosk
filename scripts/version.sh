#!/bin/bash
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PLIST="$PROJECT_DIR/Assets/Info.plist"
VERSION_PATTERN='^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$'
BUILD_PATTERN='^[1-9][0-9]*$'

usage() {
    echo "Usage: ./scripts/version.sh [VERSION BUILD | --check-tag vVERSION[-alpha.N|-beta.N|-rc.N]]" >&2
    exit 2
}

if [ "$#" -eq 2 ] && [ "$1" != "--check-tag" ]; then
    [[ "$1" =~ $VERSION_PATTERN ]] && [[ "$2" =~ $BUILD_PATTERN ]] || usage
    # This explicit version-edit command changes the source asset. Builds only copy it.
    /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $1" "$PLIST"
    /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $2" "$PLIST"
elif [ "$#" -ne 0 ] && { [ "$#" -ne 2 ] || [ "$1" != "--check-tag" ]; }; then
    usage
fi

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PLIST")"
BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$PLIST")"
if ! [[ "$VERSION" =~ $VERSION_PATTERN ]] || ! [[ "$BUILD" =~ $BUILD_PATTERN ]]; then
    echo "Info.plist must contain a numeric MAJOR.MINOR.PATCH version and a positive integer build number." >&2
    exit 1
fi

if [ "${1:-}" = "--check-tag" ]; then
    TAG_PATTERN="^v${VERSION//./\.}(-(alpha|beta|rc)\.[1-9][0-9]*)?$"
    if ! [[ "$2" =~ $TAG_PATTERN ]]; then
        echo "Tag '$2' must match Info.plist version v$VERSION, optionally with -alpha.N, -beta.N, or -rc.N." >&2
        exit 1
    fi
fi
echo "$VERSION (build $BUILD)"

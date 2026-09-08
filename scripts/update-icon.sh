#!/bin/bash
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SOURCE_IMAGE="${1:-$PROJECT_DIR/Assets/AppIcon.png}"
ICONSET_DIR="$(mktemp -d)/AppIcon.iconset"
mkdir -p "$ICONSET_DIR"
trap 'rm -r "$(dirname "$ICONSET_DIR")"' EXIT

# Run explicitly after editing/exporting the master PNG. build.sh just copies the .icns.
for SIZE in 16 32 128 256 512; do
    /usr/bin/sips -z "$SIZE" "$SIZE" "$SOURCE_IMAGE" --out "$ICONSET_DIR/icon_${SIZE}x${SIZE}.png" >/dev/null
    DOUBLE_SIZE=$((SIZE * 2))
    /usr/bin/sips -z "$DOUBLE_SIZE" "$DOUBLE_SIZE" "$SOURCE_IMAGE" --out "$ICONSET_DIR/icon_${SIZE}x${SIZE}@2x.png" >/dev/null
done
/usr/bin/iconutil -c icns "$ICONSET_DIR" -o "$PROJECT_DIR/Assets/AppIcon.icns"
echo "Updated Assets/AppIcon.icns"

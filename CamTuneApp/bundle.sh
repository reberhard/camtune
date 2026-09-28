#!/bin/bash
# Build Ojo and package as a macOS .app bundle
set -euo pipefail

cd "$(dirname "$0")"

# Ad-hoc signatures bind privacy grants to one binary hash and prompt again
# after every update. Use an existing stable identity; never silently fall back.
IDENTITY="${OJO_SIGNING_IDENTITY:-}"
if [ -z "$IDENTITY" ]; then
    IDENTITIES=$(security find-identity -v -p codesigning | awk '/"(Apple Development|Developer ID Application):/ {print $2}')
    COUNT=$(printf '%s\n' "$IDENTITIES" | awk 'NF {n++} END {print n+0}')
    if [ "$COUNT" != "1" ]; then
        echo "Set OJO_SIGNING_IDENTITY to an existing code-signing identity; found $COUNT candidates." >&2
        exit 1
    fi
    IDENTITY="$IDENTITIES"
fi

echo "Building..."
swift build -c release 2>&1

APP="Ojo.app"
rm -rf "$APP"

mkdir -p "$APP/Contents/MacOS"
cp .build/release/OjoApp "$APP/Contents/MacOS/Ojo"
cp Info.plist "$APP/Contents/"
/usr/libexec/PlistBuddy -c "Add :OjoSourceCommit string $(git rev-parse HEAD)" "$APP/Contents/Info.plist"
codesign --force --deep --sign "$IDENTITY" --timestamp=none "$APP"
codesign --verify --deep --strict "$APP"

echo "Built: $APP"
echo ""
echo "To run:  open $APP"
echo "To install:  cp -r $APP /Applications/"

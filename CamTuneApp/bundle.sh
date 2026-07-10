#!/bin/bash
# Build Ojo and package as a macOS .app bundle
set -e

cd "$(dirname "$0")"

echo "Building..."
swift build -c release 2>&1

APP="Ojo.app"
rm -rf "$APP"

mkdir -p "$APP/Contents/MacOS"
cp .build/release/OjoApp "$APP/Contents/MacOS/Ojo"
cp Info.plist "$APP/Contents/"

echo "Built: $APP"
echo ""
echo "To run:  open $APP"
echo "To install:  cp -r $APP /Applications/"

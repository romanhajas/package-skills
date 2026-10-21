#!/bin/zsh
# build.sh - compile "Package Skills.app" (universal: Apple silicon + Intel).
#
#   ./build.sh                 build and install to ~/Desktop/Package Skills.app
#   ./build.sh /path/X.app     install somewhere else
#
# Needs Xcode or the Command Line Tools to build; the built app needs neither.

set -euo pipefail

SRC=${0:A:h}
DEST=${1:-$HOME/Desktop/Package Skills.app}
BUILD="$SRC/build"
APP="$BUILD/Package Skills.app"

rm -rf "$BUILD"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

for arch in arm64 x86_64; do
  swiftc -O -swift-version 5 -parse-as-library -target "$arch-apple-macos14.0" \
    -o "$BUILD/PackageSkills-$arch" "$SRC"/Sources/*.swift
done
lipo -create -output "$APP/Contents/MacOS/PackageSkills" "$BUILD"/PackageSkills-*
cp "$SRC/Info.plist" "$APP/Contents/Info.plist"
cp "$SRC/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
codesign --force --sign - "$APP" 2>/dev/null

mkdir -p "${DEST:h}"
rm -rf "$DEST"
ditto "$APP" "$DEST"
touch "$DEST"
echo "built $DEST"

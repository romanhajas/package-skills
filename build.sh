#!/bin/zsh
# build.sh - compile "Skill Bridge.app" (universal: Apple silicon + Intel).
#
#   ./build.sh                 build and install to ~/Desktop/Skill Bridge.app
#   ./build.sh /path/X.app     install somewhere else
#   ./build.sh --release       also sign, notarize and zip it as ./build/Skill-Bridge.zip
#
# Signing is ad-hoc unless .signing.env (git-ignored) says otherwise, e.g.
#   SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)"
#   NOTARY_PROFILE="notary"   # saved by: xcrun notarytool store-credentials notary ...
#
# Needs Xcode or the Command Line Tools to build; the built app needs neither.

set -euo pipefail

SRC=${0:A:h}
DEST="$HOME/Desktop/Skill Bridge.app"
BUILD="$SRC/build"
APP="$BUILD/Skill Bridge.app"

RELEASE=0
for arg in "$@"; do
  case $arg in
    --release) RELEASE=1 ;;
    -*) echo "unknown option: $arg" >&2; exit 2 ;;
    *) DEST=$arg ;;
  esac
done

SIGN_IDENTITY=- NOTARY_PROFILE=
[[ -f "$SRC/.signing.env" ]] && source "$SRC/.signing.env"
if (( RELEASE )) && [[ "$SIGN_IDENTITY" == "-" || -z "$NOTARY_PROFILE" ]]; then
  echo "--release needs SIGN_IDENTITY and NOTARY_PROFILE in .signing.env (see the top of build.sh)" >&2
  exit 2
fi
# A Developer ID signature needs the hardened runtime and a secure timestamp.
SIGN=(--force --sign "$SIGN_IDENTITY")
[[ "$SIGN_IDENTITY" != "-" ]] && SIGN+=(--options runtime --timestamp)

rm -rf "$BUILD"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

for arch in arm64 x86_64; do
  swiftc -O -swift-version 5 -parse-as-library -target "$arch-apple-macos14.0" \
    -o "$BUILD/SkillBridge-$arch" "$SRC"/Sources/*.swift
done
lipo -create -output "$APP/Contents/MacOS/SkillBridge" "$BUILD"/SkillBridge-*
rm "$BUILD"/SkillBridge-*
cp "$SRC/Info.plist" "$APP/Contents/Info.plist"
cp "$SRC/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
codesign "${SIGN[@]}" "$APP"

if (( RELEASE )); then
  ditto -c -k --keepParent "$APP" "$BUILD/notarize.zip"
  xcrun notarytool submit "$BUILD/notarize.zip" --keychain-profile "$NOTARY_PROFILE" --wait
  rm "$BUILD/notarize.zip"
  xcrun stapler staple "$APP"
  spctl --assess --type execute "$APP"
  ditto -c -k --keepParent --norsrc "$APP" "$BUILD/Skill-Bridge.zip"
  echo "notarized $BUILD/Skill-Bridge.zip"
fi

mkdir -p "${DEST:h}"
rm -rf "$DEST"
ditto "$APP" "$DEST"
touch "$DEST"
# Drop the build copy, or Spotlight lists the app twice.
rm -rf "$APP"
echo "built $DEST"

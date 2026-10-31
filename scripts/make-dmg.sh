#!/bin/bash
# Builds a universal Trackaro.app with trackaro-mcp inside it and packs them into dist/Trackaro-<version>.dmg.
#
#   scripts/make-dmg.sh
#
# Signs ad hoc by default, so macOS warns on first open of a downloaded copy. For a release without the warning:
#
#   SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" NOTARY_PROFILE=your-notarytool-profile scripts/make-dmg.sh
set -euo pipefail

cd "$(dirname "$0")/.."

sign_identity="${SIGN_IDENTITY:--}"
notary_profile="${NOTARY_PROFILE:-}"
derived=.build/xcode-release
stage=.build/dmg-stage

sign() {
    if [[ "$sign_identity" == "-" ]]; then
        codesign --force --options runtime --sign - "$1"
    else
        codesign --force --options runtime --timestamp --sign "$sign_identity" "$1"
    fi
}

echo "==> Building Trackaro.app"
(cd App && xcodegen generate --quiet)
xcodebuild -quiet \
    -project App/Trackaro.xcodeproj -scheme Trackaro -configuration Release \
    -derivedDataPath "$derived" -destination 'generic/platform=macOS' \
    ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO build

echo "==> Building trackaro-mcp"
swift build -c release --arch arm64 --arch x86_64 --product trackaro-mcp
mcp_bin="$(swift build -c release --arch arm64 --arch x86_64 --product trackaro-mcp --show-bin-path)/trackaro-mcp"

echo "==> Assembling"
rm -rf "$stage"
mkdir -p "$stage"
ditto "$derived/Build/Products/Release/Trackaro.app" "$stage/Trackaro.app"
app="$stage/Trackaro.app"
mkdir -p "$app/Contents/Helpers"
install -m 755 "$mcp_bin" "$app/Contents/Helpers/trackaro-mcp"
ln -s /Applications "$stage/Applications"

echo "==> Signing ($sign_identity)"
sign "$app/Contents/Helpers/trackaro-mcp"
sign "$app"
codesign --verify --deep --strict "$app"

version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")
dmg="dist/Trackaro-$version.dmg"

echo "==> Creating $dmg"
mkdir -p dist
rm -f "$dmg"
hdiutil create -quiet -volname "Trackaro $version" -srcfolder "$stage" -format UDZO -fs HFS+ "$dmg"

if [[ "$sign_identity" != "-" ]]; then
    sign "$dmg"
fi
if [[ -n "$notary_profile" ]]; then
    echo "==> Notarizing"
    xcrun notarytool submit "$dmg" --keychain-profile "$notary_profile" --wait
    xcrun stapler staple "$dmg"
fi

echo "==> Done: $dmg ($(du -h "$dmg" | cut -f1))"

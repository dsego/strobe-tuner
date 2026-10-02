#!/usr/bin/env sh
# Build the Mac app for the Mac App Store, sign it with the given provisioning profile and package it as a .pkg
# for App Store Connect, upload it with the Transporter app.
#
# The bundle is assembled in build/macos from the Info.plist, credits and entitlements next to this script, the
# icon is made from AppIcon.iconset. The bundle is named after CFBundleName in the Info.plist.
#
#   MAC_PROFILE=<path>              Mac App Store provisioning profile (.provisionprofile), required,
#                                   the bundle id and team come from it
#   MAC_SIGN_IDENTITY=<name>        app signing certificate, defaults to "Apple Distribution"
#   MAC_INSTALLER_IDENTITY=<name>   installer signing certificate, defaults to "3rd Party Mac Developer Installer"

set -eu

ROOT=$(cd "$(dirname "$0")/.." && pwd)
OUT="$ROOT/build/macos"
NAME=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleName' "$ROOT/macos/Info.plist")
APP="$OUT/$NAME.app"
PKG="$OUT/$NAME.pkg"
MIN_MACOS=11.0
# Shown after the settings' title, e.g. "2.0 (1)", the About panel reads it from the Info.plist
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$ROOT/macos/Info.plist") ($(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$ROOT/macos/Info.plist"))"

if [ -z "${MAC_PROFILE:-}" ] || [ ! -f "$MAC_PROFILE" ]; then
    echo "Set MAC_PROFILE to the Mac App Store provisioning profile (.provisionprofile)"
    exit 1
fi

mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

# No -microarch:native, the build has to run on every Apple silicon Mac, not only this one
echo "Compiling app"
odin build "$ROOT/app" -o:speed -minimum-os-version:$MIN_MACOS -define:VERSION="$VERSION" -out:"$APP/Contents/MacOS/app.bin"

cp "$ROOT/macos/Info.plist" "$APP/Contents/Info.plist"
cp "$ROOT/macos/Credits.rtf" "$APP/Contents/Resources/"
cp "$ROOT/assets/Acknowledgements.txt" "$APP/Contents/Resources/"
# The App Store wants the 1024px icon_512x512@2x.png in the set
iconutil -c icns "$ROOT/AppIcon.iconset" -o "$APP/Contents/Resources/AppIcon.icns"

# The bundle id and team come from the profile, its application identifier is <team id>.<bundle id>
security cms -D -i "$MAC_PROFILE" > "$OUT/profile.plist"
APP_ID=$(/usr/libexec/PlistBuddy -c 'Print :Entitlements:com.apple.application-identifier' "$OUT/profile.plist")
TEAM_ID=$(/usr/libexec/PlistBuddy -c 'Print :Entitlements:com.apple.developer.team-identifier' "$OUT/profile.plist")
BUNDLE_ID=${APP_ID#*.}
plutil -replace CFBundleIdentifier -string "$BUNDLE_ID" "$APP/Contents/Info.plist"
cp "$MAC_PROFILE" "$APP/Contents/embedded.provisionprofile"

# The sandbox and microphone entitlements, plus the app and team ids the profile allows
cp "$ROOT/macos/app.entitlements" "$OUT/entitlements.plist"
/usr/libexec/PlistBuddy -c "Add :com.apple.application-identifier string $APP_ID" "$OUT/entitlements.plist"
/usr/libexec/PlistBuddy -c "Add :com.apple.developer.team-identifier string $TEAM_ID" "$OUT/entitlements.plist"

# Xcode records the SDK and itself in these, App Store Connect rejects uploads without them or with an old SDK.
# The Xcode version is written without dots, 26.6 is 2660 and 16.4.1 is 1641.
SDK_VERSION=$(xcrun --sdk macosx --show-sdk-version)
SDK_BUILD=$(xcrun --sdk macosx --show-sdk-build-version)
XCODE_VERSION=$(xcodebuild -version | awk 'NR == 1 { print $2 }')
XCODE_BUILD=$(xcodebuild -version | awk 'NR == 2 { print $3 }')
IFS=. read -r XCODE_MAJOR XCODE_MINOR XCODE_PATCH <<EOF
$XCODE_VERSION
EOF
PLIST="$APP/Contents/Info.plist"
plutil -replace DTPlatformName -string macosx "$PLIST"
plutil -replace DTPlatformVersion -string "$SDK_VERSION" "$PLIST"
plutil -replace DTPlatformBuild -string "$SDK_BUILD" "$PLIST"
plutil -replace DTSDKName -string "macosx$SDK_VERSION" "$PLIST"
plutil -replace DTSDKBuild -string "$SDK_BUILD" "$PLIST"
plutil -replace DTXcode -string "$XCODE_MAJOR${XCODE_MINOR:-0}${XCODE_PATCH:-0}" "$PLIST"
plutil -replace DTXcodeBuild -string "$XCODE_BUILD" "$PLIST"
plutil -replace DTCompiler -string com.apple.compilers.llvm.clang.1_0 "$PLIST"
plutil -replace BuildMachineOSBuild -string "$(sw_vers -buildVersion)" "$PLIST"

codesign --force --sign "${MAC_SIGN_IDENTITY:-Apple Distribution}" --entitlements "$OUT/entitlements.plist" "$APP"
productbuild --component "$APP" /Applications --sign "${MAC_INSTALLER_IDENTITY:-3rd Party Mac Developer Installer}" "$PKG"
echo "Built $PKG ($BUNDLE_ID)"

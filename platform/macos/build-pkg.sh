#!/usr/bin/env sh
# Build the Mac app for the Mac App Store, sign it with the given provisioning profile and package it as a .pkg
# for App Store Connect, upload it with the Transporter app.
#
# The bundle is assembled in build/macos from the Info.plist, credits and entitlements next to this script, the
# icon is compiled from platform/Strobie.icon. The bundle is named after CFBundleName in the Info.plist.
#
# With app as the first argument it stops at the bundle, signed ad hoc to run on this Mac only, no profile
# or certificates needed, see just app.
#
#   MAC_PROFILE=<path>             Mac App Store provisioning profile (.provisionprofile), required,
#                                   the bundle id and team come from it
#   MAC_SIGN_IDENTITY=<name>        app signing certificate, defaults to "Apple Distribution"
#   MAC_INSTALLER_IDENTITY=<name>   installer signing certificate, defaults to "3rd Party Mac Developer Installer"

set -eu

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
DEPS="$ROOT/external/macos"
OUT="$ROOT/build/macos"
NAME=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleName' "$ROOT/platform/macos/Info.plist")
APP="$OUT/$NAME.app"
PKG="$OUT/$NAME.pkg"
MIN_MACOS=11.0
# Shown after the settings' title, e.g. "2.0 (1)", the About panel reads it from the Info.plist
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$ROOT/platform/macos/Info.plist") ($(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$ROOT/platform/macos/Info.plist"))"

MODE=${1:-pkg}

if [ "$MODE" = pkg ] && { [ -z "${MAC_PROFILE:-}" ] || [ ! -f "$MAC_PROFILE" ]; }; then
    echo "Set MAC_PROFILE to the Mac App Store provisioning profile (.provisionprofile)"
    exit 1
fi

mkdir -p "$DEPS" "$APP/Contents/MacOS" "$APP/Contents/Resources"

# The native libraries are built once into external/macos for the oldest macOS the app runs on, the ones
# `just setup` and Odin ship are built for the Mac they were built on. SDL is linked in statically,
# Homebrew's isn't on the Macs the app runs on, just sdl macos builds it.
ODIN_ROOT=$(odin root)
CC="xcrun clang -target arm64-apple-macos$MIN_MACOS"
CFLAGS="-O2 -fPIC"

if [ ! -f "$DEPS/libminiaudio.a" ]; then
    echo "Building miniaudio"
    mkdir -p "$DEPS/miniaudio"
    for src in "$ODIN_ROOT"/vendor/miniaudio/src/*.c; do
        $CC $CFLAGS -c "$src" -o "$DEPS/miniaudio/$(basename "$src" .c).o"
    done
    ar rcs "$DEPS/libminiaudio.a" "$DEPS"/miniaudio/*.o
fi

if [ ! -f "$DEPS/sdl3/lib/libSDL3.a" ]; then
    echo "No SDL in $DEPS/sdl3, build it with just sdl macos"
    exit 1
fi

# No -microarch:native, the build has to run on every Apple silicon Mac, not only this one. Odin only emits an
# object file, clang links it with the static libraries, Odin would link Homebrew's SDL.
echo "Compiling app"
odin build "$ROOT/src/app" \
    -build-mode:obj \
    -use-single-module \
    -target:darwin_arm64 \
    -minimum-os-version:$MIN_MACOS \
    -define:VERSION="$VERSION" \
    -o:speed \
    -out:"$OUT/app.o"

echo "Linking"
$CC \
    "$OUT/app.o" \
    "$DEPS/libminiaudio.a" \
    "$ODIN_ROOT/vendor/stb/lib/darwin/stb_image.a" \
    "$ODIN_ROOT/vendor/stb/lib/darwin/stb_truetype.a" \
    "$ODIN_ROOT/vendor/stb/lib/darwin/stb_rect_pack.a" \
    "$DEPS/sdl3/lib/libSDL3.a" \
    -framework CoreMedia \
    -framework CoreVideo \
    -framework Cocoa \
    -weak_framework UniformTypeIdentifiers \
    -framework IOKit \
    -framework ForceFeedback \
    -framework Carbon \
    -framework CoreAudio \
    -framework AudioToolbox \
    -framework AVFoundation \
    -framework Foundation \
    -framework GameController \
    -framework Metal \
    -framework QuartzCore \
    -weak_framework CoreHaptics \
    -o "$APP/Contents/MacOS/app.bin"

cp "$ROOT/platform/macos/Info.plist" "$APP/Contents/Info.plist"
cp "$ROOT/platform/macos/Credits.rtf" "$APP/Contents/Resources/"
cp "$ROOT/assets/Acknowledgements.txt" "$APP/Contents/Resources/"
# The icon, actool compiles Icon Composer's file into Assets.car, with an .icns for macOS before 26, and names
# them in a partial Info.plist. Its report goes to stdout, errors included, shown when it fails.
if ! xcrun actool "$ROOT/platform/Strobie.icon" --compile "$APP/Contents/Resources" --platform macosx \
    --minimum-deployment-target $MIN_MACOS --app-icon Strobie --output-partial-info-plist "$OUT/icon-info.plist" > "$OUT/actool.plist"; then
    cat "$OUT/actool.plist"
    exit 1
fi
/usr/libexec/PlistBuddy -c "Merge $OUT/icon-info.plist" "$APP/Contents/Info.plist"

# For this Mac, the sandbox and the microphone as in the store's build. A new signature each build, macOS may
# ask for the microphone again.
if [ "$MODE" = app ]; then
    codesign --force --sign - --entitlements "$ROOT/platform/macos/app.entitlements" "$APP"
    echo "Built $APP"
    exit 0
fi

# The bundle id and team come from the profile, its application identifier is <team id>.<bundle id>
security cms -D -i "$MAC_PROFILE" > "$OUT/profile.plist"
APP_ID=$(/usr/libexec/PlistBuddy -c 'Print :Entitlements:com.apple.application-identifier' "$OUT/profile.plist")
TEAM_ID=$(/usr/libexec/PlistBuddy -c 'Print :Entitlements:com.apple.developer.team-identifier' "$OUT/profile.plist")
BUNDLE_ID=${APP_ID#*.}
plutil -replace CFBundleIdentifier -string "$BUNDLE_ID" "$APP/Contents/Info.plist"
cp "$MAC_PROFILE" "$APP/Contents/embedded.provisionprofile"

# The sandbox and microphone entitlements, plus the app and team ids the profile allows
cp "$ROOT/platform/macos/app.entitlements" "$OUT/entitlements.plist"
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

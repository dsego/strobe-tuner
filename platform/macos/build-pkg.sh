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

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
DEPS="$ROOT/external/macos"
OUT="$ROOT/build/macos"
NAME=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleName' "$ROOT/platform/macos/Info.plist")
APP="$OUT/$NAME.app"
PKG="$OUT/$NAME.pkg"
MIN_MACOS=11.0
# Shown after the settings' title, e.g. "2.0 (1)", the About panel reads it from the Info.plist
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$ROOT/platform/macos/Info.plist") ($(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$ROOT/platform/macos/Info.plist"))"

if [ -z "${MAC_PROFILE:-}" ] || [ ! -f "$MAC_PROFILE" ]; then
    echo "Set MAC_PROFILE to the Mac App Store provisioning profile (.provisionprofile)"
    exit 1
fi

mkdir -p "$DEPS" "$APP/Contents/MacOS" "$APP/Contents/Resources"

# The native libraries are built once into external/macos for the oldest macOS the app runs on, the ones
# `just setup` and Odin ship are built for the Mac they were built on. SDL is linked in statically,
# Homebrew's isn't on the Macs the app runs on.
ODIN_ROOT=$(odin root)
CC="xcrun clang -target arm64-apple-macos$MIN_MACOS"
CFLAGS="-O2 -fPIC"

if [ ! -f "$DEPS/libpffft.a" ]; then
    echo "Building pffft"
    $CC $CFLAGS -c "$ROOT/external/pffft/pffft.c" -o "$DEPS/pffft.o"
    ar rcs "$DEPS/libpffft.a" "$DEPS/pffft.o"
fi

if [ ! -f "$DEPS/libpa_ringbuffer.a" ]; then
    echo "Building pa_ringbuffer"
    $CC $CFLAGS -c "$ROOT/external/portaudio/src/common/pa_ringbuffer.c" -o "$DEPS/pa_ringbuffer.o"
    ar rcs "$DEPS/libpa_ringbuffer.a" "$DEPS/pa_ringbuffer.o"
fi

if [ ! -f "$DEPS/libminiaudio.a" ]; then
    echo "Building miniaudio"
    mkdir -p "$DEPS/miniaudio"
    for src in "$ODIN_ROOT"/vendor/miniaudio/src/*.c; do
        $CC $CFLAGS -c "$src" -o "$DEPS/miniaudio/$(basename "$src" .c).o"
    done
    ar rcs "$DEPS/libminiaudio.a" "$DEPS"/miniaudio/*.o
fi

if [ ! -d "$DEPS/SDL" ]; then
    # Match the desktop SDL, the Odin bindings are written against it
    SDL_VERSION=${SDL_VERSION:-$(brew list --versions sdl3 | awk '{print $2}')}
    git -c advice.detachedHead=false clone --depth 1 --branch "release-$SDL_VERSION" https://github.com/libsdl-org/SDL "$DEPS/SDL"
fi
if [ ! -f "$DEPS/sdl3/lib/libSDL3.a" ]; then
    echo "Building SDL"
    cmake -S "$DEPS/SDL" -B "$DEPS/SDL/build" \
        -DCMAKE_OSX_ARCHITECTURES=arm64 \
        -DCMAKE_OSX_DEPLOYMENT_TARGET=$MIN_MACOS \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_INSTALL_PREFIX="$DEPS/sdl3" \
        -DSDL_SHARED=OFF \
        -DSDL_STATIC=ON \
        -DSDL_TEST_LIBRARY=OFF \
        -DSDL_EXAMPLES=OFF
    cmake --build "$DEPS/SDL/build" --config Release --parallel
    cmake --install "$DEPS/SDL/build" --config Release
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
    "$DEPS/libpffft.a" \
    "$DEPS/libpa_ringbuffer.a" \
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
# The App Store wants the 1024px icon_512x512@2x.png in the set
iconutil -c icns "$ROOT/platform/macos/AppIcon.iconset" -o "$APP/Contents/Resources/AppIcon.icns"

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

#!/usr/bin/env sh
# Build the SDL renderer for the iOS simulator, install it on a simulator and run it with the console attached.
#
# The native libraries (miniaudio, stb) are rebuilt for the simulator once, into external/ios-sim, SDL3 is
# built there, patched for the simulator, by just sdl ios-sim. Odin only emits an object file, clang links it
# into the app bundle.
#
#   IOS_SIM=<udid or name>   simulator to use, defaults to the booted one or the first available iPhone
#   IOS_SIM_FAMILY=iPad      the first available iPad instead, booted or not, see just dev ipad

set -eu

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
DEPS="$ROOT/external/ios-sim"
OUT="$ROOT/build/ios-sim"
APP="$OUT/StrobeTuner.app"
BUNDLE_ID=app.strobie
MIN_IOS=15.0
# Shown after the settings' title and in the Settings app, e.g. "2.0 (1)"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$ROOT/platform/ios/Info.plist") ($(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$ROOT/platform/ios/Info.plist"))"
TARGET="arm64-apple-ios$MIN_IOS-simulator"

ODIN_ROOT=$(odin root)
CC="xcrun -sdk iphonesimulator clang -target $TARGET"
CFLAGS="-O2 -fPIC"

mkdir -p "$DEPS" "$OUT"

# --- native libraries --------------------------------------------------------------------------

if [ ! -f "$DEPS/libminiaudio.a" ]; then
    echo "Building miniaudio"
    mkdir -p "$DEPS/miniaudio"
    # miniaudio has to be compiled as Objective-C on iOS for the AVAudioSession setup
    for src in "$ODIN_ROOT"/vendor/miniaudio/src/*.c; do
        $CC $CFLAGS -x objective-c -DMA_NO_RUNTIME_LINKING -c "$src" -o "$DEPS/miniaudio/$(basename "$src" .c).o"
    done
    ar rcs "$DEPS/libminiaudio.a" "$DEPS"/miniaudio/*.o
fi

if [ ! -f "$DEPS/libstb.a" ]; then
    echo "Building stb"
    mkdir -p "$DEPS/stb"
    for src in "$ODIN_ROOT"/vendor/stb/src/*.c; do
        $CC $CFLAGS -c "$src" -o "$DEPS/stb/$(basename "$src" .c).o"
    done
    ar rcs "$DEPS/libstb.a" "$DEPS"/stb/*.o
fi

if [ ! -f "$DEPS/sdl3/lib/libSDL3.a" ]; then
    echo "No SDL in $DEPS/sdl3, build it with just sdl ios-sim"
    exit 1
fi

# --- app ---------------------------------------------------------------------------------------

echo "Compiling app"
odin build "$ROOT/src/app" \
    -build-mode:obj \
    -use-single-module \
    -target:darwin_arm64 \
    -subtarget:iphonesimulator \
    -minimum-os-version:$MIN_IOS \
    -define:IOS=true \
    -define:VERSION="$VERSION" \
    -debug \
    -out:"$OUT/app.o"

echo "Linking"
mkdir -p "$APP"
$CC -ObjC \
    "$OUT/app.o" \
    "$DEPS/libminiaudio.a" \
    "$DEPS/libstb.a" \
    "$DEPS/sdl3/lib/libSDL3.a" \
    -liconv \
    -framework Foundation \
    -framework UIKit \
    -framework CoreFoundation \
    -framework CoreGraphics \
    -framework QuartzCore \
    -framework Metal \
    -framework AVFoundation \
    -framework AudioToolbox \
    -framework CoreAudio \
    -framework CoreMedia \
    -framework CoreVideo \
    -framework CoreMotion \
    -framework CoreHaptics \
    -framework CoreBluetooth \
    -framework GameController \
    -framework OpenGLES \
    -framework UniformTypeIdentifiers \
    -o "$APP/StrobeTuner"

cp "$ROOT/platform/ios/Info.plist" "$APP/Info.plist"

# The icon and the launch screen's colour, actool compiles Icon Composer's file and the asset catalog into
# Assets.car, with the icon's flattened sizes for iOS before 26, and lists them in a partial Info.plist. Its report
# goes to stdout, errors included, shown when it fails.
if ! xcrun actool "$ROOT/platform/Strobie.icon" "$ROOT/platform/ios/Assets.xcassets" --compile "$APP" --platform iphonesimulator --minimum-deployment-target $MIN_IOS \
    --target-device iphone --target-device ipad --app-icon Strobie --output-partial-info-plist "$OUT/icon-info.plist" > "$OUT/actool.plist"; then
    cat "$OUT/actool.plist"
    exit 1
fi
/usr/libexec/PlistBuddy -c "Merge $OUT/icon-info.plist" "$APP/Info.plist"

# The version and acknowledgements show in the app's page in the Settings app, like on the device
mkdir -p "$APP/Settings.bundle"
cp "$ROOT/platform/ios/Settings.bundle/Root.plist" "$APP/Settings.bundle/"
plutil -replace PreferenceSpecifiers.0.DefaultValue -string "$VERSION" "$APP/Settings.bundle/Root.plist"
ACKNOWLEDGEMENTS="$APP/Settings.bundle/Acknowledgements.plist"
plutil -create xml1 "$ACKNOWLEDGEMENTS"
plutil -insert PreferenceSpecifiers -json '[{"Type": "PSGroupSpecifier"}]' "$ACKNOWLEDGEMENTS"
plutil -insert PreferenceSpecifiers.0.FooterText -string "$(cat "$ROOT/assets/Acknowledgements.txt")" "$ACKNOWLEDGEMENTS"

codesign --force --sign - --timestamp=none "$APP"

# --- simulator ---------------------------------------------------------------------------------

UDID_PATTERN='[0-9A-F]\{8\}-[0-9A-F]\{4\}-[0-9A-F]\{4\}-[0-9A-F]\{4\}-[0-9A-F]\{12\}'
FAMILY=${IOS_SIM_FAMILY:-iPhone}
DEVICE=${IOS_SIM:-}
# Asked for a family, a booted phone isn't it
if [ -z "$DEVICE" ] && [ -z "${IOS_SIM_FAMILY:-}" ]; then
    DEVICE=$(xcrun simctl list devices booted | grep -o "$UDID_PATTERN" | head -1)
fi
if [ -z "$DEVICE" ]; then
    DEVICE=$(xcrun simctl list devices available | grep "$FAMILY" | grep -o "$UDID_PATTERN" | head -1)
fi
if [ -z "$DEVICE" ]; then
    echo "No $FAMILY simulator found, install one in Xcode > Settings > Components"
    exit 1
fi

xcrun simctl boot "$DEVICE" 2>/dev/null || true
open -a Simulator
xcrun simctl install "$DEVICE" "$APP"
echo "Launching, Ctrl+C to detach"
xcrun simctl launch --console-pty --terminate-running-process "$DEVICE" "$BUNDLE_ID"

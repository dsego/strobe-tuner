#!/usr/bin/env sh
# Build the SDL renderer for the iOS simulator, install it on a simulator and run it with the console attached.
#
# The native libraries (SDL3, miniaudio, stb, pffft, pa_ringbuffer) are rebuilt for the simulator once,
# into external/ios-sim. Odin only emits an object file, clang links it into the app bundle.
#
#   IOS_SIM=<udid or name>   simulator to use, defaults to the booted one or the first available iPhone
#   SDL_VERSION=3.2.x        SDL release to build, defaults to the brew installed version

set -eu

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
DEPS="$ROOT/external/ios-sim"
OUT="$ROOT/build/ios-sim"
APP="$OUT/StrobeTuner.app"
BUNDLE_ID=com.dsego.strobetuner
MIN_IOS=15.0
# Shown after the settings' title and in the Settings app, e.g. "2.0 (1)"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$ROOT/platform/ios/Info.plist") ($(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$ROOT/platform/ios/Info.plist"))"
TARGET="arm64-apple-ios$MIN_IOS-simulator"

ODIN_ROOT=$(odin root)
CC="xcrun -sdk iphonesimulator clang -target $TARGET"
CFLAGS="-O2 -fPIC"

mkdir -p "$DEPS" "$OUT"

# --- native libraries --------------------------------------------------------------------------

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

if [ ! -d "$DEPS/SDL" ]; then
    # Match the desktop SDL, the Odin bindings are written against it
    SDL_VERSION=${SDL_VERSION:-$(brew list --versions sdl3 | awk '{print $2}')}
    git clone --depth 1 --branch "release-$SDL_VERSION" https://github.com/libsdl-org/SDL "$DEPS/SDL"
fi

# Local patch: SDL_GPU requires the Apple3 GPU family on iOS, the simulator only reports Apple2
SDL_METAL="$DEPS/SDL/src/gpu/metal/SDL_gpu_metal.m"
if ! grep -q 'MTLGPUFamilyApple3\] || TARGET_OS_SIMULATOR' "$SDL_METAL"; then
    echo "Patching SDL_GPU Metal to allow the simulator"
    sed -i '' 's/\[device supportsFamily:MTLGPUFamilyApple3\];/[device supportsFamily:MTLGPUFamilyApple3] || TARGET_OS_SIMULATOR;/' "$SDL_METAL"
fi

# Local patch: the simulator doesn't support depth clip mode, skip it like on visionOS
if ! grep -q 'SDL_PLATFORM_VISIONOS) && !TARGET_OS_SIMULATOR' "$SDL_METAL"; then
    echo "Patching SDL_GPU Metal to skip depth clip mode on the simulator"
    # Only the #ifndef directly above a setDepthClipMode call
    sed -i '' '/^#ifndef SDL_PLATFORM_VISIONOS$/{N;/setDepthClipMode/s/^#ifndef SDL_PLATFORM_VISIONOS/#if !defined(SDL_PLATFORM_VISIONOS) \&\& !TARGET_OS_SIMULATOR/;}' "$SDL_METAL"
fi

# Rebuild when the source was patched after the last build
if [ ! -f "$DEPS/sdl3/lib/libSDL3.a" ] || [ "$SDL_METAL" -nt "$DEPS/SDL/build/libSDL3.a" ]; then
    echo "Building SDL"
    cmake -S "$DEPS/SDL" -B "$DEPS/SDL/build" \
        -DCMAKE_SYSTEM_NAME=iOS \
        -DCMAKE_OSX_SYSROOT=iphonesimulator \
        -DCMAKE_OSX_ARCHITECTURES=arm64 \
        -DCMAKE_OSX_DEPLOYMENT_TARGET=$MIN_IOS \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_INSTALL_PREFIX="$DEPS/sdl3" \
        -DSDL_SHARED=OFF \
        -DSDL_STATIC=ON \
        -DSDL_TEST_LIBRARY=OFF \
        -DSDL_EXAMPLES=OFF
    cmake --build "$DEPS/SDL/build" --config Release --parallel
    cmake --install "$DEPS/SDL/build" --config Release
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
    "$DEPS/libpffft.a" \
    "$DEPS/libpa_ringbuffer.a" \
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

# The icon, actool makes the sizes from the 1024px one and lists them in a partial Info.plist
xcrun actool "$ROOT/platform/ios/Assets.xcassets" --compile "$APP" --platform iphonesimulator --minimum-deployment-target $MIN_IOS \
    --target-device iphone --app-icon AppIcon --output-partial-info-plist "$OUT/icon-info.plist" > /dev/null
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
DEVICE=${IOS_SIM:-$(xcrun simctl list devices booted | grep -o "$UDID_PATTERN" | head -1)}
if [ -z "$DEVICE" ]; then
    DEVICE=$(xcrun simctl list devices available | grep 'iPhone' | grep -o "$UDID_PATTERN" | head -1)
fi
if [ -z "$DEVICE" ]; then
    echo "No iPhone simulator found, install one in Xcode > Settings > Components"
    exit 1
fi

xcrun simctl boot "$DEVICE" 2>/dev/null || true
open -a Simulator
xcrun simctl install "$DEVICE" "$APP"
echo "Launching, Ctrl+C to detach"
xcrun simctl launch --console-pty --terminate-running-process "$DEVICE" "$BUNDLE_ID"

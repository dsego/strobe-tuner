#!/usr/bin/env sh
# Build the SDL renderer for iPhone, sign it with the given provisioning profile and package it as an .ipa.
#
# The native libraries (SDL3, miniaudio, stb, pffft, pa_ringbuffer) are rebuilt for the device once,
# into external/ios-device. Odin only emits an object file, clang links it into the app bundle.
#
#   IOS_PROFILE=<path>        provisioning profile, required, the bundle id and entitlements come from it
#   IOS_SIGN_IDENTITY=<name>  signing certificate, defaults to the one in the keychain the profile was made for,
#                             else "Apple Development" for a development profile (e.g. a free Personal Team)
#                             and "Apple Distribution" for an Ad Hoc one
#   IOS_DEVICE=<name or udid> installs and launches the app on this iPhone, needs Developer Mode on it
#   SDL_VERSION=3.2.x         SDL release to build, defaults to the brew installed version
#
# An Ad Hoc .ipa also installs without Developer Mode, by dragging it onto the iPhone in Finder.
# An App Store profile makes an .ipa for App Store Connect, upload it with the Transporter app.

set -eu

ROOT=$(cd "$(dirname "$0")/.." && pwd)
DEPS="$ROOT/external/ios-device"
OUT="$ROOT/build/ios-device"
APP="$OUT/Payload/StrobeTuner.app"
IPA="$OUT/StrobeTuner.ipa"
MIN_IOS=15.0
# Shown after the settings' title and in the Settings app, e.g. "2.0 (1)"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$ROOT/ios/Info.plist") ($(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$ROOT/ios/Info.plist"))"
TARGET="arm64-apple-ios$MIN_IOS"

ODIN_ROOT=$(odin root)
CC="xcrun -sdk iphoneos clang -target $TARGET"
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

if [ ! -f "$DEPS/sdl3/lib/libSDL3.a" ]; then
    echo "Building SDL"
    cmake -S "$DEPS/SDL" -B "$DEPS/SDL/build" \
        -DCMAKE_SYSTEM_NAME=iOS \
        -DCMAKE_OSX_SYSROOT=iphoneos \
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
odin build "$ROOT/app" \
    -build-mode:obj \
    -use-single-module \
    -target:darwin_arm64 \
    -subtarget:iphone \
    -minimum-os-version:$MIN_IOS \
    -define:IOS=true \
    -define:VERSION="$VERSION" \
    -o:speed \
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

# --- signing -----------------------------------------------------------------------------------

if [ -z "${IOS_PROFILE:-}" ] || [ ! -f "$IOS_PROFILE" ]; then
    echo "IOS_PROFILE has to point to a provisioning profile (.mobileprovision), got '${IOS_PROFILE:-}'"
    exit 1
fi

# The entitlements and the bundle id come from the profile, its application-identifier is <team id>.<bundle id>
security cms -D -i "$IOS_PROFILE" > "$OUT/profile.plist"
/usr/libexec/PlistBuddy -x -c 'Print :Entitlements' "$OUT/profile.plist" > "$OUT/entitlements.plist"
APP_ID=$(/usr/libexec/PlistBuddy -c 'Print :Entitlements:application-identifier' "$OUT/profile.plist")
BUNDLE_ID=${APP_ID#*.}

cp "$ROOT/ios/Info.plist" "$APP/Info.plist"
# A wildcard profile (<team id>.*) signs any bundle id, keep the one in Info.plist
case "$BUNDLE_ID" in
    *'*'*) BUNDLE_ID=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Info.plist") ;;
    *) plutil -replace CFBundleIdentifier -string "$BUNDLE_ID" "$APP/Info.plist" ;;
esac

# The icon, actool makes the sizes from the 1024px one and lists them in a partial Info.plist
xcrun actool "$ROOT/ios/Assets.xcassets" --compile "$APP" --platform iphoneos --minimum-deployment-target $MIN_IOS \
    --target-device iphone --app-icon AppIcon --output-partial-info-plist "$OUT/icon-info.plist" > /dev/null
/usr/libexec/PlistBuddy -c "Merge $OUT/icon-info.plist" "$APP/Info.plist"
plutil -replace CFBundleSupportedPlatforms -json '["iPhoneOS"]' "$APP/Info.plist"

# Xcode records the SDK and itself in these, App Store Connect rejects uploads without them or with an old SDK.
# The Xcode version is written without dots, 26.6 is 2660 and 16.4.1 is 1641.
SDK_VERSION=$(xcrun --sdk iphoneos --show-sdk-version)
SDK_BUILD=$(xcrun --sdk iphoneos --show-sdk-build-version)
XCODE_VERSION=$(xcodebuild -version | awk 'NR == 1 { print $2 }')
XCODE_BUILD=$(xcodebuild -version | awk 'NR == 2 { print $3 }')
IFS=. read -r XCODE_MAJOR XCODE_MINOR XCODE_PATCH <<EOF
$XCODE_VERSION
EOF
plutil -replace DTPlatformName -string iphoneos "$APP/Info.plist"
plutil -replace DTPlatformVersion -string "$SDK_VERSION" "$APP/Info.plist"
plutil -replace DTPlatformBuild -string "$SDK_BUILD" "$APP/Info.plist"
plutil -replace DTSDKName -string "iphoneos$SDK_VERSION" "$APP/Info.plist"
plutil -replace DTSDKBuild -string "$SDK_BUILD" "$APP/Info.plist"
plutil -replace DTXcode -string "$XCODE_MAJOR${XCODE_MINOR:-0}${XCODE_PATCH:-0}" "$APP/Info.plist"
plutil -replace DTXcodeBuild -string "$XCODE_BUILD" "$APP/Info.plist"
plutil -replace DTCompiler -string com.apple.compilers.llvm.clang.1_0 "$APP/Info.plist"
plutil -replace BuildMachineOSBuild -string "$(sw_vers -buildVersion)" "$APP/Info.plist"

cp "$ROOT/ios/PrivacyInfo.xcprivacy" "$APP/"

# The version and acknowledgements show in the app's page in the Settings app
mkdir -p "$APP/Settings.bundle"
cp "$ROOT/ios/Settings.bundle/Root.plist" "$APP/Settings.bundle/"
plutil -replace PreferenceSpecifiers.0.DefaultValue -string "$VERSION" "$APP/Settings.bundle/Root.plist"
ACKNOWLEDGEMENTS="$APP/Settings.bundle/Acknowledgements.plist"
plutil -create xml1 "$ACKNOWLEDGEMENTS"
plutil -insert PreferenceSpecifiers -json '[{"Type": "PSGroupSpecifier"}]' "$ACKNOWLEDGEMENTS"
plutil -insert PreferenceSpecifiers.0.FooterText -string "$(cat "$ROOT/assets/Acknowledgements.txt")" "$ACKNOWLEDGEMENTS"

cp "$IOS_PROFILE" "$APP/embedded.mobileprovision"

# Only development profiles allow attaching a debugger
if [ "$(/usr/libexec/PlistBuddy -c 'Print :Entitlements:get-task-allow' "$OUT/profile.plist" 2>/dev/null)" = true ]; then
    DEFAULT_IDENTITY="Apple Development"
else
    DEFAULT_IDENTITY="Apple Distribution"
fi
# The certificate the profile was made for, by its SHA-1. Xcode can leave another certificate of the same
# name in the keychain, the name alone is ambiguous then.
if [ -z "${IOS_SIGN_IDENTITY:-}" ]; then
    IDENTITIES=$(security find-identity -v -p codesigning)
    index=0
    while certificate=$(plutil -extract "DeveloperCertificates.$index" raw -o - "$OUT/profile.plist" 2>/dev/null); do
        hash=$(printf '%s' "$certificate" | base64 -D | shasum -a 1 | awk '{ print toupper($1) }')
        case "$IDENTITIES" in
            *"$hash"*) DEFAULT_IDENTITY=$hash && break ;;
        esac
        index=$((index + 1))
    done
fi
codesign --force --sign "${IOS_SIGN_IDENTITY:-$DEFAULT_IDENTITY}" --entitlements "$OUT/entitlements.plist" "$APP"

# An .ipa is a zip with the app inside a Payload folder
ditto -c -k --keepParent "$OUT/Payload" "$IPA"
echo "Built $IPA ($BUNDLE_ID)"

if [ -n "${IOS_DEVICE:-}" ]; then
    xcrun devicectl device install app --device "$IOS_DEVICE" "$APP"
    xcrun devicectl device process launch --device "$IOS_DEVICE" "$BUNDLE_ID"
fi

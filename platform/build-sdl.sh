#!/usr/bin/env sh
# Build SDL from source for one platform and install it into external/<platform>/sdl3, the headers and the
# library the app's builds link. They never build SDL themselves, run this once per platform and again to
# update SDL.
#
#   just sdl macos|ios-device|ios-sim|android
#
#   SDL_VERSION=3.4.x     SDL release to build, defaults to the brew installed version
#   ANDROID_HOME=<path>   the Android SDK, defaults to Homebrew's android-commandlinetools
#
# The source is cloned into a new temporary folder and left there for macOS to clear.

set -eu

PLATFORM=${1:-}
ROOT=$(cd "$(dirname "$0")/.." && pwd)
PREFIX="$ROOT/external/$PLATFORM/sdl3"
SRC="$(mktemp -d)/SDL"

# The oldest versions the app runs on, the same as in the app's build scripts
MIN_MACOS=11.0
MIN_IOS=15.0
MIN_SDK=29

# Static on Apple, linked into the app. A shared libSDL3.so on Android, SDL's Java activity loads it.
case "$PLATFORM" in
    macos)
        set -- \
            -DCMAKE_OSX_ARCHITECTURES=arm64 \
            -DCMAKE_OSX_DEPLOYMENT_TARGET=$MIN_MACOS \
            -DSDL_SHARED=OFF \
            -DSDL_STATIC=ON
        ;;
    ios-device | ios-sim)
        if [ "$PLATFORM" = ios-sim ]; then
            SYSROOT=iphonesimulator
        else
            SYSROOT=iphoneos
        fi
        set -- \
            -DCMAKE_SYSTEM_NAME=iOS \
            -DCMAKE_OSX_SYSROOT=$SYSROOT \
            -DCMAKE_OSX_ARCHITECTURES=arm64 \
            -DCMAKE_OSX_DEPLOYMENT_TARGET=$MIN_IOS \
            -DSDL_SHARED=OFF \
            -DSDL_STATIC=ON
        ;;
    android)
        SDK=${ANDROID_HOME:-/opt/homebrew/share/android-commandlinetools}
        NDK=$(ls -d "$SDK"/ndk/* 2> /dev/null | tail -n 1)
        if [ -z "$NDK" ]; then
            echo "The Android SDK in $SDK needs the NDK, see the README"
            exit 1
        fi
        set -- \
            -DCMAKE_TOOLCHAIN_FILE="$NDK/build/cmake/android.toolchain.cmake" \
            -DANDROID_ABI=arm64-v8a \
            -DANDROID_PLATFORM=$MIN_SDK \
            -DCMAKE_SHARED_LINKER_FLAGS=-Wl,--strip-all \
            -DSDL_SHARED=ON \
            -DSDL_STATIC=OFF \
            -DSDL_ANDROID_JAR=OFF
        ;;
    *)
        echo "Usage: just sdl macos|ios-device|ios-sim|android"
        exit 1
        ;;
esac

# Match the desktop SDL, the Odin bindings are written against it
SDL_VERSION=${SDL_VERSION:-$(brew list --versions sdl3 | awk '{print $2}')}
git -c advice.detachedHead=false clone --depth 1 --branch "release-$SDL_VERSION" https://github.com/libsdl-org/SDL "$SRC"

if [ "$PLATFORM" = ios-sim ]; then
    SDL_METAL="$SRC/src/gpu/metal/SDL_gpu_metal.m"
    # Local patch: SDL_GPU requires the Apple3 GPU family on iOS, the simulator only reports Apple2
    sed -i '' 's/\[device supportsFamily:MTLGPUFamilyApple3\];/[device supportsFamily:MTLGPUFamilyApple3] || TARGET_OS_SIMULATOR;/' "$SDL_METAL"
    # Local patch: the simulator doesn't support depth clip mode, skip it like on visionOS. Only the #ifndef
    # directly above a setDepthClipMode call.
    sed -i '' '/^#ifndef SDL_PLATFORM_VISIONOS$/{N;/setDepthClipMode/s/^#ifndef SDL_PLATFORM_VISIONOS/#if !defined(SDL_PLATFORM_VISIONOS) \&\& !TARGET_OS_SIMULATOR/;}' "$SDL_METAL"
    if ! grep -q 'MTLGPUFamilyApple3\] || TARGET_OS_SIMULATOR' "$SDL_METAL" \
        || ! grep -q 'SDL_PLATFORM_VISIONOS) && !TARGET_OS_SIMULATOR' "$SDL_METAL"; then
        echo "The simulator patches no longer apply to SDL $SDL_VERSION, see $SDL_METAL"
        exit 1
    fi
fi

echo "Building SDL $SDL_VERSION for $PLATFORM"
cmake -S "$SRC" -B "$SRC/build" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX="$PREFIX" \
    -DSDL_TEST_LIBRARY=OFF \
    -DSDL_EXAMPLES=OFF \
    "$@"
cmake --build "$SRC/build" --config Release --parallel
cmake --install "$SRC/build" --config Release

# SDL's Java activity, compiled with the app's own
if [ "$PLATFORM" = android ]; then
    mkdir -p "$PREFIX/java"
    cp "$SRC"/android-project/app/src/main/java/org/libsdl/app/*.java "$PREFIX/java/"
fi

echo "Installed SDL $SDL_VERSION into $PREFIX"

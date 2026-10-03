#!/usr/bin/env sh
# Build the SDL renderer for Android as an .apk signed with a debug key, without Gradle.
#
# The native libraries (SDL3, pffft, pa_ringbuffer) are built with the NDK once, into external/android.
# Odin only emits an object file, the NDK's clang links it into libmain.so. SDL's Java activity loads it,
# javac and d8 compile that, aapt2 packages it all.
#
#   ANDROID_HOME=<path>      the SDK, defaults to Homebrew's android-commandlinetools
#   ANDROID_DEVICE=<serial>  installs and launches the app on this phone, "usb" for the one plugged in,
#                            needs USB debugging on it
#   SDL_VERSION=3.4.x        SDL release to build, defaults to the brew installed version
#   JAVA_HOME=<path>         defaults to Homebrew's openjdk@17
#
# SDL's logs: adb logcat -s SDL, the app's own prints go nowhere on Android

set -eu

ROOT=$(cd "$(dirname "$0")/.." && pwd)
DEPS="$ROOT/external/android"
OUT="$ROOT/build/android"
STAGE="$OUT/apk" # the .apk's files, the native libraries in lib/arm64-v8a
LIBS="$STAGE/lib/arm64-v8a"
APK="$OUT/Strobie.apk"
PACKAGE=com.dsego.strobetuner
MIN_SDK=29 # Android 10, the oldest with Vulkan on most phones
TARGET_SDK=35
# The same version as on iOS. The code is Android's own, Google Play wants it higher with each upload and
# never back, where iOS starts its build number over for each version.
VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$ROOT/ios/Info.plist")
VERSION_CODE=1

SDK=${ANDROID_HOME:-/opt/homebrew/share/android-commandlinetools}
NDK=$(ls -d "$SDK"/ndk/* 2> /dev/null | tail -n 1)
BUILD_TOOLS=$(ls -d "$SDK"/build-tools/* 2> /dev/null | tail -n 1)
PLATFORM_JAR="$SDK/platforms/android-$TARGET_SDK/android.jar"
if [ -z "$NDK" ] || [ -z "$BUILD_TOOLS" ] || [ ! -f "$PLATFORM_JAR" ]; then
    echo "The Android SDK in $SDK needs the NDK, build-tools and platforms;android-$TARGET_SDK, see the README"
    exit 1
fi
TOOLCHAIN="$NDK/toolchains/llvm/prebuilt/darwin-x86_64"
CC="$TOOLCHAIN/bin/clang --target=aarch64-linux-android$MIN_SDK"
AR="$TOOLCHAIN/bin/llvm-ar"
CFLAGS="-O2 -fPIC"

JAVA_HOME=${JAVA_HOME:-$(brew --prefix openjdk@17)/libexec/openjdk.jdk/Contents/Home}
PATH="$JAVA_HOME/bin:$PATH"
export JAVA_HOME PATH

ODIN_ROOT=$(odin root)
export ODIN_ANDROID_NDK="$NDK"

mkdir -p "$DEPS" "$OUT" "$LIBS"

# --- native libraries --------------------------------------------------------------------------

if [ ! -f "$DEPS/libpffft.a" ]; then
    echo "Building pffft"
    $CC $CFLAGS -c "$ROOT/external/pffft/pffft.c" -o "$DEPS/pffft.o"
    $AR rcs "$DEPS/libpffft.a" "$DEPS/pffft.o"
fi

if [ ! -f "$DEPS/libpa_ringbuffer.a" ]; then
    echo "Building pa_ringbuffer"
    $CC $CFLAGS -c "$ROOT/external/portaudio/src/common/pa_ringbuffer.c" -o "$DEPS/pa_ringbuffer.o"
    $AR rcs "$DEPS/libpa_ringbuffer.a" "$DEPS/pa_ringbuffer.o"
fi

# Odin's stb bindings look for the libraries in the Odin folder, where Linux has them. Built there with the
# NDK, the Odin folder has to be writable, like for the Linux build.
if [ ! -f "$ODIN_ROOT/vendor/stb/lib/stb_image.a" ]; then
    echo "Building stb into $ODIN_ROOT/vendor/stb/lib"
    CC="$CC" AR="$AR" sh "$ODIN_ROOT/vendor/stb/src/build_stb.sh" unix
fi

if [ ! -d "$DEPS/SDL" ]; then
    # Match the desktop SDL, the Odin bindings are written against it
    SDL_VERSION=${SDL_VERSION:-$(brew list --versions sdl3 | awk '{print $2}')}
    git -c advice.detachedHead=false clone --depth 1 --branch "release-$SDL_VERSION" https://github.com/libsdl-org/SDL "$DEPS/SDL"
fi

# libSDL3.so is built straight into the .apk's files, again if they're gone
if [ ! -f "$DEPS/SDL/build/CMakeCache.txt" ]; then
    cmake -S "$DEPS/SDL" -B "$DEPS/SDL/build" \
        -DCMAKE_TOOLCHAIN_FILE="$NDK/build/cmake/android.toolchain.cmake" \
        -DANDROID_ABI=arm64-v8a \
        -DANDROID_PLATFORM=$MIN_SDK \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_SHARED_LINKER_FLAGS=-Wl,--strip-all \
        -DCMAKE_LIBRARY_OUTPUT_DIRECTORY="$LIBS" \
        -DSDL_SHARED=ON \
        -DSDL_STATIC=OFF \
        -DSDL_TEST_LIBRARY=OFF \
        -DSDL_EXAMPLES=OFF \
        -DSDL_ANDROID_JAR=OFF
fi
echo "Building SDL"
cmake --build "$DEPS/SDL/build" --config Release --parallel > /dev/null

# --- app ---------------------------------------------------------------------------------------

echo "Compiling shaders"
GLSLC="$NDK/shader-tools/darwin-x86_64/glslc" sh "$ROOT/shaders/vulkan/compile.sh"

echo "Compiling app"
odin build "$ROOT/app" \
    -build-mode:obj \
    -use-single-module \
    -target:linux_arm64 \
    -subtarget:android \
    -minimum-os-version:$MIN_SDK \
    -reloc-mode:pic \
    -define:RENDERER=sdl \
    -define:VERSION="$VERSION ($VERSION_CODE)" \
    -o:speed \
    -out:"$OUT/app.o"

echo "Linking"
$CC -shared \
    "$OUT/app.o" \
    "$DEPS/libpffft.a" \
    "$DEPS/libpa_ringbuffer.a" \
    "$ODIN_ROOT/vendor/stb/lib/stb_image.a" \
    "$ODIN_ROOT/vendor/stb/lib/stb_truetype.a" \
    "$ODIN_ROOT/vendor/stb/lib/stb_rect_pack.a" \
    -L"$LIBS" -lSDL3 \
    -laaudio -landroid -lm \
    -Wl,--no-undefined \
    -Wl,-z,max-page-size=16384 \
    -o "$LIBS/libmain.so"

echo "Compiling Java"
mkdir -p "$OUT/classes"
javac -nowarn -Xlint:-options -source 8 -target 8 \
    -bootclasspath "$PLATFORM_JAR" \
    -d "$OUT/classes" \
    "$DEPS"/SDL/android-project/app/src/main/java/org/libsdl/app/*.java \
    "$ROOT/android/StrobieActivity.java"
"$BUILD_TOOLS/d8" --release --min-api $MIN_SDK --lib "$PLATFORM_JAR" --output "$STAGE" \
    $(find "$OUT/classes" -name '*.class')

# --- package -----------------------------------------------------------------------------------

echo "Packaging"
# The launcher icon from the iOS one, for now
mkdir -p "$OUT/res/mipmap-xxxhdpi"
sips -z 192 192 "$ROOT/ios/Assets.xcassets/AppIcon.appiconset/AppIcon.png" \
    --out "$OUT/res/mipmap-xxxhdpi/ic_launcher.png" > /dev/null
"$BUILD_TOOLS/aapt2" compile --dir "$OUT/res" -o "$OUT/res.zip"
"$BUILD_TOOLS/aapt2" link \
    -I "$PLATFORM_JAR" \
    --manifest "$ROOT/android/AndroidManifest.xml" \
    --min-sdk-version $MIN_SDK \
    --target-sdk-version $TARGET_SDK \
    --version-code "$VERSION_CODE" \
    --version-name "$VERSION" \
    -o "$OUT/unsigned.apk" \
    "$OUT/res.zip"

# The dex compressed, the native libraries stored so they load straight from the .apk
(cd "$STAGE" && zip -q "$OUT/unsigned.apk" classes.dex && zip -q -0 -r "$OUT/unsigned.apk" lib)

# 16 KB pages, Google Play requires it
"$BUILD_TOOLS/zipalign" -f -P 16 4 "$OUT/unsigned.apk" "$OUT/aligned.apk"

# A debug key of its own, an .apk signed with another key only installs after uninstalling this one
KEYSTORE="$DEPS/debug.keystore"
if [ ! -f "$KEYSTORE" ]; then
    keytool -genkeypair -keystore "$KEYSTORE" -storepass android -keypass android -alias androiddebugkey \
        -keyalg RSA -keysize 2048 -validity 10000 -dname "CN=Android Debug,O=Android,C=US" > /dev/null
fi
"$BUILD_TOOLS/apksigner" sign --ks "$KEYSTORE" --ks-pass pass:android --out "$APK" "$OUT/aligned.apk"
echo "Built $APK"

if [ -n "${ANDROID_DEVICE:-}" ]; then
    if [ "$ANDROID_DEVICE" = usb ]; then
        ADB="adb -d"
    else
        ADB="adb -s $ANDROID_DEVICE"
    fi
    $ADB install -r "$APK"
    $ADB shell am start -n "$PACKAGE/.StrobieActivity"
fi

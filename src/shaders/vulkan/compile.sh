#!/usr/bin/env sh
# Compiles the Vulkan shaders to SPIR-V in build/spirv, the SDL renderer embeds them on Linux and Android.
#
# glslc comes with the Android NDK, or the shaderc package (brew install shaderc, apt install glslc).
#   GLSLC=<path>  glslc to use, defaults to the one on the PATH, else the newest NDK's

set -eu

ROOT=$(cd "$(dirname "$0")/../../.." && pwd)
OUT="$ROOT/build/spirv"

if [ -z "${GLSLC:-}" ]; then
    if command -v glslc > /dev/null; then
        GLSLC=glslc
    else
        SDK=${ANDROID_HOME:-/opt/homebrew/share/android-commandlinetools}
        GLSLC=$(ls "$SDK"/ndk/*/shader-tools/*/glslc 2> /dev/null | tail -n 1)
    fi
fi
if [ -z "$GLSLC" ]; then
    echo "glslc not found, install the Android NDK or shaderc, or set GLSLC"
    exit 1
fi

mkdir -p "$OUT"
for source in "$ROOT"/src/shaders/vulkan/*.vert "$ROOT"/src/shaders/vulkan/*.frag; do
    "$GLSLC" --target-env=vulkan1.0 -O "$source" -o "$OUT/$(basename "$source").spv"
done

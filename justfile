# use with https://github.com/casey/just

default:
    @just --list

# Clones and compiles the dependencies into external/, skips whatever is there already. dev and build run it first.
setup:
    #!/usr/bin/env sh
    set -eu
    mkdir -p external
    cd external

    clone() {
        [ -d "$(basename "$1")" ] || git clone --depth 1 "$1"
    }
    clone https://github.com/PortAudio/portaudio # only for its ring buffer
    clone https://github.com/dsego/odin-pa_ringbuffer
    clone https://github.com/dsego/odin-pffft
    clone https://bitbucket.org/jpommier/pffft

    # static_lib <source.c> <library.a>, the object file stays next to the source
    static_lib() {
        [ -f "$2" ] && return
        echo "Building $2"
        clang -c -O2 -fPIC "$1" -o "${1%.c}.o"
        ar rcs "$2" "${1%.c}.o"
    }
    static_lib pffft/pffft.c odin-pffft/pffft.a
    static_lib portaudio/src/common/pa_ringbuffer.c odin-pa_ringbuffer/pa_ringbuffer.a

    # Odin's vendored stb and miniaudio ship compiled for macOS, on Linux they're built into the Odin install once
    if [ "$(uname -s)" = Linux ]; then
        vendor="$(odin root)/vendor"
        [ -f "$vendor/stb/lib/stb_image.a" ] || sh "$vendor/stb/src/build_stb.sh"
        [ -f "$vendor/miniaudio/lib/miniaudio.a" ] || sh "$vendor/miniaudio/src/build_miniaudio.sh"
        # Vulkan there, the SPIR-V the app embeds
        sh ../src/shaders/vulkan/compile.sh
    fi

# just dev [target]
#   (none) debug build, needs SDL3 (brew install sdl3)
#   stats  with the signal stats and NSDF plots
#   ios    on the iOS simulator, the first run builds the native deps into external/ios-sim
dev target="": setup
    #!/usr/bin/env sh
    case "{{target}}" in
        "") odin run src/app -debug ;;
        stats) odin run src/app -debug -define:DEBUG_STATS=true ;;
        ios) sh platform/ios/build-sim.sh ;;
        *) echo "Unknown target '{{target}}', use stats or ios"; exit 1 ;;
    esac

# Optimized build for this machine
build: setup
    odin build src/app -o:speed -microarch:native

# Signed .ipa for iPhone: IOS_PROFILE=path/to/profile.mobileprovision [IOS_DEVICE=<name>] just ipa
ipa: setup
    sh platform/ios/build-device.sh

# Debug signed .apk for Android: [ANDROID_DEVICE=usb] just apk
apk: setup
    sh platform/android/build.sh

# Signed .pkg for the Mac App Store: MAC_PROFILE=path/to/profile.provisionprofile just pkg
pkg: setup
    sh platform/macos/build-pkg.sh

# Runs the unit tests in core
test:
    odin test src/core

# Generated tones through the tuner, checks the note and the readout: just accuracy [full]
accuracy mode="": setup
    odin run sandbox/accuracy -o:speed -- {{mode}}

# Recordings shifted by known cents through the tuner, checks the readout moves by the shift: just recordings [folder] [csv]
recordings *args: setup
    odin run sandbox/recordings -o:speed -- {{args}}

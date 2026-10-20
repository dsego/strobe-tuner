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
    clone https://github.com/dsego/extreme_fft

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
#   ipad   on an iPad simulator
dev target="": setup
    #!/usr/bin/env sh
    case "{{target}}" in
        "") odin run src/app -debug -vet ;;
        stats) odin run src/app -debug -vet -define:DEBUG_STATS=true ;;
        ios) sh platform/ios/build-sim.sh ;;
        ipad) IOS_SIM_FAMILY=iPad sh platform/ios/build-sim.sh ;;
        *) echo "Unknown target '{{target}}', use stats, ios or ipad"; exit 1 ;;
    esac

# Optimized build for this machine
build: setup
    odin build src/app -o:speed -microarch:native -vet

# Signed .ipa for iPhone: IOS_PROFILE=path/to/profile.mobileprovision [IOS_DEVICE=<name>] just ipa
ipa: setup
    sh platform/ios/build-device.sh

# Debug signed .apk for Android: [ANDROID_DEVICE=usb] just apk
apk: setup
    sh platform/android/build.sh

# The Mac app in build/macos, signed ad hoc for this Mac, with its icon and About panel
app: setup
    sh platform/macos/build-pkg.sh app

# Signed .pkg for the Mac App Store: MAC_PROFILE=path/to/profile.provisionprofile just pkg
pkg: setup
    sh platform/macos/build-pkg.sh

# The web build in build/web, served on http://localhost:8000 by platform/web/serve.py
web: setup
    mkdir -p build/web
    odin build src/app -target:js_wasm32 -target-features:simd128 -o:speed -vet -out:build/web/strobie.wasm
    python3 platform/web/serve.py

# Runs the unit tests in core
test:
    mkdir -p build
    odin test src/core -vet -out:build/core_tests

# Generated tones through the tuner, checks the note and the readout: just accuracy [full]
accuracy mode="": setup
    odin run sandbox/accuracy -o:speed -- {{mode}}

# Recordings shifted by known cents through the tuner, checks the readout moves by the shift: just recordings [folder] [csv]
recordings *args: setup
    odin run sandbox/recordings -o:speed -- {{args}}

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

# Builds SDL from source into external/<platform>/sdl3 for the app, ipa, pkg and apk builds and just dev ios: just sdl macos|ios-device|ios-sim|android
sdl platform:
    sh platform/build-sdl.sh {{platform}}

# just dev [target]
#   (none) debug build, needs SDL3 (brew install sdl3)
#   stats  with the signal stats and NSDF plots
#   unlock with the unlock's reminder and a pretend store, 10 s free and a reminder every 15 s
#   ios    on every booted iOS simulator, the console on an iPhone, the first run builds the native deps into external/ios-sim
#   ipad   the same with the console on an iPad
dev target="": setup
    #!/usr/bin/env sh
    case "{{target}}" in
        "") odin run src/app -debug -vet ;;
        stats) odin run src/app -debug -vet -define:DEBUG_STATS=true ;;
        unlock) odin run src/app -debug -vet -define:UNLOCK=fake -define:UNLOCK_FREE_S=10 -define:UNLOCK_REMINDER_S=15 ;;
        ios) sh platform/ios/build-sim.sh ;;
        ipad) IOS_SIM_FAMILY=iPad sh platform/ios/build-sim.sh ;;
        *) echo "Unknown target '{{target}}', use stats, unlock, ios or ipad"; exit 1 ;;
    esac

# Optimized build for this machine, build/strobie
build: setup
    mkdir -p build
    odin build src/app -o:speed -microarch:native -vet -out:build/strobie

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

# The profiles default to Strobie_iOS_App_Store.mobileprovision and Strobie_Mac_App_Store.provisionprofile in the
# repo's root, which git ignores. The scripts don't empty the app bundles, so it stops if an earlier build's are
# still there: anything left in them would ship.
# The App Store's .ipa and .pkg, selling the unlock, for Transporter: [IOS_PROFILE=<path>] [MAC_PROFILE=<path>] just release
release: setup
    #!/usr/bin/env sh
    set -eu
    for old in build/ios-device/Payload build/macos/*.app; do
        if [ -e "$old" ]; then
            echo "$old is from an earlier build, trash build/ios-device and build/macos first"
            exit 1
        fi
    done
    export UNLOCK=storekit
    BUILD_NUMBER="$(sh platform/build-number.sh)"
    export BUILD_NUMBER
    IOS_PROFILE="${IOS_PROFILE:-Strobie_iOS_App_Store.mobileprovision}" sh platform/ios/build-device.sh
    MAC_PROFILE="${MAC_PROFILE:-Strobie_Mac_App_Store.provisionprofile}" sh platform/macos/build-pkg.sh
    commit="$(git rev-parse --short HEAD)"
    git diff --quiet HEAD || commit="$commit with uncommitted changes"
    echo "Built $BUILD_NUMBER from $commit, upload build/ios-device/StrobeTuner.ipa and build/macos/*.pkg with Transporter"

# The web build in build/web, served on http://localhost:8000 by platform/web/serve.py
web: setup
    mkdir -p build/web
    odin build src/app -target:js_wasm32 -target-features:simd128 -o:speed -vet -out:build/web/strobie.wasm
    python3 platform/web/serve.py

# The web build into the website's try/app/, the page and its scripts, odin.js and strobie.wasm, replacing
# what's there. Its version after the settings' title is dev and the build date, e.g. dev-20261020:
# just wasm [../strobe-tuner-website]
wasm site="../strobe-tuner-website": setup
    mkdir -p build/web "{{site}}/try/app"
    odin build src/app -target:js_wasm32 -target-features:simd128 -o:speed -vet -define:VERSION="dev-$(date +%Y%m%d)" -out:build/web/strobie.wasm
    cp platform/web/index.html platform/web/strobie.js platform/web/capture-worklet.js build/web/strobie.wasm "$(odin root)/core/sys/wasm/js/odin.js" "{{site}}/try/app/"

# Runs the unit tests in core
test:
    mkdir -p build
    odin test src/core -vet -out:build/core_tests

# Generated tones through the tuner, checks the note and the readout: just accuracy [full]
accuracy mode="": setup
    mkdir -p build
    odin run sandbox/accuracy -o:speed -out:build/accuracy -- {{mode}}

# Recordings shifted by known cents through the tuner, checks the readout moves by the shift: just recordings [folder] [csv]
recordings *args: setup
    odin run sandbox/recordings -o:speed -- {{args}}

# The one-time unlock for the iPhone, iPad and Mac build scripts, which source this after setting ROOT and OUT,
# see UNLOCK in src/app/app_store.odin. UNLOCK=storekit sells it through the App Store with
# platform/apple/Store.swift, UNLOCK=fake pretends to, unset leaves the whole app free.
#
# With storekit, compile_store <sdk> <target> compiles Store.swift into $OUT and leaves the object in
# STORE_OBJECT and the folder of the Swift libraries in SWIFT_LIBS, otherwise both stay empty. The scripts pass
# them to the link as ${STORE_OBJECT:+"$STORE_OBJECT" "-L$SWIFT_LIBS" -framework StoreKit}, nothing when empty.

UNLOCK="${UNLOCK:-}"
STORE_OBJECT=""
SWIFT_LIBS=""

compile_store() {
    swift_sdk="$1"
    swift_target="$2"
    if [ "$UNLOCK" != storekit ]; then
        return
    fi

    echo "Compiling the store"
    xcrun -sdk "$swift_sdk" swiftc -target "$swift_target" -parse-as-library -swift-version 5 -O \
        -c "$ROOT/platform/apple/Store.swift" -o "$OUT/store.o"
    STORE_OBJECT="$OUT/store.o"
    SWIFT_LIBS="$(xcrun -sdk "$swift_sdk" --show-sdk-path)/usr/lib/swift"
}

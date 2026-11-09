// Copyright (C) 2026  Davorin Šego

// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by the Free
// Software Foundation, either version 3 of the License, or (at your option)
// any later version.

// This program is distributed in the hope that it will be useful, but WITHOUT
// ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
// FITNESS FOR A PARTICULAR PURPOSE.  See the GNU General Public License for
// more details.

// You should have received a copy of the GNU General Public License along
// with this program.  If not, see <http://www.gnu.org/licenses/>.


package app

// The one-time unlock and its reminder, see unlock.odin. Off by default, the whole app is free and none of it
// is built. storekit sells it through the App Store: the iPhone, iPad and Mac build scripts compile
// platform/apple/Store.swift for it with UNLOCK=storekit. fake pretends to, to try the reminder in a dev
// build without App Store Connect: a purchase goes through after a moment, a restore finds nothing, e.g.
// `just dev unlock`.
UNLOCK :: #config(UNLOCK, "")
#assert(UNLOCK == "" || UNLOCK == "fake" || UNLOCK == "storekit", "UNLOCK is storekit, fake or empty")

// The non-consumable in App Store Connect, the same on iPhone, iPad and Mac
UNLOCK_PRODUCT :: "app.strobie.unlock"

// Where the purchase stands, as State in Store.swift
PurchaseState :: enum i32 {
    LOADING, // asking the App Store for the product and an earlier purchase
    READY, // the product is in, it can be bought
    BUSY, // a purchase or a restore is running
    UNLOCKED,
    UNAVAILABLE, // no product from the App Store, offline or not set up there
    NOTHING_TO_RESTORE, // a restore found no earlier purchase, it can still be bought
}

when UNLOCK == "storekit" {
    #assert(ODIN_OS == .Darwin, "UNLOCK=storekit is for the iPhone, iPad and Mac builds")

    // The build scripts link Store.swift's object, the app is built as an object and links nothing itself
    foreign import store_swift "system:StoreKit.framework"

    @(default_calling_convention = "c")
    foreign store_swift {
        strobie_store_start :: proc(product: cstring) ---
        strobie_store_retry :: proc() ---
        strobie_store_state :: proc() -> PurchaseState ---
        strobie_store_buy :: proc() ---
        strobie_store_restore :: proc() ---
    }

    ask_app_store :: proc() {
        strobie_store_start(UNLOCK_PRODUCT)
    }

    // The product asked for again when the App Store couldn't be reached, nothing otherwise
    ask_app_store_again :: proc() {
        strobie_store_retry()
    }

    purchase_state :: proc() -> PurchaseState {
        return strobie_store_state()
    }

    buy_unlock :: proc() {
        strobie_store_buy()
    }

    restore_purchase :: proc() {
        strobie_store_restore()
    }
} else when UNLOCK == "fake" {
    // The App Store's sheet takes a moment
    FAKE_APP_STORE_WAIT_S :: 1.5

    FakeAppStore :: struct {
        state:     PurchaseState,
        busy_s:    f32, // left until the purchase or restore is through
        restoring: bool,
    }

    fake_app_store: FakeAppStore

    ask_app_store :: proc() {
        fake_app_store.state = .READY
    }

    // It's always reached
    ask_app_store_again :: proc() {}

    // Once a frame, the purchase or the restore goes through after its wait. StoreKit runs on its own and
    // needs nothing like it.
    update_fake_app_store :: proc(frame_time: f32) {
        if fake_app_store.state != .BUSY do return

        fake_app_store.busy_s -= frame_time
        if fake_app_store.busy_s > 0 do return

        fake_app_store.state = .NOTHING_TO_RESTORE if fake_app_store.restoring else .UNLOCKED
    }

    purchase_state :: proc() -> PurchaseState {
        return fake_app_store.state
    }

    buy_unlock :: proc() {
        fake_app_store = {.BUSY, FAKE_APP_STORE_WAIT_S, false}
    }

    restore_purchase :: proc() {
        fake_app_store = {.BUSY, FAKE_APP_STORE_WAIT_S, true}
    }
} else {
    // Off, there's nothing to unlock and the reminder never comes
    ask_app_store :: proc() {}

    ask_app_store_again :: proc() {}

    purchase_state :: proc() -> PurchaseState {
        return .UNLOCKED
    }

    buy_unlock :: proc() {}

    restore_purchase :: proc() {}
}

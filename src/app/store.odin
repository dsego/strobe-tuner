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

// What the store is doing, as State in Store.swift
StoreState :: enum i32 {
    LOADING, // asking the App Store for the price and an earlier purchase
    READY, // the price is in, it can be bought
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
        strobie_store_state :: proc() -> StoreState ---
        strobie_store_price :: proc(buffer: [^]u8, size: i32) ---
        strobie_store_buy :: proc() ---
        strobie_store_restore :: proc() ---
    }

    store_start :: proc() {
        strobie_store_start(UNLOCK_PRODUCT)
    }

    // StoreKit runs on its own, nothing to move on
    store_update :: proc(frame_time: f32) {}

    store_state :: proc() -> StoreState {
        return strobie_store_state()
    }

    // In the buyer's currency as the App Store shows it, empty until it's loaded
    store_price :: proc() -> cstring {
        buffer := make([]u8, 32, context.temp_allocator)
        strobie_store_price(raw_data(buffer), i32(len(buffer)))
        return cstring(raw_data(buffer))
    }

    store_buy :: proc() {
        strobie_store_buy()
    }

    store_restore :: proc() {
        strobie_store_restore()
    }
} else when UNLOCK == "fake" {
    // The App Store's sheet takes a moment
    FAKE_STORE_WAIT_S :: 1.5

    FakeStore :: struct {
        state:     StoreState,
        busy_s:    f32, // left until the purchase or restore is through
        restoring: bool,
    }

    fake_store: FakeStore

    store_start :: proc() {
        fake_store.state = .READY
    }

    // Once a frame
    store_update :: proc(frame_time: f32) {
        if fake_store.state != .BUSY do return

        fake_store.busy_s -= frame_time
        if fake_store.busy_s > 0 do return

        fake_store.state = .NOTHING_TO_RESTORE if fake_store.restoring else .UNLOCKED
    }

    store_state :: proc() -> StoreState {
        return fake_store.state
    }

    store_price :: proc() -> cstring {
        return "$4.99"
    }

    store_buy :: proc() {
        fake_store = {.BUSY, FAKE_STORE_WAIT_S, false}
    }

    store_restore :: proc() {
        fake_store = {.BUSY, FAKE_STORE_WAIT_S, true}
    }
} else {
    // Off, there's nothing to unlock and the reminder never comes
    store_start :: proc() {}

    store_update :: proc(frame_time: f32) {}

    store_state :: proc() -> StoreState {
        return .UNLOCKED
    }

    store_price :: proc() -> cstring {
        return ""
    }

    store_buy :: proc() {}

    store_restore :: proc() {}
}

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

// The one-time unlock through StoreKit 2, which is Swift only, for the app's Odin code through plain C
// functions, see src/app/store.odin. The iPhone, iPad and Mac builds compile it with UNLOCK=storekit. The app
// calls in from its main thread and reads the state every frame, StoreKit's work runs in tasks on the main
// actor and leaves its result in the state.

import StoreKit

// As StoreState in src/app/store.odin
private enum State: Int32 {
    case loading = 0
    case ready = 1
    case busy = 2
    case unlocked = 3
    case unavailable = 4
    case nothingToRestore = 5
}

@MainActor
private final class Store {
    static let shared = Store()

    var productID = ""
    var product: Product?
    var state = State.loading
    var price = ""
    var updates: Task<Void, Never>?

    // The product and its price, and whether it was bought before, on this device or another with the same
    // Apple Account. A purchase finished elsewhere, Family Sharing or a refund come in as updates.
    func start(_ id: String) {
        productID = id
        updates = Task {
            for await update in Transaction.updates {
                await self.finish(update)
            }
        }
        Task {
            if await self.ownsUnlock() {
                self.state = .unlocked
            }

            do {
                self.product = try await Product.products(for: [id]).first
            } catch {
                self.product = nil
            }
            if let product = self.product {
                self.price = product.displayPrice
            }
            if self.state == .loading {
                self.state = self.product == nil ? .unavailable : .ready
            }
        }
    }

    // The App Store's sheet, cancelled or pending (Ask to Buy) it's back to ready
    func buy() {
        guard let product, state == .ready || state == .nothingToRestore else { return }

        state = .busy
        Task {
            do {
                let result = try await product.purchase()
                if case .success(let verification) = result {
                    await self.finish(verification)
                }
            } catch {}
            if self.state == .busy {
                self.state = .ready
            }
        }
    }

    // The purchases of this Apple Account again from the App Store, Apple asks for a button that does this
    func restore() {
        guard state != .busy && state != .unlocked else { return }

        let before = state
        state = .busy
        Task {
            try? await AppStore.sync()
            if await self.ownsUnlock() {
                self.state = .unlocked
            } else {
                self.state = before == .unavailable ? .unavailable : .nothingToRestore
            }
        }
    }

    func finish(_ verification: VerificationResult<Transaction>) async {
        guard case .verified(let transaction) = verification, transaction.productID == productID else { return }

        state = transaction.revocationDate == nil ? .unlocked : .ready
        await transaction.finish()
    }

    func ownsUnlock() async -> Bool {
        for await result in Transaction.currentEntitlements(for: productID) {
            if case .verified(let transaction) = result, transaction.revocationDate == nil {
                return true
            }
        }
        return false
    }
}

@_cdecl("strobie_store_start")
public func strobie_store_start(_ product: UnsafePointer<CChar>) {
    let id = String(cString: product)
    MainActor.assumeIsolated { Store.shared.start(id) }
}

@_cdecl("strobie_store_state")
public func strobie_store_state() -> Int32 {
    MainActor.assumeIsolated { Store.shared.state.rawValue }
}

// The price as the App Store shows it in the buyer's currency, into buffer and cut to fit, empty until loaded
@_cdecl("strobie_store_price")
public func strobie_store_price(_ buffer: UnsafeMutablePointer<CChar>, _ size: Int32) {
    let price = MainActor.assumeIsolated { Store.shared.price }
    var bytes = Array(price.utf8.prefix(Int(max(size, 1)) - 1))
    bytes.append(0)
    bytes.withUnsafeBufferPointer { source in
        source.withMemoryRebound(to: CChar.self) { buffer.update(from: $0.baseAddress!, count: $0.count) }
    }
}

@_cdecl("strobie_store_buy")
public func strobie_store_buy() {
    MainActor.assumeIsolated { Store.shared.buy() }
}

@_cdecl("strobie_store_restore")
public func strobie_store_restore() {
    MainActor.assumeIsolated { Store.shared.restore() }
}

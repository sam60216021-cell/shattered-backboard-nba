//
//  StoreKitManager.swift — Monthly subscription via StoreKit 2.
//
//  Update SportConfig.monthlyProductID to match your App Store Connect product.
//  Add a Configuration.storekit file for local testing.
//

import Combine
import StoreKit
import SwiftUI

@MainActor
class StoreKitManager: ObservableObject {
    static let shared = StoreKitManager()

    @Published var isSubscribed   = false
    @Published var monthlyProduct: Product? = nil
    @Published var isPurchasing   = false
    @Published var purchaseError: String? = nil

    private var updateListenerTask: Task<Void, Never>?

    private init() {
        updateListenerTask = listenForTransactions()
        Task {
            await loadProducts()
            await refreshSubscriptionStatus()
        }
    }

    deinit { updateListenerTask?.cancel() }

    // ── Load products ──────────────────────────────────────────────────────────

    func loadProducts() async {
        do {
            let products = try await Product.products(for: [SportConfig.monthlyProductID])
            monthlyProduct = products.first
        } catch {
            print("[StoreKit] loadProducts failed: \(error)")
        }
    }

    // ── Purchase ───────────────────────────────────────────────────────────────

    func purchase() async {
        guard let product = monthlyProduct else {
            purchaseError = "Product not available. Check your connection and try again."
            return
        }
        isPurchasing  = true
        purchaseError = nil
        defer { isPurchasing = false }

        do {
            let result = try await product.purchase()
            switch result {
            case .success(let verification):
                let transaction = try checkVerified(verification)
                await transaction.finish()
                await refreshSubscriptionStatus()
            case .userCancelled:
                break
            case .pending:
                purchaseError = "Your purchase is pending approval."
            @unknown default:
                break
            }
        } catch {
            purchaseError = error.localizedDescription
        }
    }

    // ── Restore ────────────────────────────────────────────────────────────────

    func restorePurchases() async {
        do {
            try await AppStore.sync()
            await refreshSubscriptionStatus()
        } catch {
            purchaseError = error.localizedDescription
        }
    }

    // ── Status ─────────────────────────────────────────────────────────────────

    func refreshSubscriptionStatus() async {
        for await result in Transaction.currentEntitlements {
            if case .verified(let t) = result,
               t.productID == SportConfig.monthlyProductID,
               t.revocationDate == nil {
                isSubscribed = true
                return
            }
        }
        isSubscribed = false
    }

    // ── Transaction listener ───────────────────────────────────────────────────

    private func listenForTransactions() -> Task<Void, Never> {
        Task.detached(priority: .background) {
            for await result in Transaction.updates {
                if case .verified(let t) = result {
                    await t.finish()
                    await self.refreshSubscriptionStatus()
                }
            }
        }
    }

    // ── Verification helper ────────────────────────────────────────────────────

    private func checkVerified<T>(_ result: VerificationResult<T>) throws -> T {
        switch result {
        case .unverified:         throw StoreError.failedVerification
        case .verified(let safe): return safe
        }
    }
}

enum StoreError: Error { case failedVerification }

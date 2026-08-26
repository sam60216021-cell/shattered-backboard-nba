//
//  PaywallView.swift — NBA subscription purchase screen.
//

import SwiftUI
import StoreKit

struct PaywallView: View {
    @ObservedObject private var store = StoreKitManager.shared
    @State private var isRestoring = false

    var body: some View {
        ZStack {
            NightSkyBackground()
            ScrollView {
                VStack(spacing: 28) {

                    // ── Hero ──────────────────────────────────────────────────
                    VStack(spacing: 12) {
                        Image(systemName: "basketball.fill")
                            .font(.system(size: 64))
                            .foregroundStyle(Color.skyBright)
                            .padding(.top, 56)

                        Text(SportConfig.appDisplayName)
                            .font(.system(size: 30, weight: .bold, design: .rounded))
                            .foregroundColor(.white)

                        Text("Professional-grade \(SportConfig.sportName) stats and insights\n— every game day.")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                    }

                    // ── Feature list ──────────────────────────────────────────
                    VStack(spacing: 14) {
                        featureRow(icon: "calendar",
                                   text: "Daily NBA schedule with tip-off times")
                        featureRow(icon: "bolt.fill",
                                   text: "Quick Picks — Safe, Medium & Risky tiers")
                        featureRow(icon: "person.3.sequence.fill",
                                   text: "Confirmed starting rotations every game day")
                        featureRow(icon: "chart.bar.fill",
                                   text: "PTS, REB, AST, 3PM, PRA props with OVER %")
                        featureRow(icon: "arrow.triangle.2.circlepath",
                                   text: "Live data refreshed daily from your Mac server")
                    }
                    .padding(.horizontal, 24)

                    // ── Price ─────────────────────────────────────────────────
                    VStack(spacing: 6) {
                        if let product = store.monthlyProduct {
                            Text(product.displayPrice)
                                .font(.system(size: 40, weight: .bold))
                                .foregroundColor(.white)
                            Text("per month · cancel anytime in Settings")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                        } else {
                            ProgressView().tint(.skyBright).padding(.vertical, 8)
                        }
                    }

                    // ── Subscribe button ──────────────────────────────────────
                    VStack(spacing: 12) {
                        Button {
                            Task { await store.purchase() }
                        } label: {
                            ZStack {
                                if store.isPurchasing {
                                    ProgressView().tint(.black)
                                } else {
                                    Text("Subscribe Now")
                                        .font(.system(size: 17, weight: .bold))
                                        .foregroundColor(.black)
                                }
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 16)
                            .background(Color.skyBright)
                            .cornerRadius(14)
                        }
                        .disabled(store.isPurchasing || store.monthlyProduct == nil)
                        .padding(.horizontal, 24)

                        if let err = store.purchaseError {
                            Text(err).font(.caption).foregroundColor(.red)
                                .padding(.horizontal, 24)
                        }

                        Button(isRestoring ? "Restoring…" : "Restore Purchases") {
                            isRestoring = true
                            Task {
                                await store.restorePurchases()
                                isRestoring = false
                            }
                        }
                        .font(.subheadline)
                        .foregroundColor(.skyBright)
                        .disabled(isRestoring)
                    }

                    Text("Payment charged to Apple ID account. Subscription renews automatically unless cancelled at least 24 hours before the renewal date.")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                        .padding(.bottom, 40)
                }
            }
        }
    }

    private func featureRow(icon: String, text: String) -> some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 20))
                .foregroundColor(.skyBright)
                .frame(width: 28)
            Text(text)
                .font(.subheadline)
                .foregroundColor(.white.opacity(0.85))
            Spacer()
        }
    }
}

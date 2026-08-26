//
//  OnboardingView.swift — First-launch NBA welcome screen.
//

import SwiftUI

struct OnboardingView: View {
    @AppStorage("hasOnboarded") private var hasOnboarded = false

    var body: some View {
        ZStack {
            NightSkyBackground()
            VStack(spacing: 0) {
                Spacer()

                // ── Hero ──────────────────────────────────────────────────────
                VStack(spacing: 16) {
                    Image(systemName: "basketball.fill")
                        .font(.system(size: 80))
                        .foregroundStyle(Color.skyBright)

                    Text(SportConfig.appDisplayName)
                        .font(.system(size: 32, weight: .bold, design: .rounded))
                        .foregroundColor(.white)

                    Text("Data-driven predictions powered\nby real-time \(SportConfig.sportName) data.")
                        .font(.title3)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                }

                Spacer()

                // ── Feature pills ─────────────────────────────────────────────
                VStack(spacing: 12) {
                    HStack(spacing: 12) {
                        featurePill(icon: "calendar",          label: "Daily Schedule")
                        featurePill(icon: "bolt.fill",         label: "Quick Picks")
                    }
                    HStack(spacing: 12) {
                        featurePill(icon: "person.3.sequence.fill", label: "Starting Rotations")
                        featurePill(icon: "chart.bar.fill",    label: "Player Props")
                    }
                }
                .padding(.horizontal, 24)

                Spacer()

                // ── CTA ───────────────────────────────────────────────────────
                Button {
                    hasOnboarded = true
                } label: {
                    Text("Get Started")
                        .font(.system(size: 18, weight: .bold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .background(Color.skyBright)
                        .foregroundColor(.black)
                        .cornerRadius(14)
                }
                .padding(.horizontal, 24)

                Text("Subscription required to access all features.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(.top, 10)
                    .padding(.bottom, 40)
            }
        }
    }

    private func featurePill(icon: String, label: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 13))
                .foregroundColor(Color.skyBright)
            Text(label)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(Color.white.opacity(0.9))
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity)
        .background(Color.white.opacity(0.07))
        .cornerRadius(10)
        .overlay(RoundedRectangle(cornerRadius: 10)
            .strokeBorder(Color.white.opacity(0.12), lineWidth: 1))
    }
}

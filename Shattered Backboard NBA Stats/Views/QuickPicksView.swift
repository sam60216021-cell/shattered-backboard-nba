//
//  QuickPicksView.swift — Picks tab: personal parlay builder.
//
//  Add picks by tapping a game on the Schedule tab → Game Picks page.
//

import SwiftUI
import Photos

// MARK: - ParlayBuilderView

struct QuickPicksView: View {

    @ObservedObject private var router = AppRouter.shared
    @State private var isSavingScreenshot = false
    @State private var screenshotMessage: String? = nil
    @State private var screenshotSuccess = false

    var body: some View {
        NavigationStack {
            ZStack {
                NightSkyBackground()
                if router.parlayPicks.isEmpty {
                    emptyState
                } else {
                    parlayList
                }
            }
            .navigationTitle("My Parlay")
            .navigationBarTitleDisplayMode(.large)
            .toolbar { toolbarItems }
            .alert(screenshotMessage ?? "", isPresented: Binding(
                get: { screenshotMessage != nil },
                set: { if !$0 { screenshotMessage = nil } }
            )) {
                Button("OK", role: .cancel) { screenshotMessage = nil }
            }
        }
    }

    // MARK: - Parlay list

    private var parlayList: some View {
        ScrollView {
            VStack(spacing: 16) {
                // Probability summary card
                summaryCard

                // Picks
                VStack(spacing: 10) {
                    ForEach(router.parlayPicks) { pick in
                        ParlayPickRow(pick: pick)
                    }
                }
                .padding(.horizontal, 16)

                // Clear button
                Button(role: .destructive) {
                    withAnimation { router.clearParlay() }
                } label: {
                    Label("Clear All Picks", systemImage: "trash")
                        .font(.subheadline.bold())
                        .foregroundColor(.red.opacity(0.85))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(Color.red.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
                        .overlay(
                            RoundedRectangle(cornerRadius: 12)
                                .stroke(Color.red.opacity(0.25), lineWidth: 1)
                        )
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 32)
            }
            .padding(.top, 12)
        }
    }

    // MARK: - Summary card

    private var summaryCard: some View {
        VStack(spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(router.parlayPicks.count) picks")
                        .font(.subheadline.bold())
                        .foregroundColor(.white)
                    Text("Combined probability")
                        .font(.caption)
                        .foregroundColor(.white.opacity(0.5))
                }
                Spacer()
                Text(combinedProbString)
                    .font(.system(size: 32, weight: .black, design: .rounded))
                    .foregroundColor(combinedProbColor)
            }


        }
        .padding(16)
        .background(Color.skyCard, in: RoundedRectangle(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(Color.skyBorder, lineWidth: 1)
        )
        .padding(.horizontal, 16)
    }

    private var combinedProbString: String {
        let p = router.combinedProbability
        if p <= 0 { return "—" }
        return "\(Int(round(p * 100)))%"
    }

    private var combinedProbColor: Color {
        let p = router.combinedProbability
        if p >= 0.50 { return .green }
        if p >= 0.30 { return .skyBright }
        return .orange
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 20) {
            Image(systemName: "star.slash.fill")
                .font(.system(size: 52))
                .foregroundColor(.skyBright.opacity(0.4))

            Text("No picks yet")
                .font(.title2.bold())
                .foregroundColor(.white)

            Text("Go to the Schedule tab, tap a game, and add props to build your parlay.")
                .font(.subheadline)
                .foregroundColor(.white.opacity(0.5))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)

            Button("Go to Schedule") {
                withAnimation { router.selectedTab = 0 }
            }
            .buttonStyle(BrightButtonStyle())
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarItems: some ToolbarContent {
        ToolbarItem(placement: .navigationBarLeading) {
            if !router.parlayPicks.isEmpty {
                Button {
                    takeScreenshot()
                } label: {
                    Image(systemName: isSavingScreenshot ? "hourglass" : "camera")
                        .foregroundColor(.skyBright)
                }
                .disabled(isSavingScreenshot)
            }
        }
        ToolbarItem(placement: .navigationBarTrailing) {
            if !router.parlayPicks.isEmpty {
                Button("Clear", role: .destructive) {
                    withAnimation { router.clearParlay() }
                }
                .foregroundColor(.red.opacity(0.8))
            }
        }
    }

    // MARK: - Screenshot

    @MainActor
    private func takeScreenshot() {
        isSavingScreenshot = true
        let screenWidth = UIScreen.main.bounds.width
        let renderer = ImageRenderer(content: parlaySnapshotView(width: screenWidth))
        renderer.scale = 3.0
        guard let uiImage = renderer.uiImage else {
            isSavingScreenshot = false
            screenshotSuccess = false
            screenshotMessage = "Failed to render parlay image."
            return
        }
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            guard status == .authorized || status == .limited else {
                DispatchQueue.main.async {
                    isSavingScreenshot = false
                    screenshotMessage = "Photo access denied. Enable it in Settings → Privacy → Photos."
                }
                return
            }
            PHPhotoLibrary.shared().performChanges({
                PHAssetChangeRequest.creationRequestForAsset(from: uiImage)
            }) { success, error in
                DispatchQueue.main.async {
                    isSavingScreenshot = false
                    if success {
                        screenshotMessage = "Parlay saved to Photos!"
                    } else {
                        screenshotMessage = error?.localizedDescription ?? "Could not save to Photos."
                    }
                }
            }
        }
    }

    // MARK: - Snapshot view (rendered off-screen at full height by ImageRenderer)

    @ViewBuilder
    private func parlaySnapshotView(width: CGFloat) -> some View {
        VStack(spacing: 0) {
            // Header bar
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("My Parlay")
                        .font(.title2.bold())
                        .foregroundColor(.white)
                    Text("Shattered Backboard")
                        .font(.caption)
                        .foregroundColor(.skyBright.opacity(0.7))
                }
                Spacer()
                Image(systemName: "basketball.fill")
                    .font(.title2)
                    .foregroundColor(.skyBright)
            }
            .padding(.horizontal, 16)
            .padding(.top, 20)
            .padding(.bottom, 12)

            // Summary card
            summaryCard
                .padding(.bottom, 12)

            // All pick rows (no remove button)
            VStack(spacing: 10) {
                ForEach(router.parlayPicks) { pick in
                    ParlayPickRow(pick: pick, showRemove: false)
                }
            }
            .padding(.horizontal, 16)

            // Footer
            Text("shatteredbackboard.app")
                .font(.caption2)
                .foregroundColor(.white.opacity(0.25))
                .padding(.top, 16)
                .padding(.bottom, 20)
        }
        .frame(width: width)
        .background(
            LinearGradient(
                gradient: Gradient(stops: [
                    .init(color: .skyDeep, location: 0.0),
                    .init(color: .skyMid,  location: 0.55),
                    .init(color: .skyDeep, location: 1.0),
                ]),
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
    }
}

// MARK: - ParlayPickRow

struct ParlayPickRow: View {
    let pick: PlayerProp
    var showRemove: Bool = true
    @ObservedObject private var router = AppRouter.shared

    var body: some View {
        HStack(spacing: 12) {
            // Confidence ring
            confidenceRing

            // Details
            VStack(alignment: .leading, spacing: 3) {
                Text(pick.playerName)
                    .font(.subheadline.bold())
                    .foregroundColor(.white)

                HStack(spacing: 6) {
                    if let team = pick.team {
                        Text(team)
                            .font(.caption2)
                            .foregroundColor(.white.opacity(0.4))
                    }
                    Text("·")
                        .foregroundColor(.white.opacity(0.3))
                    Text("\(pick.statLabel) OVER \(pick.line.cleanLine)")
                        .font(.caption2.bold())
                        .foregroundColor(.white.opacity(0.75))
                }
            }

            Spacer()

            // Remove
            if showRemove {
                Button {
                    withAnimation { router.removeFromParlay(pick) }
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title3)
                        .foregroundColor(.white.opacity(0.3))
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(Color.skyCard, in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.skyBorder, lineWidth: 1)
        )
    }

    private var confidenceRing: some View {
        let pct = pick.overPct ?? 0
        let color: Color = pct >= 0.80 ? .green : pct >= 0.65 ? .skyBright : .orange
        return ZStack {
            Circle()
                .stroke(color.opacity(0.2), lineWidth: 3)
            Circle()
                .trim(from: 0, to: pct)
                .stroke(color, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Text("\(Int(round(pct * 100)))")
                .font(.system(size: 9, weight: .black))
                .foregroundColor(color)
        }
        .frame(width: 34, height: 34)
    }
}

#Preview {
    QuickPicksView()
}

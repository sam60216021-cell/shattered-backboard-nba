//
//  SettingsView.swift — Public-facing settings (release + debug).
//
//  Visible to all users:
//    • Restore Purchases
//    • About  (app name + version)
//
//  Developer screen (DEBUG builds only):
//    Tap the version number 10 times to open DebugSettingsView.
//

import SwiftUI

struct SettingsView: View {
    @ObservedObject private var store = StoreKitManager.shared
    @ObservedObject private var localData = LocalDataService.shared
    @ObservedObject private var router = AppRouter.shared

    @State private var modelHealthRows: [ModelHealthRow] = []
    @State private var healthSampleCount: Int = 0
    @State private var isComputingHealth = false

    private var appVersion: String {
        let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        let b = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
        return "\(v) (\(b))"
    }

    #if DEBUG
    @State private var debugTapCount = 0
    @State private var showDebug = false
    #endif

    var body: some View {
        NavigationStack {
            ZStack {
                NightSkyBackground()
                Form {

                    // ── Purchases ─────────────────────────────────────────────
                    Section {
                        Button("Restore Purchases") {
                            Task { await store.restorePurchases() }
                        }
                    }

                    // ── Data ──────────────────────────────────────────────────
                    Section(header: Text("Data")) {
                        if localData.isLoadingAllLogs {
                            HStack(spacing: 10) {
                                ProgressView()
                                Text("Loading player stats…")
                                    .font(.subheadline)
                                    .foregroundColor(.secondary)
                            }
                        } else {
                            Button("Load Recent Stats") {
                                Task { await LocalDataService.shared.fetchLogsForTodaysPlayers() }
                            }
                            Button("Backfill All Player Stats") {
                                Task { await LocalDataService.shared.backfillAllPlayerLogs(forceRefresh: true) }
                            }
                            Button("Backfill Aug 3 → Now") {
                                Task { await LocalDataService.shared.backfillHistoricalPlayerLogs(from: "2026-08-03") }
                            }
                        }

                        if !SportConfig.usesServerSync {
                            Divider()
                            HStack {
                                Text("Bundled data latest game")
                                Spacer()
                                Text(localData.bundledDataLatestGameDate.isEmpty ? "Unknown" : localData.bundledDataLatestGameDate)
                                    .foregroundColor(.secondary)
                            }
                            HStack {
                                Text("Bundled generated at")
                                Spacer()
                                Text(localData.bundledDataGeneratedAt.isEmpty ? "Unknown" : localData.bundledDataGeneratedAt)
                                    .foregroundColor(.secondary)
                            }
                            HStack {
                                Text("Bundled source")
                                Spacer()
                                Text(localData.bundledDataSourceSummary.isEmpty ? "Unknown" : localData.bundledDataSourceSummary)
                                    .foregroundColor(.secondary)
                            }
                        }
                    }

                    // ── Watchlist ──────────────────────────────────────────────
                    Section(header: Text("Watchlist Alerts")) {
                        HStack {
                            Text("Watched players")
                            Spacer()
                            Text("\(router.watchlistPlayerIDs.count)")
                                .foregroundColor(.secondary)
                        }

                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text("Alert threshold")
                                Spacer()
                                Text("\(Int(router.watchAlertThreshold * 100))%")
                                    .foregroundColor(.secondary)
                            }
                            Slider(
                                value: Binding(
                                    get: { router.watchAlertThreshold },
                                    set: { router.setWatchAlertThreshold($0) }
                                ),
                                in: 0.55...0.90,
                                step: 0.05
                            )
                            .tint(.skyBright)
                        }
                    }

                    // ── Model health (lightweight backtest) ───────────────────
                    Section(header: Text("Model Health")) {
                        if isComputingHealth {
                            HStack(spacing: 10) {
                                ProgressView()
                                Text("Computing backtest calibration…")
                                    .font(.subheadline)
                                    .foregroundColor(.secondary)
                            }
                        } else if modelHealthRows.isEmpty {
                            Text("No calibration data yet.")
                                .foregroundColor(.secondary)
                        } else {
                            ForEach(modelHealthRows) { row in
                                HStack {
                                    Text(row.bucket)
                                    Spacer()
                                    Text("Pred \(Int(row.predicted * 100))%")
                                        .foregroundColor(.secondary)
                                    Text("Act \(Int(row.actual * 100))%")
                                        .foregroundColor(.secondary)
                                    Text("n=\(row.count)")
                                        .foregroundColor(.secondary)
                                }
                                .font(.caption)
                            }
                            Text("Samples: \(healthSampleCount) · PTS one-step rolling backtest")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }

                        Button("Recompute Calibration") {
                            Task { await recomputeModelHealth() }
                        }
                    }

                    // ── About ─────────────────────────────────────────────────
                    Section(header: Text("About")) {
                        HStack {
                            Text(SportConfig.appDisplayName)
                            Spacer()
                            versionLabel
                        }
                    }
                }
                .scrollContentBackground(.hidden)
                .navigationTitle("Settings")
                .task {
                    if modelHealthRows.isEmpty {
                        await recomputeModelHealth()
                    }
                }
                #if DEBUG
                .sheet(isPresented: $showDebug) { DebugSettingsView() }
                #endif
            }
        }
    }

    // MARK: - Version label (tap 10× in DEBUG to open dev tools)

    @ViewBuilder
    private var versionLabel: some View {
        #if DEBUG
        Text("Version \(appVersion)")
            .foregroundColor(.secondary)
            .onTapGesture {
                debugTapCount += 1
                if debugTapCount >= 10 {
                    debugTapCount = 0
                    showDebug = true
                }
            }
        #else
        Text("Version \(appVersion)")
            .foregroundColor(.secondary)
        #endif
    }
}

private struct ModelHealthRow: Identifiable {
    let bucket: String
    let predicted: Double
    let actual: Double
    let count: Int
    var id: String { bucket }
}

extension SettingsView {
    @MainActor
    private func recomputeModelHealth() async {
        isComputingHealth = true
        defer { isComputingHealth = false }

        guard let snapshot = localData.snapshot else {
            modelHealthRows = []
            healthSampleCount = 0
            return
        }

        struct BucketAgg {
            var sumPred: Double = 0
            var sumActual: Double = 0
            var count: Int = 0
        }

        var buckets: [Int: BucketAgg] = [:]  // key = confidence * 20 (5% buckets)
        var total = 0

        let players = Array(snapshot.players.prefix(80))
        for player in players {
            let logs = localData.localLogs(playerID: player.playerID)
            guard logs.count >= 12 else { continue }

            let windows = min(8, logs.count - 10)
            guard windows > 0 else { continue }

            for idx in 0..<windows {
                let target = logs[idx]
                let upper = min(idx + 11, logs.count)
                let history = Array(logs[(idx + 1)..<upper])
                guard history.count >= 8 else { continue }

                let ctx = ProjectionContext(
                    opponent: target.opponent,
                    isHome: nil,
                    isPlayoffs: false,
                    isFirstRound: false,
                    gameDate: target.gameDate,
                    availabilityRisk: 0
                )
                let proj = PredictionEngine.shared.project(player: player, logs: history, context: ctx)
                let line = proj.line(for: "PTS")
                guard line > 0, let actualPts = target.pts else { continue }

                let pred = proj.confidence(for: "PTS")
                let actual = actualPts > line ? 1.0 : 0.0
                let key = Int((pred * 20).rounded())
                var agg = buckets[key] ?? BucketAgg()
                agg.sumPred += pred
                agg.sumActual += actual
                agg.count += 1
                buckets[key] = agg
                total += 1
            }
        }

        healthSampleCount = total
        modelHealthRows = buckets.keys.sorted().compactMap { key in
            guard let agg = buckets[key], agg.count >= 6 else { return nil }
            let lower = Double(key) / 20.0 - 0.025
            let upper = Double(key) / 20.0 + 0.025
            let bucket = "\(Int(max(0, lower) * 100))–\(Int(min(1, upper) * 100))%"
            return ModelHealthRow(
                bucket: bucket,
                predicted: agg.sumPred / Double(agg.count),
                actual: agg.sumActual / Double(agg.count),
                count: agg.count
            )
        }
    }
}

#Preview {
    SettingsView()
}

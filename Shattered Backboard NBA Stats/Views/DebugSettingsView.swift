//
//  DebugSettingsView.swift — Developer tools screen.
//
//  This entire file is compiled ONLY in DEBUG builds.
//  It is completely absent from release/App Store builds.
//
//  Access: tap the version number on the Settings tab 10 times.
//

#if DEBUG

import SwiftUI

struct DebugSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var localData = LocalDataService.shared
    @AppStorage("debugForcePlayoffMode") private var forcePlayoffMode: Bool = false

    var body: some View {
        NavigationStack {
            ZStack {
                NightSkyBackground()
                Form {

                    // ── Live data ─────────────────────────────────────────────
                    Section(
                        header: Text("Live Data").foregroundColor(.orange),
                        footer: Text("DEBUG ONLY — compiled out of release builds")
                            .foregroundColor(.orange)
                    ) {
                        if localData.isFetching || localData.isLoadingAllLogs {
                            HStack {
                                ProgressView()
                                Text(localData.isLoadingAllLogs ? "Loading stats…" : "Fetching…").padding(.leading, 8)
                            }
                        } else {
                            Button("Refresh All Data") {
                                Task { try? await LocalDataService.shared.fetchAll() }
                            }
                            Button("Load Recent Stats") {
                                Task { await LocalDataService.shared.fetchLogsForTodaysPlayers() }
                            }
                            Button("Backfill ALL Player Stats") {
                                Task { await LocalDataService.shared.backfillAllPlayerLogs(forceRefresh: true) }
                            }
                            Button("Refresh + Load Stats") {
                                Task { try? await LocalDataService.shared.fetchAll(fetchLogs: true) }
                            }
                            Button("Clear All Schedule Data", role: .destructive) {
                                Task { await LocalDataService.shared.clearAllGames() }
                            }
                            Button("☠️ Nuclear Reset (wipe everything)", role: .destructive) {
                                Task { await LocalDataService.shared.nuclearReset() }
                            }
                        }
                        if let snap = localData.snapshot {
                            infoRow("Games",    value: "\(snap.games.count)")
                            infoRow("Players",  value: "\(snap.players.count)")
                            infoRow("Lineups",  value: "\(snap.lineups.count)")
                            infoRow("Props",    value: "\(snap.allProps.count)")
                            let withSignal = snap.allProps.filter { $0.overPct != nil || $0.projectedValue != nil }.count
                            infoRow("w/ Signal", value: "\(withSignal) / \(snap.allProps.count)")
                            if let d = localData.lastFetchDate {
                                Text("Fetched: \(d.formatted(date: .abbreviated, time: .shortened))")
                                    .font(.caption).foregroundColor(.secondary)
                            }
                            infoRow("Source", value: localData.isUsingCache ? "Cache" : "Live")
                        }
                        if let err = localData.lastError {
                            Text(err).foregroundColor(.red).font(.caption)
                        }
                    }

                    // ── Server URL ────────────────────────────────────────────
                    Section(
                        header: Text("API Server").foregroundColor(.orange),
                        footer: Text("Reads from SportConfig.baseURL by default.")
                    ) {
                        infoRow("Base URL", value: localData.serverURL)
                    }

                    // ── Projection Engine ─────────────────────────────────────
                    Section(
                        header: Text("Projection Engine").foregroundColor(.orange),
                        footer: Text("Forces every game to use playoff multipliers (−17% to −23%). Persists across launches.")
                            .foregroundColor(.secondary)
                    ) {
                        Toggle(isOn: $forcePlayoffMode) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Force Playoff Mode")
                                Text(forcePlayoffMode ? "Active — all projections use −17% to −23%" : "Off — games use auto-detected mode")
                                    .font(.caption)
                                    .foregroundColor(forcePlayoffMode ? .orange : .secondary)
                            }
                        }
                        .tint(.orange)
                    }
                }
                .scrollContentBackground(.hidden)
                .navigationTitle("Developer Tools")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button("Done") { dismiss() }
                            .foregroundColor(.skyBright)
                    }
                }
            }
        }
    }

    private func infoRow(_ label: String, value: String) -> some View {
        HStack {
            Text(label)
            Spacer()
            Text(value).foregroundColor(.secondary).font(.caption)
        }
    }
}

#Preview {
    DebugSettingsView()
}

#endif

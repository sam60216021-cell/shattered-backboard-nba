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

#Preview {
    SettingsView()
}

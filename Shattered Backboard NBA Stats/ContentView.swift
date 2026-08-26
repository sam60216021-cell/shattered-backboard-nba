//
//  ContentView.swift — Root tab container.
//
//  Tabs:
//    0  Schedule  — today's NBA games; tap a game → Game Picks
//    1  Picks     — personal parlay builder
//    2  Settings  — app settings
//

import SwiftUI

struct ContentView: View {

    @ObservedObject private var router = AppRouter.shared
    @Environment(\.scenePhase) private var scenePhase

    init() {
        // Tab bar appearance
        let tab = UITabBarAppearance()
        tab.configureWithOpaqueBackground()
        tab.backgroundColor = UIColor(red: 0.04, green: 0.06, blue: 0.18, alpha: 0.96)
        tab.stackedLayoutAppearance.normal.iconColor            = UIColor.lightGray
        tab.stackedLayoutAppearance.normal.titleTextAttributes  = [.foregroundColor: UIColor.lightGray]
        tab.stackedLayoutAppearance.selected.iconColor           = UIColor.white
        tab.stackedLayoutAppearance.selected.titleTextAttributes = [.foregroundColor: UIColor.white]
        UITabBar.appearance().standardAppearance   = tab
        UITabBar.appearance().scrollEdgeAppearance = tab

        // Navigation bar appearance
        let nav = UINavigationBarAppearance()
        nav.configureWithOpaqueBackground()
        nav.backgroundColor          = UIColor(red: 0.04, green: 0.06, blue: 0.18, alpha: 0.96)
        nav.titleTextAttributes      = [.foregroundColor: UIColor.white]
        nav.largeTitleTextAttributes = [.foregroundColor: UIColor.white]
        UINavigationBar.appearance().standardAppearance   = nav
        UINavigationBar.appearance().compactAppearance    = nav
        UINavigationBar.appearance().scrollEdgeAppearance = nav
        UINavigationBar.appearance().tintColor            = UIColor(Color.skyBright)
    }

    var body: some View {
        TabView(selection: $router.selectedTab) {

            HomeView()
                .tabItem { Label("Schedule", systemImage: "calendar") }
                .tag(0)

            QuickPicksView()
                .tabItem {
                    Label("Picks", systemImage: router.parlayPicks.isEmpty
                          ? "star"
                          : "star.fill")
                }
                .tag(1)

            PlayerSearchView()
                .tabItem { Label("Players", systemImage: "magnifyingglass") }
                .tag(2)

            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape.fill") }
                .tag(3)
        }
        .tint(.skyBright)
        // Retry schedule fetch whenever the app returns to the foreground
        // and no games are loaded (e.g. after granting local network permission).
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            let hasGames = !(LocalDataService.shared.snapshot?.games.isEmpty ?? true)
            guard !hasGames, !LocalDataService.shared.isFetching else { return }
            Task { _ = try? await LocalDataService.shared.fetchAll() }
        }
        .task {
            // One-time schema migration: wipe all local data to pick up
            // the new playoff roster.  Remove this block after 2026-05-01.
            let migrationKey = "schemaReset_2026_playoffs_v1"
            if !UserDefaults.standard.bool(forKey: migrationKey) {
                UserDefaults.standard.set(true, forKey: migrationKey)
                await LocalDataService.shared.nuclearReset()
                return
            }

            // Always attempt a fresh sync on launch.
            // • If online: persistToDatabase() atomically replaces today's data.
            // • If offline: fetchAll() throws but the snapshot loaded by
            //   loadFromDatabase() (which now falls back to the most recent cached
            //   date) remains visible, so the app works without a connection.
            _ = try? await LocalDataService.shared.fetchAll()
        }
    }
}

#Preview {
    ContentView()
}


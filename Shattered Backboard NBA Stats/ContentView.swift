//
//  ContentView.swift — Root tab container.
//
//  Tabs:
//    0  Schedule   — today's NBA games; tap a game → Game Picks
//    1  Picks      — personal parlay builder
//    2  Search     — global player search
//    3  Plays      — best picks of the day
//    4  Parlay     — similar-stat parlay builder
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
                .tabItem { Label("Search", systemImage: "magnifyingglass") }
                .tag(2)

            TopPicksView()
                .tabItem { Label("Plays", systemImage: "trophy.fill") }
                .tag(3)

            SimilarParlayView()
                .tabItem { Label("Parlay", systemImage: "person.2.wave.2.fill") }
                .tag(4)
        }
        .tint(.skyBright)
        // Retry schedule fetch whenever the app returns to the foreground
        // and no games are loaded (e.g. after granting local network permission).
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            guard !LocalDataService.shared.isFetching else { return }
            Task {
                _ = try? await LocalDataService.shared.fetchAll(fetchLogs: true)
                AppRouter.shared.pruneCompletedPicks()
            }
        }
        .task {
            // On launch: sync the schedule and fetch logs for today's players only.
            // Full historical backfill is available manually in Settings.
            _ = try? await LocalDataService.shared.fetchAll(fetchLogs: true)
            AppRouter.shared.pruneCompletedPicks()
        }
    }
}

#Preview {
    ContentView()
}


//
//  HomeView.swift — Schedule tab: today's NBA games.
//
//  Each game row is tappable and navigates to GamePicksView for that matchup.
//

import SwiftUI

struct HomeView: View {

    @ObservedObject private var dataService = LocalDataService.shared
    @State private var isRefreshing = false
    @State private var isClearing   = false
    #if DEBUG
    @State private var showDebug    = false
    #endif

    // MARK: - Body

    var body: some View {
        NavigationStack {
            ZStack {
                NightSkyBackground()
                content
            }
            .navigationBarTitleDisplayMode(.large)
            .toolbar { refreshButton }
            .navigationDestination(for: ScheduleGame.self) { game in
                GamePicksView(game: game)
            }
            #if DEBUG
            .sheet(isPresented: $showDebug) {
                ScheduleDebugView()
            }
            #endif
        }
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        let games = dataService.snapshot?.games ?? []
        let isPlayoff = dataService.gameDetails.values.first?.gameType == "playoff"

        if dataService.isFetching && games.isEmpty {
            loadingView
        } else if games.isEmpty {
            emptyView
        } else {
            gameList(games: games, isPlayoff: isPlayoff)
        }
    }

    private func gameList(games: [ScheduleGame], isPlayoff: Bool) -> some View {
        ScrollView {
            LazyVStack(spacing: 14) {
                if dataService.isUsingCache {
                    cachedBanner
                }
                ForEach(games) { game in
                    NavigationLink(value: game) {
                        GameRowView(game: game)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .refreshable { await refresh() }
        .navigationTitle(isPlayoff ? "2026 NBA Playoffs" : "Today's Games")
    }

    private var loadingView: some View {
        VStack(spacing: 16) {
            ProgressView()
                .tint(.skyBright)
                .scaleEffect(1.4)
            Text("Loading games…")
                .foregroundColor(.white.opacity(0.6))
                .font(.subheadline)
        }
    }

    private var emptyView: some View {
        VStack(spacing: 20) {
            Image(systemName: "calendar.badge.exclamationmark")
                .font(.system(size: 52))
                .foregroundColor(.skyBright.opacity(0.7))
            Text("No games today")
                .font(.title2.bold())
                .foregroundColor(.white)
            Text("Pull down to refresh or check your server connection.")
                .font(.subheadline)
                .foregroundColor(.white.opacity(0.5))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
            if let err = dataService.lastError {
                Text(err)
                    .font(.caption)
                    .foregroundColor(.orange.opacity(0.8))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }
            Button("Refresh") { Task { await refresh() } }
                .buttonStyle(BrightButtonStyle())
            #if DEBUG
            Button("Debug Schedule") { showDebug = true }
                .font(.caption)
                .foregroundColor(.skyBright.opacity(0.7))
            #endif
        }
    }

    private var cachedBanner: some View {
        let gameDate = dataService.snapshot?.games.first?.date
        let today: String = {
            let f = DateFormatter()
            f.dateFormat = "yyyy-MM-dd"
            f.timeZone   = TimeZone(identifier: "America/New_York")
            return f.string(from: Date())
        }()
        let isStale = gameDate != nil && gameDate != today
        let label   = isStale
            ? "Offline — showing last cached data (\(gameDate!))"
            : "Showing cached data"
        return HStack(spacing: 6) {
            Image(systemName: isStale ? "wifi.slash" : "clock.arrow.circlepath")
            Text(label)
            Spacer()
            Text("Pull to refresh")
        }
        .font(.caption)
        .foregroundColor(.orange.opacity(0.85))
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
    }

    @ToolbarContentBuilder
    private var refreshButton: some ToolbarContent {
        ToolbarItem(placement: .navigationBarTrailing) {
            if dataService.isFetching || isClearing {
                ProgressView().tint(.skyBright)
            } else {
                Menu {
                    Button { Task { await refresh() } } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                    #if DEBUG
                    Button { showDebug = true } label: {
                        Label("Debug Panel", systemImage: "ant.circle")
                    }
                    #endif
                    Button(role: .destructive) {
                        Task {
                            isClearing = true
                            await LocalDataService.shared.clearScheduleCache()
                            isClearing = false
                        }
                    } label: {
                        Label("Clear Cache & Reload", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .foregroundColor(.skyBright)
                }
            }
        }
    }

    // MARK: - Actions

    private func refresh() async {
        isRefreshing = true
        _ = try? await LocalDataService.shared.fetchAll()
        isRefreshing = false
    }
}

// MARK: - ScheduleDebugView (DEBUG only)

#if DEBUG
struct ScheduleDebugView: View {
    @ObservedObject private var ds = LocalDataService.shared
    @State private var selectedTab = 0
    @State private var rawResponse = ""
    @State private var isTesting   = false

    private var etDate: String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss zzz"
        f.timeZone   = TimeZone(identifier: "America/New_York")
        return f.string(from: Date())
    }

    private var lastFetchDateStored: String {
        UserDefaults.standard.string(forKey: "lastFetchDate") ?? "(never)"
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("Tab", selection: $selectedTab) {
                    Text("Status").tag(0)
                    Text("Logs").tag(1)
                    Text("Raw JSON").tag(2)
                }
                .pickerStyle(.segmented)
                .padding()

                if selectedTab == 0 { statusTab }
                else if selectedTab == 1 { logsTab }
                else { rawJSONTab }
            }
            .navigationTitle("Schedule Debug")
            .navigationBarTitleDisplayMode(.inline)
            .background(Color(uiColor: .systemBackground))
        }
    }

    // MARK: Status tab

    private var statusTab: some View {
        List {
            Section("Network") {
                row("Server URL", ds.serverURL)
                row("Fetching", ds.isFetching ? "YES" : "no")
                row("Using cache", ds.isUsingCache ? "YES" : "no")
                if let err = ds.lastError { row("Last error", err).foregroundColor(.red) }
            }
            Section("Dates") {
                row("Device ET now", etDate)
                row("lastFetchDate (UserDefaults)", lastFetchDateStored)
                if let d = ds.lastFetchDate {
                    row("lastFetchDate (in-memory)", d.formatted(date: .abbreviated, time: .shortened))
                }
            }
            Section("Snapshot") {
                row("Games", "\(ds.snapshot?.games.count ?? 0)")
                row("Players", "\(ds.snapshot?.players.count ?? 0)")
                row("Lineups", "\(ds.snapshot?.lineups.count ?? 0)")
                if let snap = ds.snapshot {
                    row("Fetched at", snap.fetchedAt.formatted(date: .abbreviated, time: .shortened))
                    if !snap.games.isEmpty {
                        ForEach(snap.games) { g in
                            row(g.awayTeam + " @ " + g.homeTeam,
                                "\(g.gameTime ?? "TBD")  id=\(g.gameID ?? "?")")
                        }
                    }
                }
            }
            Section("Actions") {
                Button("Refresh fetchAll()") {
                    Task { _ = try? await LocalDataService.shared.fetchAll() }
                }
                Button("Clear Cache & Reload") {
                    Task { await LocalDataService.shared.clearScheduleCache() }
                }
                Button("Nuclear Reset") {
                    Task { await LocalDataService.shared.nuclearReset() }
                }
                .foregroundColor(.red)
                Button(isTesting ? "Testing…" : "Ping /nba/schedule (raw)") {
                    Task {
                        isTesting = true
                        rawResponse = await LocalDataService.shared.testScheduleRaw()
                        isTesting = false
                        selectedTab = 2
                    }
                }
                .disabled(isTesting)
            }
        }
    }

    // MARK: Logs tab

    private var logsTab: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(ds.debugLogs.enumerated()), id: \.offset) { i, line in
                        Text(line)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(line.contains("ERROR") || line.contains("FAIL") ? .red :
                                             line.contains("WARN") ? .orange : .primary)
                            .textSelection(.enabled)
                            .id(i)
                    }
                }
                .padding(12)
            }
            .onChange(of: ds.debugLogs.count) { _, _ in
                if let last = ds.debugLogs.indices.last {
                    proxy.scrollTo(last, anchor: .bottom)
                }
            }
        }
        .overlay {
            if ds.debugLogs.isEmpty {
                Text("No logs yet — tap Refresh")
                    .foregroundColor(.secondary)
            }
        }
    }

    // MARK: Raw JSON tab

    private var rawJSONTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if !rawResponse.isEmpty {
                    Text("PING RESULT")
                        .font(.caption.bold())
                        .foregroundColor(.orange)
                    Text(rawResponse)
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                }
                if !ds.lastScheduleRawJSON.isEmpty {
                    Divider()
                    Text("LAST /nba/schedule RESPONSE")
                        .font(.caption.bold())
                        .foregroundColor(.orange)
                    Text(ds.lastScheduleRawJSON)
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                }
                if rawResponse.isEmpty && ds.lastScheduleRawJSON.isEmpty {
                    Text("No raw data yet.\nUse \"Ping /nba/schedule\" in the Status tab.")
                        .foregroundColor(.secondary)
                        .padding()
                }
            }
            .padding(12)
        }
    }

    @ViewBuilder
    private func row(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top) {
            Text(label)
                .foregroundColor(.secondary)
                .frame(width: 160, alignment: .leading)
            Text(value)
                .font(.system(size: 13, design: .monospaced))
                .textSelection(.enabled)
            Spacer()
        }
        .font(.caption)
    }
}
#endif

// MARK: - GameRowView

struct GameRowView: View {
    let game: ScheduleGame
    @ObservedObject private var router      = AppRouter.shared
    @ObservedObject private var dataService = LocalDataService.shared

    private var details: GameDetails?         { dataService.gameDetails[game.gameID ?? ""] }
    private var homeStanding: StandingsEntry? { dataService.standingsMap[game.homeTeam] }
    private var awayStanding: StandingsEntry? { dataService.standingsMap[game.awayTeam] }

    // MARK: - TeamProjection

    private var projection: TeamProjection? {
        guard let h = homeStanding, let a = awayStanding else { return nil }
        return TeamProjection(away: a, home: h)
    }

    // MARK: - Series label

    private func seriesRecordLabel(_ d: GameDetails) -> String {
        let h = d.homeWins, a = d.awayWins
        if h == 0 && a == 0 { return "Series begins" }
        if h > a { return "\(game.homeTeam) leads series \(h)-\(a)" }
        if a > h { return "\(game.awayTeam) leads series \(a)-\(h)" }
        return "Series tied \(h)-\(h)"
    }

    // MARK: - Analytics blurb

    private func analyticsBlurb(_ d: GameDetails) -> String {
        guard d.gameType == "playoff" else { return "" }
        let away = game.awayTeam, home = game.homeTeam
        var sentences: [String] = []

        if let h = homeStanding, let a = awayStanding {
            // Net rating comparison
            let hNR  = h.netRating
            let aNR  = a.netRating
            let diff = hNR - aNR
            let fmt: (Double) -> String = { r in
                let s = String(format: "%.1f", abs(r))
                return r >= 0 ? "+\(s)" : "-\(s)"
            }
            if abs(diff) >= 6 {
                let better = diff > 0 ? home : away
                let worse  = diff > 0 ? away : home
                let bNR    = diff > 0 ? hNR : aNR
                let wNR    = diff > 0 ? aNR : hNR
                sentences.append("\(better) (\(fmt(bNR)) net) has a \(String(format: "%.1f", abs(diff)))-pt efficiency edge on \(worse) (\(fmt(wNR))) — a gap that typically decides series.")
            } else if abs(diff) >= 2.5 {
                let better = diff > 0 ? home : away
                let worse  = diff > 0 ? away : home
                let bNR    = diff > 0 ? hNR : aNR
                let wNR    = diff > 0 ? aNR : hNR
                sentences.append("\(better) (\(fmt(bNR)) net) edges \(worse) (\(fmt(wNR))) in efficiency — slight but real advantage in a series that could go either way.")
            } else {
                sentences.append("Net ratings nearly identical: \(home) \(fmt(hNR)) vs \(away) \(fmt(aNR)) — either team can steal this on the night.")
            }

            // Recent form
            let aStr = a.streak
            let hStr = h.streak
            let aNum = Int(String(aStr.dropFirst())) ?? 1
            let hNum = Int(String(hStr.dropFirst())) ?? 1
            let aWin = aStr.hasPrefix("W")
            let hWin = hStr.hasPrefix("W")

            if aWin && aNum >= 4 && !hWin {
                sentences.append("\(away) is rolling (\(aStr.lowercased())) with genuine road momentum; \(home) (\(hStr.lowercased())) needs to disrupt that rhythm early.")
            } else if hWin && hNum >= 4 && !aWin {
                sentences.append("\(home) (\(hStr.lowercased())) is locked in and the crowd amplifies every stop; \(away) (\(aStr.lowercased())) must silence this building.")
            } else if aWin && hWin {
                sentences.append("Both squads arrive in form — \(away) (\(aStr.lowercased())) and \(home) (\(hStr.lowercased())) — expect a fast, physical start.")
            } else if !aWin && !hWin && aNum >= 3 && hNum >= 3 {
                sentences.append("\(away) (\(aStr.lowercased())) and \(home) (\(hStr.lowercased())) both in rough form — pressure peaks for whoever blinks first.")
            } else {
                sentences.append("\(home) went \(h.homeRecord) at home this season; \(away) posted \(a.roadRecord) on the road.")
            }
        }

        // Key injuries
        let awayOut = game.missingAwayPlayers.filter { $0.status == "OUT" }
        let homeOut = game.missingHomePlayers.filter { $0.status == "OUT" }
        var injParts: [String] = []
        if !awayOut.isEmpty {
            let names = awayOut.prefix(2).compactMap(\.name).joined(separator: " & ")
            injParts.append("\(away): \(names) out")
        }
        if !homeOut.isEmpty {
            let names = homeOut.prefix(2).compactMap(\.name).joined(separator: " & ")
            injParts.append("\(home): \(names) out")
        }
        if !injParts.isEmpty {
            sentences.append("Injuries to watch — \(injParts.joined(separator: "; ")).")
        }

        return sentences.joined(separator: " ")
    }

    // MARK: - Betting cell helper

    @ViewBuilder
    private func bettingCell(awayVal: String, label: String, homeVal: String,
                             awayBold: Bool, homeBold: Bool) -> some View {
        VStack(spacing: 4) {
            Text(awayVal)
                .font(.system(size: 15, weight: awayBold ? .bold : .regular, design: .rounded))
                .foregroundColor(awayBold ? .white : .white.opacity(0.5))
            Text(label)
                .font(.system(size: 8, weight: .semibold))
                .foregroundColor(.white.opacity(0.28))
                .tracking(0.8)
            Text(homeVal)
                .font(.system(size: 15, weight: homeBold ? .bold : .regular, design: .rounded))
                .foregroundColor(homeBold ? .white : .white.opacity(0.5))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
    }

    // MARK: - Body

    var body: some View {
        if let d = details, d.gameType == "playoff" {
            playoffCard(details: d)
        } else {
            compactCard
        }
    }

    // MARK: - Playoff card

    @ViewBuilder
    private func playoffCard(details d: GameDetails) -> some View {
        VStack(spacing: 0) {

            // ── Series header ───────────────────────────────────────────────
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(d.gameLabel.isEmpty ? "NBA Playoffs" : d.gameLabel)
                        .font(.caption2.bold())
                        .foregroundColor(.skyBright.opacity(0.9))
                    Text(d.seriesGameNumber)
                        .font(.caption2)
                        .foregroundColor(.white.opacity(0.4))
                }
                Spacer()
                let label = seriesRecordLabel(d)
                let neutral = label.contains("begins") || label.contains("tied")
                Text(label)
                    .font(.caption2.bold())
                    .foregroundColor(neutral ? .white.opacity(0.5) : .skyBright)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(neutral ? Color.white.opacity(0.07) : Color.skyBright.opacity(0.12),
                                in: Capsule())
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .padding(.bottom, 14)

            Divider().background(Color.skyBorder)

            // ── Teams row ───────────────────────────────────────────────────
            let isFinal      = d.statusCode == 3
            let isLive       = d.statusCode == 2 && (d.period > 0 || d.awayScore > 0 || d.homeScore > 0)
            let isStarted    = isFinal || isLive
            let seriesPlayed = d.awayWins + d.homeWins > 0
            HStack(alignment: .top, spacing: 0) {

                // Away team column
                VStack(alignment: .center, spacing: 5) {
                    Text(game.awayTeam)
                        .font(.system(size: 30, weight: .black))
                        .foregroundColor(.white)
                    if let a = awayStanding {
                        Text("\(a.wins)–\(a.losses)")
                            .font(.caption2)
                            .foregroundColor(.white.opacity(0.45))
                        Text(a.streak)
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundColor(.white.opacity(0.3))
                    }
                    Spacer(minLength: 8)
                    if isStarted {
                        Text("\(d.awayScore)")
                            .font(.system(size: 36, weight: .black, design: .rounded))
                            .foregroundColor(d.awayScore > d.homeScore ? .skyBright : .white.opacity(0.55))
                    } else if seriesPlayed {
                        VStack(spacing: 2) {
                            Text("\(d.awayWins)")
                                .font(.system(size: 30, weight: .black, design: .rounded))
                                .foregroundColor(d.awayWins >= d.homeWins ? .skyBright : .white.opacity(0.35))
                            Text("series wins")
                                .font(.system(size: 8, weight: .semibold))
                                .foregroundColor(.white.opacity(0.3))
                                .tracking(0.5)
                        }
                    }
                }
                .frame(maxWidth: .infinity)

                // Center: status / tip time
                VStack(spacing: 5) {
                    if isStarted {
                        Text(isFinal ? "FINAL" : d.period > 0 ? "Q\(d.period)" : "LIVE")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(isFinal ? .white.opacity(0.45) : Color.green.opacity(0.85))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(
                                isFinal ? Color.white.opacity(0.07) : Color.green.opacity(0.13),
                                in: Capsule()
                            )
                    } else {
                        Text("@")
                            .font(.caption.bold())
                            .foregroundColor(.white.opacity(0.3))
                        let timeStr = game.gameTime?.lowercased() ?? ""
                        if !timeStr.isEmpty {
                            Text(timeStr)
                                .font(.caption2)
                                .foregroundColor(.white.opacity(0.4))
                        }
                    }
                }
                .frame(width: 64)
                .padding(.top, 6)

                // Home team column
                VStack(alignment: .center, spacing: 5) {
                    Text(game.homeTeam)
                        .font(.system(size: 30, weight: .black))
                        .foregroundColor(.white)
                    if let h = homeStanding {
                        Text("\(h.wins)–\(h.losses)")
                            .font(.caption2)
                            .foregroundColor(.white.opacity(0.45))
                        Text(h.streak)
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundColor(.white.opacity(0.3))
                    }
                    Spacer(minLength: 8)
                    if isStarted {
                        Text("\(d.homeScore)")
                            .font(.system(size: 36, weight: .black, design: .rounded))
                            .foregroundColor(d.homeScore > d.awayScore ? .skyBright : .white.opacity(0.55))
                    } else if seriesPlayed {
                        VStack(spacing: 2) {
                            Text("\(d.homeWins)")
                                .font(.system(size: 30, weight: .black, design: .rounded))
                                .foregroundColor(d.homeWins >= d.awayWins ? .skyBright : .white.opacity(0.35))
                            Text("series wins")
                                .font(.system(size: 8, weight: .semibold))
                                .foregroundColor(.white.opacity(0.3))
                                .tracking(0.5)
                        }
                    }
                }
                .frame(maxWidth: .infinity)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 18)

            Divider().background(Color.skyBorder)

            // ── Betting lines strip ─────────────────────────────────────────
            let proj = projection
            HStack(spacing: 0) {
                bettingCell(awayVal: proj?.awayMLStr     ?? "—", label: "MONEYLINE",
                            homeVal: proj?.homeMLStr     ?? "—",
                            awayBold: proj?.awayFavored  ?? false,
                            homeBold: proj?.homeFavored  ?? false)
                Rectangle().fill(Color.skyBorder).frame(width: 1)
                bettingCell(awayVal: proj?.awaySpreadStr ?? "—", label: "SPREAD",
                            homeVal: proj?.homeSpreadStr ?? "—",
                            awayBold: proj?.awayFavored  ?? false,
                            homeBold: proj?.homeFavored  ?? false)
                Rectangle().fill(Color.skyBorder).frame(width: 1)
                bettingCell(awayVal: proj?.awayPtsDisplay ?? "—", label: "PROJ FINAL",
                            homeVal: proj?.homePtsDisplay ?? "—",
                            awayBold: (proj?.awayPts ?? 0) > (proj?.homePts ?? 0),
                            homeBold: (proj?.homePts ?? 0) > (proj?.awayPts ?? 0))
            }

            // ── Analytics blurb ─────────────────────────────────────────────
            let blurb = analyticsBlurb(d)
            if !blurb.isEmpty {
                Divider().background(Color.skyBorder)
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "chart.line.uptrend.xyaxis")
                        .font(.caption2)
                        .foregroundColor(.skyBright.opacity(0.55))
                        .padding(.top, 1)
                    Text(blurb)
                        .font(.caption)
                        .foregroundColor(.white.opacity(0.55))
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.vertical, 13)
            }

            Divider().background(Color.skyBorder)

            // ── Footer ──────────────────────────────────────────────────────
            HStack(spacing: 8) {
                let propCount = game.playerProps.count
                let highConf  = game.playerProps.contains(where: { ($0.overPct ?? 0) >= 0.70 })
                if propCount > 0 {
                    Image(systemName: highConf ? "bolt.fill" : "list.bullet")
                        .font(.caption)
                        .foregroundColor(highConf ? .yellow : .skyBright.opacity(0.7))
                    Text("\(propCount) prop\(propCount == 1 ? "" : "s")")
                        .font(.caption)
                        .foregroundColor(.white.opacity(0.55))
                } else {
                    Text("Game picks")
                        .font(.caption)
                        .foregroundColor(.white.opacity(0.35))
                }
                let injuries = (game.missingAwayPlayers + game.missingHomePlayers)
                    .filter { $0.status == "OUT" }
                if !injuries.isEmpty {
                    Text("·").foregroundColor(.white.opacity(0.25))
                    Image(systemName: "bandage.fill")
                        .font(.caption2).foregroundColor(.red.opacity(0.6))
                    Text("\(injuries.count) out")
                        .font(.caption2).foregroundColor(.red.opacity(0.6))
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption.bold())
                    .foregroundColor(.skyBright.opacity(0.6))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 11)
        }
        .background(Color.skyCard, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.skyBorder, lineWidth: 1))
    }

    // MARK: - Compact card (non-playoff / loading fallback)

    private var compactCard: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center) {
                VStack(spacing: 2) {
                    Text(game.awayTeam)
                        .font(.title3.bold()).foregroundColor(.white)
                }
                .frame(maxWidth: .infinity)
                VStack(spacing: 2) {
                    Text("@")
                        .font(.caption.bold()).foregroundColor(.white.opacity(0.4))
                    Text(game.gameTime?.lowercased() ?? "TBD")
                        .font(.caption2).foregroundColor(.white.opacity(0.5))
                }
                .frame(width: 60)
                VStack(spacing: 2) {
                    Text(game.homeTeam)
                        .font(.title3.bold()).foregroundColor(.white)
                }
                .frame(maxWidth: .infinity)
            }
            .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 10)

            Divider().background(Color.skyBorder)

            HStack(spacing: 8) {
                let propCount = game.playerProps.count
                let highConf  = game.playerProps.contains(where: { ($0.overPct ?? 0) >= 0.70 })
                if propCount > 0 {
                    Image(systemName: highConf ? "bolt.fill" : "list.bullet")
                        .font(.caption)
                        .foregroundColor(highConf ? .yellow : .skyBright.opacity(0.7))
                    Text("\(propCount) prop\(propCount == 1 ? "" : "s") available")
                        .font(.caption).foregroundColor(.white.opacity(0.55))
                } else {
                    Text("No props yet")
                        .font(.caption).foregroundColor(.white.opacity(0.3))
                }
                Spacer()
                let injuries = (game.missingAwayPlayers + game.missingHomePlayers)
                    .filter { $0.status == "OUT" }
                if !injuries.isEmpty {
                    HStack(spacing: 3) {
                        Image(systemName: "bandage.fill")
                            .font(.caption2).foregroundColor(.red.opacity(0.7))
                        Text("\(injuries.count) out")
                            .font(.caption2).foregroundColor(.red.opacity(0.7))
                    }
                }
                Image(systemName: "chevron.right")
                    .font(.caption.bold()).foregroundColor(.skyBright.opacity(0.6))
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
        }
        .background(Color.skyCard, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.skyBorder, lineWidth: 1))
    }
}

// MARK: - Shared button style

struct BrightButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.bold())
            .foregroundColor(.skyDeep)
            .padding(.horizontal, 28)
            .padding(.vertical, 10)
            .background(Color.skyBright, in: Capsule())
            .opacity(configuration.isPressed ? 0.75 : 1)
    }
}

#Preview {
    HomeView()
}

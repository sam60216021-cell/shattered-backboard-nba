//
//  HomeView.swift — Schedule tab: today's NBA games.
//
//  Each game row is tappable and navigates to GamePicksView for that matchup.
//

import SwiftUI
import Combine

struct HomeView: View {

    @ObservedObject private var dataService = LocalDataService.shared
    @ObservedObject private var scheduleStore = ScheduleStore.shared
    @State private var isClearing   = false
    @State private var showSettings = false
    private let autoRefreshTimer = Timer.publish(every: 90, on: .main, in: .common).autoconnect()
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
            .sheet(isPresented: $showSettings) {
                SettingsView()
            }
            .navigationDestination(for: ScheduleGame.self) { game in
                GamePicksView(game: game)
            }
            #if DEBUG
            .sheet(isPresented: $showDebug) {
                ScheduleDebugView()
            }
            #endif
        }
        .task {
            scheduleStore.computeIfNeeded(games: dataService.snapshot?.games ?? [])
        }
        .onChange(of: dataService.snapshot?.games.count) { _, _ in
            scheduleStore.computeIfNeeded(games: dataService.snapshot?.games ?? [])
        }
        .onReceive(dataService.$standingsMap) { _ in
            scheduleStore.computeIfNeeded(games: dataService.snapshot?.games ?? [])
        }
        .onReceive(autoRefreshTimer) { _ in
            guard !dataService.isFetching, !isClearing else { return }
            Task { await refresh() }
        }
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        let games = activeSlateGames(dataService.snapshot?.games ?? [])
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
        .navigationTitle(isPlayoff ? "\(SportConfig.currentSeason) NBA Playoffs" : scheduleTitle(for: games))
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
            Text("No games on this slate")
                .font(.title2.bold())
                .foregroundColor(.white)
            Text(SportConfig.usesServerSync
                 ? "Pull down to refresh or check your server connection."
                 : "This build uses bundled data. Install a newer app build to get newer stats.")
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

    private func scheduleTitle(for games: [ScheduleGame]) -> String {
        guard let date = games.first?.date else { return "NBA Schedule" }
        let today = isoDateString(Date())
        let tomorrow = isoDateString(Calendar.current.date(byAdding: .day, value: 1, to: Date()) ?? Date())
        if date == today { return "Today's Games" }
        if date == tomorrow { return "Tomorrow's Games" }
        return "NBA Schedule"
    }

    /// Hard guard against stray/stale StoredGame rows (bad imports, dedupe edge
    /// cases, sync glitches) mixing another date's games into today's slate —
    /// collapse to a single date: today if present, else the nearest upcoming one.
    private func activeSlateGames(_ games: [ScheduleGame]) -> [ScheduleGame] {
        guard !games.isEmpty else { return [] }
        let today = isoDateString(Date())
        let byDate = Dictionary(grouping: games, by: \.date)
        let slateDate = byDate[today] != nil ? today : byDate.keys.filter { $0 >= today }.sorted().first
        guard let slateDate else { return [] }
        return games.filter { $0.date == slateDate }
    }

    private func isoDateString(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = TimeZone(identifier: SportConfig.appTimeZoneID)
        return f.string(from: date)
    }

    private var cachedBanner: some View {
        HStack(spacing: 6) {
            Image(systemName: "clock.arrow.circlepath")
            Text("Showing cached data")
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
        AnalyticsCenterToolbarItem()

        ToolbarItem(placement: .navigationBarTrailing) {
            Button {
                showSettings = true
            } label: {
                Image(systemName: "gearshape.fill")
                    .foregroundColor(.skyBright)
            }
            .accessibilityLabel("Settings")
        }

        ToolbarItem(placement: .navigationBarTrailing) {
            Menu {
                Button { Task { await refresh() } } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .disabled(dataService.isFetching || isClearing)
                #if DEBUG
                Button { showDebug = true } label: {
                    Label("Debug Panel", systemImage: "ant.circle")
                }
                .disabled(dataService.isFetching || isClearing)
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
                .disabled(dataService.isFetching || isClearing)
            } label: {
                ZStack {
                    Image(systemName: "ellipsis.circle")
                        .opacity(dataService.isFetching || isClearing ? 0 : 1)
                    if dataService.isFetching || isClearing {
                        ProgressView()
                    }
                }
                .foregroundColor(.skyBright)
            }
            .disabled(dataService.isFetching || isClearing)
        }
    }

    // MARK: - Actions

    private func refresh() async {
        _ = try? await LocalDataService.shared.fetchAll(fetchLogs: true)
    }
}

// MARK: - ScheduleDebugView (DEBUG only)

#if DEBUG
struct ScheduleDebugView: View {
    @ObservedObject private var ds = LocalDataService.shared
    @State private var selectedTab = 0
    @State private var rawResponse = ""
    @State private var isTesting   = false

    private var localAppDate: String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss zzz"
        f.timeZone   = TimeZone(identifier: SportConfig.appTimeZoneID)
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
                row("Device Phoenix now", localAppDate)
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
    @ObservedObject private var dataService    = LocalDataService.shared
    @ObservedObject private var scheduleStore  = ScheduleStore.shared

    private var details: GameDetails?         { dataService.gameDetails[game.gameID ?? ""] }
    private var homeStanding: StandingsEntry? { dataService.standingsMap[game.homeTeam] }
    private var awayStanding: StandingsEntry? { dataService.standingsMap[game.awayTeam] }

    // User-facing team nicknames ("Aces", "Liberty") — internal codes stay untouched.
    private var awayDisplayName: String { SportConfig.teamNickname(for: game.awayTeam) }
    private var homeDisplayName: String { SportConfig.teamNickname(for: game.homeTeam) }

    // MARK: - Simulation-based projection

    private var simResult: GameSimulationResult? { scheduleStore.simulations[game.id] }

    private var projection: TeamProjection? {
        guard let h = homeStanding, let a = awayStanding else { return nil }
        return TeamProjection(away: a, home: h)
    }

    // MARK: - Series label

    private func seriesRecordLabel(_ d: GameDetails) -> String {
        let h = d.homeWins, a = d.awayWins
        if h == 0 && a == 0 { return "Series begins" }
        if h > a { return "\(homeDisplayName) leads series \(h)-\(a)" }
        if a > h { return "\(awayDisplayName) leads series \(a)-\(h)" }
        return "Series tied \(h)-\(h)"
    }

    private var cardFill: LinearGradient {
        LinearGradient(
            colors: [
                Color(red: 0.11, green: 0.19, blue: 0.35),
                Color(red: 0.08, green: 0.13, blue: 0.25),
                Color(red: 0.05, green: 0.09, blue: 0.20)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    private func teamPanel(team: String, standing: StandingsEntry?, emphasis: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                ZStack {
                    Circle()
                        .fill((emphasis ? Color.skyBright : .white).opacity(0.14))
                        .frame(width: 36, height: 36)
                    Text(SportConfig.teamNickname(for: team))
                        .font(.system(size: 14, weight: .black, design: .rounded))
                        .foregroundColor(emphasis ? .skyBright : .white)
                        .lineLimit(1)
                        .minimumScaleFactor(0.35)
                        .frame(width: 31)
                }
                Spacer(minLength: 8)
                if let standing {
                    Text(standing.streak)
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(emphasis ? .skyBright : .white.opacity(0.55))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 4)
                        .background((emphasis ? Color.skyBright : Color.white).opacity(0.10), in: Capsule())
                }
            }

            Text(SportConfig.teamNickname(for: team))
                .font(.title3.bold())
                .foregroundColor(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.55)

            if let standing {
                Text("\(standing.wins)-\(standing.losses)")
                    .font(.caption.bold())
                    .foregroundColor(.white.opacity(0.65))
            } else {
                Text("Standings syncing…")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.white.opacity(0.35))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background((emphasis ? Color.skyBright : Color.white).opacity(0.08), in: RoundedRectangle(cornerRadius: 16))
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke((emphasis ? Color.skyBright : Color.white).opacity(0.16), lineWidth: 1)
        )
    }

    private func matchupCenter(sim: GameSimulationResult?, awayFavored: Bool, homeFavored: Bool) -> some View {
        VStack(spacing: 8) {
            Text("AT")
                .font(.system(size: 10, weight: .black))
                .foregroundColor(.white.opacity(0.35))
            if let sim {
                Text("\(Int((1 - sim.homeWinProbability) * 100))%")
                    .font(.system(size: 18, weight: .black, design: .rounded))
                    .foregroundColor(awayFavored ? .skyBright : .white)
                Text("win edge")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundColor(.white.opacity(0.35))
                    .tracking(0.6)
                Text("\(Int(sim.homeWinProbability * 100))%")
                    .font(.system(size: 18, weight: .black, design: .rounded))
                    .foregroundColor(homeFavored ? .skyBright : .white)
            } else {
                Text("VS")
                    .font(.system(size: 16, weight: .black, design: .rounded))
                    .foregroundColor(.skyBright)
            }
        }
        .frame(width: 56)
    }

    private func compactFooter(propCount: Int, simAvailable: Bool) -> some View {
        HStack(spacing: 8) {
            Label(
                propCount > 0 ? "\(propCount) props ready" : "Props syncing",
                systemImage: propCount > 0 ? "bolt.fill" : "clock.arrow.circlepath"
            )
            .font(.caption)
            .foregroundColor(propCount > 0 ? .yellow.opacity(0.92) : .white.opacity(0.45))

            Spacer()

            Text(simAvailable ? "Teams, players + predictions" : "Team + player details")
                .font(.caption)
                .foregroundColor(.white.opacity(0.42))
            Image(systemName: "chevron.right")
                .font(.caption.bold())
                .foregroundColor(.skyBright.opacity(0.7))
        }
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
                    Text(game.displayDate)
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
                    Text(awayDisplayName)
                        .font(.system(size: 30, weight: .black))
                        .foregroundColor(.white)
                        .lineLimit(1)
                        .minimumScaleFactor(0.5)
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
                        if game.tipTimeSortKey != nil {
                            Text(game.displayTipTime)
                                .font(.caption2)
                                .foregroundColor(.white.opacity(0.4))
                        }
                    }
                }
                .frame(width: 64)
                .padding(.top, 6)

                // Home team column
                VStack(alignment: .center, spacing: 5) {
                    Text(homeDisplayName)
                        .font(.system(size: 30, weight: .black))
                        .foregroundColor(.white)
                        .lineLimit(1)
                        .minimumScaleFactor(0.5)
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

            // ── Model performance summary ───────────────────────────────────
            let sim = simResult
            let proj = projection
            let awayMean = sim?.awayMean ?? (proj?.awayPts ?? 0)
            let homeMean = sim?.homeMean ?? (proj?.homePts ?? 0)
            if awayMean > 0, homeMean > 0 {
                HStack {
                    Label("Prediction", systemImage: "chart.line.uptrend.xyaxis")
                        .foregroundColor(.skyBright)
                    Spacer()
                    Text("\(awayDisplayName) \(Int(awayMean.rounded())) · \(homeDisplayName) \(Int(homeMean.rounded()))")
                        .foregroundColor(.white)
                }
                .font(.caption.bold())
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }

            // ── Win probability (if simulation available) ────────────────────
            if let s = simResult {
                Divider().background(Color.skyBorder)
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Win Probability")
                            .font(.caption2.bold())
                            .foregroundColor(.white)
                        HStack(spacing: 0) {
                            Text("\(awayDisplayName) \(Int((1 - s.homeWinProbability) * 100))%")
                                .font(.caption.bold())
                                .foregroundColor(.skyBright.opacity(0.7))
                            Spacer()
                            Text("\(homeDisplayName) \(Int(s.homeWinProbability * 100))%")
                                .font(.caption.bold())
                                .foregroundColor(.skyBright.opacity(0.7))
                        }
                        Text("Score ranges · \(awayDisplayName) \(s.awayRangeStr)  |  \(homeDisplayName) \(s.homeRangeStr)")
                            .font(.caption2)
                            .foregroundColor(.white.opacity(0.45))
                    }
                    Spacer()
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }

            Divider().background(Color.skyBorder)

            // ── Footer ──────────────────────────────────────────────────────
            HStack(spacing: 8) {
                let propCount = game.playerProps.count
                let highConf  = game.playerProps.contains(where: { $0.selectedProbability >= 0.70 })
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

    // MARK: - Compact card (regular season / loading fallback)

    private var compactCard: some View {
        let sim = simResult
        let proj = projection
        let awayMean = sim?.awayMean ?? (proj?.awayPts ?? 0)
        let homeMean = sim?.homeMean ?? (proj?.homePts ?? 0)
        let homeFavored = homeMean > awayMean
        let awayFavored = awayMean > homeMean
        let timeLabel = game.displayTipTime
        let propCount = game.playerProps.count
        let injuries = (game.missingAwayPlayers + game.missingHomePlayers)
            .filter { $0.status == "OUT" }

        return VStack(spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(game.displayDate)
                        .font(.caption.bold())
                        .foregroundColor(.skyBright)
                    Text(timeLabel)
                        .font(.title3.bold())
                        .foregroundColor(.white)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 5) {
                    Text(propCount > 0 ? "\(propCount) player predictions" : "Predictions loading")
                        .font(.caption2.bold())
                        .foregroundColor(.black.opacity(0.85))
                        .padding(.horizontal, 9)
                        .padding(.vertical, 5)
                        .background(Color.skyBright, in: Capsule())
                    if !injuries.isEmpty {
                        Label("\(injuries.count) out", systemImage: "bandage.fill")
                            .font(.caption2.bold())
                            .foregroundColor(.red.opacity(0.9))
                    }
                }
            }

            HStack(spacing: 12) {
                teamPanel(team: game.awayTeam, standing: awayStanding, emphasis: awayFavored)

                matchupCenter(sim: sim, awayFavored: awayFavored, homeFavored: homeFavored)

                teamPanel(team: game.homeTeam, standing: homeStanding, emphasis: homeFavored)
            }

            if awayMean > 0, homeMean > 0 {
                HStack {
                    Label("Prediction", systemImage: "chart.line.uptrend.xyaxis")
                        .foregroundColor(.skyBright)
                    Spacer()
                    Text("\(awayDisplayName) \(Int(awayMean.rounded())) · \(homeDisplayName) \(Int(homeMean.rounded()))")
                        .foregroundColor(.white)
                }
                .font(.caption.bold())
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
            }

            compactFooter(propCount: propCount, simAvailable: sim != nil)
        }
        .padding(16)
        .background(cardFill, in: RoundedRectangle(cornerRadius: 22))
        .overlay(
            RoundedRectangle(cornerRadius: 22)
                .stroke(Color.white.opacity(0.10), lineWidth: 1)
        )
        .overlay(alignment: .topTrailing) {
            Circle()
                .fill(Color.skyBright.opacity(0.12))
                .frame(width: 120, height: 120)
                .blur(radius: 8)
                .offset(x: 30, y: -30)
        }
        .shadow(color: Color.black.opacity(0.24), radius: 14, y: 8)
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

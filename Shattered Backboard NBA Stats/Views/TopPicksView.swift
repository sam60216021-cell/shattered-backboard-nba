//
//  TopPicksView.swift — Simulation-powered plays by category.
//
//  Runs Monte Carlo simulations (500 trials) for every player in today's
//  games and surfaces the highest-value over lines, grouped alphabetically by player.
//

import Combine
import SwiftUI

// MARK: - Models

struct TopPickEntry: Identifiable {
    var id: String { "\(player.playerID)_\(stat)_\(direction.rawValue)_\(game?.id ?? "")" }
    let player:        Player
    let stat:          String
    let direction:     PropDirection
    let confidence:    Double            // simulation-based hit probability (0–1)
    let overProbability: Double          // canonical over probability (0–1)
    let suggestedLine: Double
    let valueScore:    Double
    let avgMinutes:    Double            // recent minutes per game (volume signal)
    let declineLabel: String?
    let declineStreakGames: Int
    let declineProjectionPenalty: Double
    let declineConfidencePenalty: Double
    let game:          ScheduleGame?     // which game this entry belongs to
    let simResult:     SimulationResult? // full Monte Carlo distribution

    // Inputs retained so the reasoning sheet can regenerate pick-specific
    // explanations without re-running the whole projection pipeline.
    let projection:      PlayerProjection
    let logs:            [GameLog]
    let defenderMatchup: DefenderMatchup?
}

/// One player with all their simulation picks grouped together.
struct PlayerPickGroup: Identifiable {
    var id: String { player.playerID }
    let player: Player
    let picks: [TopPickEntry]  // sorted by stat name and valueScore
}

private struct NBAPropCategory: Identifiable {
    let id: String
    let label: String
    let shortLabel: String
    let icon: String
    let color: Color
}

private struct GamePickGroup: Identifiable {
    let id: String
    let matchup: String
    let time: String
    let topPick: TopPickEntry
    let picks: [TopPickEntry]
}

private func color(for entry: TopPickEntry) -> Color {
    switch entry.confidence {
    case 0.82...: return .green
    case 0.70...: return Color(red: 0.4, green: 0.85, blue: 0.4)
    case 0.62...: return .skyBright
    default:      return .orange
    }
}

private func fmtStat(_ value: Double) -> String {
    value == value.rounded() ? String(format: "%.0f", value) : String(format: "%.1f", value)
}

// MARK: - Slate gating helpers

/// True when the game is over or off the board (final, postponed, canceled).
private func isGameFinal(_ game: ScheduleGame, details: GameDetails?) -> Bool {
    if details?.statusCode == 3 { return true }
    let status = (game.status ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard !status.isEmpty else { return false }
    return status.contains("final")
        || status.contains("postponed") || status.contains("ppd")
        || status.contains("cancel")
}

/// True when the game has tipped but hasn't finished. Live detection requires
/// POSITIVE evidence — an in-progress status code or an explicit in-game status
/// marker. Upcoming games carry time-style statuses like "8/25 - 7:00 PM EDT",
/// which contain neither "scheduled" nor "pre"; a "not-scheduled ⇒ live" rule
/// therefore wrongly flagged every upcoming game as live and emptied the
/// parlay pool entirely.
private func isGameLive(_ game: ScheduleGame, details: GameDetails?) -> Bool {
    if details?.statusCode == 2 { return true }
    guard !isGameFinal(game, details: details) else { return false }
    let status = (game.status ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard !status.isEmpty else { return false }
    let liveMarkers = ["live", "in progress", "halftime", "half",
                       "1st qtr", "2nd qtr", "3rd qtr", "4th qtr",
                       "q1", "q2", "q3", "q4", " ot", "end of"]
    return liveMarkers.contains { status.contains($0) }
}

/// True when a game is still bettable — it sits on the current slate and hasn't
/// tipped yet. Parlay legs are only ever built from games in this state, so
/// finished, in-progress, postponed, or other-day games can never supply legs.
private func isGameBettable(_ game: ScheduleGame, detailsByGameID: [String: GameDetails]) -> Bool {
    let details = detailsByGameID[game.gameID ?? game.id]
    return !isGameFinal(game, details: details) && !isGameLive(game, details: details)
}

private let allPlayCategories: [NBAPropCategory] = [
    NBAPropCategory(id: "PTS", label: "Points", shortLabel: "PTS", icon: "flame.fill", color: .orange),
    NBAPropCategory(id: "REB", label: "Rebounds", shortLabel: "REB", icon: "figure.strengthtraining.traditional", color: .green),
    NBAPropCategory(id: "AST", label: "Assists", shortLabel: "AST", icon: "arrow.triangle.branch", color: .skyBright),
    NBAPropCategory(id: "3PM", label: "Threes", shortLabel: "3PM", icon: "scope", color: .cyan),
    NBAPropCategory(id: "PRA", label: "Points + Rebounds + Assists", shortLabel: "PRA", icon: "chart.line.uptrend.xyaxis", color: .yellow),
    NBAPropCategory(id: "PR", label: "Points + Rebounds", shortLabel: "PR", icon: "sportscourt.fill", color: .mint),
    NBAPropCategory(id: "PA", label: "Points + Assists", shortLabel: "PA", icon: "point.topleft.down.curvedto.point.bottomright.up.fill", color: .teal),
    NBAPropCategory(id: "RA", label: "Rebounds + Assists", shortLabel: "RA", icon: "arrow.left.arrow.right", color: .indigo),
    NBAPropCategory(id: "FPTS", label: "Fantasy Points", shortLabel: "FPTS", icon: "star.fill", color: .purple),
    NBAPropCategory(id: "FTM", label: "Free Throws", shortLabel: "FTM", icon: "circle.grid.3x3.fill", color: .pink),
    NBAPropCategory(id: "STL", label: "Steals", shortLabel: "STL", icon: "bolt.fill", color: .red),
    NBAPropCategory(id: "BLK", label: "Blocks", shortLabel: "BLK", icon: "shield.fill", color: .blue)
]

// MARK: - TopPicksStore

@MainActor
final class TopPicksStore: ObservableObject {
    static let shared = TopPicksStore()
    private init() {}

    @Published private(set) var playerGroups: [PlayerPickGroup] = []  // grouped by player, alphabetized
    @Published private(set) var isLoading = false
    /// Slate identity (date + game IDs + player-group count) of the last completed
    /// compute. Views observe this to rebuild parlay suggestions whenever the
    /// underlying slate changes — even when the pick count happens to stay equal.
    @Published private(set) var computedSignature: String = ""

    private var lastComputedAt:  Date?  = nil
    private var lastPlayerCount: Int    = -1
    private var lastGameCount: Int      = -1
    private var lastSnapshotID: Int     = -1
    private var lastLogsRevision: Int   = -1
    private var lastComputedDay: String = ""
    private let staleInterval: TimeInterval = 1800  // 30 min

    private let evaluatedStats  = ["PTS", "REB", "AST", "PR", "PA", "RA", "PRA", "FPTS", "3PM", "FTM", "STL", "BLK"]
    private let targetConfidence: Double = 0.72
    private let blockedInjuryStatuses: Set<String> = ["OUT", "DOUBTFUL", "QUESTIONABLE", "INJURY", "SUSPENDED", "INACTIVE"]

    // Minimum meaningful line per stat — filters out trivial sub-threshold entries.
    private let minLines: [String: Double] = [
        "PTS": 4.5, "REB": 2.5, "AST": 1.5,
        "PR": 7.5, "PA": 8.5, "RA": 5.5, "PRA": 9.5, "FPTS": 12.5,
        "3PM": 0.5, "FTM": 0.5, "STL": 0.5, "BLK": 0.5
    ]

    // MARK: - Public trigger

    func computeIfNeeded(snapshotID: Int, playerCount: Int, gameCount: Int, logsRevision: Int) {
        guard !isLoading else { return }
        let today         = isoToday()
        let rosterChanged = playerCount != lastPlayerCount && playerCount > 0
        let gamesChanged  = gameCount != lastGameCount
        let snapChanged   = snapshotID != lastSnapshotID
        let logsChanged   = logsRevision != lastLogsRevision
        let newDay        = today != lastComputedDay
        let isStale       = lastComputedAt.map { Date().timeIntervalSince($0) > staleInterval } ?? true
        guard rosterChanged || gamesChanged || snapChanged || logsChanged || isStale || newDay || playerGroups.isEmpty else { return }
        Task { await compute(snapshotID: snapshotID, playerCount: playerCount, gameCount: gameCount, logsRevision: logsRevision) }
    }

    // MARK: - Compute

    private func normalizedPlayerName(_ name: String) -> String {
        name
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "[^a-z0-9]", with: "", options: .regularExpression)
    }

    private func isUnavailable(player: Player, in game: ScheduleGame) -> Bool {
        let team = (player.team ?? "").uppercased()
        let name = normalizedPlayerName(player.name)
        guard !name.isEmpty else { return false }

        let missingPool: [MissingPlayer]
        if team == game.awayTeam.uppercased() {
            missingPool = game.missingAwayPlayers
        } else if team == game.homeTeam.uppercased() {
            missingPool = game.missingHomePlayers
        } else {
            missingPool = game.missingAwayPlayers + game.missingHomePlayers
        }

        for miss in missingPool {
            guard let missName = miss.name else { continue }
            if normalizedPlayerName(missName) != name { continue }
            let status = (miss.status ?? "").uppercased()
            if blockedInjuryStatuses.contains(status) {
                return true
            }
        }
        return false
    }

    private func compute(snapshotID: Int, playerCount: Int, gameCount: Int, logsRevision: Int) async {
        let dataService = LocalDataService.shared
        let allPlayers  = dataService.snapshot?.players ?? []
        guard !allPlayers.isEmpty else { return }

        let sortedSlate = (dataService.snapshot?.games ?? [])
            .sorted {
                let l = $0.tipTimeSortKey ?? Int.max
                let r = $1.tipTimeSortKey ?? Int.max
                if l != r { return l < r }
                return $0.awayTeam < $1.awayTeam
            }
        guard !sortedSlate.isEmpty else { return }
        let slateDate = sortedSlate.first?.date ?? isoToday()
        // Hard guard: exactly one day's slate, never a past one. Stray game rows
        // carrying another date (import/dedupe edge cases) or a stale cached
        // snapshot (yesterday's games kept after a failed sync) must never leak
        // players who aren't playing today into picks or parlay legs.
        let today = isoToday()
        let slateGames = sortedSlate.filter { $0.date == slateDate && $0.date >= today }
        if slateGames.isEmpty {
            // The active slate is entirely in the past — drop any stale picks
            // instead of leaving yesterday's players in the parlay builders.
            playerGroups = []
            isLoading = false
            computedSignature = ""
            return
        }

        isLoading = playerGroups.isEmpty  // show spinner only on first load

        var picksByPlayer: [String: (player: Player, picks: [TopPickEntry])] = [:]

        for game in slateGames {
            let gamePlayers = allPlayers.filter {
                let t = ($0.team ?? "").uppercased()
                return t == game.awayTeam.uppercased() || t == game.homeTeam.uppercased()
            }
            guard !gamePlayers.isEmpty else { continue }

            // Use matchup-specific player projections so simulation means include opponent context.
            // Playoff mode prefers the server-provided game type, falling back to
            // the hard-coded qualifier heuristic.
            let details = dataService.gameDetails[game.gameID ?? game.id]
            // Games that are final or off the board produce dead legs — their
            // players are no longer bettable, so they never enter picks/parlays.
            guard !isGameFinal(game, details: details) else { continue }
            let gameProjections = PredictionEngine.shared.projectGame(
                game: game,
                players: gamePlayers,
                isPlayoffs: details?.isPlayoff ?? game.isPlayoffGame,
                isFirstRound: details?.isFirstRound ?? game.isFirstRound
            )

            for player in gamePlayers {
                guard !isUnavailable(player: player, in: game) else { continue }

                let logs = dataService.localLogs(playerID: player.playerID)
                guard logs.count >= 5 else { continue }
                guard let projection = gameProjections[player.playerID] else { continue }

                // Filter out bench players: require a genuine rotation role.
                // Recent-5 gate catches role changes (lost/earned a rotation spot);
                // recent-10 average keeps one blowout game from carrying a bench player.
                let recent5  = logs.prefix(5).map(\.min)
                let recent10 = logs.prefix(10).map(\.min)
                let avg5     = recent5.reduce(0, +)  / Double(max(1, recent5.count))
                let avg10    = recent10.reduce(0, +) / Double(max(1, recent10.count))
                guard avg5 >= 20, avg10 >= 18 else { continue }

                for stat in evaluatedStats {
                    guard let result = findSimulatedPick(
                        stat: stat, logs: logs, playerID: player.playerID,
                        player: player, game: game, projection: projection
                    ) else { continue }
                    let entry = TopPickEntry(
                        player:        player,
                        stat:          stat,
                        direction:     result.direction,
                        confidence:    result.confidence,
                        overProbability: result.overProbability,
                        suggestedLine: result.line,
                        valueScore:    result.valueScore,
                        avgMinutes:    avg10,
                        declineLabel:  projection.declineLabel,
                        declineStreakGames: projection.declineStreakGames,
                        declineProjectionPenalty: projection.declineProjectionPenalty,
                        declineConfidencePenalty: projection.declineConfidencePenalty,
                        game:          game,
                        simResult:     result.simResult,
                        projection:    projection,
                        logs:          logs,
                        defenderMatchup: result.defenderMatchup
                    )
                    
                    // Also collect for player grouping
                    let key = player.playerID
                    if picksByPlayer[key] == nil {
                        picksByPlayer[key] = (player: player, picks: [])
                    }
                    picksByPlayer[key]?.picks.append(entry)
                }
            }
        }

        // Group by player and sort alphabetically
        self.playerGroups = picksByPlayer.values
            .map { player, picks in
                let sorted = picks.sorted { $0.stat < $1.stat }  // sort by stat name
                return PlayerPickGroup(player: player, picks: sorted)
            }
            .sorted { $0.player.name < $1.player.name }
        ProjectionTracker.shared.update(
            entries: playerGroups.flatMap(\.picks),
            dataService: dataService
        )
        isLoading       = false
        lastComputedAt  = Date()
        lastComputedDay = slateDate
        lastPlayerCount = playerCount
        lastGameCount   = gameCount
        lastSnapshotID  = snapshotID
        lastLogsRevision = logsRevision
        computedSignature = [
            slateDate,
            slateGames.map(\.id).sorted().joined(separator: ","),
            String(playerGroups.count)
        ].joined(separator: "|")
    }

    // MARK: - Simulation-based line finder

    /// Runs a Monte Carlo simulation and finds the best target number to clear for `stat`.
    /// Wide confidence band (55–92%) ensures enough picks per game.
    /// Opponent defensive strength is factored into volatility estimation.
    private func findSimulatedPick(
        stat: String, logs: [GameLog], playerID: String,
        player: Player, game: ScheduleGame, projection: PlayerProjection
    ) -> (line: Double, direction: PropDirection, confidence: Double, overProbability: Double, valueScore: Double, simResult: SimulationResult, defenderMatchup: DefenderMatchup?)? {

        // Determine opponent: if player's team matches away team, opponent is home team.
        let opponent = (player.team ?? "").uppercased() == game.awayTeam.uppercased()
            ? game.homeTeam
            : game.awayTeam

        let minLine = minLines[stat] ?? 0.5
        let values  = logs.prefix(10).compactMap { $0.value(for: stat) }.filter { $0 > 0 }
        guard values.count >= 4 else { return nil }

        let projMean = projection.value(for: stat)
        guard projMean > minLine * 0.8 else { return nil }

        // Individual-defender matchup for distribution shaping in the sim.
        let defenderMatchup = MatchupDefenseEvaluator.cached(
            player: player, game: game, dataService: LocalDataService.shared
        )

        // Run Monte Carlo simulation with opponent defensive context
        let sim = SimulationEngine.shared.simulatePlayerStat(
            playerID: playerID, stat: stat,
            logs: Array(logs.prefix(20)), projectedMean: projMean,
            opponent: opponent,
            defenderMatchup: defenderMatchup
        )

        // Scan lines in the simulation's realistic range (P25 → P75).
        let startLine = max(minLine, (sim.p25 * 2).rounded(.down) / 2)
        let endLine   = max(startLine + 1.0, (sim.p75 * 2).rounded(.up) / 2)

        var bestLine:      Double? = nil
        var bestConf:      Double  = 0
        var bestOverProb:  Double  = 0
        var bestScore:     Double  = -Double.infinity

        var line = startLine
        while line <= endLine {
            let overConf = sim.hitProbability(above: line)
            if overConf >= 0.55 && overConf <= 0.92 {
                let edge  = overConf - 0.5
                let score = (line * edge * 1.2) - abs(overConf - targetConfidence) * 0.6
                if score > bestScore {
                    bestScore = score
                    bestLine  = line
                    bestConf  = overConf
                    bestOverProb = overConf
                }
            }
            line += 0.5
        }

        guard let chosenLine = bestLine else { return nil }
        return (
            line: chosenLine,
            direction: .over,
            confidence: bestConf,
            overProbability: bestOverProb,
            valueScore: bestScore,
            simResult: sim,
            defenderMatchup: defenderMatchup
        )
    }

    private func isoToday() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone   = TimeZone(identifier: SportConfig.appTimeZoneID)
        return f.string(from: Date())
    }
}

// MARK: - TopPicksView

struct TopPicksView: View {

    @ObservedObject private var store       = TopPicksStore.shared
    @ObservedObject private var dataService = LocalDataService.shared
    @ObservedObject private var router      = AppRouter.shared
    @State private var selectedStat: String = allPlayCategories[0].id
    @State private var showConsistencyBuilder = false
    private let maxDisplayedPicks = 12

    private var selectedCategory: NBAPropCategory {
        allPlayCategories.first(where: { $0.id == selectedStat }) ?? allPlayCategories[0]
    }

    private var filteredGroups: [PlayerPickGroup] {
        store.playerGroups.compactMap { group in
            let filtered = group.picks.filter { pick in
                if pick.stat != selectedStat { return false }
                return true
            }
            guard !filtered.isEmpty else { return nil }

            return PlayerPickGroup(player: group.player, picks: filtered)
        }
    }

    private var rankedPicks: [TopPickEntry] {
        let ranked = filteredGroups
            .flatMap { group in
                group.picks.map { $0 }
            }
            .sorted { lhs, rhs in
                let lhsScore = consistencyScore(for: lhs)
                let rhsScore = consistencyScore(for: rhs)
                if lhsScore == rhsScore {
                    return lhs.confidence > rhs.confidence
                }
                return lhsScore > rhsScore
            }
            .prefix(maxDisplayedPicks)

        return Array(ranked)
    }

    private var gameGroups: [GamePickGroup] {
        let grouped = Dictionary(grouping: filteredGroups.flatMap(\.picks)) { pick in
            pick.game?.id ?? "unknown"
        }

        return grouped.compactMap { gameID, picks in
            guard gameID != "unknown",
                  let game = picks.first?.game else { return nil }

            let ordered = picks.sorted { lhs, rhs in
                let lhsScore = consistencyScore(for: lhs)
                let rhsScore = consistencyScore(for: rhs)
                if lhsScore == rhsScore {
                    return lhs.confidence > rhs.confidence
                }
                return lhsScore > rhsScore
            }

            guard let topPick = ordered.first else { return nil }
            let matchup = "\(game.awayTeam) @ \(game.homeTeam)"
            let time = game.gameTime ?? "TBD"

            return GamePickGroup(
                id: gameID,
                matchup: matchup,
                time: time,
                topPick: topPick,
                picks: Array(ordered.prefix(6))
            )
        }
        .sorted {
            let l = ScheduleGame.tipMinutesSinceMidnight(from: $0.time) ?? Int.max
            let r = ScheduleGame.tipMinutesSinceMidnight(from: $1.time) ?? Int.max
            if l != r { return l < r }
            return $0.matchup < $1.matchup
        }
    }

    private var totalFilteredPicks: Int {
        filteredGroups.reduce(0) { $0 + $1.picks.count }
    }

    /// Rank score: blend stability, simulation confidence, and role volume.
    /// Volume (recent minutes per game) keeps low-usage bench players with tiny
    /// steady stat lines from outranking high-usage stars, which the previous
    /// pure relative-spread metric allowed.
    private func consistencyScore(for pick: TopPickEntry) -> Double {
        guard let sim = pick.simResult, sim.mean > 0 else {
            return pick.confidence
        }

        let spread = (sim.p90 - sim.p10) / sim.mean
        let stability = max(0, 1 - spread)
        let volume = min(1.0, max(0, pick.avgMinutes) / 32.0)
        return (stability * 0.35) + (pick.confidence * 0.35) + (volume * 0.30)
    }

    var body: some View {
        let snapshotID = dataService.snapshotID
        let playerCount = dataService.snapshot?.players.count ?? 0
        let gameCount = dataService.snapshot?.games.count ?? 0

        NavigationStack {
            ZStack {
                NightSkyBackground()
                VStack(spacing: 0) {
                    categoryTabBar
                    content
                }
            }
            .navigationTitle("Plays")
            .navigationBarTitleDisplayMode(.inline)
        }
        .task {
            store.computeIfNeeded(snapshotID: snapshotID, playerCount: playerCount, gameCount: gameCount, logsRevision: dataService.logsRevision)
        }
        .onChange(of: dataService.snapshotID) { _, _ in
            store.computeIfNeeded(
                snapshotID: dataService.snapshotID,
                playerCount: dataService.snapshot?.players.count ?? 0,
                gameCount: dataService.snapshot?.games.count ?? 0,
                logsRevision: dataService.logsRevision
            )
        }
        .onChange(of: dataService.logsRevision) { _, _ in
            store.computeIfNeeded(
                snapshotID: dataService.snapshotID,
                playerCount: dataService.snapshot?.players.count ?? 0,
                gameCount: dataService.snapshot?.games.count ?? 0,
                logsRevision: dataService.logsRevision
            )
        }
        .onChange(of: dataService.isLoadingAllLogs) { _, isLoading in
            if !isLoading {
                store.computeIfNeeded(
                    snapshotID: dataService.snapshotID,
                    playerCount: dataService.snapshot?.players.count ?? 0,
                    gameCount: dataService.snapshot?.games.count ?? 0,
                    logsRevision: dataService.logsRevision
                )
            }
        }
        .sheet(isPresented: $showConsistencyBuilder) {
            ConsistencyParlaySheet()
        }
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if store.isLoading {
            loadingView
        } else if filteredGroups.isEmpty {
            emptyView
        } else {
            playsByCategory
        }
    }

    private var categoryTabBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(allPlayCategories) { category in
                    let active = category.id == selectedStat
                    Button {
                        withAnimation(.easeInOut(duration: 0.18)) {
                            selectedStat = category.id
                        }
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: category.icon)
                                .font(.system(size: 10, weight: .bold))
                            Text(category.shortLabel)
                                .font(.system(size: 12, weight: .bold))
                        }
                        .foregroundColor(active ? .black : category.color)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(active ? category.color : category.color.opacity(0.12), in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
        .background(Color.skyDeep.opacity(0.85))
    }

    // MARK: - Plays list

    private var playsByCategory: some View {
        ScrollView {
            VStack(spacing: 20) {
                playsHeader

                HStack {
                    Text("Best \(selectedCategory.shortLabel) plays from \(gameGroups.count) game\(gameGroups.count == 1 ? "" : "s")")
                        .font(.caption)
                        .foregroundColor(.white.opacity(0.4))
                    Spacer()
                    Label("Monte Carlo", systemImage: "waveform.path.ecg")
                        .font(.caption2.bold())
                        .foregroundColor(.skyBright.opacity(0.5))
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)

                if !store.playerGroups.isEmpty {
                    consistencyBanner
                }

                if !rankedPicks.isEmpty {
                    topRankingSection
                }

                ForEach(gameGroups) { group in
                    GamePicksSection(group: group)
                }
            }
            .padding(.bottom, 32)
        }
    }

    private var playsHeader: some View {
        HStack(spacing: 8) {
            Image(systemName: selectedCategory.icon)
                .font(.system(size: 14, weight: .bold))
                .foregroundColor(selectedCategory.color)
            Text(selectedCategory.label)
                .font(.system(size: 14, weight: .bold))
                .foregroundColor(selectedCategory.color)
            Spacer()
            Text("Monte Carlo")
                .font(.caption2.weight(.semibold))
                .foregroundColor(.white.opacity(0.45))
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
    }

    // MARK: - Loading / empty

    private var loadingView: some View {
        VStack(spacing: 14) {
            ProgressView()
                .progressViewStyle(CircularProgressViewStyle(tint: .skyBright))
                .scaleEffect(1.2)
            Text("Running simulations…")
                .font(.subheadline)
                .foregroundColor(.white.opacity(0.45))
            Text("\(SimulationEngine.defaultSimulationCount) Monte Carlo trials per player stat")
                .font(.caption)
                .foregroundColor(.white.opacity(0.25))
        }
    }

    private func isoToday() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = TimeZone(identifier: SportConfig.appTimeZoneID)
        return f.string(from: Date())
    }

    private var emptyView: some View {
        let slateGames = dataService.snapshot?.games ?? []
        let hasGames = !slateGames.isEmpty
        let slateDate = slateGames.first?.date
        let isTodaySlate = slateDate == isoToday()
        let subtitle: String = {
            if dataService.isLoadingAllLogs {
                return "Building plays from local logs. This usually takes a few seconds after refresh."
            }
            if !hasGames {
                return "No games are loaded for this slate yet. Pull to refresh from Schedule first."
            }
            return isTodaySlate
                ? "Check back once today's simulations and lineups are ready."
                : "Check back once this slate's simulations and lineups are ready."
        }()

        return VStack(spacing: 16) {
            Image(systemName: selectedCategory.icon)
                .font(.system(size: 48))
                .foregroundColor(selectedCategory.color.opacity(0.35))
            Text("No \(selectedCategory.shortLabel) plays")
                .font(.title3.bold())
                .foregroundColor(.white)
            Text(subtitle)
                .font(.subheadline)
                .foregroundColor(.white.opacity(0.45))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
        }
    }

    /// Banner entry point for the 20-leg consistency parlay builder.
    private var consistencyBanner: some View {
        Button {
            showConsistencyBuilder = true
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "square.stack.3d.up.fill")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundColor(.yellow)
                VStack(alignment: .leading, spacing: 2) {
                    Text("20-Leg Consistency Parlay")
                        .font(.system(size: 13, weight: .black, design: .rounded))
                        .foregroundColor(.white)
                    Text("Each player's most consistent stat from their last 20 games")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.white.opacity(0.55))
                        .lineLimit(1)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(.white.opacity(0.35))
            }
            .padding(14)
            .background(Color.skyCard.opacity(0.75), in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.yellow.opacity(0.35), lineWidth: 1))
            .padding(.horizontal, 16)
        }
        .buttonStyle(.plain)
    }

    private var topRankingSection: some View {
        VStack(spacing: 8) {
            HStack {
                Label("Best Plays", systemImage: selectedCategory.icon)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(selectedCategory.color)
                Spacer()
                Text("\(rankedPicks.count) plays")
                    .font(.caption2.weight(.semibold))
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.top, 4)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(Array(rankedPicks.enumerated()), id: \.element.id) { idx, entry in
                        topRankLink(entry: entry, rank: idx + 1)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 10)
            }
        }
        .background(Color.skyRow.opacity(0.55))
    }

    @ViewBuilder
    private func topRankLink(entry: TopPickEntry, rank: Int) -> some View {
        NavigationLink(destination: PlayerStatsView(player: entry.player, game: entry.game)) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("#\(rank)")
                        .font(.system(size: 10, weight: .black, design: .rounded))
                        .foregroundColor(.white.opacity(0.3))
                    Spacer()
                    Text("\(Int(round(entry.confidence * 100)))%")
                        .font(.system(size: 16, weight: .black, design: .rounded))
                        .foregroundColor(color(for: entry))
                }

                Text(entry.player.name)
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(.white)
                    .lineLimit(2)

                Text("\(fmtStat(entry.suggestedLine)) \(entry.stat) to hit")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(selectedCategory.color)

                if let game = entry.game {
                    Text("\(game.awayTeam) @ \(game.homeTeam)")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.white.opacity(0.55))
                        .lineLimit(1)
                }
            }
            .frame(width: 170, alignment: .leading)
            .padding(14)
            .background(Color.skyCard.opacity(0.75), in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.skyBorder, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - GamePicksSection

private struct GamePicksSection: View {
    let group: GamePickGroup

    var body: some View {
        VStack(spacing: 6) {
            topPickBanner
            ForEach(Array(group.picks.enumerated()), id: \.element.id) { idx, entry in
                NavigationLink(destination: PlayerStatsView(player: entry.player, game: entry.game)) {
                    SimPickRow(entry: entry, rank: idx + 1)
                }
                .buttonStyle(.plain)
                if idx < group.picks.count - 1 {
                    Divider()
                        .background(Color.skyBorder.opacity(0.5))
                        .padding(.leading, 60)
                }
            }
        }
        .background(Color.skyCard.opacity(0.6), in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.skyBorder, lineWidth: 1))
        .padding(.horizontal, 12)
        .overlay(alignment: .topLeading) {
            HStack(spacing: 8) {
                Text(group.matchup)
                    .font(.system(size: 13, weight: .black, design: .rounded))
                    .foregroundColor(.white)
                Text(group.time)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 9)
            .background(Color.skyDeep.opacity(0.95), in: RoundedRectangle(cornerRadius: 12))
            .padding(.leading, 8)
            .padding(.top, -12)
        }
        .padding(.top, 10)
    }

    private var topPickBanner: some View {
        HStack(spacing: 6) {
            Image(systemName: "crown.fill")
                .font(.system(size: 10, weight: .bold))
                .foregroundColor(.yellow)
            Text("Top Play")
                .font(.system(size: 10, weight: .bold))
                .foregroundColor(.yellow)
            Text(group.topPick.player.name)
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(.white)
                .lineLimit(1)
            Spacer()
            Text(String(format: "Conf %.0f%%", group.topPick.confidence * 100))
                .font(.system(size: 9, weight: .bold))
                .foregroundColor(.skyBright)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .padding(.top, 18)
        .background(Color.black.opacity(0.22), in: RoundedRectangle(cornerRadius: 9))
        .padding(.horizontal, 10)
    }
}

// MARK: - SimPickRow

private struct SimPickRow: View {
    let entry: TopPickEntry
    let rank:  Int

    @ObservedObject private var router = AppRouter.shared
    @State private var showBlocked = false
    @State private var showExplain = false

    private var prop: PlayerProp {
        PlayerProp(
            id: "toppick_\(entry.player.playerID)_\(entry.stat)_\(entry.direction.rawValue)_\(entry.game?.id ?? "")",
            gameID: entry.game?.gameID,
            playerName: entry.player.name,
            team: entry.player.team,
            statLabel: entry.stat,
            line: entry.suggestedLine,
            direction: entry.direction,
            overPct: entry.overProbability,
            projectedValue: entry.simResult?.mean
        )
    }

    private var initials: String {
        let parts = entry.player.name.split(separator: " ")
        let first = parts.first?.first.map(String.init) ?? ""
        let last  = parts.dropFirst().first?.first.map(String.init) ?? ""
        return (first + last).uppercased()
    }

    private var confidenceColor: Color {
        color(for: entry)
    }

    private var tier: String {
        switch entry.confidence {
        case 0.82...: return "HIGH"
        case 0.70...: return "SOLID"
        case 0.62...: return "LEAN"
        default:      return "SPEC"
        }
    }

    var body: some View {
        let inParlay = router.isInParlay(prop)

        HStack(spacing: 10) {
            // Rank
            Text("\(rank)")
                .font(.system(size: 10, weight: .black, design: .rounded))
                .foregroundColor(.white.opacity(0.22))
                .frame(width: 18, alignment: .center)

            // Avatar
            ZStack {
                Circle()
                    .fill(confidenceColor.opacity(0.16))
                    .frame(width: 36, height: 36)
                Text(initials)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(confidenceColor)
            }

            // Player + stat block
            VStack(alignment: .leading, spacing: 4) {
                // Name + team
                HStack(spacing: 5) {
                    Text(entry.player.name)
                        .font(.subheadline.bold())
                        .foregroundColor(.white)
                        .lineLimit(1)
                    if let team = entry.player.team {
                        Text(team)
                            .font(.system(size: 9, weight: .bold))
                            .foregroundColor(.skyBright.opacity(0.6))
                    }
                    if let pos = entry.player.position, !pos.isEmpty {
                        Text(pos)
                            .font(.system(size: 9))
                            .foregroundColor(.white.opacity(0.3))
                    }
                }

                // Stat pill + line + mini bar
                HStack(spacing: 6) {
                    Text(entry.stat)
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(.black.opacity(0.8))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(confidenceColor, in: Capsule())

                    Text("\(fmtStat(entry.suggestedLine)) to hit")
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                        .foregroundColor(.white)

                    if let sim = entry.simResult, sim.p75 > sim.p25 {
                        miniBar(sim: sim, line: entry.suggestedLine)
                            .frame(width: 48, height: 8)

                        Text("\(fmtStat(sim.p25))–\(fmtStat(sim.p75))")
                            .font(.system(size: 9))
                            .foregroundColor(.white.opacity(0.28))
                    }
                }

                if let declineLabel = entry.declineLabel {
                    Text(declineLabel)
                        .font(.system(size: 9, weight: .bold, design: .rounded))
                        .foregroundColor(.orange.opacity(0.95))
                }
            }

            Spacer(minLength: 4)

            // Confidence badge
            VStack(alignment: .trailing, spacing: 2) {
                Text("\(Int(round(entry.confidence * 100)))%")
                    .font(.system(size: 15, weight: .black, design: .rounded))
                    .foregroundColor(confidenceColor)
                Text(tier)
                    .font(.system(size: 7, weight: .bold))
                    .foregroundColor(confidenceColor.opacity(0.6))
                    .tracking(0.5)
                Button {
                    showExplain = true
                } label: {
                    Text("WHY")
                        .font(.system(size: 7, weight: .bold))
                        .foregroundColor(.white.opacity(0.6))
                }
                .buttonStyle(.plain)
            }
            .frame(width: 42, alignment: .trailing)

            // Add / remove parlay button
            Group {
                if inParlay {
                    Button { router.removeFromParlay(prop) } label: {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.title3)
                            .foregroundColor(.skyBright)
                    }
                } else {
                    Button {
                        if !router.addToParlay(prop) { showBlocked = true }
                    } label: {
                        Image(systemName: "plus.circle.fill")
                            .font(.title3)
                            .foregroundColor(.skyBright.opacity(0.7))
                    }
                }
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
        .background(inParlay ? Color.skyBright.opacity(0.06) : Color.clear)
        .alert("Can't add to Picks", isPresented: $showBlocked) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(router.blockedReason(for: prop) ?? "")
        }
        .sheet(isPresented: $showExplain) {
            ConfidenceExplainSheet(entry: entry)
        }
    }

    // Inline mini range bar: shows P25–P75 band with a marker at the suggested line.
    private func miniBar(sim: SimulationResult, line: Double) -> some View {
        GeometryReader { geo in
            let maxD = max(sim.p90 * 1.1, line * 1.2)
            let w    = geo.size.width
            let fX   = CGFloat(sim.p25 / maxD) * w
            let cX   = CGFloat(sim.p75 / maxD) * w
            let lX   = CGFloat(line    / maxD) * w

            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.07)).frame(height: 4)
                Capsule()
                    .fill(confidenceColor.opacity(0.45))
                    .frame(width: max(2, cX - fX), height: 4)
                    .offset(x: fX)
                Rectangle()
                    .fill(confidenceColor)
                    .frame(width: 2, height: 8)
                    .offset(x: lX - 1)
            }
        }
    }

}

private struct ConfidenceExplainSheet: View {
    let entry: TopPickEntry

    /// Per-pick reasons generated by the engine from this exact pick's inputs.
    private var reasons: [PredictionEngine.PickReason] {
        PredictionEngine.shared.pickReasons(
            for: entry.projection,
            stat: entry.stat,
            line: entry.suggestedLine,
            direction: entry.direction,
            sim: entry.simResult,
            logs: entry.logs,
            defenderMatchup: entry.defenderMatchup
        )
    }

    private var rangeWidthPct: Int {
        guard let sim = entry.simResult, sim.mean > 0 else { return 0 }
        return Int(round(((sim.p90 - sim.p10) / sim.mean) * 100))
    }

    private func icon(for kind: PredictionEngine.PickReason.Kind) -> (String, Color) {
        switch kind {
        case .edge:    return ("arrow.up.right.circle.fill", .skyBright)
        case .matchup: return ("shield.lefthalf.filled", .orange)
        case .volume:  return ("clock.fill", .teal)
        case .form:    return ("flame.fill", .pink)
        case .risk:    return ("exclamationmark.triangle.fill", .yellow)
        case .sample:  return ("number.circle.fill", .white.opacity(0.45))
        }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(entry.player.name) — \(entry.stat) \(entry.direction.rawValue)")
                                .font(.headline)
                            Text("Line \(String(format: "%.1f", entry.suggestedLine))")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                        Text("\(Int(round(entry.confidence * 100)))%")
                            .font(.title2.bold())
                            .foregroundColor(.green)
                    }
                }

                Section("Why this pick") {
                    ForEach(Array(reasons.enumerated()), id: \.offset) { _, reason in
                        let (symbol, tint) = icon(for: reason.kind)
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: symbol)
                                .font(.caption)
                                .foregroundColor(tint)
                                .frame(width: 16)
                            Text(reason.text)
                                .font(.subheadline)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }

                Section("Outcome range") {
                    if let sim = entry.simResult {
                        Text("P10–P90 range: \(String(format: "%.1f", sim.p10))–\(String(format: "%.1f", sim.p90))")
                        Text("Range width: \(rangeWidthPct)% of mean")
                    } else {
                        Text("No simulation available for this pick.")
                            .foregroundColor(.secondary)
                    }
                }
            }
            .navigationTitle("Why this pick")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

// MARK: - 20-Leg Consistency Parlay

/// One leg of the consistency parlay: a player's single most consistent stat,
/// measured by how often they cleared the suggested line over their last 20 games.
private struct ConsistencyLeg: Identifiable {
    let entry: TopPickEntry
    let hits: Int
    let games: Int

    var hitRate: Double { games > 0 ? Double(hits) / Double(games) : 0 }
    var id: String { "consist_\(entry.player.playerID)_\(entry.stat)" }

    /// Mirrors the prop id used by SimPickRow so the same bet can't be added twice
    /// (once from the sheet, once from a pick row).
    var prop: PlayerProp {
        PlayerProp(
            id: "toppick_\(entry.player.playerID)_\(entry.stat)_\(entry.direction.rawValue)_\(entry.game?.id ?? "")",
            gameID: entry.game?.gameID,
            playerName: entry.player.name,
            team: entry.player.team,
            statLabel: entry.stat,
            line: entry.suggestedLine,
            direction: entry.direction,
            overPct: entry.overProbability,
            projectedValue: entry.simResult?.mean
        )
    }
}

/// Builds a 20-leg parlay from each eligible player's most consistent stat,
/// defined as the highest share of their last 20 games clearing the suggested line.
private struct ConsistencyParlaySheet: View {
    @ObservedObject private var store   = TopPicksStore.shared
    @ObservedObject private var router  = AppRouter.shared
    @Environment(\.dismiss) private var dismiss

    @State private var legs: [ConsistencyLeg] = []
    @State private var addedToast: String?

    private let legTarget  = 20
    private let minGames   = 10   // need at least 10 of the last 20 games to judge consistency
    private let minHitRate = 0.70 // stat must have cleared its line in 70%+ of those games

    // Only the stats every sportsbook posts — skip fantasy scores and combos.
    private let allowedStats: Set<String> = ["PTS", "REB", "AST", "3PM", "BLK", "STL"]

    private var combinedHitRate: Double {
        legs.isEmpty ? 0 : legs.map(\.hitRate).reduce(1.0, *)
    }

    /// "Today" in the app's display time zone — matches how slate dates are stored.
    private func isoToday() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone   = TimeZone(identifier: SportConfig.appTimeZoneID)
        return f.string(from: Date())
    }

    private func statColor(_ stat: String) -> Color {
        allPlayCategories.first(where: { $0.id == stat })?.color ?? .skyBright
    }

    /// For each player with a game TODAY, find their single most consistent stat.
    private func buildLegs() {
        let dataService = LocalDataService.shared
        let detailsByGameID = dataService.gameDetails
        let today = isoToday()
        var candidates: [ConsistencyLeg] = []

        for group in store.playerGroups {
            // Legs only come from games dated TODAY that haven't tipped —
            // finished, in-progress, or other-day games never qualify.
            let bettablePicks = group.picks.filter { entry in
                guard let game = entry.game else { return false }
                return game.date == today
                    && isGameBettable(game, detailsByGameID: detailsByGameID)
            }
            guard !bettablePicks.isEmpty else { continue }

            let logs = dataService.localLogs(playerID: group.player.playerID)
            let recent = Array(logs.prefix(20)) // newest first
            guard recent.count >= minGames else { continue }

            var best: ConsistencyLeg?
            for entry in bettablePicks where allowedStats.contains(entry.stat) {
                let hits = recent.filter { $0.value(for: entry.stat) >= entry.suggestedLine }.count
                let leg = ConsistencyLeg(entry: entry, hits: hits, games: recent.count)
                guard leg.hitRate >= minHitRate else { continue }
                if best == nil || leg.hitRate > best!.hitRate {
                    best = leg
                }
            }
            if let leg = best { candidates.append(leg) }
        }

        candidates.sort { lhs, rhs in
            if lhs.hitRate != rhs.hitRate { return lhs.hitRate > rhs.hitRate }
            if lhs.entry.confidence != rhs.entry.confidence { return lhs.entry.confidence > rhs.entry.confidence }
            return lhs.entry.avgMinutes > rhs.entry.avgMinutes
        }
        legs = Array(candidates.prefix(legTarget))
    }

    private func addAll() {
        var added = 0
        for leg in legs where router.addToParlay(leg.prop) { added += 1 }
        addedToast = added == legs.count
            ? "Added \(added) legs"
            : "Added \(added) of \(legs.count) — rest already in Picks"
    }

    var body: some View {
        NavigationStack {
            ZStack {
                NightSkyBackground()
                Group {
                    if legs.isEmpty {
                        emptyView
                    } else {
                        legList
                    }
                }
            }
            .navigationTitle("20-Leg Consistency")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .onAppear {
            // Nudge a recompute in case the cached picks are from an older slate,
            // then build legs — the sheet re-builds via computedSignature when
            // the store finishes refreshing.
            let dataService = LocalDataService.shared
            store.computeIfNeeded(
                snapshotID: dataService.snapshotID,
                playerCount: dataService.snapshot?.players.count ?? 0,
                gameCount: dataService.snapshot?.games.count ?? 0,
                logsRevision: dataService.logsRevision
            )
            buildLegs()
        }
        .onChange(of: store.computedSignature) { _, _ in
            buildLegs()
        }
        .overlay(alignment: .bottom) { toastView }
    }

    private var emptyView: some View {
        VStack(spacing: 10) {
            Image(systemName: "chart.bar.doc.horizontal")
                .font(.system(size: 30))
                .foregroundColor(.white.opacity(0.25))
            Text("Not enough consistent legs today")
                .font(.system(size: 14, weight: .bold))
                .foregroundColor(.white)
            Text("Only players with a game today qualify, and they must clear their suggested line in at least 70% of their last 20 games.")
                .font(.system(size: 11))
                .foregroundColor(.white.opacity(0.5))
                .multilineTextAlignment(.center)
        }
        .padding(40)
    }

    private var legList: some View {
        ScrollView {
            VStack(spacing: 12) {
                summaryCard
                ForEach(Array(legs.enumerated()), id: \.element.id) { idx, leg in
                    legRow(leg, rank: idx + 1)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
        }
    }

    private var summaryCard: some View {
        VStack(spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("\(legs.count) legs · most consistent stat, last 20 games")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.white.opacity(0.6))
                    if combinedHitRate > 0 {
                        Text(String(format: "If each leg repeats its rate: 1 in %.0f", 1.0 / combinedHitRate))
                            .font(.system(size: 10))
                            .foregroundColor(.white.opacity(0.4))
                    }
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text("\(Int(round(combinedHitRate * 100)))%")
                        .font(.system(size: 20, weight: .black, design: .rounded))
                        .foregroundColor(.yellow)
                    Text("combined")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(.white.opacity(0.45))
                }
            }

            Button(action: addAll) {
                Label("Add All \(legs.count) to Picks", systemImage: "plus.circle.fill")
                    .font(.system(size: 13, weight: .black, design: .rounded))
                    .foregroundColor(.black)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 11)
                    .background(Color.yellow, in: RoundedRectangle(cornerRadius: 11))
            }
            .buttonStyle(.plain)
        }
        .padding(14)
        .background(Color.skyCard.opacity(0.75), in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.skyBorder, lineWidth: 1))
    }

    private func legRow(_ leg: ConsistencyLeg, rank: Int) -> some View {
        let entry = leg.entry
        let color = statColor(entry.stat)
        return NavigationLink(destination: PlayerStatsView(player: entry.player, game: entry.game)) {
            HStack(spacing: 10) {
            Text("\(rank)")
                .font(.system(size: 10, weight: .black, design: .rounded))
                .foregroundColor(.white.opacity(0.25))
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    Text(entry.player.name)
                        .font(.system(size: 13, weight: .bold))
                        .foregroundColor(.white)
                        .lineLimit(1)
                    if let team = entry.player.team {
                        Text(team)
                            .font(.system(size: 9, weight: .bold))
                            .foregroundColor(.skyBright.opacity(0.6))
                    }
                }
                HStack(spacing: 6) {
                    Text(entry.stat)
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(.black.opacity(0.8))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(color, in: Capsule())
                    Text("\(fmtStat(entry.suggestedLine))+ · sim \(Int(round(entry.confidence * 100)))%")
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                        .foregroundColor(.white.opacity(0.8))
                }
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 3) {
                Text("\(leg.hits)/\(leg.games)")
                    .font(.system(size: 14, weight: .black, design: .rounded))
                    .foregroundColor(.yellow)
                Text("last 20")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundColor(.white.opacity(0.4))
            }

            Image(systemName: "chevron.right")
                .font(.system(size: 10, weight: .bold))
                .foregroundColor(.white.opacity(0.3))
        }
        .padding(12)
        .background(Color.skyCard.opacity(0.6), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.skyBorder, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var toastView: some View {
        if let toast = addedToast {
            Text(toast)
                .font(.system(size: 12, weight: .bold, design: .rounded))
                .foregroundColor(.black)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(Color.yellow.opacity(0.95), in: Capsule())
                .padding(.bottom, 18)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .onAppear {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) {
                        withAnimation { addedToast = nil }
                    }
                }
        }
    }
}

// MARK: - Similar Parlays (baseball-style tab, NBA stats)

private struct NBASimilarLeg: Identifiable {
    let entry: TopPickEntry
    var id: String {
        let gameID = entry.game?.id ?? "nogame"
        let lineKey = String(format: "%.2f", entry.suggestedLine)
        return "\(entry.player.playerID)|\(entry.stat)|\(entry.direction.rawValue)|\(gameID)|\(lineKey)"
    }

    var prop: PlayerProp {
        PlayerProp(
            id: "similar_\(entry.id)",
            gameID: entry.game?.gameID,
            playerName: entry.player.name,
            team: entry.player.team,
            statLabel: entry.stat,
            line: entry.suggestedLine,
            direction: entry.direction,
            overPct: entry.overProbability,
            projectedValue: entry.simResult?.mean
        )
    }
}

private struct NBASimilarParlaySuggestion: Identifiable {
    let legA: NBASimilarLeg
    let legB: NBASimilarLeg
    let fit: Double
    let combinedProb: Double
    let score: Double
    let mixedStatCount: Int

    var id: String { "\(legA.id)_\(legB.id)" }
}

private struct SimilarParlayGameOption: Identifiable {
    let id: String
    let label: String
}

private struct NBASimilarParlayBundle: Identifiable {
    let id: String
    let suggestion: NBASimilarParlaySuggestion
    let legs: [NBASimilarLeg]
}

private enum ParlayGameMixMode: String, CaseIterable {
    case any = "Any Mix"
    case sameGameOnly = "Same Game"
    case crossGameOnly = "Cross Game"
}

private enum ParlayRiskProfile: String, CaseIterable {
    case safe = "Safe"
    case balanced = "Balanced"
    case risky = "Risky"
}

struct SimilarParlayView: View {
    @ObservedObject private var store = TopPicksStore.shared
    @ObservedObject private var router = AppRouter.shared
    @ObservedObject private var dataService = LocalDataService.shared

    @State private var selectedStats: Set<String> = Set(allPlayCategories.map(\.id))
    @State private var selectedGameID: String = "ALL_GAMES"
    @State private var gameMixMode: ParlayGameMixMode = .any
    @State private var selectedRiskProfile: ParlayRiskProfile = .balanced
    @State private var legCount: Int = 2
    @State private var cachedSuggestions: [NBASimilarParlaySuggestion] = []
    @State private var cachedBundles: [NBASimilarParlayBundle] = []

    private func clamp(_ value: Double, _ lo: Double = 0.0, _ hi: Double = 1.0) -> Double {
        min(hi, max(lo, value))
    }

    private func norm(_ value: Double, lo: Double, hi: Double) -> Double {
        guard hi > lo else { return 0.5 }
        return clamp((value - lo) / (hi - lo))
    }

    private func categoryColor(for stat: String) -> Color {
        allPlayCategories.first(where: { $0.id == stat })?.color ?? .skyBright
    }

    private func normalizedPlayerName(_ name: String) -> String {
        name
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "[^a-z0-9]", with: "", options: .regularExpression)
    }

    private func isUnavailable(_ entry: TopPickEntry) -> Bool {
        guard let game = entry.game else { return false }
        let team = (entry.player.team ?? "").uppercased()
        let name = normalizedPlayerName(entry.player.name)
        guard !name.isEmpty else { return false }

        let blockedStatuses: Set<String> = ["OUT", "DOUBTFUL", "QUESTIONABLE", "INJURY", "SUSPENDED", "INACTIVE"]
        let missingPool: [MissingPlayer]
        if team == game.awayTeam.uppercased() {
            missingPool = game.missingAwayPlayers
        } else if team == game.homeTeam.uppercased() {
            missingPool = game.missingHomePlayers
        } else {
            missingPool = game.missingAwayPlayers + game.missingHomePlayers
        }

        for miss in missingPool {
            guard let missName = miss.name else { continue }
            if normalizedPlayerName(missName) != name { continue }
            let status = (miss.status ?? "").uppercased()
            if blockedStatuses.contains(status) {
                return true
            }
        }
        return false
    }

    private func minHitProbability(for profile: ParlayRiskProfile) -> Double {
        switch profile {
        case .safe: return 0.58
        case .balanced: return 0.50
        case .risky: return 0.40
        }
    }

    private func targetLegHitProbability(for profile: ParlayRiskProfile) -> Double {
        switch profile {
        case .safe: return 0.76
        case .balanced: return 0.68
        case .risky: return 0.58
        }
    }

    private func riskDescription(_ profile: ParlayRiskProfile) -> String {
        switch profile {
        case .safe: return "Targets ~76% leg hit rate"
        case .balanced: return "Targets ~68% leg hit rate"
        case .risky: return "Targets ~58% leg hit rate"
        }
    }

    private func probabilityPreference(_ probability: Double, profile: ParlayRiskProfile) -> Double {
        let target = targetLegHitProbability(for: profile)
        let tolerance: Double
        switch profile {
        case .safe:
            tolerance = 0.10
        case .balanced:
            tolerance = 0.12
        case .risky:
            tolerance = 0.14
        }
        return clamp(1.0 - abs(probability - target) / tolerance)
    }

    private func upsideScore(_ entry: TopPickEntry) -> Double {
        let mean = entry.simResult?.mean ?? entry.suggestedLine
        let range = (entry.simResult.map { $0.p90 - $0.p10 }) ?? max(1.0, mean * 0.45)
        let lineBoost = norm(entry.suggestedLine, lo: 0, hi: 45)
        let rangeBoost = norm(range, lo: 0, hi: 35)
        return clamp((lineBoost * 0.55) + (rangeBoost * 0.45))
    }

    private func legPriorityScore(_ entry: TopPickEntry) -> Double {
        let hit = entry.overProbability
        let fitProxy = entry.confidence
        let upside = upsideScore(entry)
        let pref = probabilityPreference(hit, profile: selectedRiskProfile)

        switch selectedRiskProfile {
        case .safe:
            return (pref * 0.56) + (hit * 0.28) + (fitProxy * 0.12) + (upside * 0.04)
        case .balanced:
            return (pref * 0.52) + (hit * 0.24) + (fitProxy * 0.14) + (upside * 0.10)
        case .risky:
            return (pref * 0.44) + (hit * 0.16) + (fitProxy * 0.12) + (upside * 0.28)
        }
    }

    private func dedupedEntries(_ entries: [TopPickEntry]) -> [TopPickEntry] {
        var seen = Set<String>()
        var out: [TopPickEntry] = []
        for entry in entries {
            let key = entry.id
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            out.append(entry)
        }
        return out
    }

    private var allEntries: [TopPickEntry] {
        let detailsByGameID = dataService.gameDetails
        return dedupedEntries(
            store.playerGroups
                .flatMap(\.picks)
                .filter { !isUnavailable($0) }
                // Legs must belong to a game on the current slate that hasn't
                // tipped — never a finished, in-progress, or other-day game.
                .filter { entry in
                    guard let game = entry.game else { return false }
                    return isGameBettable(game, detailsByGameID: detailsByGameID)
                }
                .filter { $0.overProbability >= minHitProbability(for: selectedRiskProfile) }
        )
    }

    private var gameOptions: [SimilarParlayGameOption] {
        var seen = Set<String>()
        var options: [SimilarParlayGameOption] = [.init(id: "ALL_GAMES", label: "All Games")]
        for entry in allEntries {
            guard let game = entry.game else { continue }
            let gid = game.id
            guard !seen.contains(gid) else { continue }
            seen.insert(gid)
            let time = game.gameTime ?? "TBD"
            options.append(.init(id: gid, label: "\(game.awayTeam) @ \(game.homeTeam) · \(time)"))
        }
        return options
    }

    private func matchesGameFilter(_ entry: TopPickEntry) -> Bool {
        if selectedGameID == "ALL_GAMES" { return true }
        return entry.game?.id == selectedGameID
    }

    private func gameID(for entry: TopPickEntry) -> String {
        entry.game?.id ?? ""
    }

    private func pairPassesMixFilter(_ a: TopPickEntry, _ b: TopPickEntry) -> Bool {
        let gA = gameID(for: a)
        let gB = gameID(for: b)

        switch gameMixMode {
        case .any:
            return true
        case .sameGameOnly:
            return !gA.isEmpty && gA == gB
        case .crossGameOnly:
            if selectedGameID != "ALL_GAMES" { return false }
            return !gA.isEmpty && !gB.isEmpty && gA != gB
        }
    }

    private var pool: [NBASimilarLeg] {
        allEntries
            .filter { selectedStats.contains($0.stat) }
            .filter { matchesGameFilter($0) }
            .sorted { lhs, rhs in
                let lScore = legPriorityScore(lhs)
                let rScore = legPriorityScore(rhs)
                if lScore != rScore { return lScore > rScore }
                if lhs.overProbability != rhs.overProbability { return lhs.overProbability > rhs.overProbability }
                if lhs.confidence != rhs.confidence { return lhs.confidence > rhs.confidence }
                return lhs.valueScore > rhs.valueScore
            }
            .prefix(40)
            .map(NBASimilarLeg.init)
    }

    private func fitScore(_ a: TopPickEntry, _ b: TopPickEntry) -> Double {
        let aMean = a.simResult?.mean ?? a.suggestedLine
        let bMean = b.simResult?.mean ?? b.suggestedLine
        let aRange = (a.simResult.map { $0.p90 - $0.p10 }) ?? max(1, aMean * 0.5)
        let bRange = (b.simResult.map { $0.p90 - $0.p10 }) ?? max(1, bMean * 0.5)

        let lineClose = 1.0 - abs(norm(a.suggestedLine, lo: 0, hi: 45) - norm(b.suggestedLine, lo: 0, hi: 45))
        let confClose = 1.0 - abs(a.confidence - b.confidence)
        let meanClose = 1.0 - abs(norm(aMean, lo: 0, hi: 45) - norm(bMean, lo: 0, hi: 45))
        let volClose = 1.0 - abs(norm(aRange, lo: 0, hi: 35) - norm(bRange, lo: 0, hi: 35))
        return clamp(lineClose * 0.25 + confClose * 0.35 + meanClose * 0.25 + volClose * 0.15)
    }

    private var suggestions: [NBASimilarParlaySuggestion] {
        let items = pool
        guard items.count >= 2 else { return [] }

        var out: [NBASimilarParlaySuggestion] = []
        for i in 0..<(items.count - 1) {
            for j in (i + 1)..<items.count {
                let a = items[i]
                let b = items[j]
                let aKey = playerStatKey(for: a)
                let bKey = playerStatKey(for: b)
                guard aKey != bKey else { continue }
                guard pairPassesMixFilter(a.entry, b.entry) else { continue }

                let fit = fitScore(a.entry, b.entry)
                guard fit >= 0.48 else { continue }

                let combined = a.entry.overProbability * b.entry.overProbability
                let statMixBonus = (a.entry.stat == b.entry.stat) ? 0.0 : 0.12
                let upside = (upsideScore(a.entry) + upsideScore(b.entry)) / 2.0
                let prefA = probabilityPreference(a.entry.overProbability, profile: selectedRiskProfile)
                let prefB = probabilityPreference(b.entry.overProbability, profile: selectedRiskProfile)
                let pref = (prefA + prefB) / 2.0
                let score: Double
                switch selectedRiskProfile {
                case .safe:
                    score = (pref * 0.52) + (combined * 0.22) + (fit * 0.18) + (upside * 0.08) + statMixBonus
                case .balanced:
                    score = (pref * 0.48) + (combined * 0.24) + (fit * 0.16) + (upside * 0.12) + statMixBonus
                case .risky:
                    score = (pref * 0.42) + (combined * 0.18) + (fit * 0.14) + (upside * 0.26) + statMixBonus
                }
                let mixedStatCount = Set([a.entry.stat, b.entry.stat]).count

                out.append(
                    NBASimilarParlaySuggestion(
                        legA: a,
                        legB: b,
                        fit: fit,
                        combinedProb: combined,
                        score: score,
                        mixedStatCount: mixedStatCount
                    )
                )
            }
        }

        return out.sorted {
            if $0.score != $1.score { return $0.score > $1.score }
            return $0.combinedProb > $1.combinedProb
        }
    }

    private func refreshCachedSuggestions() {
        // Keep candidate volume bounded so larger leg counts stay responsive.
        let nextSuggestions = Array(suggestions.prefix(140))
        cachedSuggestions = nextSuggestions
        refreshCachedBundles(using: nextSuggestions)
    }

    private func legsToAdd(
        for suggestion: NBASimilarParlaySuggestion,
        count targetCount: Int,
        poolItems: [NBASimilarLeg]
    ) -> [NBASimilarLeg] {
        let target = min(max(targetCount, 2), 6)
        var selected: [NBASimilarLeg] = [suggestion.legA, suggestion.legB]
        guard target > 2 else { return selected }

        let excludedLegIDs = Set(selected.map(\.id))
        let selectedPlayerStatKeys = Set(selected.map(playerStatKey))
        let selectedStatLabels = Set(selected.map { $0.entry.stat })
        let seedGameID = gameID(for: suggestion.legA.entry)

        let candidates = poolItems.filter {
            !excludedLegIDs.contains($0.id) &&
            !selectedPlayerStatKeys.contains(playerStatKey(for: $0))
        }.filter { leg in
            switch gameMixMode {
            case .any:
                return true
            case .sameGameOnly:
                return !seedGameID.isEmpty && gameID(for: leg.entry) == seedGameID
            case .crossGameOnly:
                return selectedGameID == "ALL_GAMES" && gameID(for: leg.entry) != seedGameID
            }
        }

        let ranked = candidates
            .map { leg -> (NBASimilarLeg, Double) in
                let fitA = fitScore(leg.entry, suggestion.legA.entry)
                let fitB = fitScore(leg.entry, suggestion.legB.entry)
                let fit = (fitA + fitB) / 2.0
                let diversityBonus = selectedStatLabels.contains(leg.entry.stat) ? 0.0 : 0.08
                let upside = upsideScore(leg.entry)
                let pref = probabilityPreference(leg.entry.overProbability, profile: selectedRiskProfile)
                let score: Double
                switch selectedRiskProfile {
                case .safe:
                    score = (pref * 0.52) + (leg.entry.overProbability * 0.22) + (fit * 0.18) + (upside * 0.08) + diversityBonus
                case .balanced:
                    score = (pref * 0.48) + (leg.entry.overProbability * 0.24) + (fit * 0.16) + (upside * 0.12) + diversityBonus
                case .risky:
                    score = (pref * 0.40) + (leg.entry.overProbability * 0.16) + (fit * 0.14) + (upside * 0.30) + diversityBonus
                }
                return (leg, score)
            }
            .sorted { $0.1 > $1.1 }
            .prefix(target - 2)
            .map { $0.0 }

        selected.append(contentsOf: ranked)
        return selected
    }

    private func playerStatKey(for leg: NBASimilarLeg) -> String {
        "\(leg.entry.player.playerID)|\(leg.entry.stat)"
    }

    private func combinedProbability(for legs: [NBASimilarLeg]) -> Double {
        legs.reduce(1.0) { $0 * $1.entry.overProbability }
    }

    private func addLegsToPicks(_ legs: [NBASimilarLeg]) {
        for leg in legs {
            _ = router.addToParlay(leg.prop)
        }
    }

    private func legSignature(_ leg: NBASimilarLeg) -> String {
        let gid = leg.entry.game?.id ?? "nogame"
        let side = leg.entry.direction.rawValue
        return "\(gid)|\(leg.entry.player.playerID)|\(leg.entry.stat)|\(String(format: "%.1f", leg.entry.suggestedLine))|\(side)"
    }

    private func parlaySignature(_ legs: [NBASimilarLeg]) -> String {
        legs.map(legSignature).sorted().joined(separator: "||")
    }

    private func buildParlayBundles(from sourceSuggestions: [NBASimilarParlaySuggestion]) -> [NBASimilarParlayBundle] {
        var seen = Set<String>()
        var usedPlayerIDs = Set<String>()
        var bundles: [NBASimilarParlayBundle] = []
        let poolItems = pool

        for suggestion in sourceSuggestions {
            let legs = legsToAdd(for: suggestion, count: legCount, poolItems: poolItems)
            let sig = parlaySignature(legs)
            guard !sig.isEmpty else { continue }
            guard !seen.contains(sig) else { continue }

            // Keep recommendation cards diverse: once a player is used in one
            // displayed parlay, skip other bundles that reuse that player.
            let playerStatKeys = Set(legs.map(playerStatKey))
            if !usedPlayerIDs.isDisjoint(with: playerStatKeys) {
                continue
            }

            seen.insert(sig)
            usedPlayerIDs.formUnion(playerStatKeys)
            bundles.append(
                NBASimilarParlayBundle(
                    id: "\(suggestion.id)|\(sig)",
                    suggestion: suggestion,
                    legs: legs
                )
            )
            if bundles.count >= 14 { break }
        }

        return bundles
    }

    private func refreshCachedBundles(using sourceSuggestions: [NBASimilarParlaySuggestion]? = nil) {
        cachedBundles = buildParlayBundles(from: sourceSuggestions ?? cachedSuggestions)
    }

    private func toggleStat(_ stat: String) {
        if selectedStats.contains(stat) {
            if selectedStats.count == 1 { return }
            selectedStats.remove(stat)
        } else {
            selectedStats.insert(stat)
        }
    }

    private func activeStatSummary() -> String {
        if selectedStats.count == allPlayCategories.count { return "All stats" }
        return "\(selectedStats.count) stats"
    }

    private var currentGameLabel: String {
        gameOptions.first(where: { $0.id == selectedGameID })?.label ?? "All Games"
    }

    var body: some View {
        let snapshotID = dataService.snapshotID
        let playerCount = dataService.snapshot?.players.count ?? 0
        let gameCount = dataService.snapshot?.games.count ?? 0

        NavigationStack {
            ZStack {
                NightSkyBackground()
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 10) {
                            Text("Build mixed parlays")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundColor(.skyBright)
                            Spacer()
                            Text(activeStatSummary())
                                .font(.caption2.weight(.semibold))
                                .foregroundColor(.secondary)
                        }
                        .padding(.horizontal, 14)
                        .padding(.top, 10)

                        HStack(spacing: 10) {
                            Text("Legs")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundColor(.secondary)
                            Picker("Leg count", selection: $legCount) {
                                ForEach(2...6, id: \.self) { count in
                                    Text("\(count)").tag(count)
                                }
                            }
                            .pickerStyle(.menu)
                            .tint(.skyBright)

                            Spacer()

                            Picker("Game", selection: $selectedGameID) {
                                ForEach(gameOptions) { option in
                                    Text(option.label).tag(option.id)
                                }
                            }
                            .pickerStyle(.menu)
                            .tint(.skyBright)
                        }
                        .padding(.horizontal, 14)
                        .padding(.top, 2)

                        Picker("Game Mix", selection: $gameMixMode) {
                            ForEach(ParlayGameMixMode.allCases, id: \.self) { mode in
                                Text(mode.rawValue).tag(mode)
                            }
                        }
                        .pickerStyle(.segmented)
                        .padding(.horizontal, 14)

                        Picker("Risk", selection: $selectedRiskProfile) {
                            ForEach(ParlayRiskProfile.allCases, id: \.self) { profile in
                                Text(profile.rawValue).tag(profile)
                            }
                        }
                        .pickerStyle(.segmented)
                        .padding(.horizontal, 14)

                        Text(riskDescription(selectedRiskProfile))
                            .font(.caption2)
                            .foregroundColor(.white.opacity(0.45))
                            .padding(.horizontal, 14)

                        Text(currentGameLabel)
                            .font(.caption2)
                            .foregroundColor(.white.opacity(0.45))
                            .padding(.horizontal, 14)

                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                Button {
                                    selectedStats = Set(allPlayCategories.map(\.id))
                                } label: {
                                    Text("All")
                                        .font(.system(size: 11, weight: .bold))
                                        .foregroundColor(selectedStats.count == allPlayCategories.count ? .black : .white.opacity(0.8))
                                        .padding(.horizontal, 10)
                                        .padding(.vertical, 6)
                                        .background(
                                            (selectedStats.count == allPlayCategories.count ? Color.skyBright : Color.white.opacity(0.08)),
                                            in: Capsule()
                                        )
                                }
                                .buttonStyle(.plain)

                                ForEach(allPlayCategories) { category in
                                    let active = selectedStats.contains(category.id)
                                    Button {
                                        toggleStat(category.id)
                                    } label: {
                                        HStack(spacing: 4) {
                                            Image(systemName: category.icon)
                                                .font(.system(size: 9, weight: .bold))
                                            Text(category.shortLabel)
                                                .font(.system(size: 11, weight: .bold))
                                        }
                                        .foregroundColor(active ? .black : category.color)
                                        .padding(.horizontal, 10)
                                        .padding(.vertical, 6)
                                        .background(active ? category.color : category.color.opacity(0.14), in: Capsule())
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            .padding(.horizontal, 14)
                        }

                        if cachedBundles.isEmpty {
                            VStack(spacing: 10) {
                                Image(systemName: store.playerGroups.isEmpty ? "calendar.badge.exclamationmark" : "person.2.wave.2.fill")
                                    .font(.system(size: 36))
                                    .foregroundColor(.secondary)
                                if store.playerGroups.isEmpty {
                                    Text("No upcoming games on the slate")
                                        .font(.headline)
                                        .foregroundColor(.secondary)
                                    Text("Today's games have wrapped and the next slate isn't loaded yet. Pull to refresh on the Schedule tab or tap ↻ to re-sync.")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                        .multilineTextAlignment(.center)
                                        .padding(.horizontal, 24)
                                } else {
                                    Text("No parlay combos for this filter")
                                        .font(.headline)
                                        .foregroundColor(.secondary)
                                    Text("Try selecting more stats, switching mix mode, or using all games.")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                        .multilineTextAlignment(.center)
                                }
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 34)
                        } else {
                            ForEach(Array(cachedBundles.enumerated()), id: \.element.id) { idx, bundle in
                                NBASimilarParlayCard(
                                    rank: idx + 1,
                                    suggestion: bundle.suggestion,
                                    legs: bundle.legs,
                                    combinedProb: combinedProbability(for: bundle.legs),
                                    onAdd: {
                                        addLegsToPicks(bundle.legs)
                                        router.selectedTab = 1
                                    },
                                    categoryColor: { stat in categoryColor(for: stat) }
                                )
                                .padding(.horizontal, 14)
                            }
                            .padding(.bottom, 16)
                        }
                    }
                }
            }
            .navigationTitle("Parlay")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        store.computeIfNeeded(
                            snapshotID: dataService.snapshotID,
                            playerCount: dataService.snapshot?.players.count ?? 0,
                            gameCount: dataService.snapshot?.games.count ?? 0,
                            logsRevision: dataService.logsRevision
                        )
                        refreshCachedSuggestions()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                }
            }
        }
        .task {
            store.computeIfNeeded(snapshotID: snapshotID, playerCount: playerCount, gameCount: gameCount, logsRevision: dataService.logsRevision)
            refreshCachedSuggestions()
        }
        .onChange(of: store.computedSignature) { _, _ in
            refreshCachedSuggestions()
        }
        .onChange(of: dataService.snapshotID) { _, _ in
            store.computeIfNeeded(
                snapshotID: dataService.snapshotID,
                playerCount: dataService.snapshot?.players.count ?? 0,
                gameCount: dataService.snapshot?.games.count ?? 0,
                logsRevision: dataService.logsRevision
            )
            refreshCachedSuggestions()
        }
        .onChange(of: selectedGameID) { _, _ in
            refreshCachedSuggestions()
        }
        .onChange(of: selectedStats) { _, _ in
            refreshCachedSuggestions()
        }
        .onChange(of: dataService.logsRevision) { _, _ in
            store.computeIfNeeded(
                snapshotID: dataService.snapshotID,
                playerCount: dataService.snapshot?.players.count ?? 0,
                gameCount: dataService.snapshot?.games.count ?? 0,
                logsRevision: dataService.logsRevision
            )
            refreshCachedSuggestions()
        }
        .onChange(of: legCount) { _, _ in
            refreshCachedBundles()
        }
        .onChange(of: gameMixMode) { _, _ in
            refreshCachedSuggestions()
        }
        .onChange(of: selectedRiskProfile) { _, _ in
            refreshCachedSuggestions()
        }
    }
}

private struct NBASimilarParlayCard: View {
    let rank: Int
    let suggestion: NBASimilarParlaySuggestion
    let legs: [NBASimilarLeg]
    let combinedProb: Double
    let onAdd: () -> Void
    let categoryColor: (String) -> Color

    private func legLine(_ leg: NBASimilarLeg) -> String {
        String(format: "O %.1f %@ · %.0f%%", leg.entry.suggestedLine, leg.entry.stat, leg.entry.overProbability * 100)
    }

    var body: some View {
        let mixCount = Set(legs.map { $0.entry.stat }).count

        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("#\(rank)")
                    .font(.system(size: 11, weight: .black, design: .rounded))
                    .foregroundColor(.yellow)
                Text(String(format: "%.0f%% fit", suggestion.fit * 100))
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(.skyBright)
                Text("• \(mixCount) stats")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.secondary)
                Spacer()
                Text(String(format: "\(legs.count)-leg · %.1f%%", combinedProb * 100))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.secondary)
            }

            Text("Highest-probability plays with mixed stat coverage.")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.secondary)
                .lineLimit(2)

            ForEach(Array(legs.enumerated()), id: \.offset) { index, leg in
                NavigationLink(destination: PlayerStatsView(player: leg.entry.player, game: leg.entry.game)) {
                    HStack(spacing: 10) {
                        Text("\(index + 1)")
                            .font(.system(size: 10, weight: .black))
                            .foregroundColor(categoryColor(leg.entry.stat))
                            .frame(width: 18, height: 18)
                            .background(categoryColor(leg.entry.stat).opacity(0.15), in: Circle())

                        VStack(alignment: .leading, spacing: 2) {
                            Text(leg.entry.player.name)
                                .font(.system(size: 13, weight: .bold))
                                .foregroundColor(.white)
                            Text(legLine(leg))
                                .font(.system(size: 11, weight: .medium))
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(.secondary)
                    }
                }
                .buttonStyle(.plain)

                if index < legs.count - 1 {
                    Divider().background(Color.white.opacity(0.08))
                }
            }

            Button {
                onAdd()
            } label: {
                Label("Add \(legs.count) Leg\(legs.count == 1 ? "" : "s") To Picks", systemImage: "plus.circle.fill")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 9)
                    .background(Color.skyBright.opacity(0.85), in: RoundedRectangle(cornerRadius: 9))
            }
            .buttonStyle(.plain)
        }
        .padding(12)
        .background(Color.skyRow.opacity(0.8), in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Color.skyBright.opacity(rank <= 3 ? 0.45 : 0.18), lineWidth: rank <= 3 ? 1.4 : 1)
        )
    }
}

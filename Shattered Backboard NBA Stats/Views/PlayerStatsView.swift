//
//  PlayerStatsView.swift — Player profile: game log, sparklines, and "Add to Picks".
//
//  Opened by tapping a player name in GamePicksView.
//

import Charts
import SwiftUI

// MARK: - PlayerStatsView

struct PlayerStatsView: View {
    let player: Player
    let game: ScheduleGame?

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @ObservedObject private var dataService = LocalDataService.shared
    @ObservedObject private var router      = AppRouter.shared

    /// Log data owned by this view — never shares state with other player navigations.
    @State private var logs: [GameLog] = []
    @State private var projection: PlayerProjection?
    @State private var simResults: [String: SimulationResult] = [:]
    @State private var activeSheet: PickSheet? = nil
    @State private var chartStat: String = "PTS"
    @State private var avgWindow: Int = 0  // 0 = season; N = last N games
    @State private var customLines: [String: Double] = [:]  // per-stat user-adjusted line
    @State private var matchup: DefenderMatchup? = nil

    private let allStats    = ["PTS", "REB", "AST", "PR", "PA", "RA", "PRA", "FPTS", "3PM", "FTM", "STL", "BLK", "DD", "TD"]
    private let chartStats  = ["PTS", "REB", "AST", "PR", "PA", "RA", "PRA", "FPTS", "3PM", "STL", "BLK", "DD", "TD"]
    private let chartGameOptions  = [10, 15, 20, 30]
    private let avgWindowOptions: [(label: String, window: Int)] = [
        ("L10", 10), ("L15", 15), ("L20", 20), ("Season", 0)
    ]
    @State private var chartGameCount: Int = 15
    #if DEBUG
    @AppStorage("debugForcePlayoffMode") private var forcePlayoffMode: Bool = false
    #endif

    // MARK: - Adjustable line helpers

    /// The active threshold line for `chartStat`. Uses the user-set value if present,
    /// otherwise seeds from the projected line (rounded to nearest 0.5), then falls
    /// back to the recent average.
    private var activeLine: Double {
        if let c = customLines[chartStat] { return c }
        if let proj = projection, proj.value(for: chartStat) > 0 {
            return (proj.value(for: chartStat) * 2).rounded() / 2
        }
        let window = avgWindow == 0 ? logs.count : avgWindow
        let a = avg(values(for: chartStat, gameCount: window).map(\.value))
        return max(0.5, (a * 2).rounded() / 2)
    }

    /// Recency-weighted fraction of the last 15 games the player went over `activeLine`.
    /// Snapped to the nearest 5% for display.
    private var activeLineHitRate: Double {
        let line   = activeLine
        guard line > 0 else { return 0.5 }
        let lambda = 0.04
        var sumW = 0.0, sumHit = 0.0, idx = 0
        for log in logs.prefix(15) {
            let v = log.value(for: chartStat)
            let w = exp(-Double(idx) * lambda)
            sumW   += w
            sumHit += w * (v > line ? 1.0 : 0.0)
            idx    += 1
        }
        guard sumW > 0 else { return 0.5 }
        return ((sumHit / sumW) * 20).rounded() / 20
    }

    /// Season low for chartStat, snapped down to nearest 0.5 (min 0.5).
    private var sliderMin: Double {
        let vals = values(for: chartStat, gameCount: logs.count).map(\.value).filter { $0 > 0 }
        guard let lo = vals.min() else { return 0.5 }
        return max(0.5, floor(lo * 2) / 2)
    }

    /// Max of season high and 1.5× projection, snapped up to nearest 0.5.
    private var sliderMax: Double {
        let vals = values(for: chartStat, gameCount: logs.count).map(\.value)
        let seasonHigh = vals.max() ?? 0
        let projHigh   = (projection?.value(for: chartStat) ?? 0) * 1.5
        let raw = max(seasonHigh, projHigh, sliderMin + 1.0)
        return ceil(raw * 2) / 2
    }

    private var sliderRange: ClosedRange<Double> { sliderMin...sliderMax }

    // MARK: - Body

    var body: some View {
        ZStack {
            NightSkyBackground()
            ScrollView {
                VStack(spacing: 16) {
                    playerHeader
                    if !logs.isEmpty {
                        statBarCard
                    }
                    if let proj = projection {
                        defenderMatchupChip
                        bestBetInsightCard(proj: proj)
                        projectionRangeCard(proj: proj)
                        trendContextCard(proj: proj)
                    }
                    addPicksSection
                    gameLogSection
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 32)
            }
        }
        .navigationTitle(player.name)
        .navigationBarTitleDisplayMode(.inline)
        .task { await loadLogs() }
        #if DEBUG
        .onChange(of: forcePlayoffMode) { _, _ in Task { await loadLogs() } }
        #endif
        .sheet(item: $activeSheet) { sheet in
            LinePickerSheet(sheet: sheet, playerName: player.name) { prop in
                _ = router.addToParlay(prop)
            }
        }
    }

    // MARK: - Data loading

    private func buildProjectionContext() -> ProjectionContext {
        let cachedLogs = dataService.localLogs(playerID: player.playerID)
        let minutesRisk: Double = {
            let mins3 = Array(cachedLogs.prefix(3)).map(\.min)
            let mins10 = Array(cachedLogs.prefix(10)).map(\.min)
            guard mins3.count >= 2, mins10.count >= 5 else { return 0.0 }
            let m3 = mins3.reduce(0, +) / Double(mins3.count)
            let m10 = mins10.reduce(0, +) / Double(mins10.count)
            guard m10 > 0 else { return 0.0 }
            if m3 < 16 { return 0.55 }
            if m3 < 22 { return 0.30 }
            if m3 < m10 * 0.85 { return 0.20 }
            return 0.0
        }()

        let statusRisk: Double = {
            guard let g = game else { return 0.0 }
            let pool = (g.missingAwayPlayers + g.missingHomePlayers)
            guard let miss = pool.first(where: { ($0.name ?? "").caseInsensitiveCompare(player.name) == .orderedSame }) else {
                return 0.0
            }
            switch (miss.status ?? "").uppercased() {
            case "OUT":          return 1.0
            case "DOUBTFUL":     return 0.75
            case "QUESTIONABLE": return 0.45
            default:              return 0.0
            }
        }()

        let availabilityRisk = min(1.0, max(statusRisk, minutesRisk))

        if let g = game {
            let isHome   = (player.team ?? "").uppercased() == g.homeTeam.uppercased()
            let opponent = isHome ? g.awayTeam : g.homeTeam
            let forced: Bool = {
                #if DEBUG
                return forcePlayoffMode
                #else
                return false
                #endif
            }()
            let details = dataService.gameDetails[g.gameID ?? g.id]
            return ProjectionContext(opponent: opponent, isHome: isHome,
                                    isPlayoffs: forced || (details?.isPlayoff ?? g.isPlayoffGame),
                                    isFirstRound: forced || (details?.isFirstRound ?? g.isFirstRound),
                                    gameDate: g.date,
                                    availabilityRisk: availabilityRisk,
                                    playerPosition: player.position,
                                    defenderMatchup: matchup)
        } else {
            let forced: Bool = {
                #if DEBUG
                return forcePlayoffMode
                #else
                return false
                #endif
            }()
            return ProjectionContext(opponent: nil, isHome: nil,
                                    isPlayoffs: forced, isFirstRound: forced,
                                    gameDate: isoToday(),
                                    availabilityRisk: availabilityRisk)
        }
    }

    private func loadLogs() async {
        // Individual-defender matchup (opposing same-position starter), if scheduled.
        if let g = game {
            matchup = MatchupDefenseEvaluator.cached(player: player, game: g, dataService: dataService)
        } else {
            matchup = nil
        }
        let ctx = buildProjectionContext()
        let cached = dataService.localLogs(playerID: player.playerID)
        guard !cached.isEmpty else {
            // No local data yet — the daily background sync (fetchAll) will populate it.
            return
        }
        logs = cached
        projection = PredictionEngine.shared.project(player: player, logs: logs, context: ctx)

        // Determine opponent for defensive volatility adjustment
        let opponent: String? = game.map { g in
            (player.team ?? "").uppercased() == g.awayTeam.uppercased() ? g.homeTeam : g.awayTeam
        }

        // Run Monte Carlo simulations for all major stats (synchronous — completes in microseconds).
        if let proj = projection {
            var results: [String: SimulationResult] = [:]
            for stat in ["PTS", "REB", "AST", "PRA", "FPTS", "3PM", "STL", "BLK"] {
                let mean = proj.value(for: stat)
                guard mean > 0 else { continue }
                results[stat] = SimulationEngine.shared.simulatePlayerStat(
                    playerID: player.playerID,
                    stat: stat,
                    logs: logs,
                    projectedMean: mean,
                    opponent: opponent,
                    defenderMatchup: matchup
                )
            }
            simResults = results
        }
    }

    private func isoToday() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone   = TimeZone(identifier: "UTC")
        return f.string(from: Date())
    }

    // MARK: - Player header

    private var playerHeader: some View {
        HStack(alignment: .top, spacing: 14) {
            ZStack {
                Circle().fill(Color.skyMid).frame(width: 52, height: 52)
                Text(initials)
                    .font(.headline.bold())
                    .foregroundColor(.skyBright)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text(player.name)
                    .font(playerNameFont)
                    .foregroundColor(.white)
                    .lineLimit(2)
                    .minimumScaleFactor(0.88)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 6) {
                    if let team = player.team {
                        Text(team).font(.caption.bold()).foregroundColor(.skyBright)
                    }
                    if let pos = player.position, !pos.isEmpty {
                        Text("·").foregroundColor(.white.opacity(0.3))
                        Text(pos).font(.caption).foregroundColor(.white.opacity(0.5))
                    }
                }
                if let label = projection?.streakLabel {
                    Text(label)
                        .font(.system(size: 10, weight: .semibold))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(Color.white.opacity(0.12), in: Capsule())
                }
                if let advanced = dataService.playerAdvancedMap[player.playerID] {
                    PlayerUsageBadge(
                        usagePct: advanced.estimatedUsagePct,
                        possessionsPer36: advanced.possessionsUsedPer36,
                        games: advanced.games
                    )
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .trailing, spacing: 8) {
                Button {
                    router.toggleWatch(playerID: player.playerID)
                } label: {
                    Image(systemName: router.isWatched(playerID: player.playerID) ? "bell.fill" : "bell")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(router.isWatched(playerID: player.playerID) ? .green : .white.opacity(0.5))
                        .padding(8)
                        .background(Color.white.opacity(0.08), in: Circle())
                }
                .buttonStyle(.plain)

                // Averages pill
                if !logs.isEmpty {
                    VStack(alignment: .trailing, spacing: 3) {
                        let avgPts = avg(logs.compactMap(\.pts))
                        let avgReb = avg(logs.compactMap(\.reb))
                        let avgAst = avg(logs.compactMap(\.ast))
                        statBubble(avgPts, label: "PPG")
                        HStack(spacing: 6) {
                            statBubble(avgReb, label: "RPG")
                            statBubble(avgAst, label: "APG")
                        }
                    }
                }
            }
        }
        .padding(14)
        .background(Color.skyCard, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.skyBorder, lineWidth: 1))
    }

    private var playerNameFont: Font {
        if horizontalSizeClass == .compact {
            return .system(size: 20, weight: .bold, design: .rounded)
        }
        return .system(size: 22, weight: .bold, design: .rounded)
    }

    private func statBubble(_ value: Double, label: String) -> some View {
        HStack(spacing: 3) {
            Text(String(format: "%.1f", value))
                .font(.system(size: 11, weight: .bold))
                .foregroundColor(.white)
            Text(label)
                .font(.system(size: 9))
                .foregroundColor(.white.opacity(0.4))
        }
    }

    private var initials: String {
        player.name.split(separator: " ")
            .compactMap { $0.first }.map(String.init).joined()
    }

    private func avg(_ values: [Double]) -> Double {
        values.isEmpty ? 0 : values.reduce(0, +) / Double(values.count)
    }

    // MARK: - Stat bar chart card

    private func values(for stat: String, gameCount: Int) -> [(date: String, value: Double)] {
        Array(logs.prefix(gameCount).reversed()).map { log in
            let val: Double
            switch stat {
            case "PTS":  val = log.pts     ?? 0
            case "REB":  val = log.reb     ?? 0
            case "AST":  val = log.ast     ?? 0
            case "3PM":  val = log.threepm ?? 0
            case "PR":   val = (log.pts ?? 0) + (log.reb ?? 0)
            case "PA":   val = (log.pts ?? 0) + (log.ast ?? 0)
            case "RA":   val = (log.reb ?? 0) + (log.ast ?? 0)
            case "PRA":  val = (log.pts ?? 0) + (log.reb ?? 0) + (log.ast ?? 0)
            case "FPTS": val = log.fantasyScore
            case "STL":  val = log.stl ?? 0
            case "BLK":  val = log.blk ?? 0
            case "DD":
                let ddCats = [log.pts ?? 0, log.reb ?? 0, log.ast ?? 0].filter { $0 >= 10 }.count
                val = ddCats >= 2 ? 1.0 : 0.0
            case "TD":
                let tdCats = [log.pts ?? 0, log.reb ?? 0, log.ast ?? 0].filter { $0 >= 10 }.count
                val = tdCats >= 3 ? 1.0 : 0.0
            default:     val = 0
            }
            // Trim to M/D (no leading zeros) for axis labels
            let parts = log.gameDate.split(separator: "-")
            let label: String
            if parts.count == 3, let m = Int(parts[1]), let d = Int(parts[2]) {
                label = "\(m)/\(d)"
            } else {
                label = String(log.gameDate.dropFirst(5)).replacingOccurrences(of: "-", with: "/")
            }
            return (date: label, value: val)
        }
    }

    private var statBarCard: some View {
        let entries  = values(for: chartStat, gameCount: chartGameCount)
        let vals     = entries.map(\.value)
        let maxVal   = vals.max() ?? 1
        // Y-axis ceiling: at least 10% above the max bar, minimum sensible floor per stat
        let statFloor: Double = ["STL","BLK","3PM"].contains(chartStat) ? 4
                               : ["DD","TD"].contains(chartStat) ? 1.5
                               : 10
        let yMax     = max(statFloor, max(activeLine * 1.1, maxVal * 1.15))
        let barColor = statColor(chartStat)

        return VStack(alignment: .leading, spacing: 10) {

            // Header row — shows active line + hit rate
            HStack {
                Label("Last \(min(chartGameCount, logs.count)) Games", systemImage: "chart.bar.fill")
                    .font(.caption.bold())
                    .foregroundColor(.skyBright)
                Spacer()
                let hitPct = Int(round(activeLineHitRate * 100))
                let hitColor: Color = activeLineHitRate >= 0.70 ? .green
                                    : activeLineHitRate >= 0.55 ? .skyBright : .orange
                Text("OVER \(activeLine.cleanLine)  ·  \(hitPct)%")
                    .font(.caption2.bold())
                    .foregroundColor(hitColor)
            }

            // Stat picker
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(chartStats, id: \.self) { stat in
                        Button {
                            withAnimation(.easeInOut(duration: 0.2)) { chartStat = stat }
                            haptic(.light)
                        } label: {
                            Text(stat)
                                .font(.caption2.bold())
                                .foregroundColor(chartStat == stat ? .skyDeep : .white.opacity(0.6))
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background(
                                    chartStat == stat ? Color.skyBright : Color.white.opacity(0.08),
                                    in: Capsule()
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            // Game count picker
            HStack(spacing: 0) {
                ForEach(chartGameOptions, id: \.self) { n in
                    Button {
                        withAnimation(.easeInOut(duration: 0.15)) { chartGameCount = n }
                        haptic(.light)
                    } label: {
                        Text("L\(n)")
                            .font(.system(size: 11, weight: .bold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 5)
                            .foregroundColor(chartGameCount == n ? .skyDeep : .white.opacity(0.5))
                            .background(
                                chartGameCount == n ? Color.skyBright.opacity(0.85) : Color.clear,
                                in: RoundedRectangle(cornerRadius: 6)
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(3)
            .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))

            // Average line picker
            HStack(spacing: 0) {
                Text("Avg line:")
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.4))
                    .padding(.trailing, 6)
                ForEach(avgWindowOptions, id: \.window) { opt in
                    Button {
                        withAnimation(.easeInOut(duration: 0.15)) { avgWindow = opt.window }
                        haptic(.light)
                    } label: {
                        Text(opt.label)
                            .font(.system(size: 11, weight: .bold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 5)
                            .foregroundColor(avgWindow == opt.window ? .skyDeep : .white.opacity(0.5))
                            .background(
                                avgWindow == opt.window ? Color.skyBright.opacity(0.85) : Color.clear,
                                in: RoundedRectangle(cornerRadius: 6)
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(3)
            .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))

            // Slider line adjuster
            let hitPct2   = Int(round(activeLineHitRate * 100))
            let hitColor2: Color = activeLineHitRate >= 0.70 ? .green
                                 : activeLineHitRate >= 0.55 ? .skyBright : .orange
            VStack(spacing: 6) {
                HStack(spacing: 8) {
                    Text("Line")
                        .font(.system(size: 11))
                        .foregroundColor(.white.opacity(0.4))
                    Text(activeLine.cleanLine)
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(.white)
                        .contentTransition(.numericText())
                        .animation(.easeInOut(duration: 0.1), value: activeLine)
                    Spacer()
                    Text("\(hitPct2)% over")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(hitColor2)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(hitColor2.opacity(0.15), in: Capsule())
                    if customLines[chartStat] != nil {
                        Button {
                            customLines.removeValue(forKey: chartStat)
                            haptic(.light)
                        } label: {
                            Text("Reset")
                                .font(.system(size: 10))
                                .foregroundColor(.white.opacity(0.35))
                        }
                        .buttonStyle(.plain)
                    }
                }
                Slider(
                    value: Binding(
                        get: { activeLine },
                        set: { raw in
                            let snapped = max(sliderMin, min(sliderMax, (raw * 2).rounded() / 2))
                            if snapped != customLines[chartStat] {
                                customLines[chartStat] = snapped
                                haptic(.light)
                            }
                        }
                    ),
                    in: sliderRange,
                    step: 0.5
                )
                .tint(.skyBright)
                HStack {
                    Text(sliderMin.cleanLine)
                        .font(.system(size: 9))
                        .foregroundColor(.white.opacity(0.25))
                    Spacer()
                    Text(sliderMax.cleanLine)
                        .font(.system(size: 9))
                        .foregroundColor(.white.opacity(0.25))
                }
            }

            // Bar chart with date labels and dynamic y scale
            Chart {
                ForEach(Array(entries.enumerated()), id: \.offset) { _, entry in
                    BarMark(
                        x: .value("Date", entry.date),
                        y: .value(chartStat, entry.value)
                    )
                    .foregroundStyle(barColor.opacity(0.85))
                    .cornerRadius(3)
                }
                RuleMark(y: .value("Line", activeLine))
                    .foregroundStyle(Color.skyBright.opacity(0.55))
                    .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                    .annotation(position: .trailing, alignment: .leading) {
                        Text(activeLine.cleanLine)
                            .font(.system(size: 8, weight: .bold))
                            .foregroundColor(.skyBright.opacity(0.7))
                    }
            }
            // Date labels drawn by Charts itself — one per bar, centered under it
            .chartXAxis {
                AxisMarks { value in
                    AxisValueLabel {
                        if let d = value.as(String.self) {
                            Text(d)
                                .font(.system(size: 8, weight: .medium))
                                .foregroundStyle(Color.white.opacity(0.5))
                                .rotationEffect(.degrees(-90))
                                .offset(x: 2)
                        }
                    }
                }
            }
            .chartYScale(domain: 0...yMax)
            .chartYAxis {
                AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) {
                    AxisGridLine().foregroundStyle(Color.white.opacity(0.06))
                    AxisValueLabel()
                        .font(.system(size: 9))
                        .foregroundStyle(Color.white.opacity(0.35))
                }
            }
            .chartPlotStyle { $0.background(Color.clear) }
            .frame(height: 210)
            .id("\(chartStat)_\(chartGameCount)_\(avgWindow)")
        }
        .padding(14)
        .background(Color.skyCard, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.skyBorder, lineWidth: 1))
    }

    // MARK: - Add to Picks section

    private var addPicksSection: some View {
        VStack(spacing: 0) {
            HStack {
                Label("Add to Picks", systemImage: "plus.circle.fill")
                    .font(.caption.bold())
                    .foregroundColor(.skyBright)
                Spacer()
                Text("Tap stat to choose a line")
                    .font(.caption2)
                    .foregroundColor(.white.opacity(0.3))
            }
            .padding(.horizontal, 14)
            .padding(.top, 14)
            .padding(.bottom, 8)

            Divider().background(Color.skyBorder)

            VStack(spacing: 0) {
                ForEach(allStats, id: \.self) { stat in
                    statPickRow(stat)
                    if stat != allStats.last {
                        Divider().background(Color.white.opacity(0.05)).padding(.leading, 14)
                    }
                }
            }
            .padding(.bottom, 4)
        }
        .background(Color.skyCard, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.skyBorder, lineWidth: 1))
    }

    @ViewBuilder
    private func statPickRow(_ stat: String) -> some View {
        let engineLine = projection?.line(for: stat)  ?? 0
        let engineProj = projection?.value(for: stat) ?? 0
        let engineConf = projection?.confidence(for: stat) ?? 0
        let hasData    = (projection?.gameCount ?? 0) > 0

        // Build a stable prop for parlay tracking
        let enginePropID = "\(game?.gameID ?? "engine")_\(player.name)_\(stat)"
        let engineProp: PlayerProp? = hasData ? PlayerProp(
            id: enginePropID,
            gameID: game?.gameID,
            playerName: player.name,
            team: player.team,
            statLabel: stat,
            line: max(0.5, engineLine),
            direction: .over,
            overPct: engineConf,
            projectedValue: engineProj > 0 ? engineProj : nil
        ) : nil

        let inParlay = engineProp.map { router.isInParlay($0) } ?? false

        // Compute L10 average for this stat
        let recentAvg: Double? = {
            let values: [Double]
            switch stat {
            case "PTS":  values = logs.prefix(10).compactMap(\.pts)
            case "REB":  values = logs.prefix(10).compactMap(\.reb)
            case "AST":  values = logs.prefix(10).compactMap(\.ast)
            case "PR":   values = logs.prefix(10).map { ($0.pts ?? 0) + ($0.reb ?? 0) }
            case "PA":   values = logs.prefix(10).map { ($0.pts ?? 0) + ($0.ast ?? 0) }
            case "RA":   values = logs.prefix(10).map { ($0.reb ?? 0) + ($0.ast ?? 0) }
            case "3PM":  values = logs.prefix(10).compactMap(\.threepm)
            case "FTM":  values = logs.prefix(10).compactMap(\.ftm)
            case "PRA":  values = logs.prefix(10).map { ($0.pts ?? 0) + ($0.reb ?? 0) + ($0.ast ?? 0) }
            case "FPTS": values = logs.prefix(10).map(\.fantasyScore)
            case "STL":  values = logs.prefix(10).compactMap(\.stl)
            case "BLK":  values = logs.prefix(10).compactMap(\.blk)
            default:     values = []
            }
            return values.isEmpty ? nil : values.reduce(0, +) / Double(values.count)
        }()

        HStack(spacing: 10) {
            Text(stat)
                .font(.caption2.bold())
                .lineLimit(1)
                .fixedSize()
                .foregroundColor(.black.opacity(0.85))
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(statColor(stat), in: Capsule())
                .frame(minWidth: 44)

            VStack(alignment: .leading, spacing: 1) {
                if hasData && engineLine > 0 {
                    Text("OVER \(engineLine.cleanLine)")
                        .font(.caption.bold())
                        .foregroundColor(.white.opacity(0.85))
                    if ["DD","TD"].contains(stat) {
                        Text("\(Int(round(engineConf * 100)))% of recent games")
                            .font(.system(size: 9))
                            .foregroundColor(Color.skyBright.opacity(0.65))
                    } else {
                        Text("proj \(engineProj.cleanLine)")
                            .font(.system(size: 9))
                            .foregroundColor(Color.skyBright.opacity(0.65))
                    }
                } else {
                    Text("Set your line")
                        .font(.caption)
                        .foregroundColor(.white.opacity(0.3))
                }
                if let ra = recentAvg {
                    Text("L10 avg: \(String(format: "%.1f", ra))")
                        .font(.system(size: 9))
                        .foregroundColor(.white.opacity(0.3))
                }
            }

            Spacer()

            if hasData {
                let color: Color = engineConf >= 0.80 ? .green : engineConf >= 0.65 ? .skyBright : .orange
                Text("\(Int(round(engineConf * 100)))%")
                    .font(.caption.bold())
                    .foregroundColor(color)
                    .frame(width: 36, alignment: .trailing)
            }

            if inParlay, let ep = engineProp {
                Button { router.removeFromParlay(ep) } label: {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.title3).foregroundColor(.skyBright)
                }
            } else {
                Button {
                    haptic(.light)
                    let defLine = max(0.5, engineLine > 0 ? engineLine : defaultLine(stat))
                    activeSheet = PickSheet(
                        stat: stat,
                        serverProp: engineProp,
                        defaultLine: defLine,
                        defaultDirection: .over,
                        gameID: game?.gameID
                    )
                } label: {
                    Image(systemName: "plus.circle.fill")
                        .font(.title3).foregroundColor(.skyBright)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(inParlay ? Color.skyBright.opacity(0.08) : Color.clear)
    }

    // MARK: - Best Bet insight

    /// Scores core single stats by hit-rate confidence PLUS matchup edge
    /// (projection vs season average), penalized where the opposing defender
    /// suppresses that stat. Returns the winner + reason.
    private func bestBet(for proj: PlayerProjection) -> (stat: String, reason: String)? {
        guard logs.count >= 3 else { return nil }

        let statKeyPaths: [(String, KeyPath<GameLog, Double?>)] = [
            ("PTS", \.pts), ("REB", \.reb), ("AST", \.ast),
            ("3PM", \.threepm), ("STL", \.stl), ("BLK", \.blk)
        ]

        var scored: [(stat: String, projected: Double, score: Double, edge: Double)] = []
        for (stat, kp) in statKeyPaths {
            let value = proj.value(for: stat)
            guard value > 0.5 else { continue }
            // Season average for this stat (all logs, not just the recent window).
            let vals = logs.compactMap { $0[keyPath: kp] }
            let avg = vals.isEmpty ? 0 : vals.reduce(0, +) / Double(vals.count)
            // Matchup edge: how far tonight's projection sits above/below the
            // season average (the engine already baked opponent & defender in).
            let edge = avg > 0 ? max(-0.10, min(0.10, ((value / avg) - 1.0) * 0.30)) : 0
            var score = proj.confidence(for: stat) + edge
            // Defender suppression mirrors the engine's projection cut.
            if let m = matchup {
                score *= max(0.6, m.multiplier(for: stat))
            }
            scored.append((stat, value, score, edge))
        }
        guard let best = scored.max(by: {
                    $0.score != $1.score ? $0.score < $1.score : $0.edge < $1.edge
                }),
              let worst = scored.min(by: { $0.score < $1.score }),
              best.stat != worst.stat,
              best.score >= 0.45 else { return nil }

        // Build the reason sentence from real signals.
        var parts: [String] = []
        let pct = Int(round(best.score * 100))

        if let m = matchup, m.isSignificant {
            let suppressed = ["PTS", "REB", "AST", "3PM", "STL", "BLK"]
                .filter { ($0 == "REB" || $0 == "PTS" || $0 == "FPTS")
                          && m.multiplier(for: $0) < 1.0 }
            if let hitStat = suppressed.first(where: { $0 == worst.stat }) ?? suppressed.first {
                parts.append("the opposing \(matchupPositionLabel) (\(m.defenderName)) caps \(hitStat)")
            }
        }
        if best.edge > 0.02 {
            let pctAbove = Int(round((best.projected / max(0.1, seasonAvg(best.stat)) - 1.0) * 100))
            parts.append("tonight projects \(pctAbove)% above the season average")
        } else if worst.score < best.score - 0.12 {
            parts.append("\(worst.stat) rates weakest tonight")
        }

        switch proj.streakFactor {
        case 0.3...:  parts.append("trending up (hot L3 vs L10)")
        case ..<(-0.3): parts.append("recent form is cold — floor matters more than ceiling")
        default: break
        }
        if proj.volatility < 0.25 && parts.isEmpty {
            parts.append(String(format: "most consistent stat (%.0f%% recent rate)", best.score * 100))
        }
        if parts.isEmpty {
            parts.append(String(format: "%d%% recent hit rate vs the line", pct))
        }

        let reason = parts.prefix(2).joined(separator: ", ")
        return (best.stat, "Take \(best.stat) — \(reason). Projected \(String(format: "%.1f", best.projected)).")
    }

    private var matchupPositionLabel: String {
        guard let pos = matchup?.defenderPosition?.uppercased() else { return "defender" }
        return pos.hasPrefix("C") ? "center" : pos.hasPrefix("G") ? "guard" : "forward"
    }

    /// Full-log season average for a core stat label.
    private func seasonAvg(_ stat: String) -> Double {
        let kp: KeyPath<GameLog, Double?>? = {
            switch stat {
            case "PTS": return \.pts
            case "REB": return \.reb
            case "AST": return \.ast
            case "3PM": return \.threepm
            case "STL": return \.stl
            case "BLK": return \.blk
            default:    return nil
            }
        }()
        guard let kp else { return 0 }
        let vals = logs.compactMap { $0[keyPath: kp] }
        guard !vals.isEmpty else { return 0 }
        return vals.reduce(0, +) / Double(vals.count)
    }

    /// Short plain-English card explaining which stat is the strongest play and why.
    @ViewBuilder
    private func bestBetInsightCard(proj: PlayerProjection) -> some View {
        if let bet = bestBet(for: proj) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: "lightbulb.fill")
                        .font(.caption.bold())
                        .foregroundColor(.skyBright)
                    Text("BEST BET — \(bet.stat)")
                        .font(.caption.bold())
                        .foregroundColor(.skyBright)
                    Spacer()
                    Text("\(Int(round(proj.confidence(for: bet.stat) * 100)))%")
                        .font(.caption2.bold())
                        .foregroundColor(.green)
                }
                Text(bet.reason)
                    .font(.caption)
                    .foregroundColor(.white.opacity(0.65))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(12)
            .background(Color.skyBright.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.skyBright.opacity(0.25), lineWidth: 1))
        }
    }

    // MARK: - Defender matchup chip

    /// Warns when the opposing same-position starter is a strong interior defender.
    @ViewBuilder
    private var defenderMatchupChip: some View {
        if let m = matchup, m.isSignificant {
            HStack(spacing: 8) {
                Image(systemName: "shield.lefthalf.filled")
                    .font(.caption.bold())
                    .foregroundColor(.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Matchup risk — \(m.riskLabel)")
                        .font(.caption.bold()).foregroundColor(.orange)
                    Text("vs \(m.defenderName)\(m.defenderPosition.map { " (\($0))" } ?? "") — projections adjusted")
                        .font(.caption2).foregroundColor(.white.opacity(0.5))
                }
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.orange.opacity(0.35), lineWidth: 1))
        }
    }

    // MARK: - Game log section

    @ViewBuilder
    private var gameLogSection: some View {
        if logs.isEmpty {
            HStack {
                Image(systemName: "clock.badge.questionmark")
                    .foregroundColor(.white.opacity(0.25))
                Text("No recent game logs in database")
                    .font(.caption).foregroundColor(.white.opacity(0.3))
            }
            .frame(maxWidth: .infinity)
            .padding(20)
            .background(Color.skyCard, in: RoundedRectangle(cornerRadius: 14))
        } else {
            VStack(spacing: 0) {
                HStack {
                    Label("Recent Games", systemImage: "chart.bar.fill")
                        .font(.caption.bold()).foregroundColor(.skyBright)
                    Spacer()
                    Text("Last \(logs.count)")
                        .font(.caption2).foregroundColor(.white.opacity(0.3))
                }
                .padding(.horizontal, 14)
                .padding(.top, 12)
                .padding(.bottom, 6)

                // Legend for matchup highlights
                if let opp = upcomingOpponent {
                    HStack(spacing: 5) {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(Color.skyBright.opacity(0.22))
                            .frame(width: 12, height: 12)
                            .overlay(RoundedRectangle(cornerRadius: 2).stroke(Color.skyBright.opacity(0.6), lineWidth: 1))
                        Text("vs \(opp) — next matchup")
                            .font(.caption2).foregroundColor(.white.opacity(0.45))
                        Spacer()
                    }
                    .padding(.horizontal, 14)
                    .padding(.bottom, 4)
                }

                Divider().background(Color.skyBorder)
                logHeaderRow
                Divider().background(Color.white.opacity(0.06))

                ForEach(logs.prefix(15)) { log in
                    logDataRow(log)
                    if log.id != logs.prefix(15).last?.id {
                        Divider().background(Color.white.opacity(0.04))
                    }
                }
                .padding(.bottom, 4)
            }
            .background(Color.skyCard, in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.skyBorder, lineWidth: 1))
        }
    }

    private var logHeaderRow: some View {
        HStack(spacing: 0) {
            Text("DATE")  .frame(width: 52, alignment: .leading)
            Text("OPP")   .frame(maxWidth: .infinity, alignment: .leading)
            Text("PTS")   .frame(width: 34, alignment: .trailing)
            Text("REB")   .frame(width: 34, alignment: .trailing)
            Text("AST")   .frame(width: 34, alignment: .trailing)
            Text("3PM")   .frame(width: 34, alignment: .trailing)
            Text("STL")   .frame(width: 34, alignment: .trailing)
            Text("BLK")   .frame(width: 34, alignment: .trailing)
        }
        .font(.system(size: 9, weight: .bold))
        .foregroundColor(.white.opacity(0.35))
        .padding(.horizontal, 14)
        .padding(.vertical, 5)
    }

    /// Opponent in the player's upcoming game, if one is scheduled.
    private var upcomingOpponent: String? {
        guard let g = game else { return nil }
        let team = (player.team ?? "").uppercased()
        guard !team.isEmpty else { return nil }
        return team == g.homeTeam.uppercased() ? g.awayTeam.uppercased() : g.homeTeam.uppercased()
    }

    /// True when this historical log row was played against the upcoming opponent.
    private func isMatchupGame(_ log: GameLog) -> Bool {
        guard let opp = upcomingOpponent,
              let logOpp = log.opponent?.uppercased().trimmingCharacters(in: .whitespaces),
              !logOpp.isEmpty else { return false }
        return logOpp == opp || logOpp.hasPrefix(opp)
    }

    private func logDataRow(_ log: GameLog) -> some View {
        let highlighted = isMatchupGame(log)
        return HStack(spacing: 0) {
            Text(String(log.gameDate.dropFirst(5)))
                .frame(width: 52, alignment: .leading)
            HStack(spacing: 4) {
                Text(log.opponent ?? "—")
                if highlighted {
                    Image(systemName: "scope")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundColor(.skyBright)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .lineLimit(1)
            .foregroundColor(highlighted ? .skyBright : nil)
            .fontWeight(highlighted ? .semibold : nil)
            statCell(log.pts,     width: 34)
            statCell(log.reb,     width: 34)
            statCell(log.ast,     width: 34)
            statCell(log.threepm, width: 34)
            statCell(log.stl,     width: 34)
            statCell(log.blk,     width: 34)
        }
        .font(.system(size: 11))
        .foregroundColor(.white.opacity(0.8))
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(
            highlighted
                ? Color.skyBright.opacity(0.10)
                : Color.clear
        )
    }

    private func statCell(_ v: Double?, width: CGFloat = 36) -> some View {
        Text(v.map { $0.truncatingRemainder(dividingBy: 1) == 0
                ? String(Int($0))
                : String(format: "%.1f", $0) } ?? "—")
            .frame(width: width, alignment: .trailing)
    }

    // MARK: - Helpers

    private func defaultLine(_ stat: String) -> Double {
        let pos = (player.position ?? "").uppercased()
        let isG = pos.hasPrefix("PG") || pos.hasPrefix("SG") || pos == "G"
        let isC = pos == "C" || pos == "FC" || pos == "C-F" || pos == "CF"
        switch stat {
        case "PTS":  return isG ? 12.5 : isC ? 9.5  : 10.5
        case "REB":  return isG ? 2.5  : isC ? 7.5  : 5.5
        case "AST":  return isG ? 3.5  : isC ? 1.5  : 2.5
        case "PR":   return isG ? 15.5 : isC ? 16.5 : 16.0
        case "PA":   return isG ? 15.5 : isC ? 11.5 : 14.0
        case "RA":   return isG ? 6.5  : isC ? 9.5  : 8.0
        case "PRA":  return isG ? 17.5 : isC ? 17.5 : 17.5
        case "FPTS": return isG ? 24.5 : isC ? 25.5 : 25.0
        case "3PM":  return isG ? 1.5  : isC ? 0.5  : 1.5
        case "FTM":  return isG ? 2.5  : isC ? 2.5  : 2.5
        case "STL":  return 0.5
        case "BLK":  return isC ? 1.5  : 0.5
        case "DD":   return 0.5
        case "TD":   return 0.5
        default:     return 10.5
        }
    }

    private func statColor(_ stat: String) -> Color { nbaStatColor(stat) }

    // MARK: - Projection Range Card

    /// Shows floor / projection / ceiling for the currently selected stat using
    /// Monte Carlo simulation data. Hidden for binary props (DD, TD).
    @ViewBuilder
    private func projectionRangeCard(proj: PlayerProjection) -> some View {
        let projValue  = proj.value(for: chartStat)
        let simResult  = simResults[chartStat]
        let floorVal   = simResult?.p25 ?? proj.floor(for: chartStat)
        let ceilingVal = simResult?.p75 ?? proj.ceiling(for: chartStat)

        if !["DD", "TD"].contains(chartStat),
           proj.gameCount > 0,
           projValue > 0,
           ceilingVal > 0,
           ceilingVal > floorVal {

            VStack(alignment: .leading, spacing: 10) {

                // Header
                HStack {
                    Label("\(chartStat) Simulation Range", systemImage: "waveform.path.ecg")
                        .font(.caption.bold())
                        .foregroundColor(.skyBright)
                    Spacer()
                    if let streak = proj.streakLabel {
                        Text(streak)
                            .font(.system(size: 10, weight: .semibold))
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(Color.white.opacity(0.12), in: Capsule())
                    }
                }

                // Three-column value row
                HStack(alignment: .bottom) {
                    VStack(spacing: 3) {
                        Text("FLOOR")
                            .font(.system(size: 8, weight: .semibold))
                            .foregroundColor(.white.opacity(0.35))
                            .tracking(0.5)
                        Text(floorVal.cleanLine)
                            .font(.system(size: 15, weight: .bold, design: .rounded))
                            .foregroundColor(.orange.opacity(0.85))
                        Text("P25")
                            .font(.system(size: 8))
                            .foregroundColor(.white.opacity(0.22))
                    }
                    Spacer()
                    VStack(spacing: 3) {
                        Text("PROJECTION")
                            .font(.system(size: 8, weight: .semibold))
                            .foregroundColor(.white.opacity(0.35))
                            .tracking(0.5)
                        Text(projValue.cleanLine)
                            .font(.system(size: 24, weight: .black, design: .rounded))
                            .foregroundColor(.skyBright)
                        Text("ENGINE")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundColor(.skyBright.opacity(0.5))
                            .tracking(0.6)
                    }
                    Spacer()
                    VStack(spacing: 3) {
                        Text("CEILING")
                            .font(.system(size: 8, weight: .semibold))
                            .foregroundColor(.white.opacity(0.35))
                            .tracking(0.5)
                        Text(ceilingVal.cleanLine)
                            .font(.system(size: 15, weight: .bold, design: .rounded))
                            .foregroundColor(.green.opacity(0.85))
                        Text("P75")
                            .font(.system(size: 8))
                            .foregroundColor(.white.opacity(0.22))
                    }
                }
                .padding(.horizontal, 4)

                // Gradient range bar with projection marker
                rangeBar(floor: floorVal, projection: projValue, ceiling: ceilingVal)

                // Footer: volatility + simulation count
                HStack {
                    Label("Vol: \(proj.volatilityLabel)", systemImage: "chart.xyaxis.line")
                        .font(.system(size: 9))
                        .foregroundColor(.white.opacity(0.35))
                    Spacer()
                    if let sim = simResult {
                        Text("n=\(sim.simCount)  ·  P10: \(sim.p10.cleanLine)  P90: \(sim.p90.cleanLine)")
                            .font(.system(size: 9))
                            .foregroundColor(.white.opacity(0.25))
                    }
                }
            }
            .padding(14)
            .background(Color.skyCard, in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.skyBorder, lineWidth: 1))
        }
    }

    /// Horizontal gradient bar showing the simulation range with a dot at the projected value.
    private func rangeBar(floor: Double, projection: Double, ceiling: Double) -> some View {
        GeometryReader { geo in
            let maxDisplay = ceiling * 1.25
            let w          = geo.size.width
            let fX  = CGFloat(floor      / maxDisplay) * w
            let cX  = CGFloat(ceiling    / maxDisplay) * w
            let pX  = CGFloat(projection / maxDisplay) * w

            ZStack(alignment: .leading) {
                // Background track
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color.white.opacity(0.07))
                    .frame(height: 6)

                // Colored range: floor → ceiling
                RoundedRectangle(cornerRadius: 3)
                    .fill(LinearGradient(
                        colors: [.orange.opacity(0.55), .skyBright.opacity(0.65), .green.opacity(0.55)],
                        startPoint: .leading, endPoint: .trailing
                    ))
                    .frame(width: max(4, cX - fX), height: 6)
                    .offset(x: fX)

                // Projection marker dot
                Circle()
                    .fill(Color.skyBright)
                    .frame(width: 13, height: 13)
                    .overlay(Circle().stroke(Color.white.opacity(0.45), lineWidth: 1.5))
                    .offset(x: pX - 6.5, y: -3.5)
            }
        }
        .frame(height: 13)
    }

    // MARK: - Trend context card

    private func trendContextCard(proj: PlayerProjection) -> some View {
        Group {
            if !logs.isEmpty {
                let recent3 = Array(logs.prefix(3))
                let recent10 = Array(logs.prefix(10))
                let l3Pts = recent3.compactMap(\.pts)
                let l10Pts = recent10.compactMap(\.pts)
                let l3Min = recent3.map(\.min)
                let l10Min = recent10.map(\.min)

                let avg3Pts = l3Pts.isEmpty ? 0 : l3Pts.reduce(0, +) / Double(l3Pts.count)
                let avg10Pts = l10Pts.isEmpty ? 0 : l10Pts.reduce(0, +) / Double(l10Pts.count)
                let avg3Min = l3Min.isEmpty ? 0 : l3Min.reduce(0, +) / Double(l3Min.count)
                let avg10Min = l10Min.isEmpty ? 0 : l10Min.reduce(0, +) / Double(l10Min.count)

                let ptsDelta = avg3Pts - avg10Pts
                let minDelta = avg3Min - avg10Min
                let usage3 = avg3Min > 0 ? avg3Pts / avg3Min : 0
                let usage10 = avg10Min > 0 ? avg10Pts / avg10Min : 0
                let usageDelta = usage3 - usage10

                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Label("Trend Context", systemImage: "chart.line.uptrend.xyaxis")
                            .font(.caption.bold())
                            .foregroundColor(.skyBright)
                        Spacer()
                        Text(proj.streakLabel ?? "Neutral")
                            .font(.caption2)
                            .foregroundColor(.white.opacity(0.5))
                    }

                    HStack(spacing: 10) {
                        trendPill(title: "Scoring", value: ptsDelta, unit: "pts")
                        trendPill(title: "Minutes", value: minDelta, unit: "min")
                        trendPill(title: "Efficiency", value: usageDelta, unit: "ppm")
                    }

                    Text("L3 vs L10 baseline helps separate momentum from noise.")
                        .font(.caption2)
                        .foregroundColor(.white.opacity(0.35))
                }
                .padding(14)
                .background(Color.skyCard, in: RoundedRectangle(cornerRadius: 14))
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.skyBorder, lineWidth: 1))
            }
        }
    }

    private func trendPill(title: String, value: Double, unit: String) -> some View {
        let color: Color = value > 0.1 ? .green : value < -0.1 ? .orange : .skyBright
        let sign = value > 0 ? "+" : ""
        return VStack(spacing: 4) {
            Text(title)
                .font(.system(size: 9, weight: .semibold))
                .foregroundColor(.white.opacity(0.45))
            Text("\(sign)\(String(format: "%.1f", value))")
                .font(.system(size: 14, weight: .bold, design: .rounded))
                .foregroundColor(color)
            Text(unit)
                .font(.system(size: 8))
                .foregroundColor(.white.opacity(0.3))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
    }
}

private struct PlayerUsageBadge: View {
    let usagePct: Double?
    let possessionsPer36: Double?
    let games: Int

    var body: some View {
        if let usagePct {
            HStack(spacing: 5) {
                Image(systemName: "chart.pie.fill")
                Text("Usage \(usagePct, specifier: "%.1f")%")
                if let possessionsPer36 {
                    Text("· \(possessionsPer36, specifier: "%.1f") poss/36")
                        .foregroundStyle(.white.opacity(0.55))
                }
            }
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(Color.orange)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Color.orange.opacity(0.14), in: Capsule())
            .accessibilityLabel("Estimated usage \(usagePct, specifier: "%.1f") percent across \(games) games")
        }
    }
}

// MARK: - PickSheet model

struct PickSheet: Identifiable {
    let id = UUID()
    let stat: String
    let serverProp: PlayerProp?
    let defaultLine: Double
    let defaultDirection: PropDirection
    let gameID: String?
}

// MARK: - LinePickerSheet

struct LinePickerSheet: View {
    let sheet: PickSheet
    let playerName: String
    let onAdd: (PlayerProp) -> Void

    @ObservedObject private var router = AppRouter.shared
    @Environment(\.dismiss) private var dismiss
    @State private var line: Double
    @State private var direction: PropDirection
    @State private var showBlocked = false
    @State private var blockedMsg  = ""

    init(sheet: PickSheet, playerName: String, onAdd: @escaping (PlayerProp) -> Void) {
        self.sheet      = sheet
        self.playerName = playerName
        self.onAdd      = onAdd
        _line = State(initialValue: sheet.defaultLine)
        _direction = State(initialValue: sheet.defaultDirection)
    }

    private var builtProp: PlayerProp {
        PlayerProp(
            id: "manual_\(UUID().uuidString)",
            gameID: sheet.serverProp?.gameID ?? sheet.gameID,
            playerName: playerName,
            team: sheet.serverProp?.team,
            statLabel: sheet.stat,
            line: line,
            direction: direction,
            overPct: sheet.serverProp?.overPct,
            projectedValue: sheet.serverProp?.projectedValue
        )
    }

    var body: some View {
        NavigationStack {
            ZStack {
                NightSkyBackground()
                VStack(spacing: 28) {
                    VStack(spacing: 8) {
                        Text(playerName)
                            .font(.title3.bold()).foregroundColor(.white)
                        Text(sheet.stat)
                            .font(.caption.bold()).foregroundColor(.skyDeep)
                            .padding(.horizontal, 14).padding(.vertical, 5)
                            .background(nbaStatColor(sheet.stat), in: Capsule())
                    }
                    .padding(.top, 8)

                    VStack(spacing: 2) {
                        HStack(spacing: 8) {
                            sideChip(.over)
                            sideChip(.under)
                        }
                        Text(direction.rawValue)
                            .font(.caption2.bold())
                            .foregroundColor(.white.opacity(0.4))
                            .tracking(3)
                        Text(line.cleanLine)
                            .font(.system(size: 64, weight: .black, design: .rounded))
                            .foregroundColor(.white)
                            .contentTransition(.numericText())
                            .animation(.easeInOut(duration: 0.1), value: line)
                    }

                    HStack(spacing: 48) {
                        Button {
                            haptic(.light); line = max(0.5, line - 0.5)
                        } label: {
                            Image(systemName: "minus.circle.fill")
                                .font(.system(size: 48)).foregroundColor(.skyBright)
                        }
                        Button {
                            haptic(.light); line += 0.5
                        } label: {
                            Image(systemName: "plus.circle.fill")
                                .font(.system(size: 48)).foregroundColor(.skyBright)
                        }
                    }

                    if let sp = sheet.serverProp {
                        let sidePct = direction == .over ? sp.overProbability : sp.underProbability
                        HStack(spacing: 5) {
                            Image(systemName: "info.circle").font(.caption2)
                            Text("Projected: \(direction.rawValue) \(sp.line.cleanLine)")
                            Text("· \(Int(round(sidePct * 100)))%")
                        }
                        .font(.caption2)
                        .foregroundColor(.white.opacity(0.35))
                    }

                    Spacer()

                    Button {
                        let p = builtProp
                        if let reason = router.blockedReason(for: p) {
                            blockedMsg = reason; showBlocked = true
                        } else {
                            onAdd(p); haptic(.medium); dismiss()
                        }
                    } label: {
                        Text("Add to Picks")
                            .font(.headline.bold()).foregroundColor(.skyDeep)
                            .frame(maxWidth: .infinity).padding(.vertical, 16)
                            .background(Color.skyBright, in: RoundedRectangle(cornerRadius: 14))
                    }
                    .padding(.horizontal, 24)
                    .padding(.bottom, 32)
                }
            }
            .navigationTitle("Choose Line")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.foregroundColor(.skyBright)
                }
            }
            .alert("Can't Add", isPresented: $showBlocked) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(blockedMsg)
            }
        }
    }

    private func sideChip(_ side: PropDirection) -> some View {
        Button {
            haptic(.light)
            direction = side
        } label: {
            Text(side.rawValue)
                .font(.system(size: 11, weight: .bold))
                .foregroundColor(direction == side ? .skyDeep : .white.opacity(0.75))
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(direction == side ? Color.skyBright : Color.white.opacity(0.08), in: Capsule())
        }
        .buttonStyle(.plain)
    }
}

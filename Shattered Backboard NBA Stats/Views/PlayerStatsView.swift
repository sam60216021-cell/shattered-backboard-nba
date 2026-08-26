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

    @ObservedObject private var dataService = LocalDataService.shared
    @ObservedObject private var router      = AppRouter.shared

    /// Log data owned by this view — never shares state with other player navigations.
    @State private var logs: [GameLog] = []
    @State private var isLoading = false
    @State private var projection: PlayerProjection?
    @State private var activeSheet: PickSheet? = nil
    @State private var chartStat: String = "PTS"
    @State private var avgWindow: Int = 0  // 0 = season; N = last N games
    @State private var customLines: [String: Double] = [:]  // per-stat user-adjusted line

    private let allStats    = ["PTS", "REB", "AST", "PRA", "3PM", "FTM", "STL", "BLK", "DD", "TD"]
    private let chartStats  = ["PTS", "REB", "AST", "3PM", "PRA", "STL", "BLK", "DD", "TD"]
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

    private func loadLogs() async {
        isLoading = true
        await dataService.fetchPlayerLogs(playerID: player.playerID)
        logs = dataService.playerLogs
        // Compute on-device projection with full game context when available
        let ctx: ProjectionContext
        if let g = game {
            let isHome   = (player.team ?? "").uppercased() == g.homeTeam.uppercased()
            let opponent = isHome ? g.awayTeam : g.homeTeam
            let forced   = { () -> Bool in
                #if DEBUG
                return forcePlayoffMode
                #else
                return false
                #endif
            }()
            ctx = ProjectionContext(opponent: opponent, isHome: isHome,
                                    isPlayoffs: forced || g.isPlayoffGame,
                                    isFirstRound: forced || g.isFirstRound,
                                    gameDate: g.date)
        } else {
            let forced = { () -> Bool in
                #if DEBUG
                return forcePlayoffMode
                #else
                return false
                #endif
            }()
            ctx = ProjectionContext(opponent: nil, isHome: nil,
                                    isPlayoffs: forced, isFirstRound: forced,
                                    gameDate: isoToday())
        }
        projection = PredictionEngine.shared.project(player: player, logs: logs, context: ctx)
        isLoading = false
    }

    private func isoToday() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone   = TimeZone(identifier: "UTC")
        return f.string(from: Date())
    }

    // MARK: - Player header

    private var playerHeader: some View {
        HStack(spacing: 14) {
            ZStack {
                Circle().fill(Color.skyMid).frame(width: 52, height: 52)
                Text(initials)
                    .font(.headline.bold())
                    .foregroundColor(.skyBright)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(player.name).font(.title3.bold()).foregroundColor(.white)
                HStack(spacing: 6) {
                    if let team = player.team {
                        Text(team).font(.caption.bold()).foregroundColor(.skyBright)
                    }
                    if let pos = player.position, !pos.isEmpty {
                        Text("·").foregroundColor(.white.opacity(0.3))
                        Text(pos).font(.caption).foregroundColor(.white.opacity(0.5))
                    }
                }
            }
            Spacer()
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
        .padding(14)
        .background(Color.skyCard, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.skyBorder, lineWidth: 1))
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
            case "PRA":  val = (log.pts ?? 0) + (log.reb ?? 0) + (log.ast ?? 0)
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
                ForEach(Array(entries.enumerated()), id: \.offset) { idx, entry in
                    BarMark(
                        x: .value("Game", idx),
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
            .chartXAxis(.hidden)
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
            .frame(height: 180)
            .id("\(chartStat)_\(chartGameCount)_\(avgWindow)")

            // Rotated date labels — one per bar, centered under each column
            HStack(spacing: 0) {
                ForEach(Array(entries.enumerated()), id: \.offset) { _, entry in
                    Text(entry.date)
                        .font(.system(size: 8, weight: .medium))
                        .foregroundStyle(Color.white.opacity(0.5))
                        .fixedSize()
                        .rotationEffect(.degrees(-90))
                        .frame(maxWidth: .infinity)
                }
            }
            .frame(height: 40)
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
            case "3PM":  values = logs.prefix(10).compactMap(\.threepm)
            case "FTM":  values = logs.prefix(10).compactMap(\.ftm)
            case "PRA":  values = logs.prefix(10).map { ($0.pts ?? 0) + ($0.reb ?? 0) + ($0.ast ?? 0) }
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

    // MARK: - Game log section

    @ViewBuilder
    private var gameLogSection: some View {
        if isLoading && logs.isEmpty {
            HStack(spacing: 10) {
                ProgressView().tint(.skyBright)
                Text("Loading game log…")
                    .font(.caption).foregroundColor(.white.opacity(0.4))
            }
            .frame(maxWidth: .infinity)
            .padding(20)
            .background(Color.skyCard, in: RoundedRectangle(cornerRadius: 14))
        } else if logs.isEmpty {
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

    private func logDataRow(_ log: GameLog) -> some View {
        HStack(spacing: 0) {
            Text(String(log.gameDate.dropFirst(5)))
                .frame(width: 52, alignment: .leading)
            Text(log.opponent ?? "—")
                .frame(maxWidth: .infinity, alignment: .leading)
                .lineLimit(1)
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
        case "PTS":  return isG ? 18.5 : isC ? 13.5 : 15.5
        case "REB":  return isG ? 3.5  : isC ? 9.5  : 6.5
        case "AST":  return isG ? 5.5  : isC ? 2.5  : 3.5
        case "PRA":  return isG ? 25.5 : isC ? 24.5 : 24.5
        case "3PM":  return isG ? 2.5  : isC ? 0.5  : 1.5
        case "FTM":  return isG ? 3.5  : isC ? 4.5  : 3.5
        case "STL":  return 0.5
        case "BLK":  return isC ? 1.5  : isG ? 0.5  : 0.5
        case "DD":   return 0.5
        case "TD":   return 0.5
        default:     return 15.5
        }
    }

    private func statColor(_ stat: String) -> Color { nbaStatColor(stat) }
}

// MARK: - PickSheet model

struct PickSheet: Identifiable {
    let id = UUID()
    let stat: String
    let serverProp: PlayerProp?
    let defaultLine: Double
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
    @State private var showBlocked = false
    @State private var blockedMsg  = ""

    init(sheet: PickSheet, playerName: String, onAdd: @escaping (PlayerProp) -> Void) {
        self.sheet      = sheet
        self.playerName = playerName
        self.onAdd      = onAdd
        _line = State(initialValue: sheet.defaultLine)
    }

    private var builtProp: PlayerProp {
        PlayerProp(
            id: "manual_\(UUID().uuidString)",
            gameID: sheet.serverProp?.gameID ?? sheet.gameID,
            playerName: playerName,
            team: sheet.serverProp?.team,
            statLabel: sheet.stat,
            line: line,
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
                        Text("OVER")
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
                        HStack(spacing: 5) {
                            Image(systemName: "info.circle").font(.caption2)
                            Text("Projected: OVER \(sp.line.cleanLine)")
                            if let pct = sp.overPct {
                                Text("· \(Int(round(pct * 100)))%")
                            }
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
}

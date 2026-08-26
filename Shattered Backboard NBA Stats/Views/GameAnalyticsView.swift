//
//  GameAnalyticsView.swift — Per-game analytics card embedded in GamePicksView.
//
//  Shows projected final score, moneyline, spread, and team stats.
//  Score projection sources (priority order):
//    1. Engine totals — sum of PTS projections from PredictionEngine (most accurate)
//    2. TeamProjection — blended season averages from StandingsEntry
//    3. Dashes         — no data yet
//

import SwiftUI

struct GameAnalyticsView: View {
    let game: ScheduleGame
    /// Projections passed from GamePicksView; may be empty while computing.
    let projections: [String: PlayerProjection]

    @ObservedObject private var dataService = LocalDataService.shared
    @State private var gameSimResult: GameSimulationResult? = nil

    // MARK: - Standings

    private var awayStanding: StandingsEntry? { dataService.standingsMap[game.awayTeam] }
    private var homeStanding: StandingsEntry? { dataService.standingsMap[game.homeTeam] }

    // MARK: - Projected scores

    /// Sum of projected PTS for all away-team players (engine-based).
    private var awayEnginePts: Double {
        projections.values
            .filter { $0.team.uppercased() == game.awayTeam.uppercased() }
            .reduce(0) { $0 + $1.pts }
    }

    /// Sum of projected PTS for all home-team players (engine-based).
    private var homeEnginePts: Double {
        projections.values
            .filter { $0.team.uppercased() == game.homeTeam.uppercased() }
            .reduce(0) { $0 + $1.pts }
    }

    private var hasEngineData: Bool { awayEnginePts > 0 && homeEnginePts > 0 }

    private var standingsProj: TeamProjection? {
        guard let h = homeStanding, let a = awayStanding else { return nil }
        return TeamProjection(away: a, home: h)
    }

    private var awayFinal: Double? {
        if hasEngineData { return awayEnginePts }
        return standingsProj?.awayPts
    }
    private var homeFinal: Double? {
        if hasEngineData { return homeEnginePts }
        return standingsProj?.homePts
    }

    // MARK: - Spread / moneyline

    private var spread: Double? {
        guard let h = homeFinal, let a = awayFinal else { return standingsProj?.spread }
        let raw = h - a
        return (max(-30, min(30, raw)) * 2).rounded() / 2
    }

    private var homeFavored: Bool { (spread ?? 0) > 0 }

    private var homeMLStr: String { mlString(favored: true) }
    private var awayMLStr: String { mlString(favored: false) }

    private func mlString(favored: Bool) -> String {
        guard let s = spread else { return "—" }
        let p = OddsMath.homeWinProbability(spread: s)
        let isFavored = favored ? homeFavored : !homeFavored
        let val = OddsMath.americanOdds(fromWinProbability: isFavored ? p : 1.0 - p)
        return val >= 0 ? "+\(val)" : "\(val)"
    }

    private func fmtSpread(_ v: Double) -> String {
        v == v.rounded() ? String(format: "%.0f", v) : String(format: "%.1f", v)
    }

    private var homeSpreadStr: String {
        guard let s = spread else { return "—" }
        let v = -s
        return v > 0 ? "+\(fmtSpread(v))" : fmtSpread(v)
    }
    private var awaySpreadStr: String {
        guard let s = spread else { return "—" }
        let v = s
        return v > 0 ? "+\(fmtSpread(v))" : fmtSpread(v)
    }

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            scoreLine
            Divider().background(Color.skyBorder)
            bettingStrip
            if let sim = gameSimResult {
                Divider().background(Color.skyBorder)
                winProbabilityRow(sim: sim)
            }
            if let h = homeStanding, let a = awayStanding {
                Divider().background(Color.skyBorder)
                teamStatsRow(away: a, home: h)
            }
        }
        .background(Color.skyCard.opacity(0.65), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.skyBorder, lineWidth: 1))
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .task(id: hasEngineData) {
            guard hasEngineData else { return }
            gameSimResult = SimulationEngine.shared.simulateGame(
                game: game, projections: projections
            )
        }
    }

    // MARK: - Score line

    private var scoreLine: some View {
        HStack(spacing: 0) {
            teamBlock(team: game.awayTeam, pts: awayFinal,
                      standing: awayStanding,
                      isHigher: (awayFinal ?? 0) > (homeFinal ?? 0))

            // Center label
            VStack(spacing: 3) {
                Text(hasEngineData ? "ENGINE" : "PROJECTED")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundColor(hasEngineData ? .skyBright : .white.opacity(0.35))
                    .tracking(0.8)
                Text("FINAL")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundColor(.white.opacity(0.22))
                    .tracking(0.8)
            }
            .frame(width: 56)

            teamBlock(team: game.homeTeam, pts: homeFinal,
                      standing: homeStanding,
                      isHigher: (homeFinal ?? 0) > (awayFinal ?? 0))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    @ViewBuilder
    private func teamBlock(team: String, pts: Double?,
                           standing: StandingsEntry?, isHigher: Bool) -> some View {
        VStack(spacing: 3) {
            Text(team)
                .font(.system(size: 24, weight: .black))
                .foregroundColor(.white)
            if let s = standing {
                Text("\(s.wins)–\(s.losses)")
                    .font(.caption2)
                    .foregroundColor(.white.opacity(0.4))
                Text(s.streak)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(.white.opacity(0.3))
            }
            Spacer(minLength: 4)
            if let p = pts, p > 0 {
                Text("\(Int(p.rounded()))")
                    .font(.system(size: 32, weight: .black, design: .rounded))
                    .foregroundColor(isHigher ? .skyBright : .white.opacity(0.55))
            } else {
                Text("—")
                    .font(.system(size: 26, weight: .black, design: .rounded))
                    .foregroundColor(.white.opacity(0.2))
            }
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Betting strip

    private var bettingStrip: some View {
        HStack(spacing: 0) {
            bettingCell(away: awayMLStr,     label: "MONEYLINE", home: homeMLStr,
                        awayBold: !homeFavored, homeBold: homeFavored)
            Rectangle().fill(Color.skyBorder).frame(width: 1)
            bettingCell(away: awaySpreadStr, label: "SPREAD",    home: homeSpreadStr,
                        awayBold: !homeFavored, homeBold: homeFavored)
            Rectangle().fill(Color.skyBorder).frame(width: 1)
            bettingCell(away: awayFinal.map { "\(Int($0.rounded()))" } ?? "—",
                        label: "PROJ SCORE",
                        home: homeFinal.map { "\(Int($0.rounded()))" } ?? "—",
                        awayBold: (awayFinal ?? 0) > (homeFinal ?? 0),
                        homeBold: (homeFinal ?? 0) > (awayFinal ?? 0))
        }
    }

    @ViewBuilder
    private func bettingCell(away: String, label: String, home: String,
                             awayBold: Bool, homeBold: Bool) -> some View {
        VStack(spacing: 4) {
            Text(away)
                .font(.system(size: 15, weight: awayBold ? .bold : .regular, design: .rounded))
                .foregroundColor(awayBold ? .white : .white.opacity(0.5))
            Text(label)
                .font(.system(size: 8, weight: .semibold))
                .foregroundColor(.white.opacity(0.28))
                .tracking(0.8)
            Text(home)
                .font(.system(size: 15, weight: homeBold ? .bold : .regular, design: .rounded))
                .foregroundColor(homeBold ? .white : .white.opacity(0.5))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
    }

    // MARK: - Team stats row

    @ViewBuilder
    private func teamStatsRow(away: StandingsEntry, home: StandingsEntry) -> some View {
        HStack(spacing: 0) {
            // Away: OFF | DEF | NET (left-aligned)
            HStack(spacing: 14) {
                miniStat("OFF", value: String(format: "%.1f", away.pointsPG),
                         hi: away.pointsPG > home.pointsPG)
                miniStat("DEF", value: String(format: "%.1f", away.oppPointsPG),
                         hi: away.oppPointsPG < home.oppPointsPG)
                let aNR = away.netRating
                miniStat("NET",
                         value: aNR >= 0 ? "+\(String(format: "%.1f", aNR))" : String(format: "%.1f", aNR),
                         hi: aNR > home.netRating)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // Streak chips (center column)
            VStack(spacing: 4) {
                streakChip(away.streak)
                streakChip(home.streak)
            }
            .frame(width: 48)

            // Home: NET | DEF | OFF (right-aligned, mirrored)
            HStack(spacing: 14) {
                let hNR = home.netRating
                miniStat("NET",
                         value: hNR >= 0 ? "+\(String(format: "%.1f", hNR))" : String(format: "%.1f", hNR),
                         hi: hNR > away.netRating)
                miniStat("DEF", value: String(format: "%.1f", home.oppPointsPG),
                         hi: home.oppPointsPG < away.oppPointsPG)
                miniStat("OFF", value: String(format: "%.1f", home.pointsPG),
                         hi: home.pointsPG > away.pointsPG)
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private func miniStat(_ label: String, value: String, hi: Bool) -> some View {
        VStack(spacing: 1) {
            Text(label)
                .font(.system(size: 8, weight: .semibold))
                .foregroundColor(.white.opacity(0.3))
                .tracking(0.5)
            Text(value)
                .font(.system(size: 12, weight: .bold, design: .rounded))
                .foregroundColor(hi ? .skyBright : .white.opacity(0.5))
        }
    }

    // MARK: - Win probability row (Monte Carlo)

    @ViewBuilder
    private func winProbabilityRow(sim: GameSimulationResult) -> some View {
        VStack(spacing: 7) {
            // Label
            Text("WIN PROBABILITY  ·  \(sim.simCount) SIMULATIONS")
                .font(.system(size: 8, weight: .semibold))
                .foregroundColor(.white.opacity(0.28))
                .tracking(0.8)

            // Split bar
            GeometryReader { geo in
                let awayFrac = CGFloat(sim.awayWinProbability)
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.skyBright.opacity(0.28))
                        .frame(height: 22)
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.white.opacity(0.13))
                        .frame(width: awayFrac * geo.size.width, height: 22)

                    HStack {
                        Text("\(game.awayTeam)  \(sim.awayWinPct)%")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(.white.opacity(0.75))
                            .padding(.leading, 8)
                        Spacer()
                        Text("\(sim.homeWinPct)%  \(game.homeTeam)")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(.skyBright)
                            .padding(.trailing, 8)
                    }
                }
            }
            .frame(height: 22)

            // Score ranges
            HStack {
                Text("Range \(sim.awayRangeStr)")
                    .font(.system(size: 9))
                    .foregroundColor(.white.opacity(0.30))
                Spacer()
                Text("Range \(sim.homeRangeStr)")
                    .font(.system(size: 9))
                    .foregroundColor(.white.opacity(0.30))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private func streakChip(_ streak: String) -> some View {
        let isWin  = streak.hasPrefix("W")
        let num    = Int(streak.dropFirst()) ?? 1
        let color: Color = isWin
            ? (num >= 4 ? .green : .skyBright)
            : (num >= 4 ? .red : .red.opacity(0.75))
        Text(streak)
            .font(.system(size: 9, weight: .bold))
            .foregroundColor(color)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(color.opacity(0.15), in: Capsule())
    }
}

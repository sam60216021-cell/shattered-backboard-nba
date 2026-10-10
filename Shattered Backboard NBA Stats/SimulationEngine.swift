//
//  SimulationEngine.swift — Monte Carlo simulation for NBA projections.
//
//  Generates fast on-device simulations (log-normal distribution, 500 trials) to
//  produce score ranges, win probabilities, and accurate parlay hit rates.
//
//  All public methods are synchronous — fast enough to call on the main thread.
//  500 simulations × any reasonable player count completes in microseconds.
//

import Foundation
import SwiftData

// MARK: - SimulationResult

/// Monte Carlo output for a single player stat.
struct SimulationResult {
    let playerID: String
    let stat:     String
    let simCount: Int
    let mean:     Double
    let stdDev:   Double
    let p10:      Double   // conservative floor  (10th percentile)
    let p25:      Double   // floor               (25th percentile)
    let p50:      Double   // median              (50th percentile)
    let p75:      Double   // ceiling             (75th percentile)
    let p90:      Double   // high ceiling        (90th percentile)

    /// Probability (0–1) that the simulated stat exceeds `line`.
    /// Uses a normal CDF approximation on the underlying distribution.
    func hitProbability(above line: Double) -> Double {
        guard stdDev > 0, mean > 0 else { return mean > line ? 1.0 : 0.0 }
        return 1.0 - normalCDF((line - mean) / stdDev)
    }

    // Hart (1968) rational approximation; max error ≈ 7.5e-8
    private func normalCDF(_ z: Double) -> Double {
        let absZ = abs(z)
        let t    = 1.0 / (1.0 + 0.2316419 * absZ)
        let poly = t * (0.319381530 + t * (-0.356563782 + t * (1.781477937 + t * (-1.821255978 + t * 1.330274429))))
        let cdf  = 1.0 - (exp(-absZ * absZ / 2.0) / sqrt(2.0 * .pi)) * poly
        return z >= 0 ? cdf : 1.0 - cdf
    }
}

// MARK: - GameSimulationResult

/// Monte Carlo output for a full game's score distribution.
struct GameSimulationResult {
    let awayTeam:           String
    let homeTeam:           String
    let awayMean:           Double   // average simulated away score
    let homeMean:           Double
    let awayP10:            Double   // away score 10th percentile
    let awayP90:            Double   // away score 90th percentile
    let homeP10:            Double
    let homeP90:            Double
    let homeWinProbability: Double   // fraction of sims where home team wins
    let projTotal:          Double
    let simCount:           Int
    let impliedHomeML:      Int
    let impliedAwayML:      Int
    let projectedSpread:    Double

    var awayWinProbability: Double { 1.0 - homeWinProbability }
    var homeWinPct: Int            { Int(round(homeWinProbability * 100)) }
    var awayWinPct: Int            { Int(round(awayWinProbability * 100)) }
    var awayRangeStr: String       { "\(Int(awayP10.rounded()))–\(Int(awayP90.rounded()))" }
    var homeRangeStr: String       { "\(Int(homeP10.rounded()))–\(Int(homeP90.rounded()))" }
}

// MARK: - SimulationEngine

/// On-device Monte Carlo engine. Fully offline — no network calls.
final class SimulationEngine {
    static let shared = SimulationEngine()
    private init() {}

    static var defaultSimulationCount: Int { SportConfig.predictionSimulationCount }
    private let defaultSimCount = SportConfig.predictionSimulationCount

    // MARK: - Player stat simulation

    /// Runs a log-normal Monte Carlo for one player stat, optionally adjusted for opponent defense.
    ///
    /// - Parameters:
    ///   - playerID: Used to tag the result.
    ///   - stat: Stat label ("PTS", "REB", "AST", "PRA", "3PM", "STL", "BLK").
    ///   - logs: Recent game logs — used to estimate historical variance.
    ///   - projectedMean: Expected value from `PredictionEngine.project()`.
    ///   - opponent: Optional opponent team code (e.g., "NYL") — used to adjust volatility.
    ///   - simCount: Number of Monte Carlo trials (default 500).
    func simulatePlayerStat(
        playerID:      String,
        stat:          String,
        logs:          [GameLog],
        projectedMean: Double,
        opponent:      String? = nil,
        defenderMatchup: DefenderMatchup? = nil,
        simCount:      Int? = nil
    ) -> SimulationResult {
        let n = max(1, simCount ?? defaultSimCount)
        guard projectedMean > 0 else {
            return SimulationResult(playerID: playerID, stat: stat, simCount: 0,
                                    mean: 0, stdDev: 0,
                                    p10: 0, p25: 0, p50: 0, p75: 0, p90: 0)
        }

        var rng = SeededGenerator(seed: stableSeed(for: playerSeedKey(
            playerID: playerID,
            stat: stat,
            logs: logs,
            projectedMean: projectedMean,
            opponent: opponent,
            defenderName: defenderMatchup?.defenderName,
            simCount: n
        )))

        // Direct-defender impact (0 → none, ≤0.10 → elite matchup pressure).
        // The projected mean already includes the defender cut; here we shape the
        // DISTRIBUTION: more volatility + a heavier downside tail when locked down.
        let defenderImpact: Double = {
            guard let m = defenderMatchup else { return 0 }
            return max(0.0, min(0.10, 1.0 - m.multiplier(for: stat)))
        }()

        // Opponent defensive volatility adjustment (0.85–1.15 range).
        // Strong defense (low oppPts) → higher volatility (less predictable).
        // Weak defense (high oppPts) → lower volatility (more predictable).
        let opponentVolatilityMult: Double = {
            guard let opp = opponent else { return 1.0 }
            let standings = LocalDataService.shared.standingsMap[opp]
            guard let oppDef = standings else { return 1.0 }
            let leagueAvgOppPts = 88.0
            let defRatio = oppDef.oppPointsPG / leagueAvgOppPts
            return 1.0 + (1.0 - defRatio) * 0.12
        }()

        // Historical std dev scaled to the projected mean (preserves relative volatility).
        let stdDev: Double = {
            let rawVals = logs.prefix(15).compactMap { log -> Double? in
                let v = log.value(for: stat); return v > 0 ? v : nil
            }
            guard rawVals.count >= 3 else { return projectedMean * 0.40 }
            let histMean = rawVals.reduce(0, +) / Double(rawVals.count)
            let variance = rawVals.map { pow($0 - histMean, 2) }.reduce(0, +) / Double(rawVals.count)
            let histSD   = sqrt(variance)
            let scale    = histMean > 0 ? projectedMean / histMean : 1.0
            return max(0.5, min(projectedMean * 0.65, histSD * scale * opponentVolatilityMult))
        }()

        // Log-normal parameters in log-space: ensures all samples are non-negative.
        let cv    = stdDev / projectedMean
        let sigma = sqrt(log(1.0 + cv * cv))
        let mu    = log(projectedMean) - 0.5 * sigma * sigma

        var samples = [Double](repeating: 0, count: n)
        for i in 0..<n {
            samples[i] = max(0.0, exp(normalSample(mean: mu, stdDev: sigma, using: &rng)))
        }
        samples.sort()

        // Downside-tail drag: compress the bottom 40% of outcomes when an elite
        // same-position defender is across from the player. This lowers the floor
        // (p10/p25) without double-counting the mean adjustment already applied.
        if defenderImpact > 0 {
            let dragCutoff = Int(Double(n) * 0.40)
            let dragFactor = 1.0 - defenderImpact * 0.7
            for i in 0..<max(0, dragCutoff) {
                samples[i] *= dragFactor
            }
        }
        samples.sort()

        let mean     = samples.reduce(0, +) / Double(n)
        let variance = samples.map { pow($0 - mean, 2) }.reduce(0, +) / Double(n)

        return SimulationResult(
            playerID: playerID, stat: stat, simCount: n,
            mean:   mean,  stdDev: sqrt(variance),
            p10:    pct(samples, 0.10),
            p25:    pct(samples, 0.25),
            p50:    pct(samples, 0.50),
            p75:    pct(samples, 0.75),
            p90:    pct(samples, 0.90)
        )
    }

    // MARK: - Game simulation

    /// Simulates final scores for both teams using per-player projections.
    ///
    /// A correlated game-pace shock (±5% Normal) is applied to both teams each trial
    /// so that high-scoring games affect both sides — matching real-world correlation.
    ///
    /// Returns nil when player projections are unavailable or too sparse.
    func simulateGame(
        game:        ScheduleGame,
        projections: [String: PlayerProjection],
        simCount:    Int? = nil
    ) -> GameSimulationResult? {
        let n = max(1, simCount ?? defaultSimCount)

        let awayProjs = projections.values.filter { $0.team.uppercased() == game.awayTeam.uppercased() }
        let homeProjs = projections.values.filter { $0.team.uppercased() == game.homeTeam.uppercased() }

        // Build team means from likely rotation minutes instead of summing every roster player.
        // Summing full-roster per-game points can dramatically overstate totals.
        let awayRotationMean = estimateTeamPointsFromRotation(awayProjs)
        let homeRotationMean = estimateTeamPointsFromRotation(homeProjs)

        // Use recent real game outcomes as the primary calibration anchor.
        let awayRecentMean = recentTeamScoringMean(for: game.awayTeam)
        let homeRecentMean = recentTeamScoringMean(for: game.homeTeam)

        // Anchor projections to standings scoring pace so outputs stay in realistic NBA ranges.
        let awayBaseline = teamBaselinePoints(for: game.awayTeam)
        let homeBaseline = teamBaselinePoints(for: game.homeTeam)

        let rawAwayMean = blendedTeamMean(
            rotationMean: awayRotationMean,
            recentMean: awayRecentMean,
            baselineMean: awayBaseline
        )
        let rawHomeMean = blendedTeamMean(
            rotationMean: homeRotationMean,
            recentMean: homeRecentMean,
            baselineMean: homeBaseline
        )

        let adjustedAdvanced = adjustedTeamMeans(game: game, awayBase: rawAwayMean, homeBase: rawHomeMean)
        let adjusted = applyStandingsMatchupAdjustment(
            game: game,
            awayBase: adjustedAdvanced.away,
            homeBase: adjustedAdvanced.home
        )

        // Hard safety rails for plausible NBA team scoring outcomes.
        let awayMean = max(78.0, min(134.0, adjusted.away))
        let homeMean = max(78.0, min(134.0, adjusted.home))
        guard awayMean > 20, homeMean > 20 else { return nil }

        let awayDefMult: Double = defenseVolatilityMult(for: game.homeTeam)
        let homeDefMult: Double = defenseVolatilityMult(for: game.awayTeam)
        let paceVolMult = gamePaceVolatilityMultiplier(awayTeam: game.awayTeam, homeTeam: game.homeTeam)
        let homeScoreBias = homeScoreBiasAdjustment(awayTeam: game.awayTeam, homeTeam: game.homeTeam)

        // NBA team-level SD ≈ 12% of mean (wider distribution than WNBA), adjusted for defense.
        let awaySD = awayMean * 0.12 * awayDefMult * paceVolMult
        let homeSD = homeMean * 0.12 * homeDefMult * paceVolMult

        var rng = SeededGenerator(seed: stableSeed(for: gameSeedKey(
            game: game,
            awayMean: awayMean,
            homeMean: homeMean,
            simCount: n
        )))

        var awayScores = [Double](repeating: 0, count: n)
        var homeScores = [Double](repeating: 0, count: n)
        var homeWins   = 0

        for i in 0..<n {
            let pace = normalSample(mean: 1.0, stdDev: 0.05, using: &rng)   // shared game-pace shock
            let a    = max(70.0, normalSample(mean: awayMean * pace, stdDev: awaySD, using: &rng))
            let h    = max(70.0, normalSample(mean: (homeMean + homeScoreBias) * pace, stdDev: homeSD, using: &rng))
            awayScores[i] = a
            homeScores[i] = h
            if h > a { homeWins += 1 }
        }
        awayScores.sort()
        homeScores.sort()

        let awayAvg = awayScores.reduce(0, +) / Double(n)
        let homeAvg = homeScores.reduce(0, +) / Double(n)
        let homeWinProbability = Double(homeWins) / Double(n)
        let projectedSpread = ((homeAvg - awayAvg) * 2).rounded() / 2

        return GameSimulationResult(
            awayTeam:           game.awayTeam,
            homeTeam:           game.homeTeam,
            awayMean:           awayAvg,
            homeMean:           homeAvg,
            awayP10:            pct(awayScores, 0.10),
            awayP90:            pct(awayScores, 0.90),
            homeP10:            pct(homeScores, 0.10),
            homeP90:            pct(homeScores, 0.90),
            homeWinProbability: homeWinProbability,
            projTotal:          awayAvg + homeAvg,
            simCount:           n,
            impliedHomeML:      americanMoneyline(fromProbability: homeWinProbability),
            impliedAwayML:      americanMoneyline(fromProbability: 1.0 - homeWinProbability),
            projectedSpread:    projectedSpread
        )
    }

    private func estimateTeamPointsFromRotation(_ projections: [PlayerProjection]) -> Double {
        guard !projections.isEmpty else { return 0 }

        let candidates = projections
            .filter { $0.minutes > 0 && $0.pts >= 0 }
            .sorted { $0.minutes > $1.minutes }
        guard !candidates.isEmpty else { return 0 }

        let rotation = Array(candidates.prefix(10))
        let sumPts = rotation.reduce(0.0) { $0 + $1.pts }
        let sumMin = rotation.reduce(0.0) { $0 + $1.minutes }

        // Team regulation minutes = 240 (5 × 48). Scale gently if projected minutes are under/over.
        let minScale: Double = {
            guard sumMin > 0 else { return 1.0 }
            return max(0.82, min(1.08, 240.0 / sumMin))
        }()

        return sumPts * minScale
    }

    private func blendedTeamMean(rotationMean: Double, recentMean: Double, baselineMean: Double) -> Double {
        let hasRotation = rotationMean > 0
        let hasRecent = recentMean > 0
        let hasBaseline = baselineMean > 0

        if hasRecent && hasRotation && hasBaseline {
            return (recentMean * 0.50) + (rotationMean * 0.35) + (baselineMean * 0.15)
        }
        if hasRecent && hasRotation {
            return (recentMean * 0.60) + (rotationMean * 0.40)
        }
        if hasRecent && hasBaseline {
            return (recentMean * 0.75) + (baselineMean * 0.25)
        }
        if hasRotation && hasBaseline {
            return (rotationMean * 0.65) + (baselineMean * 0.35)
        }
        if hasRecent { return recentMean }
        if hasRotation { return max(92.0, rotationMean) }
        if hasBaseline { return baselineMean }
        // Last-resort fallback when local logs or standings are temporarily missing.
        return 112.0
    }

    private func recentTeamScoringMean(for team: String, lookbackGames: Int = 8) -> Double {
        let teamCode = team.uppercased()
        let cutoffDate = Calendar.current.date(byAdding: .day, value: -120, to: Date()) ?? Date()
        let cutoff = Self.isoDateString(cutoffDate)
        let ctx = AppDatabase.shared.mainContext

        let desc = FetchDescriptor<StoredGameLog>(
            predicate: #Predicate { log in
                log.gameDate >= cutoff
            },
            sortBy: [SortDescriptor(\.gameDate, order: .reverse)]
        )
        let rows = ((try? ctx.fetch(desc)) ?? []).filter {
            (($0.team ?? "").uppercased() == teamCode)
        }
        guard !rows.isEmpty else { return 0 }

        var byGame: [String: [StoredGameLog]] = [:]
        for row in rows {
            byGame[row.gameDate, default: []].append(row)
        }

        let recentDates = byGame.keys.sorted(by: >).prefix(lookbackGames)
        var teamGamePoints: [Double] = []
        for date in recentDates {
            guard let gameRows = byGame[date] else { continue }
            let topRotation = gameRows
                .sorted { ($0.minutesSeconds ?? 0) > ($1.minutesSeconds ?? 0) }
                .prefix(10)
            let points = topRotation.reduce(0.0) { $0 + max(0.0, $1.pts ?? 0.0) }
            if points >= 45 { teamGamePoints.append(points) }
        }

        guard !teamGamePoints.isEmpty else { return 0 }
        return teamGamePoints.reduce(0, +) / Double(teamGamePoints.count)
    }

    private static func isoDateString(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = TimeZone(identifier: SportConfig.appTimeZoneID)
        return f.string(from: date)
    }

    private func teamBaselinePoints(for team: String) -> Double {
        guard let s = LocalDataService.shared.standingsMap[team] else { return 0 }
        let games = max(1, s.wins + s.losses)
        let raw = s.pointsPG
        if raw > 300 {
            return raw / Double(games)
        }
        return raw
    }

    // MARK: - Parlay simulation

    /// Estimates combined parlay probability using a correlated Monte Carlo approach.
    ///
    /// Picks in the same game receive a shared pace shock, which correctly raises
    /// the combined probability when high-scoring games help multiple picks and lowers
    /// it when they conflict — more accurate than multiplying independent probabilities.
    /// Opponent defensive strength is factored into each player's volatility.
    ///
    /// - Parameters:
    ///   - picks: Props currently in the parlay builder.
    ///   - logsByName: Recent game logs keyed by player name (for variance estimation).
    ///   - gamesByID: Game objects keyed by gameID to look up opponent.
    ///   - simCount: Number of Monte Carlo trials (default 500).
    func simulateParlayProbability(
        picks:      [PlayerProp],
        logsByName: [String: [GameLog]],
        gamesByID:  [String: ScheduleGame] = [:],
        simCount:   Int? = nil
    ) -> Double {
        let n = max(1, simCount ?? defaultSimCount)
        guard !picks.isEmpty else { return 1.0 }

        struct PickProfile {
            let mean:   Double
            let stdDev: Double
            let line:   Double
            let direction: PropDirection
            let gameID: String?
            let opponent: String?
        }

        let profiles: [PickProfile] = picks.compactMap { prop in
            let line = prop.line
            let mean = max(line * 0.5, prop.projectedValue ?? (line * 1.05))
            guard mean > 0 else { return nil }
            let logs = logsByName[prop.playerName] ?? []
            let vals = logs.prefix(15).map { $0.value(for: prop.statLabel) }.filter { $0 > 0 }
            let opponent = prop.gameID.flatMap { gamesByID[$0] }.map { game in
                (prop.team ?? "").uppercased() == game.homeTeam.uppercased() ? game.awayTeam : game.homeTeam
            }
            let sd: Double = {
                guard vals.count >= 3 else { return mean * 0.40 }
                let m  = vals.reduce(0, +) / Double(vals.count)
                let v  = vals.map { pow($0 - m, 2) }.reduce(0, +) / Double(vals.count)
                let s  = sqrt(v)
                let baseSD = max(0.5, min(mean * 0.65, m > 0 ? s * (mean / m) : s))
                let oppMult = opponent.map { defenseVolatilityMult(for: $0) } ?? 1.0
                return baseSD * oppMult
            }()
            return PickProfile(
                mean: mean,
                stdDev: sd,
                line: line,
                direction: prop.direction,
                gameID: prop.gameID,
                opponent: opponent
            )
        }

        guard !profiles.isEmpty else {
            return picks.reduce(1.0) { $0 * $1.selectedProbability }
        }

        let gameIDs = Array(Set(profiles.compactMap(\.gameID)))

        var rng = SeededGenerator(seed: stableSeed(for: parlaySeedKey(
            picks: picks,
            logsByName: logsByName,
            simCount: n
        )))

        var parlayHits = 0
        for _ in 0..<n {
            // One shared pace factor per game (4% stddev → mild correlation).
            var paceMap: [String: Double] = [:]
            for gid in gameIDs {
                paceMap[gid] = normalSample(mean: 1.0, stdDev: 0.04, using: &rng)
            }
            var allHit = true
            for prof in profiles {
                let pace   = prof.gameID.flatMap { paceMap[$0] } ?? 1.0
                let sample = normalSample(mean: prof.mean * pace, stdDev: prof.stdDev, using: &rng)
                switch prof.direction {
                case .over:
                    if sample <= prof.line { allHit = false; break }
                case .under:
                    if sample >= prof.line { allHit = false; break }
                }
            }
            if allHit { parlayHits += 1 }
        }
        return Double(parlayHits) / Double(n)
    }

    // MARK: - Math helpers

    private func pct(_ sorted: [Double], _ p: Double) -> Double {
        guard !sorted.isEmpty else { return 0 }
        let idx  = max(0.0, min(Double(sorted.count - 1), p * Double(sorted.count - 1)))
        let lo   = Int(idx)
        let hi   = min(lo + 1, sorted.count - 1)
        return sorted[lo] + (idx - Double(lo)) * (sorted[hi] - sorted[lo])
    }

    /// Box-Muller transform: draws one N(mean, stdDev) sample.
    private func normalSample<R: RandomNumberGenerator>(mean: Double, stdDev: Double, using rng: inout R) -> Double {
        let u1 = Double.random(in: Double.ulpOfOne...1.0, using: &rng)
        let u2 = Double.random(in: 0.0..<1.0, using: &rng)
        let z  = sqrt(-2.0 * log(u1)) * cos(2.0 * .pi * u2)
        return mean + stdDev * z
    }

    private func playerSeedKey(
        playerID: String,
        stat: String,
        logs: [GameLog],
        projectedMean: Double,
        opponent: String?,
        defenderName: String? = nil,
        simCount: Int
    ) -> String {
        let recentVals = logs.prefix(10).map { String(format: "%.2f", $0.value(for: stat)) }.joined(separator: ",")
        return [
            "player", playerID, stat.uppercased(), String(simCount),
            String(format: "%.4f", projectedMean), (opponent ?? "-").uppercased(),
            (defenderName ?? "-").uppercased(), recentVals
        ].joined(separator: "|")
    }

    private func gameSeedKey(
        game: ScheduleGame,
        awayMean: Double,
        homeMean: Double,
        simCount: Int
    ) -> String {
        [
            "game", game.id, game.date,
            game.awayTeam.uppercased(), game.homeTeam.uppercased(),
            String(simCount),
            String(format: "%.4f", awayMean),
            String(format: "%.4f", homeMean)
        ].joined(separator: "|")
    }

    private func parlaySeedKey(
        picks: [PlayerProp],
        logsByName: [String: [GameLog]],
        simCount: Int
    ) -> String {
        let pickKey = picks
            .map {
                let val = $0.projectedValue ?? 0
                return "\(($0.playerName).uppercased())|\($0.statLabel)|\($0.direction.rawValue)|\(String(format: "%.2f", $0.line))|\(String(format: "%.2f", val))|\(($0.gameID ?? "-"))"
            }
            .sorted()
            .joined(separator: "#")

        let logsKey = logsByName
            .map { name, logs in
                let pts = logs.prefix(5).compactMap(\.pts).map { String(format: "%.1f", $0) }.joined(separator: ",")
                return "\(name.uppercased()):\(pts)"
            }
            .sorted()
            .joined(separator: "#")

        return ["parlay", String(simCount), pickKey, logsKey].joined(separator: "|")
    }

    private func stableSeed(for input: String) -> UInt64 {
        var hash: UInt64 = 1469598103934665603
        for byte in input.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1099511628211
        }
        return hash == 0 ? 1 : hash
    }

    private struct SeededGenerator: RandomNumberGenerator {
        private var state: UInt64

        init(seed: UInt64) {
            self.state = seed == 0 ? 0x9E3779B97F4A7C15 : seed
        }

        mutating func next() -> UInt64 {
            state &+= 0x9E3779B97F4A7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
            z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
            return z ^ (z >> 31)
        }
    }

    /// Calculates opponent defensive volatility multiplier (0.85–1.15 range).
    /// Strong defense (low oppPts) → higher volatility (less predictable).
    /// Weak defense (high oppPts) → lower volatility (more predictable).
    private func defenseVolatilityMult(for opponentTeam: String) -> Double {
        let standings = LocalDataService.shared.standingsMap[opponentTeam]
        guard let oppDef = standings else { return 1.0 }
        let leagueAvgOppPts = 88.0
        let defRatio = oppDef.oppPointsPG / leagueAvgOppPts
        return 1.0 + (1.0 - defRatio) * 0.12
    }

    private func adjustedTeamMeans(game: ScheduleGame, awayBase: Double, homeBase: Double) -> (away: Double, home: Double) {
        let map = LocalDataService.shared.teamAdvancedMap
        let away = map[game.awayTeam]
        let home = map[game.homeTeam]
        let league = Array(map.values)

        let leaguePace = average(league.compactMap(\.pace)) ?? 97.0
        let leagueOff = average(league.compactMap(\.offRating)) ?? 100.0
        let leagueDef = average(league.compactMap(\.defRating)) ?? 100.0
        let leagueTS = average(league.compactMap(\.tsPct)) ?? 0.54
        let leagueEFG = average(league.compactMap(\.efgPct)) ?? 0.49
        let leagueAst = average(league.compactMap(\.astRatio)) ?? 18.0

        func teamBoost(team: TeamAdvancedEntry?, opponent: TeamAdvancedEntry?) -> Double {
            guard let team else { return 1.0 }
            let paceTerm = normalizedDelta(team.pace, baseline: leaguePace) * 0.14
            let offTerm = normalizedDelta(team.offRating, baseline: leagueOff) * 0.24
            let tsTerm = normalizedDelta(team.tsPct, baseline: leagueTS) * 0.12
            let efgTerm = normalizedDelta(team.efgPct, baseline: leagueEFG) * 0.12
            let astTerm = normalizedDelta(team.astRatio, baseline: leagueAst) * 0.08
            let oppDefTerm = normalizedDelta(opponent?.defRating, baseline: leagueDef) * 0.18
            let total = paceTerm + offTerm + tsTerm + efgTerm + astTerm + oppDefTerm
            return max(0.90, min(1.11, 1.0 + total))
        }

        return (
            awayBase * teamBoost(team: away, opponent: home),
            homeBase * teamBoost(team: home, opponent: away)
        )
    }

    private func applyStandingsMatchupAdjustment(
        game: ScheduleGame,
        awayBase: Double,
        homeBase: Double
    ) -> (away: Double, home: Double) {
        let standings = LocalDataService.shared.standingsMap
        guard let awayS = standings[game.awayTeam], let homeS = standings[game.homeTeam] else {
            return (awayBase, homeBase)
        }

        let awayOff = normalizedStandingsPoints(awayS.pointsPG, wins: awayS.wins, losses: awayS.losses)
        let awayDef = normalizedStandingsPoints(awayS.oppPointsPG, wins: awayS.wins, losses: awayS.losses)
        let homeOff = normalizedStandingsPoints(homeS.pointsPG, wins: homeS.wins, losses: homeS.losses)
        let homeDef = normalizedStandingsPoints(homeS.oppPointsPG, wins: homeS.wins, losses: homeS.losses)

        // Per-side standings expectation from offense vs opponent defense.
        let awayStandSide = (awayOff + homeDef) / 2.0
        let homeStandSide = (homeOff + awayDef) / 2.0

        // Team strength edge from net rating and win pct, used to widen 50/50 splits.
        let awayNet = awayOff - awayDef
        let homeNet = homeOff - homeDef
        let netGap = homeNet - awayNet
        let pctGap = homeS.pct - awayS.pct
        let homeEdgeMult = max(0.90, min(1.14, 1.0 + (netGap * 0.015) + (pctGap * 0.10)))
        let awayEdgeMult = max(0.90, min(1.14, 1.0 - (netGap * 0.015) - (pctGap * 0.10)))

        // Keep player-level model as core signal, but enforce meaningful standings context.
        let away = ((awayBase * 0.65) + (awayStandSide * 0.35)) * awayEdgeMult
        let home = ((homeBase * 0.65) + (homeStandSide * 0.35)) * homeEdgeMult
        return (away, home)
    }

    private func normalizedStandingsPoints(_ raw: Double, wins: Int, losses: Int) -> Double {
        let games = max(1, wins + losses)
        if raw > 300 { return raw / Double(games) }
        return raw
    }

    private func homeScoreBiasAdjustment(awayTeam: String, homeTeam: String) -> Double {
        let map = LocalDataService.shared.teamAdvancedMap
        let away = map[awayTeam]
        let home = map[homeTeam]
        let netGap = ((home?.netRating ?? 0) - (away?.netRating ?? 0)) * 0.06
        return max(-1.5, min(2.5, 1.2 + netGap))
    }

    private func gamePaceVolatilityMultiplier(awayTeam: String, homeTeam: String) -> Double {
        let map = LocalDataService.shared.teamAdvancedMap
        let away = map[awayTeam]
        let home = map[homeTeam]
        let league = Array(map.values)
        let leaguePace = average(league.compactMap(\.pace)) ?? 97.0
        let avgPace = average([away?.pace, home?.pace].compactMap { $0 }) ?? leaguePace
        let delta = (avgPace - leaguePace) / max(leaguePace, 1.0)
        return max(0.92, min(1.08, 1.0 + (delta * 0.35)))
    }

    private func normalizedDelta(_ value: Double?, baseline: Double) -> Double {
        guard let value, baseline != 0 else { return 0 }
        return (value - baseline) / baseline
    }

    private func average(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +) / Double(values.count)
    }

    private func americanMoneyline(fromProbability probability: Double) -> Int {
        OddsMath.americanOdds(fromWinProbability: probability)
    }
}

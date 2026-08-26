//
//  PredictionEngine.swift — On-device NBA stat projections.
//
//  Pure computation — fully offline. No network calls.
//
//  Factors in:
//    • Recency-weighted game-log average (exponential decay, up to 40 games)
//    • Opponent historical matchup (≥ 3 prior games required)
//    • Home / away split (±2.5% — pronounced NBA home-court advantage)
//    • Back-to-back / rest-day fatigue (0.93×–1.04×)
//    • Aggressive baseline (+10%) in regular season — slightly above typical lines
//    • Conservative mode (−22%, extra −8% stacking) for playoffs
//
//  Generates: PTS, REB, AST, PR, PA, RA, PRA, FPTS, 3PM, STL, BLK
//

import Foundation
import SwiftData

// MARK: - PlayerProjection

/// Fully-computed on-device projections for one player in one upcoming game.
struct PlayerProjection {
    let playerID:   String
    let playerName: String
    let team:       String
    let gameCount:  Int         // number of log rows consumed
    let pts:        Double
    let reb:        Double
    let ast:        Double
    let pr:         Double      // pts + reb
    let pa:         Double      // pts + ast
    let ra:         Double      // reb + ast
    let pra:        Double      // pts + reb + ast
    let fpts:       Double      // fantasy score
    let ftm:        Double
    let threepm:    Double
    let stl:        Double
    let blk:        Double
    let dd:         Double      // recency-weighted double-double rate (0–1)
    let td:         Double      // recency-weighted triple-double rate (0–1)
    let minutes:    Double      // projected minutes per game
    let confidence: Double      // PTS hit rate (0–1, snapped to nearest 0.05)
    let confidences: [String: Double]  // per-stat hit rates
    let floors:      [String: Double]  // 25th-percentile recent outcome per stat
    let ceilings:    [String: Double]  // 75th-percentile recent outcome per stat
    let volatility:  Double            // PTS coefficient of variation (0 = stable, 1 = high)
    let streakFactor: Double           // −1.0 cold → 0.0 neutral → +1.0 hot (L3 vs L10 delta)
    let declineStreakGames: Int        // consecutive recent games with clear form decline
    let declineProjectionPenalty: Double // multiplier applied to projected stats
    let declineConfidencePenalty: Double // multiplier applied to confidence
    let isPlayoffs: Bool

    // MARK: Helpers

    /// Returns the hit-rate confidence for a specific stat (falls back to PTS confidence).
    func confidence(for stat: String) -> Double {
        confidences[stat] ?? confidence
    }

    // MARK: Convenience accessors

    func floor(for stat: String) -> Double   { floors[stat]   ?? 0 }
    func ceiling(for stat: String) -> Double { ceilings[stat] ?? 0 }

    var volatilityLabel: String {
        switch volatility {
        case 0..<0.25:  return "Low"
        case 0.25..<0.45: return "Medium"
        default:        return "High"
        }
    }

    /// Non-nil when the player is on a notable hot or cold streak.
    var streakLabel: String? {
        if streakFactor >  0.3 { return "🔥 Hot" }
        if streakFactor < -0.3 { return "❄️ Cold" }
        return nil
    }

    /// Non-nil when a multi-game form decline is active.
    var declineLabel: String? {
        guard declineStreakGames >= 2 else { return nil }
        return "Form dip (\(declineStreakGames)G)"
    }

    static func empty(player: Player) -> PlayerProjection {
        PlayerProjection(
            playerID: player.playerID, playerName: player.name,
            team: player.team ?? "", gameCount: 0,
            pts: 0, reb: 0, ast: 0, pr: 0, pa: 0, ra: 0, pra: 0, fpts: 0,
            ftm: 0, threepm: 0, stl: 0, blk: 0, dd: 0, td: 0, minutes: 0,
            confidence: 0, confidences: [:],
            floors: [:], ceilings: [:], volatility: 0, streakFactor: 0,
            declineStreakGames: 0,
            declineProjectionPenalty: 1.0,
            declineConfidencePenalty: 1.0,
            isPlayoffs: false
        )
    }

    /// Look up a projected value by stat label string.
    func value(for stat: String) -> Double {
        switch stat {
        case "PTS":  return pts
        case "REB":  return reb
        case "AST":  return ast
        case "PR":   return pr
        case "PA":   return pa
        case "RA":   return ra
        case "PRA":  return pra
        case "FPTS": return fpts
        case "FTM":  return ftm
        case "3PM":  return threepm
        case "STL":  return stl
        case "BLK":  return blk
        case "DD":   return dd
        case "TD":   return td
        default:     return 0
        }
    }

    /// Engine value rounded to the nearest 0.5 — ready to use as a default pick line.
    func line(for stat: String) -> Double {
        if stat == "DD" || stat == "TD" { return 0.5 }  // binary prop: always over/under 0.5
        let v = value(for: stat)
        guard v > 0 else { return 0 }
        return (v * 2).rounded() / 2
    }
}

// MARK: - ProjectionContext

struct ProjectionContext {
    let opponent:     String?   // 3-letter team code; nil → skip opponent adjustment
    let isHome:       Bool?     // nil → skip home/away adjustment
    let isPlayoffs:   Bool
    let isFirstRound: Bool      // true = first round of playoffs (extra −10%)
    let gameDate:     String    // "YYYY-MM-DD" of the upcoming game (for rest-day calc)
    let availabilityRisk: Double // 0.0 healthy → 1.0 high risk (injury/minutes concern)
    let gameStatusCode: Int?    // 1 upcoming, 2 live, 3 final
    let period: Int?
    let hoursToTip: Double?
    let playerPosition: String?
    let defenderMatchup: DefenderMatchup?   // opposing same-position starter; nil → skip

    init(opponent: String?, isHome: Bool?, isPlayoffs: Bool,
         isFirstRound: Bool = false, gameDate: String,
         availabilityRisk: Double = 0.0,
         gameStatusCode: Int? = nil,
         period: Int? = nil,
         hoursToTip: Double? = nil,
         playerPosition: String? = nil,
         defenderMatchup: DefenderMatchup? = nil) {
        self.opponent     = opponent
        self.isHome       = isHome
        self.isPlayoffs   = isPlayoffs
        self.isFirstRound = isFirstRound
        self.gameDate     = gameDate
        self.availabilityRisk = availabilityRisk
        self.gameStatusCode = gameStatusCode
        self.period = period
        self.hoursToTip = hoursToTip
        self.playerPosition = playerPosition
        self.defenderMatchup = defenderMatchup
    }
}

// MARK: - PredictionEngine

final class PredictionEngine {
    static let shared = PredictionEngine()
    private init() { loadGlobalStatTuning() }

    private struct CalibrationProfile {
        let biasMultiplier: Double
        let uncertainty: Double   // 0 = stable model fit, 1 = highly unstable
        let sampleCount: Int
    }

    private struct DeclineSignal {
        let streakGames: Int
        let projectionMultiplier: Double
        let confidenceMultiplier: Double
    }

    private let statTuningDefaultsKey = "nba_global_stat_tuning_v1"
    private var globalStatTuning: [String: Double] = [:]

    // ── Tuning constants (NBA-calibrated) ────────────────────────────────────
    // NBA season = 82 games → deeper log windows and gentler recency bias than
    // the short-season WNBA build.
    private let maxLogs        = 40     // cap at ~half an NBA season of logs
    private let decayLambda    = 0.04   // exp(-i × λ) — gentle recency bias
    private let aggressiveMult        = 1.10   // +10% regular season (legacy NBA calibration)
    private let playoffMult           = 0.78   // −22% playoffs — tighter defence, lower pace
    private let playoffExtraMult      = 0.92   // additional −8% in playoffs on top of playoffMult
    private let playoffFirstRoundMult = 0.90   // additional −10% for first-round games
    private let playoffMaxConf        = 0.75   // confidence capped at 75% in playoffs
    private let regularSeasonBiasMult = 1.00   // neutral global calibration for regular-season projections

    // MARK: - Global auto-tuning

    func updateGlobalStatTuning(_ tuning: [String: Double]) {
        guard !tuning.isEmpty else { return }
        globalStatTuning = tuning
        if let data = try? JSONSerialization.data(withJSONObject: tuning, options: []) {
            UserDefaults.standard.set(data, forKey: statTuningDefaultsKey)
        }
    }

    private func loadGlobalStatTuning() {
        guard let data = UserDefaults.standard.data(forKey: statTuningDefaultsKey),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Double]
        else {
            globalStatTuning = [:]
            return
        }
        globalStatTuning = obj
    }

    private func tuned(_ stat: String, _ value: Double) -> Double {
        let mult = globalStatTuning[stat] ?? 1.0
        return max(0, value * mult)
    }

    // MARK: - Batch: project all players in a game

    /// Queries SwiftData for all players in the game in a single batched fetch.
    /// Must be called on the MainActor (reads from SwiftData main context).
    @MainActor
    func projectGame(
        game: ScheduleGame,
        players: [Player],
        isPlayoffs: Bool,
        isFirstRound: Bool = false
    ) -> [String: PlayerProjection] {
        let ctx       = AppDatabase.shared.mainContext
        let cutoffStr = daysAgoStr(365)     // fetch up to 365 days so 2025 seed data is included; engine caps at 20 games
        let awayTeam = game.awayTeam.uppercased()
        let homeTeam = game.homeTeam.uppercased()

        func matchesGameTeams(_ player: Player) -> Bool {
            let teamCode = (player.team ?? "").uppercased()
            if teamCode == awayTeam || teamCode == homeTeam {
                return true
            }
            // Fallback: infer active team from recent logs when roster team code is stale.
            if let inferred = LocalDataService.shared.localLogs(playerID: player.playerID).first?.team?.uppercased() {
                return inferred == awayTeam || inferred == homeTeam
            }
            return false
        }

        let gamePlayers = players.filter { matchesGameTeams($0) }
        guard !gamePlayers.isEmpty else { return [:] }

        // Alias map for handling occasional player_id changes between sources.
        let storedPlayers = (try? ctx.fetch(FetchDescriptor<StoredPlayer>())) ?? []
        var aliasIDsByName: [String: Set<String>] = [:]
        for sp in storedPlayers {
            let key = sp.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !key.isEmpty else { continue }
            aliasIDsByName[key, default: []].insert(sp.playerID)
        }

        // ── Batched fetch: date-window only (predicate-safe), then filter in memory ──
        let playerIDSet = Set(gamePlayers.map { $0.playerID })
        let desc = FetchDescriptor<StoredGameLog>(
            predicate: #Predicate { log in
                log.gameDate >= cutoffStr
            },
            sortBy: [SortDescriptor(\.gameDate, order: .reverse)]
        )
        let allLogs = ((try? ctx.fetch(desc)) ?? [])
            .filter { playerIDSet.contains($0.playerID) }
            .map { $0.toGameLog() }

        // Group logs by playerID in memory
        var logsByPlayer: [String: [GameLog]] = [:]
        for log in allLogs {
            guard let pid = log.playerID else { continue }
            logsByPlayer[pid, default: []].append(log)
        }

        // Project each player using their pre-loaded logs
        var result: [String: PlayerProjection] = [:]
        for player in gamePlayers {
            let isHome   = (player.team ?? "").uppercased() == game.homeTeam.uppercased()
            let opponent = isHome ? game.awayTeam : game.homeTeam
            let batchedLogs = Array((logsByPlayer[player.playerID] ?? []).prefix(maxLogs))
            var logs: [GameLog] = {
                if !batchedLogs.isEmpty { return batchedLogs }
                return Array(LocalDataService.shared.localLogs(playerID: player.playerID).prefix(maxLogs))
            }()

            if logs.isEmpty {
                let nameKey = player.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                if let aliases = aliasIDsByName[nameKey], !aliases.isEmpty {
                    for aliasID in aliases where aliasID != player.playerID {
                        let aliasLogs = Array(LocalDataService.shared.localLogs(playerID: aliasID).prefix(maxLogs))
                        if !aliasLogs.isEmpty {
                            logs = aliasLogs
                            break
                        }
                    }
                }
            }

            let details  = game.gameID.flatMap { LocalDataService.shared.gameDetails[$0] }
            let hoursToTip = hoursUntilTip(from: game.gameTime)

            // Availability risk from injury report + recent minutes trend.
            let statusRisk: Double = {
                let pool = (game.missingAwayPlayers + game.missingHomePlayers)
                guard let miss = pool.first(where: { ($0.name ?? "").caseInsensitiveCompare(player.name) == .orderedSame }) else {
                    return 0.0
                }
                let status = (miss.status ?? "").uppercased()
                var base: Double
                switch status {
                case "OUT":          base = 1.0
                case "DOUBTFUL":     base = 0.78
                case "QUESTIONABLE": base = 0.48
                default:              base = 0.0
                }
                if let hrs = hoursToTip, hrs <= 2, (status == "DOUBTFUL" || status == "QUESTIONABLE") {
                    base += 0.12
                }
                if let reason = miss.reason?.lowercased(), reason.contains("minute") || reason.contains("limit") {
                    base += 0.10
                }
                if details?.statusCode == 2, status != "" {
                    base = max(base, 0.90)
                }
                return min(1.0, base)
            }()

            let minutesRisk: Double = {
                let mins3 = Array(logs.prefix(3)).map(\.min)
                let mins10 = Array(logs.prefix(10)).map(\.min)
                guard mins3.count >= 2, mins10.count >= 5 else { return 0.0 }
                let m3 = mins3.reduce(0, +) / Double(mins3.count)
                let m10 = mins10.reduce(0, +) / Double(mins10.count)
                guard m10 > 0 else { return 0.0 }
                if m3 < 16 { return 0.55 }
                if m3 < 22 { return 0.30 }
                if m3 < m10 * 0.85 { return 0.20 }
                return 0.0
            }()

            // Individual-defender matchup (memoized per player+game).
            let matchup = MatchupDefenseEvaluator.cached(
                player: player, game: game, dataService: LocalDataService.shared
            )
            let projCtx  = ProjectionContext(
                opponent: opponent,
                isHome: isHome,
                isPlayoffs: isPlayoffs,
                isFirstRound: isFirstRound,
                gameDate: game.date,
                availabilityRisk: min(1.0, max(statusRisk, minutesRisk)),
                gameStatusCode: details?.statusCode,
                period: details?.period,
                hoursToTip: hoursToTip,
                playerPosition: player.position,
                defenderMatchup: matchup
            )
            result[player.playerID] = project(player: player, logs: logs, context: projCtx)
        }
        return result
    }

    // MARK: - Single-player projection

    func project(player: Player, logs: [GameLog], context: ProjectionContext) -> PlayerProjection {
        guard !logs.isEmpty else { return .empty(player: player) }
        let recent = Array(logs.prefix(maxLogs))
        let declineSignal = sustainedDeclineSignal(recent)

        let ptsCalibration = calibrationProfile(for: recent, keyPath: \.pts)
        let rebCalibration = calibrationProfile(for: recent, keyPath: \.reb)
        let astCalibration = calibrationProfile(for: recent, keyPath: \.ast)
        let threeCalibration = calibrationProfile(for: recent, keyPath: \.threepm)
        let stlCalibration = calibrationProfile(for: recent, keyPath: \.stl)
        let blkCalibration = calibrationProfile(for: recent, keyPath: \.blk)
        let ftmCalibration = calibrationProfile(for: recent, keyPath: \.ftm)

        let pts     = roundHalf(projectStat(recent, keyPath: \.pts,     context: context) * declineSignal.projectionMultiplier)
        let reb     = roundHalf(projectStat(recent, keyPath: \.reb,     context: context) * declineSignal.projectionMultiplier)
        let ast     = roundHalf(projectStat(recent, keyPath: \.ast,     context: context) * declineSignal.projectionMultiplier)
        let prLine  = pts + reb
        let paLine  = pts + ast
        let raLine  = reb + ast
        let praLine = pts + reb + ast
        let ftm     = roundHalf(projectStat(recent, keyPath: \.ftm,     context: context) * declineSignal.projectionMultiplier)
        let threepm = roundHalf(projectStat(recent, keyPath: \.threepm, context: context) * declineSignal.projectionMultiplier)
        let stl     = roundHalf(projectStat(recent, keyPath: \.stl,     context: context) * declineSignal.projectionMultiplier)
        let blk     = roundHalf(projectStat(recent, keyPath: \.blk,     context: context) * declineSignal.projectionMultiplier)
        let tov     = projectStat(recent, keyPath: \.tov,     context: context)
        let fptsLine = pts + (reb * 1.2) + (ast * 1.5) + (stl * 3.0) + (blk * 3.0) - tov
        let ddRate  = hitRateDD(recent)
        let tdRate  = hitRateTD(recent)

        // Projected minutes: simple weighted average of recent game minutes
        let minValues = recent.map { $0.min }
        let minutes   = weightedAverage(minValues)

        // Per-stat confidence: recency-weighted hit rate vs the projected value (last 15 games)
        let ptsConf = hitRate(recent, keyPath: \.pts,     line: pts)
        let maxConf = context.isPlayoffs ? playoffMaxConf : 1.0
        let confidencePenalty = confidencePenaltyMultiplier(
            volatility: {
                let vals = recent.compactMap(\.pts)
                guard vals.count >= 3 else { return 0.5 }
                let mean = vals.reduce(0, +) / Double(vals.count)
                guard mean > 0 else { return 0.5 }
                let variance = vals.map { pow($0 - mean, 2) }.reduce(0, +) / Double(vals.count)
                return min(1.0, sqrt(variance) / mean)
            }(),
            uncertainty: ptsCalibration.uncertainty,
            availabilityRisk: context.availabilityRisk
        )
        let confidences: [String: Double] = [
            "PTS": min(maxConf, ptsConf * confidencePenalty * declineSignal.confidenceMultiplier),
            "REB": min(maxConf, hitRate(recent, keyPath: \.reb,     line: reb) * confidencePenaltyMultiplier(volatility: 0.35, uncertainty: rebCalibration.uncertainty, availabilityRisk: context.availabilityRisk) * declineSignal.confidenceMultiplier),
            "AST": min(maxConf, hitRate(recent, keyPath: \.ast,     line: ast) * confidencePenaltyMultiplier(volatility: 0.35, uncertainty: astCalibration.uncertainty, availabilityRisk: context.availabilityRisk) * declineSignal.confidenceMultiplier),
            "PR":  min(maxConf, hitRatePR(recent, line: prLine) * confidencePenalty * declineSignal.confidenceMultiplier),
            "PA":  min(maxConf, hitRatePA(recent, line: paLine) * confidencePenalty * declineSignal.confidenceMultiplier),
            "RA":  min(maxConf, hitRateRA(recent, line: raLine) * confidencePenalty * declineSignal.confidenceMultiplier),
            "3PM": min(maxConf, hitRate(recent, keyPath: \.threepm, line: threepm) * confidencePenaltyMultiplier(volatility: 0.40, uncertainty: threeCalibration.uncertainty, availabilityRisk: context.availabilityRisk) * declineSignal.confidenceMultiplier),
            "PRA": min(maxConf, hitRatePRA(recent, line: praLine) * confidencePenalty * declineSignal.confidenceMultiplier),
            "FPTS": min(maxConf, hitRateFPTS(recent, line: fptsLine) * confidencePenalty * declineSignal.confidenceMultiplier),
            "FTM": min(maxConf, hitRate(recent, keyPath: \.ftm,     line: ftm) * confidencePenaltyMultiplier(volatility: 0.35, uncertainty: ftmCalibration.uncertainty, availabilityRisk: context.availabilityRisk) * declineSignal.confidenceMultiplier),
            "STL": min(maxConf, hitRate(recent, keyPath: \.stl,     line: stl) * confidencePenaltyMultiplier(volatility: 0.45, uncertainty: stlCalibration.uncertainty, availabilityRisk: context.availabilityRisk) * declineSignal.confidenceMultiplier),
            "BLK": min(maxConf, hitRate(recent, keyPath: \.blk,     line: blk) * confidencePenaltyMultiplier(volatility: 0.45, uncertainty: blkCalibration.uncertainty, availabilityRisk: context.availabilityRisk) * declineSignal.confidenceMultiplier),
            "DD":  min(maxConf, ddRate),
            "TD":  min(maxConf, tdRate),
        ]

        // ── Percentile ranges: 25th / 75th of recent game values ─────────────────
        let floorCeiling: (floors: [String: Double], ceilings: [String: Double]) = {
            typealias KP = KeyPath<GameLog, Double?>
            let statKPs: [(String, KP)] = [
                ("PTS", \.pts), ("REB", \.reb), ("AST", \.ast),
                ("3PM", \.threepm), ("FTM", \.ftm), ("STL", \.stl), ("BLK", \.blk)
            ]
            var f: [String: Double] = [:]
            var c: [String: Double] = [:]
            for (label, kp) in statKPs {
                let vals = recent.compactMap { $0[keyPath: kp] }.filter { $0 > 0 }.sorted()
                f[label] = percentileValue(vals, 0.25)
                c[label] = percentileValue(vals, 0.75)
            }
            let praVals = recent.compactMap { log -> Double? in
                guard let p = log.pts, let r = log.reb, let a = log.ast else { return nil }
                return p + r + a
            }.sorted()
            let prVals = recent.compactMap { log -> Double? in
                guard let p = log.pts, let r = log.reb else { return nil }
                return p + r
            }.sorted()
            let paVals = recent.compactMap { log -> Double? in
                guard let p = log.pts, let a = log.ast else { return nil }
                return p + a
            }.sorted()
            let raVals = recent.compactMap { log -> Double? in
                guard let r = log.reb, let a = log.ast else { return nil }
                return r + a
            }.sorted()
            f["PR"] = percentileValue(prVals, 0.25)
            c["PR"] = percentileValue(prVals, 0.75)
            f["PA"] = percentileValue(paVals, 0.25)
            c["PA"] = percentileValue(paVals, 0.75)
            f["RA"] = percentileValue(raVals, 0.25)
            c["RA"] = percentileValue(raVals, 0.75)
            f["PRA"] = percentileValue(praVals, 0.25)
            c["PRA"] = percentileValue(praVals, 0.75)
            let fptsVals = recent.map(\.fantasyScore).filter { $0 > 0 }.sorted()
            f["FPTS"] = percentileValue(fptsVals, 0.25)
            c["FPTS"] = percentileValue(fptsVals, 0.75)
            return (f, c)
        }()

        // ── Volatility: PTS coefficient of variation ───────────────────────────────
        let volatility: Double = {
            let vals = recent.compactMap(\.pts)
            guard vals.count >= 3 else { return 0.5 }
            let mean = vals.reduce(0, +) / Double(vals.count)
            guard mean > 0 else { return 0.5 }
            let variance = vals.map { pow($0 - mean, 2) }.reduce(0, +) / Double(vals.count)
            return min(1.0, sqrt(variance) / mean)
        }()

        // ── Streak factor: L3 vs L10 PTS delta, scaled to [−1, +1] ─────────────────
        let streakFactor: Double = {
            let pts3  = Array(recent.prefix(3)).compactMap(\.pts)
            let pts10 = Array(recent.prefix(10)).compactMap(\.pts)
            guard pts3.count >= 2, pts10.count >= 5 else { return 0.0 }
            let avg3  = pts3.reduce(0, +) / Double(pts3.count)
            let avg10 = pts10.reduce(0, +) / Double(pts10.count)
            guard avg10 > 0 else { return 0.0 }
            return max(-1.0, min(1.0, ((avg3 - avg10) / avg10) * 3.0))
        }()

        return PlayerProjection(
            playerID:     player.playerID,
            playerName:   player.name,
            team:         player.team ?? "",
            gameCount:    recent.count,
            pts:          pts,
            reb:          reb,
            ast:          ast,
            pr:           prLine,
            pa:           paLine,
            ra:           raLine,
            pra:          praLine,
            fpts:         roundHalf(fptsLine),
            ftm:          ftm,
            threepm:      threepm,
            stl:          stl,
            blk:          blk,
            dd:           ddRate,
            td:           tdRate,
            minutes:      minutes,
            confidence:   ptsConf,
            confidences:  confidences,
            floors:       floorCeiling.floors,
            ceilings:     floorCeiling.ceilings,
            volatility:   volatility,
            streakFactor: streakFactor,
            declineStreakGames: declineSignal.streakGames,
            declineProjectionPenalty: declineSignal.projectionMultiplier,
            declineConfidencePenalty: declineSignal.confidenceMultiplier,
            isPlayoffs:   context.isPlayoffs
        )
    }

    // MARK: - Sustained decline signal

    /// Detects multi-game downturns relative to the player's own recent baseline.
    private func sustainedDeclineSignal(_ logs: [GameLog]) -> DeclineSignal {
        let recent = Array(logs.prefix(12))
        guard recent.count >= 8 else {
            return DeclineSignal(streakGames: 0, projectionMultiplier: 1.0, confidenceMultiplier: 1.0)
        }

        let baselineSlice = Array(recent.dropFirst(3).prefix(7))
        let baselineScores = baselineSlice.map(\.fantasyScore).filter { $0 > 0 }
        guard baselineScores.count >= 5 else {
            return DeclineSignal(streakGames: 0, projectionMultiplier: 1.0, confidenceMultiplier: 1.0)
        }
        let baselineScore = baselineScores.reduce(0, +) / Double(baselineScores.count)

        let baselineMinutesRaw = baselineSlice.map(\.min).filter { $0 > 0 }
        let baselineMinutes = baselineMinutesRaw.isEmpty
            ? 0
            : (baselineMinutesRaw.reduce(0, +) / Double(baselineMinutesRaw.count))

        guard baselineScore > 0 else {
            return DeclineSignal(streakGames: 0, projectionMultiplier: 1.0, confidenceMultiplier: 1.0)
        }

        var streakGames = 0
        var streakScores: [Double] = []

        for game in recent {
            let score = game.fantasyScore
            guard score > 0 else { break }

            let lowScore = score <= baselineScore * 0.84
            let lowMinutes = baselineMinutes > 0 && game.min <= baselineMinutes * 0.90
            let isDeclineGame = lowScore || (score <= baselineScore * 0.90 && lowMinutes)

            if isDeclineGame {
                streakGames += 1
                streakScores.append(score)
            } else {
                break
            }
        }

        guard streakGames >= 2, !streakScores.isEmpty else {
            return DeclineSignal(streakGames: 0, projectionMultiplier: 1.0, confidenceMultiplier: 1.0)
        }

        let streakAvg = streakScores.reduce(0, +) / Double(streakScores.count)
        let declinePct = max(0.0, min(0.45, (baselineScore - streakAvg) / baselineScore))
        let severity = max(0.0, min(1.0, (declinePct - 0.10) / 0.25))

        let projectionPenalty = max(0.84, 1.0 - (0.03 * Double(streakGames)) - (0.07 * severity))
        let confidencePenalty = max(0.80, 1.0 - (0.025 * Double(streakGames)) - (0.05 * severity))

        return DeclineSignal(
            streakGames: streakGames,
            projectionMultiplier: projectionPenalty,
            confidenceMultiplier: confidencePenalty
        )
    }

    // MARK: - Core stat algorithm

    private func projectStat(
        _ logs: [GameLog],
        keyPath: KeyPath<GameLog, Double?>,
        context: ProjectionContext
    ) -> Double {
        let values = logs.compactMap { $0[keyPath: keyPath] }
        guard !values.isEmpty else { return 0 }

        let base = weightedAverage(values)
        guard base > 0 else { return 0 }

        let oppMult = opponentMultiplier(
            logs: logs, keyPath: keyPath,
            opponent: context.opponent, base: base
        )
        // Pronounced NBA home-court advantage — use ±2.5%
        let homeAwayMult: Double = {
            switch context.isHome {
            case true:  return 1.025
            case false: return 0.975
            default:    return 1.0
            }
        }()
        let restMult = restMultiplier(logs: logs, gameDate: context.gameDate)
        let modeMult = context.isPlayoffs ? playoffMult : aggressiveMult

        // Minutes trend penalty: recent minutes drop vs baseline lowers projection.
        let minutesTrendMult: Double = {
            let recent3 = Array(logs.prefix(3)).map(\.min)
            let recent10 = Array(logs.prefix(10)).map(\.min)
            guard recent3.count >= 2, recent10.count >= 5 else { return 1.0 }
            let m3 = recent3.reduce(0, +) / Double(recent3.count)
            let m10 = recent10.reduce(0, +) / Double(recent10.count)
            guard m10 > 0 else { return 1.0 }
            let ratio = m3 / m10
            return max(0.85, min(1.01, ratio))
        }()

        // Availability risk penalty (injury/questionable/minutes concern).
        let availabilityMult = max(0.88, 1.0 - (context.availabilityRisk * 0.12))

        // Recent streak adjustment: asymmetric cap (more downside than upside) to curb over-projection.
        let streakMult: Double = {
            let recent3  = Array(logs.prefix(3)).compactMap { $0[keyPath: keyPath] }
            let recent10 = Array(logs.prefix(10)).compactMap { $0[keyPath: keyPath] }
            guard recent3.count >= 2, recent10.count >= 5 else { return 1.0 }
            let avg3  = recent3.reduce(0, +) / Double(recent3.count)
            let avg10 = recent10.reduce(0, +) / Double(recent10.count)
            guard avg10 > 0 else { return 1.0 }
            let delta = (avg3 - avg10) / avg10
            return 1.0 + max(-0.06, min(0.03, delta * 0.25))
        }()

        // Blend in consistency and derived advanced metrics so hot/cold efficiency
        // and role stability influence every projection directly.
        let consistencyMult = consistencyMultiplier(values: values)
        let advancedMult = advancedMetricsMultiplier(
            logs: logs,
            keyPath: keyPath,
            base: base
        )
        let calibration = calibrationProfile(for: logs, keyPath: keyPath)
        let calibrationMult = calibrationMultiplier(from: calibration)
        let uncertaintyMult = uncertaintyPenaltyMultiplier(from: calibration)
        let opponentEnvMult = opponentEnvironmentMultiplier(
            opponent: context.opponent,
            keyPath: keyPath,
            playerPosition: context.playerPosition
        )
        let blowoutMult = blowoutRiskMultiplier(logs: logs, opponent: context.opponent)
        let statusMult = gameStatusMinutesMultiplier(context: context)
        // Individual-defender matchup: opposing same-position starter's interior presence.
        let defenderMult = context.defenderMatchup?.multiplier(for: statLabel(for: keyPath)) ?? 1.0
        let combined = base
            * oppMult
            * homeAwayMult
            * restMult
            * modeMult
            * streakMult
            * minutesTrendMult
            * availabilityMult
            * consistencyMult
            * advancedMult
            * calibrationMult
            * uncertaintyMult
            * opponentEnvMult
            * blowoutMult
            * statusMult
            * defenderMult

        // Keep single-game adjustments from drifting too far from recency-weighted baseline.
        let clampedToBase = max(base * 0.70, min(base * 1.12, combined))
        let biasAdjusted  = context.isPlayoffs ? clampedToBase : (clampedToBase * regularSeasonBiasMult)

        let postExtra      = context.isPlayoffs ? biasAdjusted * playoffExtraMult : biasAdjusted
        let adjusted       = (context.isPlayoffs && context.isFirstRound) ? postExtra * playoffFirstRoundMult : postExtra
        let tunedValue = tuned(statLabel(for: keyPath), adjusted)
        return max(0, roundHalf(tunedValue))
    }

    // MARK: - Exponential-decay weighted average

    private func weightedAverage(_ values: [Double]) -> Double {
        var sumW = 0.0, sumWV = 0.0
        for (i, v) in values.enumerated() {
            let w = exp(-Double(i) * decayLambda)
            sumW  += w
            sumWV += w * v
        }
        return sumW > 0 ? sumWV / sumW : 0
    }

    // MARK: - Consistency + advanced metrics multipliers

    /// Stable performers (low coefficient of variation) get a small boost;
    /// highly volatile performers get a slight downgrade.
    private func consistencyMultiplier(values: [Double]) -> Double {
        guard values.count >= 5 else { return 1.0 }
        let mean = values.reduce(0, +) / Double(values.count)
        guard mean > 0 else { return 1.0 }
        let variance = values.map { pow($0 - mean, 2) }.reduce(0, +) / Double(values.count)
        let cv = sqrt(variance) / mean
        // cv <= 0.20 => +2%, cv >= 0.60 => -3%
        let normalized = max(0.0, min(1.0, (cv - 0.20) / 0.40))
        return 1.02 - (normalized * 0.05)
    }

    /// Derived advanced metrics from available NBA box-score fields.
    /// Uses TS%, usage proxy, AST/TOV quality, and stocks-per-minute trend.
    private func advancedMetricsMultiplier(
        logs: [GameLog],
        keyPath: KeyPath<GameLog, Double?>,
        base: Double
    ) -> Double {
        guard !logs.isEmpty, base > 0 else { return 1.0 }

        let recent = Array(logs.prefix(10))
        let short = Array(logs.prefix(3))

        // True shooting trend (scoring efficiency).
        let tsRecent = averageTrueShooting(short)
        let tsBase = averageTrueShooting(recent)
        let tsMult: Double = {
            guard let t3 = tsRecent, let t10 = tsBase, t10 > 0 else { return 1.0 }
            let delta = (t3 - t10) / t10
            return 1.0 + max(-0.03, min(0.03, delta * 0.20))
        }()

        // Usage trend proxy: (FGA + 0.44*FTA + TOV) / minute.
        let usage3 = usageProxy(short)
        let usage10 = usageProxy(recent)
        let usageMult: Double = {
            guard usage10 > 0 else { return 1.0 }
            let delta = (usage3 - usage10) / usage10
            return 1.0 + max(-0.04, min(0.04, delta * 0.22))
        }()

        // Playmaking quality trend from AST/TOV ratio.
        let astTov3 = astTovRatio(short)
        let astTov10 = astTovRatio(recent)
        let playmakingMult: Double = {
            guard astTov10 > 0 else { return 1.0 }
            let delta = (astTov3 - astTov10) / astTov10
            return 1.0 + max(-0.03, min(0.03, delta * 0.18))
        }()

        // Defensive event rate trend from stocks (STL + BLK) per minute.
        let stocks3 = stocksPerMinute(short)
        let stocks10 = stocksPerMinute(recent)
        let stocksMult: Double = {
            guard stocks10 > 0 else { return 1.0 }
            let delta = (stocks3 - stocks10) / stocks10
            return 1.0 + max(-0.04, min(0.04, delta * 0.20))
        }()

        // Stat-specific blend so only relevant advanced metrics apply.
        if keyPath == \GameLog.pts || keyPath == \GameLog.threepm || keyPath == \GameLog.ftm {
            return max(0.92, min(1.08, tsMult * usageMult))
        }
        if keyPath == \GameLog.ast {
            return max(0.93, min(1.08, usageMult * playmakingMult))
        }
        if keyPath == \GameLog.reb {
            // Rebounds are mostly role/minutes driven; usage gets a minor effect.
            return max(0.95, min(1.05, 1.0 + ((usageMult - 1.0) * 0.35)))
        }
        if keyPath == \GameLog.stl || keyPath == \GameLog.blk {
            return max(0.92, min(1.08, stocksMult * (1.0 + ((usageMult - 1.0) * 0.20))))
        }

        // Composite or fallback stats still get light advanced influence.
        let blended = 1.0 + ((tsMult - 1.0) * 0.35) + ((usageMult - 1.0) * 0.40) + ((playmakingMult - 1.0) * 0.25)
        return max(0.94, min(1.06, blended))
    }

    private func averageTrueShooting(_ logs: [GameLog]) -> Double? {
        let values = logs.compactMap { log -> Double? in
            guard let pts = log.pts, let fga = log.fga, let fta = log.fta else { return nil }
            let denom = 2.0 * (fga + 0.44 * fta)
            guard denom > 0 else { return nil }
            return pts / denom
        }
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +) / Double(values.count)
    }

    private func usageProxy(_ logs: [GameLog]) -> Double {
        let values = logs.compactMap { log -> Double? in
            let min = log.min
            guard min > 0 else { return nil }
            let fga = log.fga ?? 0
            let fta = log.fta ?? 0
            let tov = log.tov ?? 0
            return (fga + (0.44 * fta) + tov) / min
        }
        guard !values.isEmpty else { return 0 }
        return values.reduce(0, +) / Double(values.count)
    }

    private func astTovRatio(_ logs: [GameLog]) -> Double {
        let ast = logs.compactMap(\.ast).reduce(0, +)
        let tov = logs.compactMap(\.tov).reduce(0, +)
        // Treat near-zero turnovers as strong ball security, but cap impact upstream.
        return tov <= 0.1 ? ast : (ast / tov)
    }

    private func stocksPerMinute(_ logs: [GameLog]) -> Double {
        let values = logs.compactMap { log -> Double? in
            let min = log.min
            guard min > 0 else { return nil }
            let stocks = (log.stl ?? 0) + (log.blk ?? 0)
            return stocks / min
        }
        guard !values.isEmpty else { return 0 }
        return values.reduce(0, +) / Double(values.count)
    }

    private func statLabel(for keyPath: KeyPath<GameLog, Double?>) -> String {
        if keyPath == \GameLog.pts { return "PTS" }
        if keyPath == \GameLog.reb { return "REB" }
        if keyPath == \GameLog.ast { return "AST" }
        if keyPath == \GameLog.threepm { return "3PM" }
        if keyPath == \GameLog.ftm { return "FTM" }
        if keyPath == \GameLog.stl { return "STL" }
        if keyPath == \GameLog.blk { return "BLK" }
        return ""
    }

    private func gameStatusMinutesMultiplier(context: ProjectionContext) -> Double {
        var mult = 1.0
        if let status = context.gameStatusCode {
            if status == 2 { mult *= 0.94 }
            if status == 3 { mult *= 0.92 }
        }
        if let period = context.period, period > 0 { mult *= 0.96 }
        if let hrs = context.hoursToTip, hrs <= 1.5, context.availabilityRisk >= 0.40 {
            mult *= 0.93
        }
        return max(0.85, min(1.0, mult))
    }

    /// Player-level rolling calibration from pseudo out-of-sample backtesting on
    /// the most recent games. This reduces persistent over/under projection bias.
    private func calibrationProfile(
        for logs: [GameLog],
        keyPath: KeyPath<GameLog, Double?>
    ) -> CalibrationProfile {
        guard logs.count >= 8 else {
            return CalibrationProfile(biasMultiplier: 1.0, uncertainty: 0.22, sampleCount: 0)
        }

        let targetCount = min(8, logs.count - 5)
        var ratioWeightedSum = 0.0
        var apeWeightedSum = 0.0
        var sumW = 0.0
        var used = 0

        for idx in 0..<targetCount {
            guard let actual = logs[idx][keyPath: keyPath], actual >= 0 else { continue }
            let history = Array(logs[(idx + 1)...].prefix(10))
            let histVals = history.compactMap { $0[keyPath: keyPath] }
            guard histVals.count >= 4 else { continue }
            let pred = weightedAverage(histVals)
            guard pred > 0 else { continue }

            let w = exp(-Double(idx) * 0.35)
            let ratio = actual / pred
            let ape = abs(actual - pred) / max(1.0, pred)

            ratioWeightedSum += w * ratio
            apeWeightedSum += w * ape
            sumW += w
            used += 1
        }

        guard used >= 3, sumW > 0 else {
            return CalibrationProfile(biasMultiplier: 1.0, uncertainty: 0.24, sampleCount: used)
        }

        let rawBias = ratioWeightedSum / sumW
        let rawAPE = apeWeightedSum / sumW
        let strength = min(1.0, Double(used) / 6.0)

        let shrunkBias = 1.0 + ((rawBias - 1.0) * strength)
        let bias = max(0.88, min(1.12, shrunkBias))
        let uncertainty = max(0.08, min(0.55, rawAPE))

        return CalibrationProfile(biasMultiplier: bias, uncertainty: uncertainty, sampleCount: used)
    }

    private func calibrationMultiplier(from profile: CalibrationProfile) -> Double {
        guard profile.sampleCount > 0 else { return 1.0 }
        return profile.biasMultiplier
    }

    private func uncertaintyPenaltyMultiplier(from profile: CalibrationProfile) -> Double {
        guard profile.sampleCount > 0 else { return 1.0 }
        // Larger modeled error history shrinks projection magnitude modestly.
        return max(0.92, min(1.0, 1.0 - (profile.uncertainty * 0.08)))
    }

    private func confidencePenaltyMultiplier(
        volatility: Double,
        uncertainty: Double,
        availabilityRisk: Double
    ) -> Double {
        let v = max(0.0, min(1.0, volatility))
        let u = max(0.0, min(1.0, uncertainty))
        let a = max(0.0, min(1.0, availabilityRisk))
        let penalty = (v * 0.18) + (u * 0.22) + (a * 0.25)
        return max(0.60, min(1.0, 1.0 - penalty))
    }

    /// Slightly trims raw output in likely blowout spots where late-game minutes
    /// become less reliable for top-rotation players.
    private func blowoutRiskMultiplier(logs: [GameLog], opponent: String?) -> Double {
        guard let opp = opponent?.uppercased(),
              let team = logs.first?.team?.uppercased() else { return 1.0 }

        let standings = LocalDataService.shared.standingsMap
        guard let own = standings[team], let oppTeam = standings[opp] else { return 1.0 }

        let diff = abs(own.netRating - oppTeam.netRating)
        if diff >= 15 { return 0.94 }
        if diff >= 10 { return 0.97 }
        return 1.0
    }

    /// Opponent environment boost/penalty from team-level advanced metrics.
    /// Keeps impact intentionally small and bounded to avoid overfitting.
    private func opponentEnvironmentMultiplier(
        opponent: String?,
        keyPath: KeyPath<GameLog, Double?>,
        playerPosition: String? = nil
    ) -> Double {
        guard let opp = opponent?.uppercased() else { return 1.0 }
        let map = LocalDataService.shared.teamAdvancedMap
        guard let team = map[opp], !map.isEmpty else { return 1.0 }

        func avg(_ values: [Double?]) -> Double? {
            let nums = values.compactMap { $0 }
            guard !nums.isEmpty else { return nil }
            return nums.reduce(0, +) / Double(nums.count)
        }

        let teams = Array(map.values)
        let avgPace = avg(teams.map(\.pace))
        let avgDef = avg(teams.map(\.defRating))
        let avgTov = avg(teams.map(\.tovPct))
        let avgReb = avg(teams.map(\.rebPct))

        let paceDelta: Double = {
            guard let oppPace = team.pace, let leaguePace = avgPace, leaguePace > 0 else { return 0 }
            return (oppPace - leaguePace) / leaguePace
        }()
        let defDelta: Double = {
            // Higher defensive rating means easier scoring environment.
            guard let oppDef = team.defRating, let leagueDef = avgDef, leagueDef > 0 else { return 0 }
            return (oppDef - leagueDef) / leagueDef
        }()
        let tovDelta: Double = {
            // Higher opponent TOV% means more steal/block opportunity pressure.
            guard let oppTov = team.tovPct, let leagueTov = avgTov, leagueTov > 0 else { return 0 }
            return (oppTov - leagueTov) / leagueTov
        }()
        let rebDelta: Double = {
            // Lower opponent REB% generally leaves more boards for the other side.
            guard let oppReb = team.rebPct, let leagueReb = avgReb, leagueReb > 0 else { return 0 }
            return (leagueReb - oppReb) / leagueReb
        }()

        let posMult = positionSplitMultiplier(
            opponent: opp,
            keyPath: keyPath,
            playerPosition: playerPosition
        )

        if keyPath == \GameLog.pts || keyPath == \GameLog.threepm || keyPath == \GameLog.ftm {
            let boost = (paceDelta * 0.12) + (defDelta * 0.20)
            return 1.0 + max(-0.05, min(0.05, boost))
        }
        if keyPath == \GameLog.ast {
            let boost = (paceDelta * 0.10) + (defDelta * 0.14)
            return 1.0 + max(-0.05, min(0.05, boost))
        }
        if keyPath == \GameLog.reb {
            let boost = (paceDelta * 0.08) + (rebDelta * 0.18)
            return 1.0 + max(-0.04, min(0.04, boost))
        }
        if keyPath == \GameLog.stl || keyPath == \GameLog.blk {
            let boost = (paceDelta * 0.08) + (tovDelta * 0.24)
            return 1.0 + max(-0.05, min(0.05, boost))
        }

        let generic = 1.0 + max(-0.04, min(0.04, (paceDelta * 0.08) + (defDelta * 0.10)))
        return max(0.90, min(1.10, generic * posMult))
    }

    private func positionGroup(for raw: String?) -> String {
        let p = (raw ?? "").uppercased()
        if p.contains("G") { return "GUARD" }
        if p.contains("C") && !p.contains("F") { return "BIG" }
        if p.contains("F") { return "WING" }
        return "WING"
    }

    private func positionSplitMultiplier(
        opponent: String,
        keyPath: KeyPath<GameLog, Double?>,
        playerPosition: String?
    ) -> Double {
        let map = LocalDataService.shared.teamPositionSplitsMap
        guard !map.isEmpty else { return 1.0 }
        let group = positionGroup(for: playerPosition)
        guard let teamSplits = map[opponent], let split = teamSplits[group], split.sampleSize >= 20 else {
            return 1.0
        }

        let allSplits = map.values.flatMap { $0.values }.filter { $0.positionGroup == group && $0.sampleSize >= 20 }
        guard !allSplits.isEmpty else { return 1.0 }

        func avg(_ keyPath: KeyPath<TeamPositionSplitEntry, Double?>) -> Double? {
            let vals = allSplits.compactMap { $0[keyPath: keyPath] }
            guard !vals.isEmpty else { return nil }
            return vals.reduce(0, +) / Double(vals.count)
        }

        func ratio(_ teamVal: Double?, _ leagueAvg: Double?) -> Double {
            guard let t = teamVal, let a = leagueAvg, a > 0 else { return 0 }
            return (t - a) / a
        }

        let delta: Double = {
            if keyPath == \GameLog.pts {
                return ratio(split.ptsAllowed, avg(\.ptsAllowed))
            }
            if keyPath == \GameLog.reb {
                return ratio(split.rebAllowed, avg(\.rebAllowed))
            }
            if keyPath == \GameLog.ast {
                return ratio(split.astAllowed, avg(\.astAllowed))
            }
            if keyPath == \GameLog.threepm {
                return ratio(split.threepmAllowed, avg(\.threepmAllowed))
            }
            if keyPath == \GameLog.stl {
                return ratio(split.stlAllowed, avg(\.stlAllowed))
            }
            if keyPath == \GameLog.blk {
                return ratio(split.blkAllowed, avg(\.blkAllowed))
            }
            return ratio(split.praAllowed, avg(\.praAllowed))
        }()

        let weight = min(1.0, Double(split.sampleSize) / 80.0)
        let boost = delta * 0.22 * weight
        return 1.0 + max(-0.05, min(0.05, boost))
    }

    private func hoursUntilTip(from tipString: String?) -> Double? {
        guard let s = tipString?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
        let cleaned = s
            .replacingOccurrences(of: " ET", with: "", options: .caseInsensitive)
            .replacingOccurrences(of: " EDT", with: "", options: .caseInsensitive)
            .replacingOccurrences(of: " EST", with: "", options: .caseInsensitive)
            .replacingOccurrences(of: " MST", with: "", options: .caseInsensitive)
            .replacingOccurrences(of: " MDT", with: "", options: .caseInsensitive)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.timeZone = TimeZone(identifier: SportConfig.appTimeZoneID)
        fmt.dateFormat = "h:mm a"
        guard let t = fmt.date(from: cleaned) else { return nil }

        let cal = Calendar(identifier: .gregorian)
        let now = Date()
        guard let appTZ = TimeZone(identifier: SportConfig.appTimeZoneID) else { return nil }
        var comps = cal.dateComponents(in: appTZ, from: now)
        let tipComps = cal.dateComponents([.hour, .minute], from: t)
        comps.hour = tipComps.hour
        comps.minute = tipComps.minute
        comps.second = 0
        guard let sameDayTip = cal.date(from: comps) else { return nil }
        return sameDayTip.timeIntervalSince(now) / 3600.0
    }

    // MARK: - Opponent matchup multiplier

    private func opponentMultiplier(
        logs: [GameLog],
        keyPath: KeyPath<GameLog, Double?>,
        opponent: String?,
        base: Double
    ) -> Double {
        guard let opp = opponent, base > 0 else { return 1.0 }
        let oppValues = logs
            .filter { ($0.opponent ?? "").uppercased() == opp.uppercased() }
            .compactMap { $0[keyPath: keyPath] }
        guard oppValues.count >= 3 else { return 1.0 }
        let oppAvg = oppValues.reduce(0, +) / Double(oppValues.count)
        // NBA: wide matchup range — 82-game samples support stronger splits.
        return min(1.30, max(0.75, oppAvg / base))
    }

    // MARK: - Rest-days multiplier

    private func restMultiplier(logs: [GameLog], gameDate: String) -> Double {
        guard let lastStr  = logs.first?.gameDate,
              let lastDate = parseDate(lastStr),
              let gameD    = parseDate(gameDate) else { return 1.0 }
        let days = Calendar.current
            .dateComponents([.day], from: lastDate, to: gameD).day ?? 2
        // NBA congested schedule → meaningful fatigue swings.
        switch days {
        case 0:    return 0.93   // back-to-back — fatigue penalty
        case 1:    return 1.00   // one rest day — normal
        case 2:    return 1.02   // slightly better rested
        default:   return 1.04   // well rested (3+ days off)
        }
    }

    // MARK: - Confidence: recency-weighted hit rate (0–1, snapped to nearest 5%)

    /// Recency-weighted fraction of the last 10 games where the player exceeded `line`.
    /// A 10-game window balances sample size against recency across an 82-game season.
    private func hitRate(
        _ logs: [GameLog],
        keyPath: KeyPath<GameLog, Double?>,
        line: Double
    ) -> Double {
        guard line > 0 else { return 0.5 }
        let window = Array(logs.prefix(10))
        var sumW   = 0.0
        var sumHit = 0.0
        var gameIdx = 0
        for log in window {
            guard let v = log[keyPath: keyPath] else { continue }
            let w    = exp(-Double(gameIdx) * decayLambda)
            sumW    += w
            sumHit  += w * (v > line ? 1.0 : 0.0)
            gameIdx += 1
        }
        guard sumW > 0 else { return 0.5 }
        // Snap to nearest 5%
        return ((sumHit / sumW) * 20).rounded() / 20
    }

    /// Same as `hitRate` but for the composite PTS+REB+AST stat.
    private func hitRatePRA(_ logs: [GameLog], line: Double) -> Double {
        guard line > 0 else { return 0.5 }
        let window = Array(logs.prefix(10))
        var sumW   = 0.0
        var sumHit = 0.0
        var gameIdx = 0
        for log in window {
            guard let p = log.pts, let r = log.reb, let a = log.ast else { continue }
            let v    = p + r + a
            let w    = exp(-Double(gameIdx) * decayLambda)
            sumW    += w
            sumHit  += w * (v > line ? 1.0 : 0.0)
            gameIdx += 1
        }
        guard sumW > 0 else { return 0.5 }
        return ((sumHit / sumW) * 20).rounded() / 20
    }

    /// Same as `hitRate` but for PrizePicks-style fantasy score.
    private func hitRateFPTS(_ logs: [GameLog], line: Double) -> Double {
        guard line > 0 else { return 0.5 }
        let window = Array(logs.prefix(10))
        var sumW   = 0.0
        var sumHit = 0.0
        var gameIdx = 0
        for log in window {
            let v    = log.fantasyScore
            let w    = exp(-Double(gameIdx) * decayLambda)
            sumW    += w
            sumHit  += w * (v > line ? 1.0 : 0.0)
            gameIdx += 1
        }
        guard sumW > 0 else { return 0.5 }
        return ((sumHit / sumW) * 20).rounded() / 20
    }

    /// Same as `hitRate` but for PTS+REB.
    private func hitRatePR(_ logs: [GameLog], line: Double) -> Double {
        guard line > 0 else { return 0.5 }
        let window = Array(logs.prefix(10))
        var sumW   = 0.0
        var sumHit = 0.0
        var gameIdx = 0
        for log in window {
            guard let p = log.pts, let r = log.reb else { continue }
            let v    = p + r
            let w    = exp(-Double(gameIdx) * decayLambda)
            sumW    += w
            sumHit  += w * (v > line ? 1.0 : 0.0)
            gameIdx += 1
        }
        guard sumW > 0 else { return 0.5 }
        return ((sumHit / sumW) * 20).rounded() / 20
    }

    /// Same as `hitRate` but for PTS+AST.
    private func hitRatePA(_ logs: [GameLog], line: Double) -> Double {
        guard line > 0 else { return 0.5 }
        let window = Array(logs.prefix(10))
        var sumW   = 0.0
        var sumHit = 0.0
        var gameIdx = 0
        for log in window {
            guard let p = log.pts, let a = log.ast else { continue }
            let v    = p + a
            let w    = exp(-Double(gameIdx) * decayLambda)
            sumW    += w
            sumHit  += w * (v > line ? 1.0 : 0.0)
            gameIdx += 1
        }
        guard sumW > 0 else { return 0.5 }
        return ((sumHit / sumW) * 20).rounded() / 20
    }

    /// Same as `hitRate` but for REB+AST.
    private func hitRateRA(_ logs: [GameLog], line: Double) -> Double {
        guard line > 0 else { return 0.5 }
        let window = Array(logs.prefix(10))
        var sumW   = 0.0
        var sumHit = 0.0
        var gameIdx = 0
        for log in window {
            guard let r = log.reb, let a = log.ast else { continue }
            let v    = r + a
            let w    = exp(-Double(gameIdx) * decayLambda)
            sumW    += w
            sumHit  += w * (v > line ? 1.0 : 0.0)
            gameIdx += 1
        }
        guard sumW > 0 else { return 0.5 }
        return ((sumHit / sumW) * 20).rounded() / 20
    }

    /// Recency-weighted fraction of the last 10 games where the player recorded a double-double.
    private func hitRateDD(_ logs: [GameLog]) -> Double {
        let window = Array(logs.prefix(10))
        var sumW = 0.0, sumHit = 0.0, idx = 0
        for log in window {
            guard let p = log.pts, let r = log.reb, let a = log.ast else { continue }
            let cats = [p, r, a].filter { $0 >= 10 }.count
            let w    = exp(-Double(idx) * decayLambda)
            sumW    += w
            sumHit  += w * (cats >= 2 ? 1.0 : 0.0)
            idx     += 1
        }
        guard sumW > 0 else { return 0.5 }
        return ((sumHit / sumW) * 20).rounded() / 20
    }

    /// Recency-weighted fraction of the last 10 games where the player recorded a triple-double.
    private func hitRateTD(_ logs: [GameLog]) -> Double {
        let window = Array(logs.prefix(10))
        var sumW = 0.0, sumHit = 0.0, idx = 0
        for log in window {
            guard let p = log.pts, let r = log.reb, let a = log.ast else { continue }
            let cats = [p, r, a].filter { $0 >= 10 }.count
            let w    = exp(-Double(idx) * decayLambda)
            sumW    += w
            sumHit  += w * (cats >= 3 ? 1.0 : 0.0)
            idx     += 1
        }
        guard sumW > 0 else { return 0.0 }
        return ((sumHit / sumW) * 20).rounded() / 20
    }

    // MARK: - Date / rounding helpers

    private func daysAgoStr(_ days: Int) -> String {
        isoDateStr(Calendar.current.date(byAdding: .day, value: -days, to: .now)!)
    }

    private func isoDateStr(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone   = TimeZone(identifier: "UTC")
        return f.string(from: date)
    }

    private func parseDate(_ str: String) -> Date? {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone   = TimeZone(identifier: "UTC")
        return f.date(from: str)
    }

    private func roundHalf(_ v: Double) -> Double {
        (v * 2).rounded() / 2
    }

    /// Linear interpolation percentile on a pre-sorted array.
    private func percentileValue(_ sorted: [Double], _ p: Double) -> Double {
        guard !sorted.isEmpty else { return 0 }
        let idx  = max(0.0, min(Double(sorted.count - 1), p * Double(sorted.count - 1)))
        let lo   = Int(idx)
        let hi   = min(lo + 1, sorted.count - 1)
        return sorted[lo] + (idx - Double(lo)) * (sorted[hi] - sorted[lo])
    }
}

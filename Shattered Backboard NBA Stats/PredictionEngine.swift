//
//  PredictionEngine.swift — On-device NBA stat projections.
//
//  Pure computation — fully offline. No network calls.
//
//  Factors in:
//    • Recency-weighted game-log average (exponential decay, up to 40 games)
//    • Opponent historical matchup (≥ 3 prior games required)
//    • Home / away split
//    • Back-to-back / rest-day fatigue
//    • Slightly aggressive baseline (+10%) in regular season
//    • Conservative mode (−4%) for playoffs    • PTS boosted an additional +18% across all contexts (regular season & playoffs)//  Generates: PTS, REB, AST, PRA, 3PM, STL, BLK
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
    let pra:        Double      // pts + reb + ast
    let threepm:    Double
    let stl:        Double
    let blk:        Double
    let dd:         Double      // recency-weighted double-double rate (0–1)
    let td:         Double      // recency-weighted triple-double rate (0–1)
    let minutes:    Double      // projected minutes per game
    let confidence: Double      // PTS hit rate (0–1, snapped to nearest 0.05)
    let confidences: [String: Double]  // per-stat hit rates
    let isPlayoffs: Bool

    // MARK: Helpers

    /// Returns the hit-rate confidence for a specific stat (falls back to PTS confidence).
    func confidence(for stat: String) -> Double {
        confidences[stat] ?? confidence
    }

    static func empty(player: Player) -> PlayerProjection {
        PlayerProjection(
            playerID: player.playerID, playerName: player.name,
            team: player.team ?? "", gameCount: 0,
            pts: 0, reb: 0, ast: 0, pra: 0,
            threepm: 0, stl: 0, blk: 0, dd: 0, td: 0, minutes: 0,
            confidence: 0, confidences: [:], isPlayoffs: false
        )
    }

    /// Look up a projected value by stat label string.
    func value(for stat: String) -> Double {
        switch stat {
        case "PTS":  return pts
        case "REB":  return reb
        case "AST":  return ast
        case "PRA":  return pra
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

    init(opponent: String?, isHome: Bool?, isPlayoffs: Bool,
         isFirstRound: Bool = false, gameDate: String) {
        self.opponent     = opponent
        self.isHome       = isHome
        self.isPlayoffs   = isPlayoffs
        self.isFirstRound = isFirstRound
        self.gameDate     = gameDate
    }
}

// MARK: - PredictionEngine

final class PredictionEngine {
    static let shared = PredictionEngine()
    private init() {}

    // ── Tuning constants ───────────────────────────────────────────────────────
    private let maxLogs        = 40
    private let decayLambda    = 0.04   // exp(-i × λ) — gentle recency bias
    private let aggressiveMult       = 1.10   // +10% regular season (slightly above typical lines)
    private let playoffMult          = 0.78   // −22% playoffs (tighter defence, lower pace)
    private let playoffExtraMult     = 0.92   // additional −8% in playoffs on top of playoffMult
    private let ptsBoostMult         = 1.18   // +18% PTS-only boost across all contexts (inc. playoffs)
    private let playoffFirstRoundMult = 0.90   // additional −10% for first-round games
    private let playoffMaxConf        = 0.75   // confidence capped at 75% in playoffs

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
        let cutoffStr = daysAgoStr(200)     // fetch up to 200 days; engine caps at 40 games

        let gamePlayers = players.filter {
            let t = ($0.team ?? "").uppercased()
            return t == game.awayTeam.uppercased() || t == game.homeTeam.uppercased()
        }
        guard !gamePlayers.isEmpty else { return [:] }

        // ── Single batched fetch for all players in the game ─────────────────────
        let playerIDs = gamePlayers.map { $0.playerID }
        let desc = FetchDescriptor<StoredGameLog>(
            predicate: #Predicate { log in
                playerIDs.contains(log.playerID) && log.gameDate >= cutoffStr
            },
            sortBy: [SortDescriptor(\.gameDate, order: .reverse)]
        )
        let allLogs = ((try? ctx.fetch(desc)) ?? []).map { $0.toGameLog() }

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
            let logs     = Array((logsByPlayer[player.playerID] ?? []).prefix(maxLogs))
            let projCtx  = ProjectionContext(
                opponent: opponent,
                isHome: isHome,
                isPlayoffs: isPlayoffs,
                isFirstRound: isFirstRound,
                gameDate: game.date
            )
            result[player.playerID] = project(player: player, logs: logs, context: projCtx)
        }
        return result
    }

    // MARK: - Single-player projection

    func project(player: Player, logs: [GameLog], context: ProjectionContext) -> PlayerProjection {
        guard !logs.isEmpty else { return .empty(player: player) }
        let recent = Array(logs.prefix(maxLogs))

        let pts     = projectStat(recent, keyPath: \.pts,     context: context) * ptsBoostMult
        let reb     = projectStat(recent, keyPath: \.reb,     context: context)
        let ast     = projectStat(recent, keyPath: \.ast,     context: context)
        let threepm = projectStat(recent, keyPath: \.threepm, context: context)
        let stl     = projectStat(recent, keyPath: \.stl,     context: context)
        let blk     = projectStat(recent, keyPath: \.blk,     context: context)
        let ddRate  = hitRateDD(recent)
        let tdRate  = hitRateTD(recent)

        // Projected minutes: simple weighted average of recent game minutes
        let minValues = recent.map { $0.min }
        let minutes   = weightedAverage(minValues)

        // Per-stat confidence: recency-weighted hit rate vs the projected value (last 15 games)
        let praLine = pts + reb + ast
        let ptsConf = hitRate(recent, keyPath: \.pts,     line: pts)
        let maxConf = context.isPlayoffs ? playoffMaxConf : 1.0
        let confidences: [String: Double] = [
            "PTS": min(maxConf, ptsConf),
            "REB": min(maxConf, hitRate(recent, keyPath: \.reb,     line: reb)),
            "AST": min(maxConf, hitRate(recent, keyPath: \.ast,     line: ast)),
            "3PM": min(maxConf, hitRate(recent, keyPath: \.threepm, line: threepm)),
            "PRA": min(maxConf, hitRatePRA(recent,                   line: praLine)),
            "STL": min(maxConf, hitRate(recent, keyPath: \.stl,     line: stl)),
            "BLK": min(maxConf, hitRate(recent, keyPath: \.blk,     line: blk)),
            "DD":  min(maxConf, ddRate),
            "TD":  min(maxConf, tdRate),
        ]

        return PlayerProjection(
            playerID:    player.playerID,
            playerName:  player.name,
            team:        player.team ?? "",
            gameCount:   recent.count,
            pts:         pts,
            reb:         reb,
            ast:         ast,
            pra:         pts + reb + ast,
            threepm:     threepm,
            stl:         stl,
            blk:         blk,
            dd:          ddRate,
            td:          tdRate,
            minutes:     minutes,
            confidence:  ptsConf,
            confidences: confidences,
            isPlayoffs:  context.isPlayoffs
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
        let homeAwayMult: Double = {
            switch context.isHome {
            case true:  return 1.025
            case false: return 0.975
            default:    return 1.0
            }
        }()
        let restMult = restMultiplier(logs: logs, gameDate: context.gameDate)
        let modeMult = context.isPlayoffs ? playoffMult : aggressiveMult

        let raw = base * oppMult * homeAwayMult * restMult * modeMult
        let postExtra      = context.isPlayoffs ? raw * playoffExtraMult : raw
        let adjusted       = (context.isPlayoffs && context.isFirstRound) ? postExtra * playoffFirstRoundMult : postExtra
        return max(0, roundHalf(adjusted))
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
        return min(1.30, max(0.75, oppAvg / base))
    }

    // MARK: - Rest-days multiplier

    private func restMultiplier(logs: [GameLog], gameDate: String) -> Double {
        guard let lastStr  = logs.first?.gameDate,
              let lastDate = parseDate(lastStr),
              let gameD    = parseDate(gameDate) else { return 1.0 }
        let days = Calendar.current
            .dateComponents([.day], from: lastDate, to: gameD).day ?? 2
        switch days {
        case 0:    return 0.93   // back-to-back — fatigue penalty
        case 1:    return 1.00   // one rest day — normal
        case 2:    return 1.02   // slightly better rested
        default:   return 1.04   // well rested (3+ days off)
        }
    }

    // MARK: - Confidence: recency-weighted hit rate (0–1, snapped to nearest 5%)

    /// Recency-weighted fraction of the last 15 games where the player exceeded `line`.
    private func hitRate(
        _ logs: [GameLog],
        keyPath: KeyPath<GameLog, Double?>,
        line: Double
    ) -> Double {
        guard line > 0 else { return 0.5 }
        let window = Array(logs.prefix(15))
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
        let window = Array(logs.prefix(15))
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

    /// Recency-weighted fraction of the last 15 games where the player recorded a double-double.
    private func hitRateDD(_ logs: [GameLog]) -> Double {
        let window = Array(logs.prefix(15))
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

    /// Recency-weighted fraction of the last 15 games where the player recorded a triple-double.
    private func hitRateTD(_ logs: [GameLog]) -> Double {
        let window = Array(logs.prefix(15))
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
}

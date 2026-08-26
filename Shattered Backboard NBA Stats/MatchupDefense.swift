//
//  MatchupDefense.swift — Individual-defender matchup adjustment.
//
//  Identifies the opposing starter at the same position (from official
//  lineups) and derives an "interior impact" score from that defender's
//  own rebounds + blocks production. Used by PredictionEngine to dampen
//  projections (mainly REB-centric stats for bigs) and surfaced in the
//  UI as a matchup-risk chip.
//

import Foundation

// MARK: - DefenderMatchup

/// Result of evaluating the opposing team's primary defender for an upcoming game.
struct DefenderMatchup {
    let defenderName: String
    let defenderPosition: String?
    /// 0.0 (no impact) → 1.0 (elite interior presence).
    let impact: Double

    /// Per-stat projection multipliers. Only meaningful adjustments are non-1.0;
    /// guards' stats are barely affected, bigs' rebounds the most.
    func multiplier(for stat: String) -> Double {
        guard impact > 0 else { return 1.0 }
        switch stat {
        case "REB", "RA", "PR", "PRA": return 1.0 - impact * 0.10
        case "FPTS":                   return 1.0 - impact * 0.08
        case "PTS", "PA":              return 1.0 - impact * 0.05
        case "AST":                    return 1.0 - impact * 0.02
        default:                       return 1.0
        }
    }

    /// True when the impact is large enough to warn about in the UI.
    var isSignificant: Bool { impact >= 0.35 }

    var riskLabel: String {
        switch impact {
        case ..<0.20: return "Light pressure"
        case ..<0.40: return "Moderate pressure"
        case ..<0.65: return "Strong interior defense"
        default:      return "Elite interior defense"
        }
    }
}

// MARK: - MatchupDefenseEvaluator

enum MatchupDefenseEvaluator {

    /// Memoized results keyed by playerID + gameID — Top Picks evaluates many
    /// players per scan, and each evaluation touches snapshot + logs.
    private static var cache: [String: DefenderMatchup?] = [:]

    /// Cached wrapper around evaluate(_:). Use this from list/scan contexts.
    static func cached(player: Player,
                       game: ScheduleGame,
                       dataService: LocalDataService) -> DefenderMatchup? {
        let key = "\(player.playerID)|\(game.id)"
        if let hit = cache[key], let match = hit ?? nil {
            return match
        }
        if cache.keys.contains(key) { return nil }   // cached negative result
        let result = evaluate(player: player, game: game, dataService: dataService)
        cache[key] = result
        return result
    }

    /// Call after a lineups refresh so official starters re-evaluate.
    static func clearCache() { cache.removeAll() }

    /// Normalize a raw position string ("G", "F-C", "FC", "Guard") to G / F / C.
    private static func primaryPosition(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        let first = raw.uppercased().trimmingCharacters(in: .whitespaces).first
        switch first {
        case "G", "W": return "G"
        case "F":      return "F"
        case "C":      return "C"
        default:       return nil
        }
    }

    /// Evaluate the defender matchup for a player's upcoming game.
    /// Returns nil when there is no lineup data, no same-position opponent
    /// starter, or the projected player isn't a frontcourt player.
    static func evaluate(player: Player,
                         game: ScheduleGame,
                         dataService: LocalDataService) -> DefenderMatchup? {
        let playerPos = primaryPosition(player.position)
        // Only frontcourt matchups meaningfully suppress production.
        guard playerPos == "F" || playerPos == "C" else { return nil }
        let playerTeam = (player.team ?? "").uppercased()
        guard !playerTeam.isEmpty else { return nil }

        let oppCode = playerTeam == game.homeTeam.uppercased()
            ? game.awayTeam.uppercased() : game.homeTeam.uppercased()

        // Locate the lineup row for this game (by gameID, then date+teams fallback).
        let lineup: GameLineup? = {
            let all = dataService.snapshot?.lineups ?? []
            if let gid = game.gameID, let hit = all.first(where: { $0.gameID == gid }) {
                return hit
            }
            return all.first {
                $0.date == game.date &&
                $0.homeTeam?.uppercased() == game.homeTeam.uppercased() &&
                $0.awayTeam?.uppercased() == game.awayTeam.uppercased()
            }
        }()
        guard let lineup else { return nil }

        // Opposing side's listed starters.
        let oppIsAway = lineup.awayTeam?.uppercased() == oppCode
        let candidates: [LineupPlayer] = (oppIsAway ? lineup.awayLineup : lineup.homeLineup)
            .filter { lp in
                // Trust team tag when present; otherwise the side list itself is authoritative.
                if let team = lp.team?.uppercased(), !team.isEmpty {
                    return team == oppCode
                }
                return true
            }
            .filter { lp in
                let status = (lp.status ?? "").uppercased()
                return !(["OUT", "DOUBTFUL", "INACTIVE", "SUSPENDED"].contains(status))
            }

        // Preference: exact position match → any frontcourt starter.
        let samePos    = candidates.filter { primaryPosition($0.position) == playerPos }
        let frontcourt = candidates.filter { ["F", "C"].contains(primaryPosition($0.position) ?? "") }
        let pool = !samePos.isEmpty ? samePos : frontcourt
        guard let defender = pool.first else { return nil }
        guard let defName = defender.name, !defName.isEmpty else { return nil }

        // Resolve the defender's historical logs via name → roster playerID.
        let logs = logsForDefender(named: defName, team: oppCode, dataService: dataService)

        let impact: Double
        if logs.count >= 5 {
            impact = interiorImpact(logs: logs)
        } else {
            // Unknown/small sample — assume a mild baseline presence rather than zero.
            impact = 0.25
        }

        return DefenderMatchup(
            defenderName: defName,
            defenderPosition: defender.position,
            impact: max(0.0, min(1.0, impact))
        )
    }

    /// Resolve the defender's game logs by matching name → roster playerID.
    private static func logsForDefender(named name: String,
                                        team: String,
                                        dataService: LocalDataService) -> [GameLog] {
        let players = dataService.snapshot?.players ?? []
        let norm: (String) -> String = { $0.lowercased().trimmingCharacters(in: .whitespaces) }
        let target = norm(name)

        // Exact full-name match first, then last-name token fallback.
        let pid: String? = {
            if let p = players.first(where: { norm($0.name) == target && ($0.team ?? "").uppercased() == team }) {
                return p.playerID
            }
            let lastName = target.split(separator: " ").last.map(String.init) ?? target
            if let p = players.first(where: {
                norm($0.name).hasSuffix(" \(lastName)") && ($0.team ?? "").uppercased() == team
            }) {
                return p.playerID
            }
            return nil
        }()
        guard let pid else { return [] }
        return dataService.localLogs(playerID: pid)
    }

    /// Interior-impact score from the defender's own REB + BLK per-36 rates.
    private static func interiorImpact(logs: [GameLog]) -> Double {
        var mins = 0.0, reb = 0.0, blk = 0.0
        for log in logs.prefix(20) {
            let m = log.min
            mins += m
            reb  += log.reb ?? 0
            blk  += log.blk ?? 0
        }
        guard mins >= 120 else { return 0.25 }  // < ~4 full games of minutes → weak signal
        let rebPer36 = reb / mins * 36.0
        let blkPer36 = blk / mins * 36.0
        // League-relative scaling: 5 REB/36 ≈ average big floor, 11 ≈ elite;
        // 0.4 BLK/36 floor, 1.6+ ≈ elite rim protection.
        let rebScore = max(0.0, min(1.0, (rebPer36 - 5.0) / 6.0))
        let blkScore = max(0.0, min(1.0, (blkPer36 - 0.4) / 1.2))
        return max(0.0, min(1.0, 0.55 * rebScore + 0.45 * blkScore))
    }
}


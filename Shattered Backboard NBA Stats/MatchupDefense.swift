//
//  MatchupDefense.swift — Individual-defender matchup adjustment.
//
//  Identifies the most likely direct opposing starter from official lineups.
//  Recent minutes, steals, blocks, and rebounds estimate perimeter pressure
//  and interior resistance for every position group.
//

import Foundation

// MARK: - DefenderMatchup

/// Result of evaluating the opposing team's primary defender for an upcoming game.
struct DefenderMatchup {
    let defenderName: String
    let defenderPosition: String?
    /// 0.0 (no impact) → 1.0 (elite overall defensive activity).
    let impact: Double
    let perimeterImpact: Double
    let interiorImpact: Double
    let assignmentConfidence: Double

    /// Per-stat projection multipliers. Only meaningful adjustments are non-1.0;
    /// Perimeter defenders influence scoring, threes, assists, and turnovers;
    /// interior defenders influence rebounds and paint-dependent production.
    func multiplier(for stat: String) -> Double {
        guard impact > 0 else { return 1.0 }
        switch stat {
        case "REB", "RA":
            return 1.0 - interiorImpact * 0.10 * assignmentConfidence
        case "3PM":
            return 1.0 - perimeterImpact * 0.07 * assignmentConfidence
        case "AST":
            return 1.0 - perimeterImpact * 0.05 * assignmentConfidence
        case "PTS", "PA", "PR", "PRA":
            let combined = perimeterImpact * 0.60 + interiorImpact * 0.40
            return 1.0 - combined * 0.075 * assignmentConfidence
        case "FPTS", "DD", "TD":
            let combined = perimeterImpact * 0.45 + interiorImpact * 0.55
            return 1.0 - combined * 0.08 * assignmentConfidence
        case "TOV":
            return 1.0 + perimeterImpact * 0.08 * assignmentConfidence
        default:
            return 1.0
        }
    }

    /// True when the impact is large enough to warn about in the UI.
    var isSignificant: Bool { impact >= 0.35 }

    var riskLabel: String {
        switch impact {
        case ..<0.20: return "Light pressure"
        case ..<0.40: return "Moderate pressure"
        case ..<0.65: return "Strong matchup pressure"
        default:      return "Elite matchup pressure"
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

    /// Normalize a raw position string to a broad on-court assignment group.
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

    /// Preserve detailed assignments when the feed supplies PG/SG/SF/PF/C.
    private static func detailedPosition(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let value = raw.uppercased()
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: "/", with: "")
            .replacingOccurrences(of: " ", with: "")
        if value.contains("POINT") || value.hasPrefix("PG") { return "PG" }
        if value.contains("SHOOTING") || value.hasPrefix("SG") { return "SG" }
        if value.contains("SMALL") || value.hasPrefix("SF") { return "SF" }
        if value.contains("POWER") || value.hasPrefix("PF") { return "PF" }
        if value == "C" || value.contains("CENTER") { return "C" }
        return nil
    }

    /// Evaluate the defender matchup for a player's upcoming game.
    /// Returns nil when there is no lineup data or no active opposing starter.
    static func evaluate(player: Player,
                         game: ScheduleGame,
                         dataService: LocalDataService) -> DefenderMatchup? {
        let playerPos = primaryPosition(player.position)
        let playerDetailedPos = detailedPosition(player.position)
        guard playerPos != nil else { return nil }
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
        // Prefer official starters. Before lineups are published, project the
        // opposing five by recent minutes so every scheduled prediction still
        // receives a player-vs-player signal.
        let candidates: [LineupPlayer] = {
            if let lineup {
                let oppIsAway = lineup.awayTeam?.uppercased() == oppCode
                let official = (oppIsAway ? lineup.awayLineup : lineup.homeLineup)
                    .filter { lp in
                        if let team = lp.team?.uppercased(), !team.isEmpty {
                            return team == oppCode
                        }
                        return true
                    }
                    .filter { isAvailable(status: $0.status) }
                if !official.isEmpty {
                    return official
                }
            }

            let unavailableNames = Set(
                (game.missingAwayPlayers + game.missingHomePlayers)
                    .filter { !isAvailable(status: $0.status) }
                    .compactMap(\.name)
                    .map { normalizedName($0) }
            )
            return (dataService.snapshot?.players ?? [])
                .filter { ($0.team ?? "").uppercased() == oppCode }
                .filter { !unavailableNames.contains(normalizedName($0.name)) }
                .sorted {
                    recentMinutes(playerID: $0.playerID, dataService: dataService)
                        > recentMinutes(playerID: $1.playerID, dataService: dataService)
                }
                .prefix(5)
                .map {
                    LineupPlayer(
                        name: $0.name,
                        position: $0.position,
                        status: "PROJECTED",
                        source: "recent_minutes",
                        updatedAt: nil,
                        team: $0.team
                    )
                }
        }()
        guard !candidates.isEmpty else { return nil }

        // Prefer an exact PG/SG/SF/PF/C assignment, then the same broad group.
        let exact = candidates.filter {
            playerDetailedPos != nil && detailedPosition($0.position) == playerDetailedPos
        }
        let sameGroup = candidates.filter { primaryPosition($0.position) == playerPos }
        let pool = !exact.isEmpty ? exact : (!sameGroup.isEmpty ? sameGroup : candidates)

        // When two starters share a position, select the one with the strongest
        // combination of playing time and relevant defensive activity instead of
        // trusting feed order.
        let ranked = pool.compactMap { candidate -> (LineupPlayer, DefenderActivity)? in
            guard let name = candidate.name, !name.isEmpty else { return nil }
            let logs = logsForDefender(named: name, team: oppCode, dataService: dataService)
            return (candidate, defenderActivity(logs: logs))
        }
        let selected = ranked.max { lhs, rhs in
            assignmentScore(lhs.1) < assignmentScore(rhs.1)
        }
        guard let defender = selected?.0 else { return nil }
        guard let defName = defender.name, !defName.isEmpty else { return nil }

        // Resolve the defender's historical logs via name → roster playerID.
        let logs = logsForDefender(named: defName, team: oppCode, dataService: dataService)

        let activity = selected?.1 ?? defenderActivity(logs: logs)
        let confidence: Double = !exact.isEmpty ? 1.0 : (!sameGroup.isEmpty ? 0.82 : 0.60)
        let impact = playerPos == "C"
            ? activity.interior
            : playerPos == "G" ? activity.perimeter : (activity.perimeter + activity.interior) / 2

        return DefenderMatchup(
            defenderName: defName,
            defenderPosition: defender.position,
            impact: max(0.0, min(1.0, impact)),
            perimeterImpact: activity.perimeter,
            interiorImpact: activity.interior,
            assignmentConfidence: confidence
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

    private static func isAvailable(status: String?) -> Bool {
        let value = (status ?? "").uppercased()
        return !["OUT", "DOUBTFUL", "INACTIVE", "SUSPENDED"].contains(value)
    }

    private static func normalizedName(_ name: String) -> String {
        name.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func recentMinutes(playerID: String, dataService: LocalDataService) -> Double {
        let values = dataService.localLogs(playerID: playerID).prefix(10).map(\.min)
        return values.isEmpty ? 0 : values.reduce(0, +) / Double(values.count)
    }

    private struct DefenderActivity {
        let minutesPerGame: Double
        let perimeter: Double
        let interior: Double
    }

    private static func assignmentScore(_ activity: DefenderActivity) -> Double {
        min(1, activity.minutesPerGame / 34) * 0.55
            + max(activity.perimeter, activity.interior) * 0.45
    }

    /// Defensive activity proxies derived from available box-score data.
    private static func defenderActivity(logs: [GameLog]) -> DefenderActivity {
        var mins = 0.0, reb = 0.0, blk = 0.0, stl = 0.0
        var games = 0
        for log in logs.prefix(20) {
            let m = log.min
            guard m > 0 else { continue }
            games += 1
            mins += m
            reb  += log.reb ?? 0
            blk  += log.blk ?? 0
            stl  += log.stl ?? 0
        }
        guard mins >= 120, games > 0 else {
            return DefenderActivity(minutesPerGame: 24, perimeter: 0.25, interior: 0.25)
        }
        let rebPer36 = reb / mins * 36.0
        let blkPer36 = blk / mins * 36.0
        let stlPer36 = stl / mins * 36.0
        let rebScore = max(0.0, min(1.0, (rebPer36 - 5.0) / 6.0))
        let blkScore = max(0.0, min(1.0, (blkPer36 - 0.4) / 1.2))
        let stealScore = max(0.0, min(1.0, (stlPer36 - 0.5) / 1.5))
        let perimeter = max(0.0, min(1.0, stealScore * 0.75 + blkScore * 0.25))
        let interior = max(0.0, min(1.0, rebScore * 0.55 + blkScore * 0.45))
        return DefenderActivity(
            minutesPerGame: mins / Double(games),
            perimeter: perimeter,
            interior: interior
        )
    }
}

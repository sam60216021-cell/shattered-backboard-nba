//
//  Models.swift — NBA data models.
//

import Foundation

// MARK: - Player

struct Player: Identifiable, Codable, Hashable {
    var id: String { playerID }
    let playerID: String
    let name: String
    let team: String?
    let position: String?

    enum CodingKeys: String, CodingKey {
        case playerID = "player_id"
        case name, team
        case position = "pos"
    }
}

// MARK: - ScheduleGame

struct ScheduleGame: Identifiable, Codable, Hashable {
    var id: String { gameID ?? "\(date)_\(awayTeam)_\(homeTeam)" }
    let gameID: String?
    let date: String
    let awayTeam: String
    let homeTeam: String
    let gameTime: String?
    let status: String?
    let missingAwayPlayers: [MissingPlayer]
    let missingHomePlayers: [MissingPlayer]
    let playerProps: [PlayerProp]

    // MARK: Playoff helpers (derived — not decoded from server)

    /// True when both teams are known 2026 playoff qualifiers.
    var isPlayoffGame: Bool {
        let away = awayTeam.uppercased()
        let home = homeTeam.uppercased()
        return SportConfig.playoffTeams2026.contains(away) &&
               SportConfig.playoffTeams2026.contains(home)
    }

    /// True when the game date falls within the first round window.
    var isFirstRound: Bool {
        isPlayoffGame && date <= SportConfig.firstRoundEndDate
    }
}

// MARK: - MissingPlayer

struct MissingPlayer: Codable, Hashable {
    let name: String?
    let status: String?   // "OUT", "DOUBTFUL", "QUESTIONABLE"
    let reason: String?
}

// MARK: - PlayerProp

struct PlayerProp: Identifiable, Codable, Hashable {
    /// Stable unique ID — includes gameID so the same player+stat in two games doesn't collide.
    let id: String
    let gameID: String?
    let playerName: String
    let team: String?
    let statLabel: String       // "PTS", "REB", "AST", "3PM", "PRA", "FTM"
    let line: Double
    let overPct: Double?        // 0–1; nil when not available
    let projectedValue: Double? // server projection for this stat

    // MARK: Display helpers

    var confidencePct: Int { Int(round((overPct ?? 0) * 100)) }
}

// MARK: - Lineup

struct GameLineup: Identifiable, Codable {
    var id: String { gameID ?? "\(date ?? "")_\(awayTeam ?? "")_\(homeTeam ?? "")" }
    let gameID: String?
    let date: String?
    let awayTeam: String?
    let homeTeam: String?
    let gameTime: String?
    let awayLineup: [LineupPlayer]
    let homeLineup: [LineupPlayer]

    enum CodingKeys: String, CodingKey {
        case gameID   = "game_id"
        case date
        case awayTeam = "away"
        case homeTeam = "home"
        case gameTime = "time"
        case awayLineup = "away_lineup"
        case homeLineup = "home_lineup"
    }
}

struct LineupPlayer: Codable, Identifiable {
    var id: String { name ?? "\(position ?? "")_\(team ?? "")_player" }
    let name: String?
    let position: String?
    let status: String?
    let source: String?
    let updatedAt: String?
    let team: String?

    enum CodingKeys: String, CodingKey {
        case name, position, status, source, team
        case updatedAt = "updated_at"
    }
}

// MARK: - DataSnapshot

struct DataSnapshot: Codable {
    let fetchedAt: Date
    let games: [ScheduleGame]
    let players: [Player]
    let lineups: [GameLineup]
    let allProps: [PlayerProp]
}

// MARK: - GameDetails

/// Per-game live metadata (playoff info, live score) fetched from server.
/// Persisted to UserDefaults so it survives between launches and is available offline.
struct GameDetails: Codable {
    let gameType: String          // "playoff" | "regular"
    let seriesGameNumber: String  // "Game 2"
    let gameLabel: String         // "East First Round"
    let homeScore: Int
    let awayScore: Int
    let period: Int
    let statusCode: Int           // 1 = upcoming, 2 = live, 3 = final
    let homeWins: Int             // series wins for home team
    let awayWins: Int             // series wins for away team
}

// MARK: - StandingsEntry

/// One team's regular-season standing. Keyed by team abbreviation in
/// `LocalDataService.standingsMap`. Persisted to UserDefaults for offline use.
struct StandingsEntry: Codable {
    let abbr: String
    let conference: String
    let wins: Int
    let losses: Int
    let pct: Double
    let homeRecord: String
    let roadRecord: String
    let lastTen: String
    let streak: String
    let pointsPG: Double
    let oppPointsPG: Double

    /// Season net rating proxy (positive = outscoring opponents).
    var netRating: Double { pointsPG - oppPointsPG }
}

// MARK: - TeamProjection

/// Pure value type that derives spread, moneyline, and projected score for a
/// single matchup from each team's season averages + opponent defensive rating.
/// All math lives here so views stay simple.
struct TeamProjection {
    let away: StandingsEntry
    let home: StandingsEntry

    // MARK: Projected scores

    /// Away team's expected points: blend their offensive output vs home's defense.
    var awayPts: Double {
        (away.pointsPG + home.oppPointsPG) / 2.0
    }

    /// Home team's expected points: blend their offensive output vs away's defense,
    /// plus a standard 2.5-point home-court advantage.
    var homePts: Double {
        (home.pointsPG + away.oppPointsPG) / 2.0 + 2.5
    }

    var projTotal: Double { awayPts + homePts }

    // MARK: Spread

    /// Positive → home favored. Negative → away favored. Snapped to 0.5-pt increments.
    var spread: Double {
        let raw = homePts - awayPts
        return (max(-20, min(20, raw)) * 2).rounded() / 2
    }

    var homeFavored: Bool { spread > 0 }
    var awayFavored: Bool { spread < 0 }

    var homeSpreadStr: String {
        let v = -spread
        return v > 0 ? "+\(v.cleanLine)" : v.cleanLine
    }
    var awaySpreadStr: String {
        let v = spread
        return v > 0 ? "+\(v.cleanLine)" : v.cleanLine
    }

    // MARK: Implied moneyline (standard spread → American odds conversion)

    var homeML: Int {
        let absS = max(0.5, abs(spread))
        let fav  = -Int(round((absS * 20 + 100) / 5)) * 5
        let dog  =  Int(round((absS * 15 + 100) / 5)) * 5
        return homeFavored ? fav : dog
    }
    var awayML: Int {
        let absS = max(0.5, abs(spread))
        let fav  = -Int(round((absS * 20 + 100) / 5)) * 5
        let dog  =  Int(round((absS * 15 + 100) / 5)) * 5
        return awayFavored ? fav : dog
    }

    var homeMLStr: String { homeML >= 0 ? "+\(homeML)" : "\(homeML)" }
    var awayMLStr: String { awayML >= 0 ? "+\(awayML)" : "\(awayML)" }

    var awayPtsDisplay: String { "\(Int(awayPts.rounded()))" }
    var homePtsDisplay: String { "\(Int(homePts.rounded()))" }
}

// MARK: - GameLog

struct GameLog: Identifiable {
    var id: String { "\(playerID ?? "")_\(gameDate)" }
    let playerID: String?
    let season: Int?
    let gameDate: String
    let team: String?
    let opponent: String?
    let minutesSeconds: Double?

    let pts: Double?
    let reb: Double?
    let ast: Double?
    let threepm: Double?
    let ftm: Double?
    let fga: Double?
    let fta: Double?
    let stl: Double?
    let blk: Double?
    let tov: Double?

    var min: Double { (minutesSeconds ?? 0) / 60.0 }
    var pra: Double { (pts ?? 0) + (reb ?? 0) + (ast ?? 0) }

    /// Returns the numeric value for the given NBA stat key.
    func value(for key: String) -> Double {
        switch key {
        case "PTS":  return pts     ?? 0
        case "REB":  return reb     ?? 0
        case "AST":  return ast     ?? 0
        case "3PM":  return threepm ?? 0
        case "FTM":  return ftm     ?? 0
        case "STL":  return stl     ?? 0
        case "BLK":  return blk     ?? 0
        case "TOV":  return tov     ?? 0
        case "MIN":  return min
        case "PRA":  return pra
        case "PR":   return (pts ?? 0) + (reb ?? 0)
        case "PA":   return (pts ?? 0) + (ast ?? 0)
        case "RA":   return (reb ?? 0) + (ast ?? 0)
        case "DD":
            let ddCats = [pts ?? 0, reb ?? 0, ast ?? 0].filter { $0 >= 10 }.count
            return ddCats >= 2 ? 1.0 : 0.0
        case "TD":
            let tdCats = [pts ?? 0, reb ?? 0, ast ?? 0].filter { $0 >= 10 }.count
            return tdCats >= 3 ? 1.0 : 0.0
        default:     return pts     ?? 0
        }
    }
}

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

    // MARK: Playoff helpers (fallback heuristics)
    // Prefer the server-provided game type via LocalDataService.gameDetails
    // (see GameDetails.isPlayoff); these are only used when it is unavailable.

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

    // MARK: Date display helpers

    private static let isoDayParser = ISO8601DateFormatter()

    private static let friendlyDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "EEE, MMM d"
        return f
    }()

    /// Human-friendly date label, e.g. "Today", "Tomorrow", or "Sat, Aug 16".
    var displayDate: String {
        guard let d = ScheduleGame.isoDayParser.date(from: date) else { return date }
        let cal = Calendar.current
        if cal.isDateInToday(d)     { return "Today" }
        if cal.isDateInTomorrow(d)  { return "Tomorrow" }
        if cal.isDateInYesterday(d) { return "Yesterday" }
        return ScheduleGame.friendlyDateFormatter.string(from: d)
    }

    // MARK: Tip time sorting

    /// Chronological sort key: minutes since midnight for the tip time.
    /// nil means unknown/TBD — those games sort last.
    var tipTimeSortKey: Int? {
        ScheduleGame.tipMinutesSinceMidnight(from: gameTime)
    }

    /// Parses a display tip string into minutes since midnight.
    /// Display tips are formatted "h:mm a 'MST'" (see LocalDataService.formatDisplayTip),
    /// e.g. "7:00 PM MST", but raw passthroughs may carry ET/EDT/MST/MDT suffixes,
    /// none at all, or a 24-hour clock ("19:00"). Returns nil for TBD/TBA or
    /// anything unparseable. All games in a slate share one date, so minutes
    /// since midnight is a sufficient chronological ordering.
    static func tipMinutesSinceMidnight(from value: String?) -> Int? {
        guard let raw = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else { return nil }

        let lower = raw.lowercased()
        if lower == "tbd" || lower == "tba" { return nil }

        var cleaned = raw
        for suffix in [" EDT", " EST", " ET", " MDT", " MST"] where cleaned.uppercased().hasSuffix(suffix) {
            cleaned = String(cleaned.dropLast(suffix.count)).trimmingCharacters(in: .whitespaces)
        }

        let tokens = cleaned.split(separator: " ", omittingEmptySubsequences: true).map(String.init)

        // "7:00 PM" / "12:30 AM"
        if tokens.count == 2, let minutes = parseClockToMinutes(tokens[0], meridiem: tokens[1]) {
            return minutes
        }
        // "19:00" — 24-hour clock, no meridiem
        if tokens.count == 1, let minutes = parseClockToMinutes(tokens[0], meridiem: nil) {
            return minutes
        }
        return nil
    }

    /// Parses "H:MM" / "HH:MM" / "H" into minutes since midnight, applying the
    /// meridiem ("AM"/"PM") when present. Returns nil when malformed.
    private static func parseClockToMinutes(_ clock: String, meridiem: String?) -> Int? {
        let parts = clock.split(separator: ":").map(String.init)
        guard (1...2).contains(parts.count),
              let hour = Int(parts[0]), (0...23).contains(hour) else { return nil }

        let minute: Int
        if parts.count == 2 {
            guard let m = Int(parts[1]), (0...59).contains(m) else { return nil }
            minute = m
        } else {
            minute = 0
        }

        var h = hour
        if let meridiem {
            let m = meridiem.uppercased()
            guard (1...12).contains(hour) else { return nil }   // 12-hour clock
            if m.hasPrefix("P"), h < 12 { h += 12 }
            else if m.hasPrefix("A"), h == 12 { h = 0 }
            else if !m.hasPrefix("P") && !m.hasPrefix("A") { return nil }
        }

        guard h < 24 else { return nil }
        return h * 60 + minute
    }
}

// MARK: - MissingPlayer

struct MissingPlayer: Codable, Hashable {
    let name: String?
    let status: String?   // "OUT", "DOUBTFUL", "QUESTIONABLE"
    let reason: String?
}

// MARK: - PlayerProp

enum PropDirection: String, Codable, Hashable {
    case over = "OVER"
    case under = "UNDER"
}

struct PlayerProp: Identifiable, Codable, Hashable {
    /// Stable unique ID — includes gameID so the same player+stat in two games doesn't collide.
    let id: String
    let gameID: String?
    let playerName: String
    let team: String?
    let statLabel: String       // "PTS", "REB", "AST", "3PM", "PRA", "FTM"
    let line: Double
    let direction: PropDirection
    let overPct: Double?        // 0–1; nil when not available
    let projectedValue: Double? // server projection for this stat

    // MARK: Display helpers

    var overProbability: Double {
        min(1.0, max(0.0, overPct ?? 0.5))
    }

    var underProbability: Double {
        1.0 - overProbability
    }

    var selectedProbability: Double {
        direction == .over ? overProbability : underProbability
    }

    var confidencePct: Int { Int(round(selectedProbability * 100)) }

    var sideLabel: String { direction.rawValue }

    init(
        id: String,
        gameID: String?,
        playerName: String,
        team: String?,
        statLabel: String,
        line: Double,
        direction: PropDirection = .over,
        overPct: Double?,
        projectedValue: Double?
    ) {
        self.id = id
        self.gameID = gameID
        self.playerName = playerName
        self.team = team
        self.statLabel = statLabel
        self.line = line
        self.direction = direction
        self.overPct = overPct
        self.projectedValue = projectedValue
    }

    enum CodingKeys: String, CodingKey {
        case id
        case gameID
        case playerName
        case team
        case statLabel
        case line
        case direction
        case overPct
        case projectedValue
    }

    enum AlternateCodingKeys: String, CodingKey {
        case game_id
        case player_name
        case stat
        case over_pct
        case projected_value
        case side
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        let alt = try decoder.container(keyedBy: AlternateCodingKeys.self)

        gameID = try container.decodeIfPresent(String.self, forKey: .gameID)
            ?? alt.decodeIfPresent(String.self, forKey: .game_id)
        playerName = try container.decodeIfPresent(String.self, forKey: .playerName)
            ?? alt.decodeIfPresent(String.self, forKey: .player_name)
            ?? ""
        team = try container.decodeIfPresent(String.self, forKey: .team)
        statLabel = try container.decodeIfPresent(String.self, forKey: .statLabel)
            ?? alt.decodeIfPresent(String.self, forKey: .stat)
            ?? "PTS"
        line = try container.decode(Double.self, forKey: .line)
        overPct = try container.decodeIfPresent(Double.self, forKey: .overPct)
            ?? alt.decodeIfPresent(Double.self, forKey: .over_pct)
        projectedValue = try container.decodeIfPresent(Double.self, forKey: .projectedValue)
            ?? alt.decodeIfPresent(Double.self, forKey: .projected_value)

        if let rawDirection = try container.decodeIfPresent(String.self, forKey: .direction),
           let parsed = PropDirection(rawValue: rawDirection.uppercased()) {
            direction = parsed
        } else {
            if let rawSide = try alt.decodeIfPresent(String.self, forKey: .side),
               let parsed = PropDirection(rawValue: rawSide.uppercased()) {
                direction = parsed
            } else {
                direction = .over
            }
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encodeIfPresent(gameID, forKey: .gameID)
        try container.encode(playerName, forKey: .playerName)
        try container.encodeIfPresent(team, forKey: .team)
        try container.encode(statLabel, forKey: .statLabel)
        try container.encode(line, forKey: .line)
        try container.encode(direction.rawValue, forKey: .direction)
        try container.encodeIfPresent(overPct, forKey: .overPct)
        try container.encodeIfPresent(projectedValue, forKey: .projectedValue)
    }
}

// MARK: - Picks Tracker

enum TrackerStat: String, Codable, CaseIterable {
    case points
    case rebounds
    case assists
    case threes
    case pra
    case fpts
    case steals
    case blocks

    var displayName: String {
        switch self {
        case .points: return "Points"
        case .rebounds: return "Rebounds"
        case .assists: return "Assists"
        case .threes: return "Threes"
        case .pra: return "PRA"
        case .fpts: return "Fantasy Points"
        case .steals: return "Steals"
        case .blocks: return "Blocks"
        }
    }

    var shortLabel: String {
        switch self {
        case .points: return "PTS"
        case .rebounds: return "REB"
        case .assists: return "AST"
        case .threes: return "3PM"
        case .pra: return "PRA"
        case .fpts: return "FPTS"
        case .steals: return "STL"
        case .blocks: return "BLK"
        }
    }
}

struct TrackedPlayer: Codable, Hashable {
    let name: String
    let teamAbbrev: String
    let targetStat: TrackerStat
    let targetValue: Int

    var idKey: String {
        "\(name.lowercased())_\(teamAbbrev.uppercased())_\(targetStat.rawValue)_\(targetValue)"
    }

    init(name: String, teamAbbrev: String, targetStat: TrackerStat, targetValue: Int) {
        self.name = name
        self.teamAbbrev = teamAbbrev.uppercased()
        self.targetStat = targetStat
        self.targetValue = max(1, targetValue)
    }

    init(prop: PlayerProp) {
        let stat = prop.statLabel.uppercased()
        let mapped: TrackerStat
        switch stat {
        case "PTS": mapped = .points
        case "REB": mapped = .rebounds
        case "AST": mapped = .assists
        case "3PM": mapped = .threes
        case "PRA": mapped = .pra
        case "FPTS": mapped = .fpts
        case "STL": mapped = .steals
        case "BLK": mapped = .blocks
        default: mapped = .points
        }

        self.init(
            name: prop.playerName.trimmingCharacters(in: .whitespacesAndNewlines),
            teamAbbrev: (prop.team ?? "").uppercased(),
            targetStat: mapped,
            targetValue: max(1, Int(ceil(prop.line)))
        )
    }
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

/// Per-game live metadata (playoff info, live score) fetched from server and
/// persisted to SwiftData via StoredGameDetails. Restored on launch.
struct GameDetails {
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

extension GameDetails {
    /// Explicit server classification - nil when the game type is unknown, in
    /// which case callers fall back to the hard-coded playoff-qualifier
    /// heuristic in ScheduleGame.isPlayoffGame.
    var isPlayoff: Bool? {
        switch gameType.lowercased() {
        case "playoff": return true
        case "regular": return false
        default:        return nil
        }
    }

    /// First-round classification derived from the server-provided series
    /// label (e.g. "East First Round"). Nil when the round cannot be determined.
    var isFirstRound: Bool? {
        guard isPlayoff == true, !gameLabel.isEmpty else { return nil }
        return gameLabel.localizedCaseInsensitiveContains("first round")
    }
}

// MARK: - StandingsEntry

/// One team's regular-season standing. Keyed by team abbreviation in
/// `LocalDataService.standingsMap`. Persisted to SwiftData via StoredStandings.
struct StandingsEntry {
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

// MARK: - TeamAdvancedEntry

/// Team-level advanced context from the league advanced-stats feed (per-game advanced table).
/// Used to adjust projections for opponent environment (pace, defense, etc.).
struct TeamAdvancedEntry {
    let abbr: String
    let pace: Double?
    let offRating: Double?
    let defRating: Double?
    let netRating: Double?
    let tsPct: Double?
    let efgPct: Double?
    let tovPct: Double?
    let rebPct: Double?
    let astRatio: Double?
}

// MARK: - PlayerAdvancedEntry

/// Possession-based player context generated by the Mac feed builder.
/// `estimatedUsagePct` is the player's share of his team's recorded used
/// possessions (FGA + 0.44×FTA + TOV), not the NBA's official USG% statistic.
struct PlayerAdvancedEntry {
    let playerID: String
    let name: String
    let team: String?
    let games: Int
    let minutesPerGame: Double?
    let estimatedUsagePct: Double?
    let possessionsUsedPer36: Double?
}

// MARK: - TeamPositionSplitEntry

/// Opponent-allowed production split by offensive position bucket.
/// Example key path in map: team "NYL" -> position "GUARD".
struct TeamPositionSplitEntry {
    let teamAbbr: String
    let positionGroup: String   // "GUARD" | "WING" | "BIG"
    let ptsAllowed: Double?
    let rebAllowed: Double?
    let astAllowed: Double?
    let threepmAllowed: Double?
    let stlAllowed: Double?
    let blkAllowed: Double?
    let praAllowed: Double?
    let sampleSize: Int
}

// MARK: - BacktestSummary

/// Rolling model-health snapshot generated from local historical logs.
struct BacktestSummary {
    let generatedAt: Date
    let sampleCount: Int
    let statBias: [String: Double]    // actual/predicted by stat
    let statMAE: [String: Double]     // mean absolute percentage error by stat
}

// MARK: - OddsMath

/// Shared odds-conversion math so every surface (game cards, analytics, sims)
/// derives moneylines the same way.
enum OddsMath {
    /// Logistic conversion of a point spread to a win probability.
    /// Positive spread = home favored. ~0.145/pt ~= a 3-point favorite wins ~58%.
    static func homeWinProbability(spread: Double) -> Double {
        1.0 / (1.0 + exp(-0.145 * spread))
    }

    /// American odds (e.g. -150 / +140) for a win probability, snapped to 5s.
    /// Probability is clamped to 0.5%-99.5% to keep odds finite.
    static func americanOdds(fromWinProbability probability: Double) -> Int {
        let p = min(0.995, max(0.005, probability))
        if p >= 0.5 {
            return -Int(round((p / (1 - p)) * 100.0 / 5.0) * 5.0)
        }
        return Int(round(((1 - p) / p) * 100.0 / 5.0) * 5.0)
    }
}

// MARK: - TeamProjection

/// Pure value type that derives spread, moneyline, and projected score for a
/// single matchup from each team's season averages + opponent defensive rating.
/// All math lives here so views stay simple.
struct TeamProjection {
    let away: StandingsEntry
    let home: StandingsEntry

    /// Some upstream feeds occasionally provide season totals in `pointsPG`
    /// fields instead of true per-game averages. Normalize by games played when
    /// values are implausibly high for a NBA per-game stat.
    private func normalizedPoints(_ raw: Double, wins: Int, losses: Int) -> Double {
        let games = max(1, wins + losses)
        if raw > 300 { return raw / Double(games) }
        return raw
    }

    private var awayOffense: Double {
        normalizedPoints(away.pointsPG, wins: away.wins, losses: away.losses)
    }

    private var awayDefenseAllowed: Double {
        normalizedPoints(away.oppPointsPG, wins: away.wins, losses: away.losses)
    }

    private var homeOffense: Double {
        normalizedPoints(home.pointsPG, wins: home.wins, losses: home.losses)
    }

    private var homeDefenseAllowed: Double {
        normalizedPoints(home.oppPointsPG, wins: home.wins, losses: home.losses)
    }

    // MARK: Projected scores

    /// Away team's expected points: blend their offensive output vs home's defense.
    var awayPts: Double {
        (awayOffense + homeDefenseAllowed) / 2.0
    }

    /// Home team's expected points: blend their offensive output vs away's defense,
    /// plus a standard 2.5-point home-court advantage.
    var homePts: Double {
        (homeOffense + awayDefenseAllowed) / 2.0 + 2.5
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

    // MARK: Implied moneyline (spread → win probability → American odds)

    var homeML: Int {
        OddsMath.americanOdds(fromWinProbability: OddsMath.homeWinProbability(spread: spread))
    }
    var awayML: Int {
        OddsMath.americanOdds(fromWinProbability: 1.0 - OddsMath.homeWinProbability(spread: spread))
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
    // PrizePicks-style fantasy score: 1*PTS + 1.2*REB + 1.5*AST + 3*STL + 3*BLK - 1*TOV
    var fantasyScore: Double {
        (pts ?? 0)
        + ((reb ?? 0) * 1.2)
        + ((ast ?? 0) * 1.5)
        + ((stl ?? 0) * 3.0)
        + ((blk ?? 0) * 3.0)
        - (tov ?? 0)
    }

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
        case "FPTS": return fantasyScore
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

//
//  Database.swift — SwiftData persistent models + shared container.
//
//  All server data is saved here immediately after a sync.
//  The app reads from this store first so it works fully offline.
//

import Foundation
import SwiftData

// MARK: - StoredGame

/// One scheduled NBA game.  Replaced on every sync for the current date.
@Model
final class StoredGame {
    @Attribute(.unique) var gameID: String
    var date: String
    var awayTeam: String
    var homeTeam: String
    var gameTime: String?
    var status: String?
    var syncedAt: Date

    init(gameID: String, date: String, awayTeam: String, homeTeam: String,
         gameTime: String?, status: String?, syncedAt: Date = .now) {
        self.gameID    = gameID
        self.date      = date
        self.awayTeam  = awayTeam
        self.homeTeam  = homeTeam
        self.gameTime  = gameTime
        self.status    = status
        self.syncedAt  = syncedAt
    }
}

// MARK: - StoredMissingPlayer

/// Injured / absent player tied to a game.  Deleted + re-inserted each sync.
@Model
final class StoredMissingPlayer {
    var gameID: String          // foreign key → StoredGame.gameID
    var name: String?
    var status: String?         // "OUT", "DOUBTFUL", "QUESTIONABLE"
    var reason: String?
    var isAway: Bool            // true = away team, false = home team
    var syncedAt: Date

    init(gameID: String, name: String?, status: String?, reason: String?,
         isAway: Bool, syncedAt: Date = .now) {
        self.gameID   = gameID
        self.name     = name
        self.status   = status
        self.reason   = reason
        self.isAway   = isAway
        self.syncedAt = syncedAt
    }
}

// MARK: - StoredProp

/// One player prop line (PTS over 24.5 @ 78%).  Replaced on every sync.
@Model
final class StoredProp {
    @Attribute(.unique) var propID: String  // "\(gameID)_\(playerName)_\(statLabel)"
    var gameID: String?
    var playerName: String
    var team: String?
    var statLabel: String       // "PTS", "REB", "AST", "3PM", "PRA", "FTM"
    var line: Double
    var overPct: Double?        // 0–1
    var projectedValue: Double? // server projected value
    var syncedAt: Date

    init(propID: String, gameID: String?, playerName: String, team: String?,
         statLabel: String, line: Double, overPct: Double?,
         projectedValue: Double?, syncedAt: Date = .now) {
        self.propID         = propID
        self.gameID         = gameID
        self.playerName     = playerName
        self.team           = team
        self.statLabel      = statLabel
        self.line           = line
        self.overPct        = overPct
        self.projectedValue = projectedValue
        self.syncedAt       = syncedAt
    }
}

// MARK: - StoredPlayer

/// NBA roster entry.  Upserted (never deleted) so the full roster persists.
@Model
final class StoredPlayer {
    @Attribute(.unique) var playerID: String
    var name: String
    var team: String?
    var position: String?
    var syncedAt: Date

    init(playerID: String, name: String, team: String?,
         position: String?, syncedAt: Date = .now) {
        self.playerID = playerID
        self.name     = name
        self.team     = team
        self.position = position
        self.syncedAt = syncedAt
    }
}

// MARK: - StoredGameLog

/// One row in a player's historical game log.
/// Accumulated permanently — only NEW dates are ever inserted.
@Model
final class StoredGameLog {
    /// Stable ID: "\(playerID)_\(gameDate)"
    @Attribute(.unique) var logID: String
    var playerID: String
    var season: Int
    var gameDate: String        // "YYYY-MM-DD"
    var team: String?
    var opponent: String?
    var minutesSeconds: Double?

    var pts: Double?
    var reb: Double?
    var ast: Double?
    var threepm: Double?
    var ftm: Double?
    var fga: Double?
    var fta: Double?
    var stl: Double?
    var blk: Double?
    var tov: Double?
    var syncedAt: Date

    init(logID: String, playerID: String, season: Int, gameDate: String,
         team: String?, opponent: String?, minutesSeconds: Double?,
         pts: Double?, reb: Double?, ast: Double?, threepm: Double?,
         ftm: Double?, fga: Double?, fta: Double?,
         stl: Double?, blk: Double?, tov: Double?,
         syncedAt: Date = .now) {
        self.logID         = logID
        self.playerID      = playerID
        self.season        = season
        self.gameDate      = gameDate
        self.team          = team
        self.opponent      = opponent
        self.minutesSeconds = minutesSeconds
        self.pts   = pts;  self.reb  = reb;  self.ast    = ast
        self.threepm = threepm; self.ftm = ftm
        self.fga   = fga;  self.fta  = fta
        self.stl   = stl;  self.blk  = blk;  self.tov   = tov
        self.syncedAt = syncedAt
    }

    /// Convert to the lightweight value type used by views.
    func toGameLog() -> GameLog {
        GameLog(
            playerID: playerID,
            season: season,
            gameDate: gameDate,
            team: team,
            opponent: opponent,
            minutesSeconds: minutesSeconds,
            pts: pts, reb: reb, ast: ast,
            threepm: threepm, ftm: ftm,
            fga: fga, fta: fta,
            stl: stl, blk: blk, tov: tov
        )
    }
}

// MARK: - StoredLineupPlayer

/// One player entry in a game lineup.  Replaced on every sync.
@Model
final class StoredLineupPlayer {
    var gameID: String          // foreign key
    var name: String?
    var position: String?
    var status: String?
    var source: String?
    var updatedAt: String?
    var team: String?
    var isAway: Bool
    var syncedAt: Date

    init(gameID: String, name: String?, position: String?, status: String?,
         source: String?, updatedAt: String?, team: String?,
         isAway: Bool, syncedAt: Date = .now) {
        self.gameID    = gameID
        self.name      = name
        self.position  = position
        self.status    = status
        self.source    = source
        self.updatedAt = updatedAt
        self.team      = team
        self.isAway    = isAway
        self.syncedAt  = syncedAt
    }
}

// MARK: - StoredGameDetails

/// Live per-game metadata (scores, period, status, playoff series).
/// Persisted on every sync so it survives app kills and background suspension.
@Model
final class StoredGameDetails {
    @Attribute(.unique) var gameID: String
    var gameType: String          // "playoff" | "regular"
    var seriesGameNumber: String  // "Game 2"
    var gameLabel: String         // "East First Round"
    var homeScore: Int
    var awayScore: Int
    var period: Int
    var statusCode: Int           // 1=upcoming 2=live 3=final
    var homeWins: Int
    var awayWins: Int
    var syncedAt: Date

    init(gameID: String, gameType: String, seriesGameNumber: String,
         gameLabel: String, homeScore: Int, awayScore: Int,
         period: Int, statusCode: Int, homeWins: Int, awayWins: Int,
         syncedAt: Date = .now) {
        self.gameID            = gameID
        self.gameType          = gameType
        self.seriesGameNumber  = seriesGameNumber
        self.gameLabel         = gameLabel
        self.homeScore         = homeScore
        self.awayScore         = awayScore
        self.period            = period
        self.statusCode        = statusCode
        self.homeWins          = homeWins
        self.awayWins          = awayWins
        self.syncedAt          = syncedAt
    }

    func toGameDetails() -> GameDetails {
        GameDetails(
            gameType: gameType, seriesGameNumber: seriesGameNumber,
            gameLabel: gameLabel, homeScore: homeScore, awayScore: awayScore,
            period: period, statusCode: statusCode,
            homeWins: homeWins, awayWins: awayWins
        )
    }
}

// MARK: - StoredStandings

/// One team's season standing.  Replaced wholesale on every standings sync.
@Model
final class StoredStandings {
    @Attribute(.unique) var abbr: String
    var conference: String
    var wins: Int
    var losses: Int
    var pct: Double
    var homeRecord: String
    var roadRecord: String
    var lastTen: String
    var streak: String
    var pointsPG: Double
    var oppPointsPG: Double
    var syncedAt: Date

    init(abbr: String, conference: String, wins: Int, losses: Int, pct: Double,
         homeRecord: String, roadRecord: String, lastTen: String, streak: String,
         pointsPG: Double, oppPointsPG: Double, syncedAt: Date = .now) {
        self.abbr         = abbr
        self.conference   = conference
        self.wins         = wins
        self.losses       = losses
        self.pct          = pct
        self.homeRecord   = homeRecord
        self.roadRecord   = roadRecord
        self.lastTen      = lastTen
        self.streak       = streak
        self.pointsPG     = pointsPG
        self.oppPointsPG  = oppPointsPG
        self.syncedAt     = syncedAt
    }

    func toStandingsEntry() -> StandingsEntry {
        StandingsEntry(
            abbr: abbr, conference: conference,
            wins: wins, losses: losses, pct: pct,
            homeRecord: homeRecord, roadRecord: roadRecord,
            lastTen: lastTen, streak: streak,
            pointsPG: pointsPG, oppPointsPG: oppPointsPG
        )
    }
}

// MARK: - Stored advanced analytics

/// Team-level advanced metrics used by the projection engine.
@Model
final class StoredTeamAdvanced {
    @Attribute(.unique) var abbr: String
    var pace: Double?
    var offRating: Double?
    var defRating: Double?
    var netRating: Double?
    var tsPct: Double?
    var efgPct: Double?
    var tovPct: Double?
    var rebPct: Double?
    var astRatio: Double?
    var syncedAt: Date

    init(entry: TeamAdvancedEntry, syncedAt: Date = .now) {
        abbr = entry.abbr
        pace = entry.pace
        offRating = entry.offRating
        defRating = entry.defRating
        netRating = entry.netRating
        tsPct = entry.tsPct
        efgPct = entry.efgPct
        tovPct = entry.tovPct
        rebPct = entry.rebPct
        astRatio = entry.astRatio
        self.syncedAt = syncedAt
    }

    func toEntry() -> TeamAdvancedEntry {
        TeamAdvancedEntry(
            abbr: abbr, pace: pace, offRating: offRating,
            defRating: defRating, netRating: netRating,
            tsPct: tsPct, efgPct: efgPct, tovPct: tovPct,
            rebPct: rebPct, astRatio: astRatio
        )
    }
}

/// Player-level usage and possession context used by AI projections.
@Model
final class StoredPlayerAdvanced {
    @Attribute(.unique) var playerID: String
    var name: String
    var team: String?
    var games: Int
    var minutesPerGame: Double?
    var estimatedUsagePct: Double?
    var possessionsUsedPer36: Double?
    var syncedAt: Date

    init(entry: PlayerAdvancedEntry, syncedAt: Date = .now) {
        playerID = entry.playerID
        name = entry.name
        team = entry.team
        games = entry.games
        minutesPerGame = entry.minutesPerGame
        estimatedUsagePct = entry.estimatedUsagePct
        possessionsUsedPer36 = entry.possessionsUsedPer36
        self.syncedAt = syncedAt
    }

    func toEntry() -> PlayerAdvancedEntry {
        PlayerAdvancedEntry(
            playerID: playerID, name: name, team: team, games: games,
            minutesPerGame: minutesPerGame,
            estimatedUsagePct: estimatedUsagePct,
            possessionsUsedPer36: possessionsUsedPer36
        )
    }
}

/// Opponent production allowed to each position group.
@Model
final class StoredTeamPositionSplit {
    @Attribute(.unique) var splitID: String
    var teamAbbr: String
    var positionGroup: String
    var ptsAllowed: Double?
    var rebAllowed: Double?
    var astAllowed: Double?
    var threepmAllowed: Double?
    var stlAllowed: Double?
    var blkAllowed: Double?
    var praAllowed: Double?
    var sampleSize: Int
    var syncedAt: Date

    init(entry: TeamPositionSplitEntry, syncedAt: Date = .now) {
        splitID = "\(entry.teamAbbr.uppercased())_\(entry.positionGroup.uppercased())"
        teamAbbr = entry.teamAbbr
        positionGroup = entry.positionGroup
        ptsAllowed = entry.ptsAllowed
        rebAllowed = entry.rebAllowed
        astAllowed = entry.astAllowed
        threepmAllowed = entry.threepmAllowed
        stlAllowed = entry.stlAllowed
        blkAllowed = entry.blkAllowed
        praAllowed = entry.praAllowed
        sampleSize = entry.sampleSize
        self.syncedAt = syncedAt
    }

    func toEntry() -> TeamPositionSplitEntry {
        TeamPositionSplitEntry(
            teamAbbr: teamAbbr, positionGroup: positionGroup,
            ptsAllowed: ptsAllowed, rebAllowed: rebAllowed,
            astAllowed: astAllowed, threepmAllowed: threepmAllowed,
            stlAllowed: stlAllowed, blkAllowed: blkAllowed,
            praAllowed: praAllowed, sampleSize: sampleSize
        )
    }
}

// MARK: - AppDatabase

/// Shared SwiftData container.  Initialised once at app launch.
final class AppDatabase {
    static let shared = AppDatabase()

    let container: ModelContainer

    /// Main-actor context — safe to use from @MainActor code.
    var mainContext: ModelContext { container.mainContext }

    private static let storeName = "NBALocalStore"

    private init() {
        let schema = Schema([
            StoredGame.self,
            StoredMissingPlayer.self,
            StoredProp.self,
            StoredPlayer.self,
            StoredGameLog.self,
            StoredLineupPlayer.self,
            StoredGameDetails.self,
            StoredStandings.self,
            StoredTeamAdvanced.self,
            StoredPlayerAdvanced.self,
            StoredTeamPositionSplit.self,
        ])

        // Build an explicit store URL so we can guarantee the parent
        // directory exists before SwiftData tries to open/recover the store.
        // Missing parent directory is the root cause of the CoreData recovery error.
        let storeURL: URL? = {
            guard let appSupport = FileManager.default.urls(
                for: .applicationSupportDirectory, in: .userDomainMask
            ).first else { return nil }
            let dir = appSupport.appendingPathComponent(Self.storeName, isDirectory: true)
            try? FileManager.default.createDirectory(
                at: dir, withIntermediateDirectories: true
            )
            return dir.appendingPathComponent("\(Self.storeName).store")
        }()

        if let url = storeURL {
            container = Self.makeContainer(schema: schema, storeURL: url)
        } else {
            // Can't resolve Application Support — use in-memory.
            let memConfig = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
            container = try! ModelContainer(for: schema, configurations: [memConfig])
        }
    }

    /// Attempts to open the persistent store at `storeURL`.
    /// On failure, deletes the corrupted store files and tries once more.
    /// Final fallback is an in-memory store so the app never crashes.
    private static func makeContainer(schema: Schema, storeURL: URL) -> ModelContainer {
        let config = ModelConfiguration(
            Self.storeName,
            schema: schema,
            url: storeURL,
            allowsSave: true
        )
        do {
            return try ModelContainer(for: schema, configurations: [config])
        } catch {
            print("[AppDatabase] Initial open failed (\(error)) — deleting store and retrying")
            deleteStoreFiles(at: storeURL)
            do {
                return try ModelContainer(for: schema, configurations: [config])
            } catch {
                print("[AppDatabase] Retry failed (\(error)) — falling back to in-memory store")
                let memConfig = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
                return try! ModelContainer(for: schema, configurations: [memConfig])
            }
        }
    }

    /// Removes the SQLite store file and its WAL/SHM sidecar files.
    private static func deleteStoreFiles(at url: URL) {
        let fm = FileManager.default
        for suffix in ["", "-wal", "-shm"] {
            let target = URL(fileURLWithPath: url.path + suffix)
            try? fm.removeItem(at: target)
        }
    }
}

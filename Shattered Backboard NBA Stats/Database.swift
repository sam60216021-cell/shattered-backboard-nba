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

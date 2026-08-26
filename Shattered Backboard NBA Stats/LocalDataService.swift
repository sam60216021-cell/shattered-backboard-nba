//
//  LocalDataService.swift — Local-first NBA data service.
//
//  Reads from the SwiftData store on every launch (instant offline).
//  Syncs from the server in the background and persists new data immediately.
//  All views continue to observe `snapshot` — no view changes required.
//
//  Data persistence strategy:
//    • StoredGame / StoredProp / StoredMissingPlayer / StoredLineupPlayer
//        → Replaced wholesale on each sync (today's data)
//    • StoredPlayer (roster)
//        → Upserted; old players kept; never deleted
//    • StoredGameLog (per-player historical stats)
//        → Accumulated; only NEW game dates are inserted; never deleted
//

import Combine
import Foundation
import SwiftData

// MARK: - Raw server response shapes

private struct RawScheduleResponse: Decodable {
    let date: String?
    let games: [RawGame]?
}

private struct RawGame: Decodable {
    let game_id: String?
    let date: String?
    let away: String?
    let home: String?
    let tip: String?                  // schedule endpoint uses "tip" for game time
    let time: String?                 // lineups endpoint uses "time"
    let status: String?
    let game_type: String?            // "playoff" | "regular"
    let series_game_number: String?   // "Game 2"
    let game_label: String?           // "East First Round"
    let home_score: Int?
    let away_score: Int?
    let period: Int?
    let status_code: Int?             // 1=upcoming 2=live 3=final
    let home_wins: Int?               // series wins for home team
    let away_wins: Int?               // series wins for away team
    let missing_away_players: [RawMissingPlayer]?
    let missing_home_players: [RawMissingPlayer]?
}

private struct RawMissingPlayer: Decodable {
    let name: String?
    let status: String?
    let reason: String?
}

private struct RawStatsResponse: Decodable {
    let players: [RawStatPlayer]?
}

private struct RawStatPlayer: Decodable {
    let player_id: String?
    let name: String?
    let team: String?
    let pos: String?
}

private struct RawLineupsResponse: Decodable {
    let date: String?
    let rows: [RawLineupGame]?
}

private struct RawLineupGame: Decodable {
    let game_id: String?
    let date: String?
    let away: String?
    let home: String?
    let time: String?
    let away_lineup: [RawLineupPlayer]?
    let home_lineup: [RawLineupPlayer]?
}

private struct RawLineupPlayer: Decodable {
    let player_id: String?
    let name: String?
    let position: String?
    let status: String?
    let source: String?
    let updated_at: String?
    let team: String?
}

private struct RawPlayerLogsResponse: Decodable {
    let player_id: String?
    let season: Int?
    let logs: [RawGameLog]?
}

private struct RawStandingsResponse: Decodable {
    let standings: [RawStandingsEntry]?
}

private struct RawStandingsEntry: Decodable {
    let team_abbreviation: String?
    let conference: String?
    let wins: Int?
    let losses: Int?
    let pct: Double?
    let home_record: String?
    let road_record: String?
    let last_10: String?
    let streak: String?
    let points_pg: Double?
    let opp_points_pg: Double?
}

private struct RawGameLog: Decodable {
    let season: Int?
    let player_id: String?
    let game_date: String?
    let team: String?
    let opponent: String?
    let mp_seconds: Double?
    let pts: Double?
    let reb: Double?
    let ast: Double?
    let three_p: Double?
    let ftm: Double?
    let fga: Double?
    let fta: Double?
    let stl: Double?
    let blk: Double?
    let tov: Double?
}

/// Top-level container for StarterLogs.json (bundled seed data).
private struct BundleLogsFile: Decodable {
    let season: Int?
    let logs: [RawGameLog]?
}

// MARK: - Service

@MainActor
final class LocalDataService: ObservableObject {
    static let shared = LocalDataService()

    // MARK: Published state (same interface as before — views don't change)

    @Published var isFetching    = false
    @Published var lastFetchDate: Date?
    @Published var lastError: String?
    @Published var snapshot: DataSnapshot? { didSet { snapshotID &+= 1 } }
    @Published var snapshotID: Int = 0
    /// true when the current snapshot came from the local DB rather than a live sync
    @Published var isUsingCache  = false

    @Published var playerLogs: [GameLog] = []
    @Published var isLoadingLogs = false
    @Published var logsPlayerID: String = ""
    @Published var isLoadingAllLogs = false

    /// Rolling buffer of the last 120 sync log messages (DEBUG panel only).
    @Published var debugLogs: [String] = []
    /// Raw JSON from the last schedule response (DEBUG panel only).
    @Published var lastScheduleRawJSON: String = ""
    /// Raw JSON from the last lineups response (DEBUG panel only).
    @Published var lastLineupsRawJSON: String = ""

    /// Per-game live metadata (series record, scores, game type). Populated on sync; empty offline.
    @Published var gameDetails: [String: GameDetails] = [:]
    /// Season standings keyed by team abbreviation (e.g. "DET"). Populated on sync; empty offline.
    @Published var standingsMap: [String: StandingsEntry] = [:]

    // MARK: Server URL (user-configurable in debug settings)

    var serverURL: String {
        get { UserDefaults.standard.string(forKey: SportConfig.serverURLKey) ?? SportConfig.baseURL }
        set { UserDefaults.standard.set(newValue, forKey: SportConfig.serverURLKey) }
    }

    // MARK: Private

    private var modelContext: ModelContext { AppDatabase.shared.mainContext }

    private let session: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest  = 15
        cfg.timeoutIntervalForResource = 30
        return URLSession(configuration: cfg)
    }()

    /// Game-log window kept in the local DB.  Older rows are pruned on launch.
    private static let logRetentionDays = 60

    private init() {
        // 1. Import bundled seed data on very first launch (before pruning, so logs survive).
        importBundledLogsIfNeeded()
        // 2. Prune stale data; pruneOldGames() rebuilds the snapshot when done.
        pruneOldGameLogs()
        pruneOldGames()
        // 3. Restore last-known gameDetails and standingsMap so they're available offline.
        restorePersistedMetadata()
    }

    // MARK: - Restore persisted metadata (offline support)

    private func restorePersistedMetadata() {
        if let data = UserDefaults.standard.data(forKey: "cachedGameDetails"),
           let map  = try? JSONDecoder().decode([String: GameDetails].self, from: data),
           !map.isEmpty {
            gameDetails = map
            syncLog("[restoreMetadata] restored gameDetails for \(map.count) game(s)")
        }
        if let data = UserDefaults.standard.data(forKey: "cachedStandingsMap"),
           let map  = try? JSONDecoder().decode([String: StandingsEntry].self, from: data),
           !map.isEmpty {
            standingsMap = map
            syncLog("[restoreMetadata] restored standingsMap for \(map.count) team(s)")
        }
    }

    // MARK: - Bundled seed data import

    private static let bundleImportKey = "bundleLogsImported_v3"

    /// Runs exactly once per install. Imports StarterLogs.json from the app bundle
    /// into SwiftData so projections are available on the very first launch.
    private func importBundledLogsIfNeeded() {
        guard !UserDefaults.standard.bool(forKey: Self.bundleImportKey) else { return }
        guard let url  = Bundle.main.url(forResource: "StarterLogs", withExtension: "json"),
              let data = try? Data(contentsOf: url) else {
            syncLog("[bundleImport] StarterLogs.json not found in bundle — skipping")
            return
        }
        guard let file = try? JSONDecoder().decode(BundleLogsFile.self, from: data),
              let logs = file.logs, !logs.isEmpty else {
            syncLog("[bundleImport] failed to decode StarterLogs.json")
            return
        }
        let season = file.season ?? SportConfig.currentSeason
        persistLogs(logs, defaultPlayerID: "", defaultSeason: season)
        UserDefaults.standard.set(true, forKey: Self.bundleImportKey)
        syncLog("[bundleImport] imported \(logs.count) starter log rows (season \(season))")
    }

    // MARK: - Load from local SwiftData store

    private func loadFromDatabase() {
        let now   = Date()
        let today = Self.isoDateString(now)
        let ctx   = modelContext

        // Try today's games first; if none found (offline, new day), fall back to
        // the most recently cached date so the app stays usable without a connection.
        let todayDesc = FetchDescriptor<StoredGame>(
            predicate: #Predicate { $0.date == today }
        )
        var games = (try? ctx.fetch(todayDesc)) ?? []

        if games.isEmpty {
            // Offline fallback: load the most recent available date from the store
            let allDesc = FetchDescriptor<StoredGame>(
                sortBy: [SortDescriptor(\.date, order: .reverse)]
            )
            let allGames = (try? ctx.fetch(allDesc)) ?? []
            if let latestDate = allGames.first?.date {
                let d = latestDate
                games = allGames.filter { $0.date == d }
            }
        }

        let storedPlayers = (try? ctx.fetch(FetchDescriptor<StoredPlayer>())) ?? []
        let missing       = (try? ctx.fetch(FetchDescriptor<StoredMissingPlayer>())) ?? []
        let lineupRows    = (try? ctx.fetch(FetchDescriptor<StoredLineupPlayer>())) ?? []

        guard !games.isEmpty else {
            // No local data yet — snapshot stays nil, views will show loading state
            return
        }

        let snap = assembleSnapshot(
            games: games, storedProps: [],
            players: storedPlayers, missing: missing,
            lineups: lineupRows, fetchedAt: now
        )
        snapshot      = snap
        lastFetchDate = snap.fetchedAt
        isUsingCache  = true
    }

    // MARK: - Sync from server

    @discardableResult
    func fetchAll(fetchLogs: Bool = false) async throws -> DataSnapshot {
        let base = serverURL.trimmingCharacters(in: .whitespaces)

        guard
            let scheduleURL  = URL(string: base + SportConfig.scheduleEndpoint),
            let lineupsURL   = URL(string: base + SportConfig.lineupsEndpoint),
            let statsURL     = URL(string: base + SportConfig.statsEndpoint),
            let rosterURL    = URL(string: base + SportConfig.rosterEndpoint),
            let standingsURL = URL(string: base + SportConfig.standingsEndpoint)
        else { throw URLError(.badURL) }

        isFetching = true
        lastError  = nil
        defer { isFetching = false }

        syncLog("[fetchAll] Starting sync — server: \(base)")

        do {
            async let schedTask    = session.data(from: scheduleURL)
            async let lineupsTask  = session.data(from: lineupsURL)
            async let statsTask    = session.data(from: statsURL)
            async let rosterTask   = session.data(from: rosterURL)
            async let standTask    = session.data(from: standingsURL)

            // Schedule is critical — throw if it fails so the caller knows.
            let (sData, sResp)  = try await schedTask
            // Lineups/stats/roster/standings are supplemental — failures are logged
            // but must NOT prevent schedule data from being persisted and displayed.
            let lineupsResult   = try? await lineupsTask
            let stDataOpt       = try? await statsTask
            let roDataOpt       = try? await rosterTask
            let stndDataOpt     = try? await standTask

            let lData = lineupsResult?.0
            let lResp = lineupsResult?.1

            let schedRaw = String(data: sData, encoding: .utf8) ?? "<binary>"
            let lineupsRaw = lData.flatMap { String(data: $0, encoding: .utf8) } ?? "(no data)"
            lastScheduleRawJSON = schedRaw
            lastLineupsRawJSON  = lineupsRaw
            syncLog("[fetchAll] schedule: \(sData.count) bytes  lineups: \(lData?.count ?? 0) bytes")
            syncLog("[fetchAll] schedule JSON: \(String(data: sData.prefix(600), encoding: .utf8) ?? "<binary>")")

            // Only throw for a bad schedule response — lineups HTTP error is logged only.
            if let http = sResp as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                syncLog("[fetchAll] HTTP \(http.statusCode) for schedule")
                lastError = "Server returned \(http.statusCode) for schedule"
                throw URLError(.badServerResponse)
            }
            if let http = lResp as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                syncLog("[fetchAll] HTTP \(http.statusCode) for lineups — continuing without lineup data")
            }

            let decoder = JSONDecoder()
            var decodeErrors: [String] = []
            let schedule = decode(RawScheduleResponse.self, from: sData, tag: "schedule", errors: &decodeErrors, decoder: decoder)
            let lineups  = lData.flatMap {
                decode(RawLineupsResponse.self, from: $0, tag: "lineups", errors: &decodeErrors, decoder: decoder)
            }
            let stats    = stDataOpt.flatMap { (stData, _) in
                decode(RawStatsResponse.self, from: stData, tag: "stats",  errors: &decodeErrors, decoder: decoder)
            }
            let roster   = roDataOpt.flatMap { (roData, _) in
                decode(RawStatsResponse.self, from: roData, tag: "roster", errors: &decodeErrors, decoder: decoder)
            }

            // Parse standings into standingsMap (in-memory only, not persisted)
            if let (stndData, _) = stndDataOpt,
               let rawStandings = try? JSONDecoder().decode(RawStandingsResponse.self, from: stndData) {
                var map: [String: StandingsEntry] = [:]
                for s in rawStandings.standings ?? [] {
                    guard let abbr = s.team_abbreviation, !abbr.isEmpty else { continue }
                    map[abbr] = StandingsEntry(
                        abbr: abbr,
                        conference: s.conference ?? "",
                        wins: s.wins ?? 0,
                        losses: s.losses ?? 0,
                        pct: s.pct ?? 0,
                        homeRecord: s.home_record ?? "",
                        roadRecord: s.road_record ?? "",
                        lastTen: s.last_10 ?? "",
                        streak: s.streak ?? "",
                        pointsPG: s.points_pg ?? 0,
                        oppPointsPG: s.opp_points_pg ?? 0
                    )
                }
                standingsMap = map
                syncLog("[fetchAll] standingsMap populated — \(map.count) teams")
                // Persist for offline use
                if let encoded = try? JSONEncoder().encode(map) {
                    UserDefaults.standard.set(encoded, forKey: "cachedStandingsMap")
                }
            }

            // Extract per-game metadata (in-memory only)
            var newGameDetails: [String: GameDetails] = [:]
            for g in schedule?.games ?? [] {
                guard let gid = g.game_id else { continue }
                newGameDetails[gid] = GameDetails(
                    gameType: g.game_type ?? "regular",
                    seriesGameNumber: g.series_game_number ?? "",
                    gameLabel: g.game_label ?? "",
                    homeScore: g.home_score ?? 0,
                    awayScore: g.away_score ?? 0,
                    period: g.period ?? 0,
                    statusCode: g.status_code ?? 1,
                    homeWins: g.home_wins ?? 0,
                    awayWins: g.away_wins ?? 0
                )
            }
            gameDetails = newGameDetails
            syncLog("[fetchAll] gameDetails populated — \(newGameDetails.count) games")
            // Persist for offline use
            if let encoded = try? JSONEncoder().encode(newGameDetails) {
                UserDefaults.standard.set(encoded, forKey: "cachedGameDetails")
            }

            syncLog("[fetchAll] parsed — date: \(schedule?.date ?? "nil")  games: \(schedule?.games?.count ?? 0)  lineups: \(lineups?.rows?.count ?? 0)")

            if let games = schedule?.games {
                for g in games {
                    syncLog("[schedule] game_id=\(g.game_id ?? "nil") away=\(g.away ?? "nil") home=\(g.home ?? "nil") time=\(g.time ?? "nil") status=\(g.status ?? "nil")")
                }
            }

            if !decodeErrors.isEmpty {
                syncLog("[fetchAll] decode errors: \(decodeErrors.joined(separator: "; "))")
                lastError = "Decode failed: \(decodeErrors.joined(separator: ", "))"
            }

            // Merge roster (full team) + stats (top players) into one list; roster wins on overlap
            let mergedStats: RawStatsResponse? = {
                var all = stats?.players ?? []
                let rosterPlayers = roster?.players ?? []
                if !rosterPlayers.isEmpty {
                    let existingIDs = Set(all.compactMap { $0.player_id })
                    for p in rosterPlayers {
                        if let id = p.player_id, existingIDs.contains(id) {
                            // replace entry with richer roster data
                            all.removeAll { $0.player_id == id }
                        }
                        all.append(p)
                    }
                }
                return all.isEmpty ? nil : RawStatsResponse(players: all)
            }()

            // Persist schedule, lineups, and full rotation stats to the local DB
            persistToDatabase(schedule: schedule, lineups: lineups, stats: mergedStats)

            // Reload the DataSnapshot from the now-updated DB (today only)
            let today         = Self.isoDateString(Date())
            let todayDesc     = FetchDescriptor<StoredGame>(predicate: #Predicate { $0.date == today })
            let games         = (try? modelContext.fetch(todayDesc)) ?? []
            let storedPlayers = (try? modelContext.fetch(FetchDescriptor<StoredPlayer>())) ?? []
            let missing       = (try? modelContext.fetch(FetchDescriptor<StoredMissingPlayer>())) ?? []
            let lineupRows    = (try? modelContext.fetch(FetchDescriptor<StoredLineupPlayer>())) ?? []

            syncLog("[fetchAll] DB after persist — games: \(games.count)  players: \(storedPlayers.count)")

            let built = assembleSnapshot(
                games: games, storedProps: [],
                players: storedPlayers, missing: missing,
                lineups: lineupRows, fetchedAt: Date()
            )
            snapshot      = built
            lastFetchDate = Date()
            isUsingCache  = false
            // Record the ET date of this successful sync so ContentView can
            // detect a day rollover and clear stale cached games on next launch.
            UserDefaults.standard.set(Self.isoDateString(Date()), forKey: "lastFetchDate")
            syncLog("[fetchAll] Snapshot published — \(built.games.count) games, \(storedPlayers.count) players")

            if fetchLogs {
                await fetchLogsForTodaysPlayers()
            }

            return built

        } catch {
            if lastError == nil { lastError = "Cannot reach server: \(error.localizedDescription)" }
            syncLog("[fetchAll] FAILED: \(error)")
            if snapshot != nil { isUsingCache = true }
            throw error
        }
    }

    // MARK: - Player game logs (offline-first)

    func fetchPlayerLogs(playerID: String, season: Int = SportConfig.currentSeason) async {
        logsPlayerID  = playerID
        isLoadingLogs = true
        defer { isLoadingLogs = false }

        // 1. Serve local logs immediately
        let localLogs = loadLocalLogs(playerID: playerID, season: season)
        if !localLogs.isEmpty {
            playerLogs = localLogs
        }

        // 2. Attempt to sync fresh logs from server
        let base = serverURL.trimmingCharacters(in: .whitespaces)
        let encodedID = playerID.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? playerID
        guard let url = URL(string: "\(base)\(SportConfig.playerLogsEndpoint)?player_id=\(encodedID)&season=\(season)&days=\(Self.logRetentionDays)")
        else { return }
        syncLog("[fetchPlayerLogs] URL: \(base)\(SportConfig.playerLogsEndpoint)?player_id=\(encodedID)&season=\(season)&days=\(Self.logRetentionDays)")

        do {
            let (data, resp) = try await session.data(from: url)
            syncLog("[fetchPlayerLogs] \(playerID) — \(data.count) bytes  HTTP \((resp as? HTTPURLResponse)?.statusCode ?? 0)")
            if let http = resp as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                let body = String(data: data.prefix(500), encoding: .utf8) ?? "<binary>"
                syncLog("[fetchPlayerLogs] HTTP \(http.statusCode) error — body: \(body)")
                return
            }
            syncLog("[fetchPlayerLogs] JSON: \(String(data: data.prefix(400), encoding: .utf8) ?? "<binary>")")
            if let resp = try? JSONDecoder().decode(RawPlayerLogsResponse.self, from: data) {
                let rawCount = resp.logs?.count ?? 0
                syncLog("[fetchPlayerLogs] parsed \(rawCount) rows for playerID=\(resp.player_id ?? playerID)")
                persistLogs(resp.logs ?? [], defaultPlayerID: playerID,
                            defaultSeason: season)
                playerLogs = loadLocalLogs(playerID: playerID, season: season)
                syncLog("[fetchPlayerLogs] DB now has \(playerLogs.count) logs for \(playerID)")
            } else {
                syncLog("[fetchPlayerLogs] decode failed — raw: \(String(data: data.prefix(300), encoding: .utf8) ?? "<binary>")")
            }
        } catch {
            syncLog("[fetchPlayerLogs] network error for \(playerID): \(error)")
        }
    }

    // MARK: - Player log syncing

    /// Force-refresh logs for every player in today's snapshot, regardless of cache.
    /// Falls back to reading players from the local DB if the snapshot hasn't been built yet.
    /// If no players are found anywhere, triggers a full fetchAll() which populates players
    /// (via the fixed lineups endpoint) and then fetches their logs.
    func fetchLogsForTodaysPlayers() async {
        syncLog("[fetchLogsForTodaysPlayers] ▶ called — snapshot players: \(snapshot?.players.count ?? -1)")

        // Prefer snapshot; fall back to a DB read so this works before fetchAll() completes.
        var playerIDs = snapshot?.players.map { $0.playerID } ?? []
        if playerIDs.isEmpty {
            let stored = (try? modelContext.fetch(FetchDescriptor<StoredPlayer>())) ?? []
            playerIDs = stored.map { $0.playerID }
        }

        // No players yet — bootstrap by running a full sync (which populates StoredPlayer
        // from the lineups endpoint and then calls fetchLogsForTodaysPlayers itself).
        if playerIDs.isEmpty {
            syncLog("[fetchLogsForTodaysPlayers] no players in snapshot or DB — running fetchAll to bootstrap")
            _ = try? await fetchAll(fetchLogs: true)
            return
        }

        isLoadingAllLogs = true
        defer { isLoadingAllLogs = false }
        syncLog("[fetchLogsForTodaysPlayers] refreshing logs for \(playerIDs.count) player(s)")
        await withTaskGroup(of: Void.self) { group in
            for pid in playerIDs {
                group.addTask { await self.silentFetchLogs(playerID: pid) }
            }
        }
        syncLog("[fetchLogsForTodaysPlayers] done")
    }

    /// Concurrently fetches and persists logs for any playerIDs that have no rows in the local DB.
    /// Does not update any published state — safe to call from any view.
    func prefetchMissingLogs(playerIDs: [String]) async {
        let ctx = modelContext
        let missing = playerIDs.filter { pid in
            var d = FetchDescriptor<StoredGameLog>(predicate: #Predicate { $0.playerID == pid })
            d.fetchLimit = 1
            return ((try? ctx.fetch(d)) ?? []).isEmpty
        }
        guard !missing.isEmpty else { return }
        syncLog("[prefetch] fetching logs for \(missing.count) player(s) with no local data")
        await withTaskGroup(of: Void.self) { group in
            for pid in missing {
                group.addTask { await self.silentFetchLogs(playerID: pid) }
            }
        }
    }

    /// Fetches and persists player logs from the server without touching published state.
    private func silentFetchLogs(playerID: String,
                                 season: Int = SportConfig.currentSeason) async {
        let base    = serverURL.trimmingCharacters(in: .whitespaces)
        let encoded = playerID.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? playerID
        let urlStr  = "\(base)\(SportConfig.playerLogsEndpoint)?player_id=\(encoded)&season=\(season)&days=\(Self.logRetentionDays)"
        guard let url = URL(string: urlStr) else {
            syncLog("[silentFetchLogs] bad URL for playerID=\(playerID)")
            return
        }
        syncLog("[silentFetchLogs] GET \(urlStr)")
        do {
            let (data, resp) = try await session.data(from: url)
            let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
            if let http = resp as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                let body = String(data: data.prefix(300), encoding: .utf8) ?? "<binary>"
                syncLog("[silentFetchLogs] HTTP \(status) for \(playerID) — body: \(body)")
                return
            }
            if let decoded = try? JSONDecoder().decode(RawPlayerLogsResponse.self, from: data) {
                let count = decoded.logs?.count ?? 0
                syncLog("[silentFetchLogs] \(playerID) — \(data.count) bytes, \(count) log rows")
                persistLogs(decoded.logs ?? [], defaultPlayerID: playerID, defaultSeason: season)
            } else {
                syncLog("[silentFetchLogs] decode failed for \(playerID) — raw: \(String(data: data.prefix(200), encoding: .utf8) ?? "<binary>")")
            }
        } catch {
            syncLog("[silentFetchLogs] network error for \(playerID): \(error.localizedDescription)")
        }
    }

    // MARK: - Persistence helpers

    private func persistToDatabase(
        schedule: RawScheduleResponse?,
        lineups: RawLineupsResponse?,
        stats: RawStatsResponse?
    ) {
        let ctx   = modelContext
        let now   = Date()
        let today = Self.isoDateString(now)   // "yyyy-MM-dd" UTC, consistent with all other date handling

        // ── Clear today's transient data ─────────────────────────────────────
        deleteAll(StoredGame.self,          from: ctx)
        deleteAll(StoredMissingPlayer.self, from: ctx)
        deleteAll(StoredLineupPlayer.self,  from: ctx)

        // ── Persist games ────────────────────────────────────────────────────
        let rawGames = schedule?.games ?? []
        // The server returns days_ahead=2 by default — games for today AND future days.
        // Use the server's top-level "date" field as the authoritative "today" so we
        // only store today's games.  Fall back to client UTC today if the field is absent.
        let serverDate = schedule?.date.flatMap { $0.isEmpty ? nil : $0 } ?? today
        syncLog("[persist] serverDate=\(serverDate)  total raw games=\(rawGames.count)")
        for g in rawGames {
            guard let away = g.away, !away.isEmpty,
                  let home = g.home, !home.isEmpty else {
                syncLog("[persist] skipping game — missing away/home: \(g)")
                continue
            }
            // Only skip games that are clearly from a past date (completed games
            // the server still includes in the response).  Games whose date is
            // today OR in the future are kept — the server sometimes stamps
            // today's afternoon/evening games with tomorrow's UTC date.
            if let gameDate = g.date, !gameDate.isEmpty, gameDate < serverDate {
                syncLog("[persist] skipping past game date=\(gameDate) (\(away)@\(home)) status=\(g.status ?? "?")")
                continue
            }
            let gid = g.game_id ?? "\(away)_\(home)"
            syncLog("[persist] game gid=\(gid) \(away)@\(home) time=\(g.time ?? "?") status=\(g.status ?? "?")")
            ctx.insert(StoredGame(
                gameID: gid, date: today,
                awayTeam: away, homeTeam: home,
                gameTime: g.tip ?? g.time, status: g.status, syncedAt: now
            ))
            for mp in g.missing_away_players ?? [] {
                ctx.insert(StoredMissingPlayer(
                    gameID: gid, name: mp.name, status: mp.status,
                    reason: mp.reason, isAway: true, syncedAt: now))
            }
            for mp in g.missing_home_players ?? [] {
                ctx.insert(StoredMissingPlayer(
                    gameID: gid, name: mp.name, status: mp.status,
                    reason: mp.reason, isAway: false, syncedAt: now))
            }
        }

        // ── Persist lineups + upsert players from lineup data ────────────────────
        let existingPlayers = (try? ctx.fetch(FetchDescriptor<StoredPlayer>())) ?? []
        var playerByID = Dictionary(uniqueKeysWithValues:
            existingPlayers.map { ($0.playerID, $0) })

        var lineupRows     = 0
        var playersUpserted = 0
        for g in lineups?.rows ?? [] {
            let gid = g.game_id ?? ""
            for (lp, isAway) in (g.away_lineup ?? []).map({ ($0, true) })
                             + (g.home_lineup ?? []).map({ ($0, false) }) {
                ctx.insert(StoredLineupPlayer(
                    gameID: gid, name: lp.name, position: lp.position,
                    status: lp.status, source: lp.source,
                    updatedAt: lp.updated_at, team: lp.team,
                    isAway: isAway, syncedAt: now))
                lineupRows += 1

                // Upsert player record from lineup data
                if let id = lp.player_id, !id.isEmpty, let name = lp.name, !name.isEmpty {
                    if let existing = playerByID[id] {
                        existing.name     = name
                        existing.team     = lp.team
                        existing.position = lp.position
                        existing.syncedAt = now
                    } else {
                        let sp = StoredPlayer(playerID: id, name: name,
                                              team: lp.team, position: lp.position, syncedAt: now)
                        ctx.insert(sp)
                        playerByID[id] = sp
                    }
                    playersUpserted += 1
                }
            }
        }
        // ── Upsert full rotation from stats (covers bench players not in lineup) ────
        for sp in stats?.players ?? [] {
            guard let id = sp.player_id, !id.isEmpty,
                  let name = sp.name, !name.isEmpty else { continue }
            if let existing = playerByID[id] {
                if let t = sp.team, !t.isEmpty { existing.team = t }
                if let p = sp.pos,  !p.isEmpty { existing.position = p }
                existing.syncedAt = now
            } else {
                let newP = StoredPlayer(playerID: id, name: name,
                                        team: sp.team, position: sp.pos, syncedAt: now)
                ctx.insert(newP)
                playerByID[id] = newP
                playersUpserted += 1
            }
        }
        syncLog("[persist] lineup rows: \(lineupRows)  players upserted: \(playersUpserted)")

        // Save everything
        do {
            try ctx.save()
            syncLog("[persist] context save succeeded")
        } catch {
            syncLog("[persist] context save FAILED: \(error)")
        }
    }

    private func pruneOldGameLogs() {
        let ctx    = modelContext
        let cutoff = Calendar.current.date(
            byAdding: .day, value: -Self.logRetentionDays, to: Date()
        ) ?? Date()
        let cutoffStr = Self.isoDateString(cutoff)
        let stale = (try? ctx.fetch(
            FetchDescriptor<StoredGameLog>(
                predicate: #Predicate { $0.gameDate < cutoffStr }
            )
        )) ?? []
        for obj in stale { ctx.delete(obj) }
        if !stale.isEmpty { try? ctx.save() }
    }

    /// Deletes schedule rows older than the 2 most recent cached dates.
    /// Keeps the previous day's data as an offline fallback so the app
    /// remains usable when there is no network connection.
    ///
    /// IMPORTANT: StoredMissingPlayer / StoredLineupPlayer / StoredProp are NOT
    /// wiped here. They are cleared and repopulated by persistToDatabase() on every
    /// successful sync. Deleting them on launch would destroy visible offline data.
    private func pruneOldGames() {
        let ctx   = modelContext
        let today = Self.isoDateString(Date())

        let allGames = (try? ctx.fetch(FetchDescriptor<StoredGame>())) ?? []

        syncLog("[pruneOldGames] today=\(today)  total StoredGame rows=\(allGames.count)")
        let allDates = allGames.map { $0.date }
        syncLog("[pruneOldGames] dates in DB: \(allDates.isEmpty ? "[none]" : allDates.joined(separator: ", "))")

        // Keep the 2 most recent cached dates (today + prior day) as offline fallback.
        let distinctDates = Set(allDates).sorted(by: >)
        let datesToKeep   = Set(distinctDates.prefix(2))

        let staleGames = allGames.filter { !datesToKeep.contains($0.date) }
        syncLog("[pruneOldGames] stale (outside 2 most recent dates): \(staleGames.count)")
        for obj in staleGames {
            syncLog("[pruneOldGames]   deleting game date=\(obj.date) id=\(obj.gameID)")
            ctx.delete(obj)
        }

        let surviving = allGames.count - staleGames.count
        syncLog("[pruneOldGames] done — deleted \(staleGames.count) row(s), \(surviving) remain")
        if !staleGames.isEmpty { try? ctx.save() }

        // Rebuild the published snapshot from the now-clean database.
        loadFromDatabase()
        objectWillChange.send()
    }

    /// Public: nuke ALL schedule-related rows from the DB, then immediately re-sync from the server.
    /// Use this to recover from data inconsistencies (stale dates, bad rows, etc.).
    func clearAllGames() async {
        let ctx = modelContext
        deleteAll(StoredGame.self,          from: ctx)
        deleteAll(StoredMissingPlayer.self, from: ctx)
        deleteAll(StoredLineupPlayer.self,  from: ctx)
        deleteAll(StoredProp.self,          from: ctx)
        try? ctx.save()
        snapshot = nil
        syncLog("[clearAllGames] wiped all schedule data — re-syncing")
        _ = try? await fetchAll()
    }

    /// Nuclear reset: wipe every row in the database, then do a full sync
    /// (schedule + lineups + logs for all players) in one shot.
    func nuclearReset() async {
        let ctx = modelContext
        syncLog("[nuclearReset] wiping ALL local data…")
        deleteAll(StoredGame.self,        from: ctx)
        deleteAll(StoredMissingPlayer.self, from: ctx)
        deleteAll(StoredLineupPlayer.self,  from: ctx)
        deleteAll(StoredProp.self,          from: ctx)
        deleteAll(StoredPlayer.self,        from: ctx)
        deleteAll(StoredGameLog.self,       from: ctx)
        try? ctx.save()
        snapshot = nil
        syncLog("[nuclearReset] DB cleared — starting full sync")
        _ = try? await fetchAll(fetchLogs: true)
        syncLog("[nuclearReset] complete")
    }

    /// Public: wipe today's schedule from the local store and trigger a live sync.
    /// Called from the UI when the user wants a hard refresh.
    func clearScheduleCache() async {
        let ctx = modelContext
        // Wipe all schedule-related tables (pruneOldGames handles stale dates too)
        deleteAll(StoredGame.self,          from: ctx)
        deleteAll(StoredMissingPlayer.self, from: ctx)
        deleteAll(StoredLineupPlayer.self,  from: ctx)
        deleteAll(StoredProp.self,          from: ctx)
        try? ctx.save()
        snapshot = nil          // clear visible list immediately
        _ = try? await fetchAll()
    }

    private static func isoDateString(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        // NBA game dates are defined in Eastern Time. Using UTC causes the app's
        // "today" to advance at midnight UTC (8 pm EDT / 5 pm PDT), which is
        // earlier than the NBA day boundary. This makes the date filter in
        // persistToDatabase skip all of today's games and pruneOldGames() delete
        // valid cached rows whenever the app is used in the evening.
        f.timeZone = TimeZone(identifier: "America/New_York")
        return f.string(from: date)
    }

    private func persistLogs(_ rawLogs: [RawGameLog],
                             defaultPlayerID: String, defaultSeason: Int) {
        let ctx    = modelContext
        let now    = Date()
        let cutoffStr = Self.isoDateString(
            Calendar.current.date(byAdding: .day,
                                  value: -Self.logRetentionDays, to: now) ?? now
        )

        // Load existing log IDs for this player to avoid re-inserting
        let pid = defaultPlayerID
        var existing: FetchDescriptor<StoredGameLog> {
            var d = FetchDescriptor<StoredGameLog>(
                predicate: #Predicate { $0.playerID == pid }
            )
            d.propertiesToFetch = [\.logID]
            return d
        }
        let existingIDs = Set(
            ((try? ctx.fetch(existing)) ?? []).map { $0.logID }
        )

        for r in rawLogs {
            let resolvedPlayerID = r.player_id ?? defaultPlayerID
            guard let date = r.game_date, !date.isEmpty,
                  date >= cutoffStr,
                  r.mp_seconds != nil || r.pts != nil else { continue }
            let logID = "\(resolvedPlayerID)_\(date)"
            guard !existingIDs.contains(logID) else { continue }   // already stored
            ctx.insert(StoredGameLog(
                logID: logID,
                playerID: resolvedPlayerID,
                season: r.season ?? defaultSeason,
                gameDate: date,
                team: r.team, opponent: r.opponent,
                minutesSeconds: r.mp_seconds,
                pts: r.pts, reb: r.reb, ast: r.ast,
                threepm: r.three_p, ftm: r.ftm,
                fga: r.fga, fta: r.fta,
                stl: r.stl, blk: r.blk, tov: r.tov,
                syncedAt: now
            ))
        }
        try? ctx.save()
    }

    private func loadLocalLogs(playerID: String, season: Int) -> [GameLog] {
        let pid = playerID
        let cutoffStr = Self.isoDateString(
            Calendar.current.date(byAdding: .day,
                                  value: -Self.logRetentionDays, to: Date()) ?? Date()
        )
        var desc = FetchDescriptor<StoredGameLog>(
            predicate: #Predicate { $0.playerID == pid && $0.season == season && $0.gameDate >= cutoffStr },
            sortBy: [SortDescriptor(\.gameDate, order: .reverse)]
        )
        desc.fetchLimit = Self.logRetentionDays   // at most one game per day
        return ((try? modelContext.fetch(desc)) ?? []).map { $0.toGameLog() }
    }

    private func deleteAll<T: PersistentModel>(_ type: T.Type, from ctx: ModelContext) {
        let all = (try? ctx.fetch(FetchDescriptor<T>())) ?? []
        for obj in all { ctx.delete(obj) }
    }

    // MARK: - DataSnapshot assembly from stored objects

    private func assembleSnapshot(
        games: [StoredGame],
        storedProps: [StoredProp],
        players: [StoredPlayer],
        missing: [StoredMissingPlayer],
        lineups: [StoredLineupPlayer],
        fetchedAt: Date
    ) -> DataSnapshot {

        // Build prop buckets (same fallback-matching logic as before)
        var propsByGame: [String: [PlayerProp]] = [:]
        var allProps: [PlayerProp] = []
        for sp in storedProps {
            let prop = PlayerProp(
                id: sp.propID, gameID: sp.gameID,
                playerName: sp.playerName, team: sp.team,
                statLabel: sp.statLabel, line: sp.line,
                overPct: sp.overPct, projectedValue: sp.projectedValue
            )
            propsByGame[sp.gameID ?? "", default: []].append(prop)
            allProps.append(prop)
        }

        // Missing player lookup by gameID
        var missingByGame: [String: (away: [MissingPlayer], home: [MissingPlayer])] = [:]
        for m in missing {
            let mp = MissingPlayer(name: m.name, status: m.status, reason: m.reason)
            if m.isAway {
                missingByGame[m.gameID, default: ([], [])].away.append(mp)
            } else {
                missingByGame[m.gameID, default: ([], [])].home.append(mp)
            }
        }

        // Assemble ScheduleGame objects
        let scheduleGames: [ScheduleGame] = games.map { g in
            let gid    = g.gameID
            let awayUC = g.awayTeam.uppercased()
            let homeUC = g.homeTeam.uppercased()

            // Primary: exact game_id match
            var gameProps = propsByGame[gid] ?? []

            // Fallback: orphaned props (no game_id) whose team belongs here
            for prop in propsByGame[""] ?? [] {
                let pt = (prop.team ?? "").uppercased()
                if (pt == awayUC || pt == homeUC),
                   !gameProps.contains(where: { $0.id == prop.id }) {
                    gameProps.append(prop)
                }
            }
            // Sweep: props filed under a different ID but team matches
            for (key, bucket) in propsByGame where key != gid && key != "" {
                for prop in bucket {
                    let pt = (prop.team ?? "").uppercased()
                    if (pt == awayUC || pt == homeUC),
                       !gameProps.contains(where: { $0.id == prop.id }) {
                        gameProps.append(prop)
                    }
                }
            }

            return ScheduleGame(
                gameID: g.gameID, date: g.date,
                awayTeam: g.awayTeam, homeTeam: g.homeTeam,
                gameTime: g.gameTime, status: g.status,
                missingAwayPlayers: missingByGame[gid]?.away ?? [],
                missingHomePlayers: missingByGame[gid]?.home ?? [],
                playerProps: gameProps
            )
        }

        // Lineups
        var lineupsByGame: [String: (away: [LineupPlayer], home: [LineupPlayer])] = [:]
        for lp in lineups {
            let lpl = LineupPlayer(name: lp.name, position: lp.position,
                                   status: lp.status, source: lp.source,
                                   updatedAt: lp.updatedAt, team: lp.team)
            if lp.isAway {
                lineupsByGame[lp.gameID, default: ([], [])].away.append(lpl)
            } else {
                lineupsByGame[lp.gameID, default: ([], [])].home.append(lpl)
            }
        }
        let gameLineups: [GameLineup] = games.map { g in
            GameLineup(
                gameID: g.gameID, date: g.date,
                awayTeam: g.awayTeam, homeTeam: g.homeTeam,
                gameTime: g.gameTime,
                awayLineup: lineupsByGame[g.gameID]?.away ?? [],
                homeLineup: lineupsByGame[g.gameID]?.home ?? []
            )
        }

        let playersList: [Player] = players.map {
            Player(playerID: $0.playerID, name: $0.name,
                   team: $0.team, position: $0.position)
        }

        return DataSnapshot(
            fetchedAt: fetchedAt,
            games: scheduleGames,
            players: playersList,
            lineups: gameLineups,
            allProps: allProps
        )
    }

    // MARK: - Decode helper

    private func decode<T: Decodable>(_ type: T.Type, from data: Data,
                                      tag: String, errors: inout [String],
                                      decoder: JSONDecoder) -> T? {
        do {
            return try decoder.decode(type, from: data)
        } catch {
            let preview = String(data: data.prefix(300), encoding: .utf8) ?? "<binary>"
            syncLog("[DECODE ERROR] \(tag): \(error)")
            syncLog("[DECODE ERROR] \(tag) raw preview: \(preview)")
            errors.append("\(tag): \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - Direct server test (debug panel)

    /// Fires a raw GET to /nba/schedule and returns the response body as a String.
    /// Safe to call from the UI — never throws, surfaces any error inline.
    func testScheduleRaw() async -> String {
        let base = serverURL.trimmingCharacters(in: .whitespaces)
        guard let url = URL(string: base + SportConfig.scheduleEndpoint) else {
            return "Bad URL: \(base + SportConfig.scheduleEndpoint)"
        }
        do {
            let (data, resp) = try await session.data(from: url)
            let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
            let body   = String(data: data, encoding: .utf8) ?? "<non-UTF8 body>"
            return "HTTP \(status)\n\n\(body)"
        } catch {
            return "ERROR: \(error.localizedDescription)"
        }
    }

    // MARK: - Sync logging

    private func syncLog(_ msg: String) {
        print("[LocalDataService] \(msg)")
        let line = msg
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.debugLogs.append(line)
            if self.debugLogs.count > 120 { self.debugLogs.removeFirst() }
        }
    }
}

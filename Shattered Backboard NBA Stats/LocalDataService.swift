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
import CryptoKit
import Foundation
import SwiftData

extension Notification.Name {
    static let didRefreshPlayerLogs = Notification.Name("didRefreshPlayerLogs")
}

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

private struct RawBulkLogsResponse: Decodable {
    let season: Int?
    /// player_id → array of game logs
    let logs_by_player: [String: [RawGameLog]]?
}

private struct RawStandingsResponse: Decodable {
    let standings: [RawStandingsEntry]?
}

private struct RawTeamAdvancedResponse: Decodable {
    let season: Int?
    let teams: [RawTeamAdvancedEntry]?
}

private struct RawTeamPositionSplitsResponse: Decodable {
    let season: Int?
    let days: Int?
    let splits: [RawTeamPositionSplitEntry]?
}

private struct RawTeamPositionSplitEntry: Decodable {
    let team_abbreviation: String?
    let position_group: String?
    let pts_allowed: Double?
    let reb_allowed: Double?
    let ast_allowed: Double?
    let threepm_allowed: Double?
    let stl_allowed: Double?
    let blk_allowed: Double?
    let pra_allowed: Double?
    let sample_size: Int?
}

private struct RawTeamAdvancedEntry: Decodable {
    let team_abbreviation: String?
    let pace: Double?
    let off_rating: Double?
    let def_rating: Double?
    let net_rating: Double?
    let ts_pct: Double?
    let efg_pct: Double?
    let tov_pct: Double?
    let reb_pct: Double?
    let ast_ratio: Double?
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

private struct BundleSourceStatus: Decodable {
    let espn_rows: Int?
    let stats_wnba_rows: Int?
    let carried_existing_rows: Int?
}

/// Top-level container for StarterLogs.json (bundled seed data).
private struct BundleLogsFile: Decodable {
    let season: Int?
    let date: String?
    let generated_at: String?
    let source_status: BundleSourceStatus?
    let players: [RawStatPlayer]?
    let games: [RawGame]?
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
    @Published var snapshot: DataSnapshot? {
        didSet {
            snapshotID &+= 1
            // Fresh snapshot may contain updated official lineups — re-evaluate matchups.
            MatchupDefenseEvaluator.clearCache()
        }
    }
    @Published var snapshotID: Int = 0
    /// Bumped whenever new game log rows are actually written to the DB.
    /// Views key cached projections off this so a routine stats refresh
    /// (not just the one-off historical backfill) invalidates old predictions.
    @Published var logsRevision: Int = 0
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
    /// Team advanced metrics keyed by team abbreviation.
    @Published var teamAdvancedMap: [String: TeamAdvancedEntry] = [:]
    /// Team defensive splits keyed by team abbreviation, then position bucket.
    @Published var teamPositionSplitsMap: [String: [String: TeamPositionSplitEntry]] = [:]
    /// Latest rolling backtest summary used for model auto-tuning.
    @Published var latestBacktestSummary: BacktestSummary?
    /// Build-bundled data metadata surfaced in Settings.
    @Published var bundledDataGeneratedAt: String = ""
    @Published var bundledDataLatestGameDate: String = ""
    @Published var bundledDataSourceSummary: String = ""

    // MARK: Server URL (user-configurable in debug settings)

    var serverURL: String {
        get { UserDefaults.standard.string(forKey: SportConfig.serverURLKey) ?? SportConfig.baseURL }
        set { UserDefaults.standard.set(newValue, forKey: SportConfig.serverURLKey) }
    }

    // MARK: Private

    /// GET via URLSession with the shared-secret `X-API-Key` header attached
    /// when the target is the configured stats server. URLs pointing
    /// elsewhere (ESPN fallbacks) never receive the key. No-op when
    /// `SportConfig.serverAPIKey` is empty.
    private func authenticatedData(from url: URL) async throws -> (Data, URLResponse) {
        var urlRequest = URLRequest(url: url)
        let key = SportConfig.serverAPIKey
        if !key.isEmpty,
           let serverHost = URL(string: serverURL)?.host,
           url.host == serverHost {
            urlRequest.setValue(key, forHTTPHeaderField: "X-API-Key")
        }
        return try await session.data(for: urlRequest)
    }

    private var modelContext: ModelContext { AppDatabase.shared.mainContext }

    /// In-memory cache of game logs per playerID — survives tab switches and back-navigation
    /// within a single app session. Invalidated automatically when fresh logs are written.
    private var logMemoryCache: [String: [GameLog]] = [:]

    private let session: URLSession = {
        let cfg = URLSessionConfiguration.default
        // Render free tier can take 50+ s to wake from a cold start.
        // The warmup ping in fetchAll absorbs that cost before the heavy
        // parallel requests fire, but set a generous cap here as a safety net.
        cfg.timeoutIntervalForRequest  = 60
        cfg.timeoutIntervalForResource = 180
        return URLSession(configuration: cfg)
    }()

    /// Set to false when the server fails to respond; back to true on next success.
    /// Used to suppress background log prefetches after a connectivity failure.
    private var serverReachable = true
    private var isPrimingPredictionData = false

    /// Game-log window kept in the local DB.  Older rows are pruned on launch.
    /// 365 days covers the full prior NBA season so 2025 seed data stays alive
    /// throughout 2026 until live game logs accumulate and the engine's recency
    /// weighting naturally de-emphasises the older rows.
    private static let logRetentionDays = 400   // covers full current NBA season (Oct-Jun) + buffer

    /// Window sent to the server for log fetch requests.
    private static let logFetchDays = 90

    /// Returns the latest game_date stored across all local logs, or nil if none.
    /// Used as the `since` cutoff so we only request games the phone doesn't have yet.
    private func latestLocalGameDate() -> String? {
        var desc = FetchDescriptor<StoredGameLog>(
            sortBy: [SortDescriptor(\.gameDate, order: .reverse)]
        )
        desc.fetchLimit = 1
        return (try? modelContext.fetch(desc))?.first?.gameDate
    }

    /// Preserve a much wider local schedule window so the app keeps the current
    /// season's games locally and only prunes very old rows. This prevents the UI
    /// from appearing stuck on an older date after refreshes.
    private static let schedulePastRetentionDays = 365
    private static let scheduleFutureRetentionDays = 45

    /// Minimum interval between full schedule/lineup/stat sync attempts.
    /// Kept short so the Schedule tab can roll to the next slate soon after finals.
    private static let fullSyncMinInterval: TimeInterval = 2 * 60
    /// Minimum interval between per-player log refresh attempts.
    private static let playerLogRefreshInterval: TimeInterval = 12 * 60 * 60

    private static let lastFullSyncAtKey = "lastFullSyncAt"
    private static let responseCacheDirName = "NBAResponseCache"

    private struct CachedHTTPPayload: Codable {
        let savedAt: Date
        let body: Data
    }

    private init() {
        loadBundledDataVersionFromDefaults()
        // 1. Import bundled seed data on very first launch (before pruning, so logs survive).
        importBundledLogsIfNeeded()
        // 2. Prune stale data; pruneOldGames() rebuilds the snapshot when done.
        pruneOldGameLogs()
        pruneOldGames()
    }

    // MARK: - Bundled seed data import

    private static let bundleDigestKey = "bundleLogsDigest_v1"
    private static let bundleGeneratedAtKey = "bundle_generated_at"
    private static let bundleLatestDateKey = "bundle_latest_game_date"
    private static let bundleSourceSummaryKey = "bundle_source_summary"
    private static let lastNameHydrationAtKey = "bundle_name_hydration_last_at"
    private static let lastBundledScheduleRefreshDateKey = "bundle_schedule_refresh_date"

    /// Imports StarterLogs.json from the app bundle whenever its content changes.
    /// This makes data refresh automatically on app updates that ship a new bundle.
    private func importBundledLogsIfNeeded() {
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

        updateBundledDataVersionMetadata(file: file, logs: logs)

        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let previousDigest = UserDefaults.standard.string(forKey: Self.bundleDigestKey)
        let hasStoredGames = hasAnyStoredGames()
        let shouldImport = previousDigest != digest || !hasAnyBundledData() || !hasAnyLocalLogs() || !hasStoredGames
        guard shouldImport else {
            // Keep schedule rows aligned to today's date even when bundle content
            // is unchanged, so date-filtering fixes apply without requiring a
            // new bundle digest.
            if !(file.games ?? []).isEmpty && (!hasStoredGames || shouldRefreshBundledScheduleToday()) {
                refreshBundledScheduleRowsOnly()
                persistBundledGames(file.games ?? [], fallbackDate: file.date)
                UserDefaults.standard.set(Self.isoDateString(Date()), forKey: Self.lastBundledScheduleRefreshDateKey)
                syncLog("[bundleImport] refreshed bundled schedule rows")
            }
            syncLog("[bundleImport] StarterLogs.json unchanged — keeping existing local data")
            return
        }

        let bundledPlayers = file.players ?? []
        let bundledGames = file.games ?? []
        resetBundleManagedTables(
            resetPlayers: !bundledPlayers.isEmpty,
            resetGames: !bundledGames.isEmpty
        )

        let season = file.season ?? SportConfig.currentSeason
        persistLogs(logs, defaultPlayerID: "", defaultSeason: season)

        if !bundledPlayers.isEmpty {
            persistBundledPlayers(bundledPlayers)
        } else {
            persistDerivedPlayersFromLogs(logs)
        }
        if !bundledGames.isEmpty {
            persistBundledGames(bundledGames, fallbackDate: file.date)
            UserDefaults.standard.set(Self.isoDateString(Date()), forKey: Self.lastBundledScheduleRefreshDateKey)
        }

        UserDefaults.standard.set(digest, forKey: Self.bundleDigestKey)
        UserDefaults.standard.set(Self.isoDateString(Date()), forKey: "lastFetchDate")
        syncLog("[bundleImport] imported \(logs.count) log rows, \(bundledPlayers.count) players, \(bundledGames.count) games")
    }

    private func shouldRefreshBundledScheduleToday() -> Bool {
        let today = Self.isoDateString(Date())
        let last = UserDefaults.standard.string(forKey: Self.lastBundledScheduleRefreshDateKey)
        return last != today
    }

    // MARK: - Load from local SwiftData store

    private func loadFromDatabase() {
        let now = Date()
        let ctx = modelContext

        let allStoredGames = (try? ctx.fetch(FetchDescriptor<StoredGame>())) ?? []
        let activeDate = activeScheduleDate(from: allStoredGames)
        let games = allStoredGames.filter { $0.date == activeDate }

        let storedProps   = (try? ctx.fetch(FetchDescriptor<StoredProp>())) ?? []
        let storedPlayers = (try? ctx.fetch(FetchDescriptor<StoredPlayer>())) ?? []
        let missing       = (try? ctx.fetch(FetchDescriptor<StoredMissingPlayer>())) ?? []
        let lineupRows    = (try? ctx.fetch(FetchDescriptor<StoredLineupPlayer>())) ?? []

        // Restore standings from SwiftData
        let storedStandings = (try? ctx.fetch(FetchDescriptor<StoredStandings>())) ?? []
        if !storedStandings.isEmpty {
            standingsMap = Dictionary(
                uniqueKeysWithValues: storedStandings.map { ($0.abbr, $0.toStandingsEntry()) }
            )
        } else if !SportConfig.usesServerSync {
            let derived = deriveStandingsFromLocalLogs()
            if !derived.isEmpty {
                standingsMap = derived
                persistStandings(derived)
                syncLog("[standings] derived \(derived.count) teams from local logs")
            }
        }

        // Restore game details from SwiftData
        let storedDetails = (try? ctx.fetch(FetchDescriptor<StoredGameDetails>())) ?? []
        if !storedDetails.isEmpty {
            gameDetails = Dictionary(
                uniqueKeysWithValues: storedDetails.map { ($0.gameID, $0.toGameDetails()) }
            )
        }

        // Publish even when the active slate is empty (off day / pre-sync) so any
        // stale in-memory snapshot from a previous day is replaced with the empty
        // state instead of lingering as "today's" games. Only a truly empty store
        // on first launch keeps the snapshot nil so views show the loading state.
        guard !allStoredGames.isEmpty || snapshot != nil else {
            return
        }

        if let activeDate {
            syncLog("[loadFromDatabase] active schedule date=\(activeDate) games=\(games.count)")
        }

        let snap = assembleSnapshot(
            games: games, storedProps: storedProps,
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
        if !SportConfig.usesServerSync {
            importBundledLogsIfNeeded()
            await hydratePlaceholderPlayerNamesIfNeeded()
            loadFromDatabase()
            if standingsMap.isEmpty {
                let derived = deriveStandingsFromLocalLogs()
                if !derived.isEmpty {
                    standingsMap = derived
                    persistStandings(derived)
                    syncLog("[fetchAll] standings fallback built from local logs: \(derived.count) teams")
                }
            }
            let built = publishSnapshotFromDatabase(fetchedAt: Date())
            isUsingCache = true
            lastError = nil
            syncLog("[fetchAll] bundle-only mode active — skipping server sync")
            if fetchLogs {
                await recomputeBacktestAndAutoTune()
            }
            return built
        }

        if let snap = snapshot,
           !snap.games.isEmpty,
           !shouldRunFullSync() {
            isUsingCache = true
            syncLog("[fetchAll] using local cache — last full sync is still fresh")
            if fetchLogs {
                startPredictionWarmupIfNeeded(reason: "fresh snapshot")
            }
            return snap
        }

        // Resolve placeholder player names before any network sync attempt.
        // Bundled seed logs carry IDs but no names; until a real roster/stats
        // sync supplies canonical ones, hydrate from public sources so Player
        // Search shows real players. Self-throttled, and a no-op when there is
        // nothing left to resolve.
        if await hydratePlaceholderPlayerNamesIfNeeded() {
            loadFromDatabase()
            publishSnapshotFromDatabase(fetchedAt: Date())
        }

        let base = serverURL.trimmingCharacters(in: .whitespaces)

        // Ask the server for the slate keyed to the app's display time zone.
        // Without the date param the server defaults to Eastern Time's "today",
        // which runs 2–3 hours ahead of the app's zone and serves the next
        // day's games late at night.
        let scheduleDateParam = Self.isoDateString(Date())
        guard
            let scheduleURL  = URL(string: base + SportConfig.scheduleEndpoint + "?date=" + scheduleDateParam),
            let lineupsURL   = URL(string: base + SportConfig.lineupsEndpoint),
            let statsURL     = URL(string: base + SportConfig.statsEndpoint),
            let rosterURL    = URL(string: base + SportConfig.rosterEndpoint),
            let standingsURL = URL(string: base + SportConfig.standingsEndpoint),
            let teamAdvURL   = URL(string: base + SportConfig.teamAdvancedEndpoint),
            let posSplitURL  = URL(string: base + SportConfig.teamPositionSplitsEndpoint)
        else { throw URLError(.badURL) }

        isFetching = true
        lastError  = nil
        defer { isFetching = false }

        syncLog("[fetchAll] Starting sync — server: \(base)")

        serverReachable = true

        do {
            // Request today's slate first. Late at night the server may already
            // have purged finished games ("games":[]) — in that case walk
            // forward day-by-day so the app surfaces the NEXT upcoming slate
            // instead of going blank until the server's own "today" rolls over.
            var sData = try await fetchScheduleData(serverURL: scheduleURL)
            // A slate counts as usable only if it has games on today or later.
            // Finished-only results (server purged the day, or the ESPN
            // fallback returned completed games) must trigger the probe too,
            // or the builders go blank until the server's "today" rolls over.
            func upcomingGameCount(in data: Data) -> Int {
                let today = Self.isoDateString(Date())
                let games = (try? JSONDecoder().decode(RawScheduleResponse.self, from: data))?.games ?? []
                return games.filter { ($0.date ?? "") >= today }.count
            }
            if upcomingGameCount(in: sData) == 0 {
                syncLog("[fetchAll] today (\(scheduleDateParam)) has no upcoming games — probing next days")
                for offset in 1...4 {
                    guard
                        let offsetDate = Calendar.current.date(byAdding: .day, value: offset, to: Date()),
                        let dayURL = URL(string: base + SportConfig.scheduleEndpoint + "?date=" + Self.isoDateString(offsetDate))
                    else { continue }
                    guard let dayData = try? await fetchScheduleData(serverURL: dayURL) else { continue }
                    let dayCount = upcomingGameCount(in: dayData)
                    syncLog("[fetchAll] probe \(Self.isoDateString(offsetDate)): \(dayCount) upcoming games")
                    if dayCount > 0 {
                        sData = dayData
                        break
                    }
                }
            }

            let schedRaw = String(data: sData, encoding: .utf8) ?? "<binary>"
            lastScheduleRawJSON = schedRaw
            syncLog("[fetchAll] schedule: \(sData.count) bytes")
            syncLog("[fetchAll] schedule JSON: \(String(data: sData.prefix(600), encoding: .utf8) ?? "<binary>")")

            let decoder = JSONDecoder()
            var decodeErrors: [String] = []
            let schedule = decode(RawScheduleResponse.self, from: sData, tag: "schedule", errors: &decodeErrors, decoder: decoder)

            updateGameDetails(from: schedule)

            syncLog("[fetchAll] parsed schedule — date: \(schedule?.date ?? "nil")  games: \(schedule?.games?.count ?? 0)")
            if let games = schedule?.games {
                for g in games {
                    syncLog("[schedule] game_id=\(g.game_id ?? "nil") away=\(g.away ?? "nil") home=\(g.home ?? "nil") time=\(g.time ?? "nil") status=\(g.status ?? "nil")")
                }
            }

            if !decodeErrors.isEmpty {
                syncLog("[fetchAll] decode errors: \(decodeErrors.joined(separator: "; "))")
                lastError = "Decode failed: \(decodeErrors.joined(separator: ", "))"
            }

            // Publish today's games first so schedule visibility is not blocked by
            // slower supplemental endpoints on the server.
            persistToDatabase(schedule: schedule, lineups: nil, stats: nil)
            let built = publishSnapshotFromDatabase(fetchedAt: Date())
            isUsingCache = false
            UserDefaults.standard.set(Self.isoDateString(Date()), forKey: "lastFetchDate")
            if !built.games.isEmpty {
                UserDefaults.standard.set(Date(), forKey: Self.lastFullSyncAtKey)
            } else {
                UserDefaults.standard.removeObject(forKey: Self.lastFullSyncAtKey)
                syncLog("[fetchAll] snapshot contained 0 games — not marking full sync as fresh")
            }
            syncLog("[fetchAll] Schedule snapshot published early — \(built.games.count) games")

            Task { @MainActor in
                await self.applySupplementalSync(
                    schedule: schedule,
                    lineupsURL: lineupsURL,
                    statsURL: statsURL,
                    rosterURL: rosterURL,
                    standingsURL: standingsURL,
                    teamAdvURL: teamAdvURL,
                    posSplitURL: posSplitURL
                )
            }

            if fetchLogs {
                startPredictionWarmupIfNeeded(reason: "post-schedule sync")
            }

            return built

        } catch {
            if lastError == nil { lastError = "Cannot reach server: \(error.localizedDescription)" }
            syncLog("[fetchAll] FAILED: \(error)")
            serverReachable = false
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

        if !shouldRefreshPlayerLogs(playerID: playerID, maxAge: Self.playerLogRefreshInterval) {
            syncLog("[fetchPlayerLogs] using local logs for \(playerID) — refresh window not reached")
            return
        }

        if !SportConfig.usesServerSync {
            syncLog("[fetchPlayerLogs] bundle-only mode — using local logs for \(playerID)")
            return
        }

        // 2. Attempt to sync fresh logs from server
        // Skip the network round-trip if the server is known unreachable (e.g. the
        // warmup ping in fetchAll just failed). This prevents a 60-second hang on
        // cold-start when the caller already has nothing to show from local cache.
        guard serverReachable else {
            syncLog("[fetchPlayerLogs] skipping network fetch — server marked unreachable")
            return
        }

        let base = serverURL.trimmingCharacters(in: .whitespaces)
        let encodedID = playerID.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? playerID
        guard let url = URL(string: "\(base)\(SportConfig.playerLogsEndpoint)?player_id=\(encodedID)&season=\(season)&days=\(Self.logFetchDays)")
        else { return }
        syncLog("[fetchPlayerLogs] URL: \(base)\(SportConfig.playerLogsEndpoint)?player_id=\(encodedID)&season=\(season)&days=\(Self.logFetchDays)")

        do {
            let data = try await fetchDataWithCache(from: url,
                                                    maxAge: Self.playerLogRefreshInterval,
                                                    tag: "player_logs_\(playerID)")
            syncLog("[fetchPlayerLogs] \(playerID) — \(data.count) bytes")
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

    /// Downloads and persists logs for players on today's slate first so startup
    /// predictions are ready quickly. Falls back to the broader stored roster only
    /// when today's player set can't be resolved.
    func fetchLogsForTodaysPlayers() async {
        if !SportConfig.usesServerSync {
            syncLog("[fetchLogsForTodaysPlayers] bundle-only mode — local logs only")
            await recomputeBacktestAndAutoTune()
            return
        }

        let allStored = (try? modelContext.fetch(FetchDescriptor<StoredPlayer>())) ?? []
        let todayTeams = Set((snapshot?.games ?? []).flatMap {
            [$0.awayTeam.uppercased(), $0.homeTeam.uppercased()]
        })

        var playerIDs: [String] = []
        if !todayTeams.isEmpty {
            playerIDs = allStored
                .filter { player in
                    guard let team = player.team?.uppercased() else { return false }
                    return todayTeams.contains(team)
                }
                .map(\.playerID)
        }

        // Merge in any snapshot players not yet persisted (e.g. first-run bootstrap).
        if let snapIDs = snapshot?.players
            .filter({ player in
                todayTeams.isEmpty || todayTeams.contains((player.team ?? "").uppercased())
            })
            .map({ $0.playerID }) {
            let existing = Set(playerIDs)
            playerIDs += snapIDs.filter { !existing.contains($0) }
        }

        if todayTeams.isEmpty {
            syncLog("[fetchLogsForTodaysPlayers] no teams on current snapshot — skipping log warmup")
            return
        }

        playerIDs = Array(Set(playerIDs)).sorted()

        syncLog("[fetchLogsForTodaysPlayers] ▶ called — \(playerIDs.count) target players")

        // No players yet — bootstrap by running a full sync.
        if playerIDs.isEmpty {
            syncLog("[fetchLogsForTodaysPlayers] no players anywhere — running fetchAll to bootstrap")
            _ = try? await fetchAll(fetchLogs: true)
            return
        }

        isLoadingAllLogs = true
        defer { isLoadingAllLogs = false }
        let refreshIDs = playerIDs.filter {
            shouldRefreshPlayerLogs(playerID: $0, maxAge: Self.playerLogRefreshInterval)
        }
        guard !refreshIDs.isEmpty else {
            syncLog("[fetchLogsForTodaysPlayers] all player logs are already fresh locally")
            return
        }
        syncLog("[fetchLogsForTodaysPlayers] refreshing logs for \(refreshIDs.count)/\(playerIDs.count) players")
        await fetchBulkPlayerLogs(
            playerIDs: refreshIDs,
            season: SportConfig.currentSeason,
            maxAge: Self.playerLogRefreshInterval
        )
        syncLog("[fetchLogsForTodaysPlayers] done")
    }

    /// Backfills logs for the full known roster (stored players + current snapshot players).
    /// Use `forceRefresh=true` to bypass freshness windows and refresh from the server now.
    func backfillAllPlayerLogs(forceRefresh: Bool = true,
                               season: Int = SportConfig.currentSeason) async {
        if !SportConfig.usesServerSync {
            syncLog("[backfillAllPlayerLogs] bundle-only mode — local logs only")
            await recomputeBacktestAndAutoTune()
            return
        }

        if isLoadingAllLogs {
            syncLog("[backfillAllPlayerLogs] skipped — already running")
            return
        }

        var playerIDs = Set((try? modelContext.fetch(FetchDescriptor<StoredPlayer>()))?.map(\.playerID) ?? [])
        for p in snapshot?.players ?? [] {
            playerIDs.insert(p.playerID)
        }

        // Bootstrap a roster when nothing has been loaded yet.
        if playerIDs.isEmpty {
            syncLog("[backfillAllPlayerLogs] no roster yet — fetching schedule/stats first")
            _ = try? await fetchAll(fetchLogs: false)
            playerIDs = Set((try? modelContext.fetch(FetchDescriptor<StoredPlayer>()))?.map(\.playerID) ?? [])
            for p in snapshot?.players ?? [] {
                playerIDs.insert(p.playerID)
            }
        }

        let sortedIDs = Array(playerIDs).sorted()
        guard !sortedIDs.isEmpty else {
            syncLog("[backfillAllPlayerLogs] no players available to backfill")
            return
        }

        isLoadingAllLogs = true
        defer { isLoadingAllLogs = false }

        let targetIDs: [String]
        if forceRefresh {
            targetIDs = sortedIDs
        } else {
            targetIDs = sortedIDs.filter {
                shouldRefreshPlayerLogs(playerID: $0, maxAge: Self.playerLogRefreshInterval)
            }
        }

        guard !targetIDs.isEmpty else {
            syncLog("[backfillAllPlayerLogs] all player logs already fresh locally")
            return
        }

        let maxAge: TimeInterval = forceRefresh ? 0 : Self.playerLogRefreshInterval
        syncLog("[backfillAllPlayerLogs] refreshing logs for \(targetIDs.count)/\(sortedIDs.count) players")
        await fetchBulkPlayerLogs(playerIDs: targetIDs, season: season, maxAge: maxAge)
        await recomputeBacktestAndAutoTune()
        syncLog("[backfillAllPlayerLogs] done")
    }

    /// Backfills historical logs for the full known roster from a specific start date through today.
    /// This is intended for one-off recovery jobs such as loading August 3rd onward.
    func backfillHistoricalPlayerLogs(from startDate: String,
                                      season: Int = SportConfig.currentSeason) async {
        if !SportConfig.usesServerSync {
            syncLog("[backfillHistoricalPlayerLogs] bundle-only mode — local logs only")
            await recomputeBacktestAndAutoTune()
            return
        }

        if isLoadingAllLogs {
            syncLog("[backfillHistoricalPlayerLogs] skipped — already running")
            return
        }

        var playerIDs = Set((try? modelContext.fetch(FetchDescriptor<StoredPlayer>()))?.map(\.playerID) ?? [])
        for p in snapshot?.players ?? [] {
            playerIDs.insert(p.playerID)
        }

        if playerIDs.isEmpty {
            syncLog("[backfillHistoricalPlayerLogs] no roster yet — fetching schedule/stats first")
            _ = try? await fetchAll(fetchLogs: false)
            playerIDs = Set((try? modelContext.fetch(FetchDescriptor<StoredPlayer>()))?.map(\.playerID) ?? [])
            for p in snapshot?.players ?? [] {
                playerIDs.insert(p.playerID)
            }
        }

        let sortedIDs = Array(playerIDs).sorted()
        guard !sortedIDs.isEmpty else {
            syncLog("[backfillHistoricalPlayerLogs] no players available")
            return
        }

        isLoadingAllLogs = true
        defer { isLoadingAllLogs = false }

        syncLog("[backfillHistoricalPlayerLogs] starting historical backfill for \(sortedIDs.count) players from \(startDate) to today")
        await fetchBulkPlayerLogsForDateRange(playerIDs: sortedIDs,
                                              season: season,
                                              startDate: startDate)
        await recomputeBacktestAndAutoTune()
        clearProjectionCache()
        syncLog("[backfillHistoricalPlayerLogs] done")
    }

    private func fetchBulkPlayerLogsForDateRange(playerIDs: [String],
                                                 season: Int,
                                                 startDate: String) async {
        guard !playerIDs.isEmpty else { return }
        let batchSize = 100
        let batches = stride(from: 0, to: playerIDs.count, by: batchSize).map {
            Array(playerIDs[$0 ..< min($0 + batchSize, playerIDs.count)])
        }

        for (i, batch) in batches.enumerated() {
            await fetchBulkBatchForDateRange(playerIDs: batch,
                                             season: season,
                                             batchIndex: i + 1,
                                             total: batches.count,
                                             startDate: startDate)
        }
    }

    private func fetchBulkBatchForDateRange(playerIDs: [String],
                                             season: Int,
                                             batchIndex: Int,
                                             total: Int,
                                             startDate: String) async {
        let base = serverURL.trimmingCharacters(in: .whitespaces)
        let idsJoined = playerIDs.joined(separator: ",")
            .addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        let urlStr = "\(base)\(SportConfig.playerLogsBulkEndpoint)?player_ids=\(idsJoined)&season=\(season)&days=365&start_date=\(startDate)"
        guard let url = URL(string: urlStr) else {
            syncLog("[fetchBulkBatchForDateRange \(batchIndex)/\(total)] bad URL — falling back to individual fetches")
            await fetchLogsIndividuallyForDateRange(playerIDs: playerIDs, season: season, startDate: startDate)
            return
        }

        syncLog("[fetchBulkBatchForDateRange \(batchIndex)/\(total)] GET \(playerIDs.count) players from \(startDate)")
        do {
            let data = try await fetchDataWithCache(from: url,
                                                    maxAge: 0,
                                                    tag: "player_logs_bulk_hist_\(batchIndex)")
            if let decoded = try? JSONDecoder().decode(RawBulkLogsResponse.self, from: data),
               let byPlayer = decoded.logs_by_player {
                var totalRows = 0
                for (pid, rawLogs) in byPlayer {
                    persistLogs(rawLogs, defaultPlayerID: pid, defaultSeason: season)
                    totalRows += rawLogs.count
                }
                syncLog("[fetchBulkBatchForDateRange \(batchIndex)/\(total)] persisted \(totalRows) rows across \(byPlayer.count) players")
            } else {
                syncLog("[fetchBulkBatchForDateRange \(batchIndex)/\(total)] decode failed — falling back to individual fetches")
                await fetchLogsIndividuallyForDateRange(playerIDs: playerIDs, season: season, startDate: startDate)
            }
        } catch {
            syncLog("[fetchBulkBatchForDateRange \(batchIndex)/\(total)] error: \(error.localizedDescription) — falling back to individual fetches")
            await fetchLogsIndividuallyForDateRange(playerIDs: playerIDs, season: season, startDate: startDate)
        }
    }

    private func fetchLogsIndividuallyForDateRange(playerIDs: [String],
                                                   season: Int,
                                                   startDate: String) async {
        syncLog("[fetchLogsIndividuallyForDateRange] fetching \(playerIDs.count) players")
        await withTaskGroup(of: Void.self) { group in
            var active = 0
            for pid in playerIDs {
                if active >= 4 {
                    await group.next()
                    active -= 1
                }
                group.addTask { await self.silentFetchHistoricalLogs(playerID: pid, season: season, startDate: startDate) }
                active += 1
            }
        }
    }

    private func silentFetchHistoricalLogs(playerID: String,
                                           season: Int = SportConfig.currentSeason,
                                           startDate: String) async {
        let base = serverURL.trimmingCharacters(in: .whitespaces)
        let encoded = playerID.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? playerID
        let urlStr = "\(base)\(SportConfig.playerLogsEndpoint)?player_id=\(encoded)&season=\(season)&days=365&start_date=\(startDate)"
        guard let url = URL(string: urlStr) else {
            syncLog("[silentFetchHistoricalLogs] bad URL for playerID=\(playerID)")
            return
        }
        syncLog("[silentFetchHistoricalLogs] GET \(urlStr)")
        do {
            let data = try await fetchDataWithCache(from: url,
                                                    maxAge: 0,
                                                    tag: "player_logs_hist_\(playerID)")
            if let decoded = try? JSONDecoder().decode(RawPlayerLogsResponse.self, from: data) {
                let count = decoded.logs?.count ?? 0
                syncLog("[silentFetchHistoricalLogs] \(playerID) — \(count) log rows")
                persistLogs(decoded.logs ?? [], defaultPlayerID: playerID, defaultSeason: season)
            }
        } catch {
            syncLog("[silentFetchHistoricalLogs] network error for \(playerID): \(error.localizedDescription)")
        }
    }

    private func clearProjectionCache() {
        NotificationCenter.default.post(name: .didRefreshPlayerLogs, object: nil)
    }

    private func startPredictionWarmupIfNeeded(reason: String) {
        guard !(snapshot?.games.isEmpty ?? true) else {
            syncLog("[warmup] skipped — no games on current snapshot (\(reason))")
            return
        }
        guard !isPrimingPredictionData else {
            syncLog("[warmup] skipped — already running (\(reason))")
            return
        }

        isPrimingPredictionData = true
        Task(priority: .utility) { @MainActor in
            self.syncLog("[warmup] starting prediction data refresh (\(reason))")
            defer {
                self.isPrimingPredictionData = false
                self.syncLog("[warmup] prediction data refresh complete")
            }

            await self.fetchLogsForTodaysPlayers()
            await self.recomputeBacktestAndAutoTune()
        }
    }

    /// Fetches game logs for all given player IDs, batching into chunks ≤ 100.
    /// Passes the latest locally-stored game date as `since` so the server only
    /// returns rows the phone doesn't already have.
    private func fetchBulkPlayerLogs(playerIDs: [String],
                                     season: Int,
                                     maxAge: TimeInterval) async {
        guard !playerIDs.isEmpty else { return }
        let batchSize = 100
        let batches = stride(from: 0, to: playerIDs.count, by: batchSize).map {
            Array(playerIDs[$0 ..< min($0 + batchSize, playerIDs.count)])
        }
        syncLog("[fetchBulkPlayerLogs] \(playerIDs.count) players → \(batches.count) batch(es) of ≤\(batchSize)")
        for (i, batch) in batches.enumerated() {
            await fetchBulkBatch(
                playerIDs: batch,
                season: season,
                batchIndex: i + 1,
                total: batches.count,
                maxAge: maxAge
            )
        }
    }

    /// Sends one bulk request for up to 100 player IDs and persists the results.
    /// Passes the device's latest stored game date as `start_date` so the server
    /// only returns rows the phone doesn't already have.
    private func fetchBulkBatch(playerIDs: [String], season: Int,
                                batchIndex: Int, total: Int,
                                maxAge: TimeInterval) async {
        let sinceDate = latestLocalGameDate()
        let base = serverURL.trimmingCharacters(in: .whitespaces)
        let idsJoined = playerIDs.joined(separator: ",")
            .addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        var urlStr = "\(base)\(SportConfig.playerLogsBulkEndpoint)?player_ids=\(idsJoined)&season=\(season)&days=\(Self.logFetchDays)"
        if let since = sinceDate {
            urlStr += "&start_date=\(since)"
        }
        guard let url = URL(string: urlStr) else {
            syncLog("[fetchBulkBatch \(batchIndex)/\(total)] bad URL — falling back to individual fetches")
            await fetchLogsIndividually(playerIDs: playerIDs, season: season, maxAge: maxAge)
            return
        }
        syncLog("[fetchBulkBatch \(batchIndex)/\(total)] GET \(playerIDs.count) players")
        do {
            let data = try await fetchDataWithCache(from: url,
                                                    maxAge: maxAge,
                                                    tag: "player_logs_bulk_\(batchIndex)")
            if let decoded = try? JSONDecoder().decode(RawBulkLogsResponse.self, from: data),
               let byPlayer = decoded.logs_by_player {
                var totalRows = 0
                for (pid, rawLogs) in byPlayer {
                    persistLogs(rawLogs, defaultPlayerID: pid, defaultSeason: season)
                    totalRows += rawLogs.count
                }
                syncLog("[fetchBulkBatch \(batchIndex)/\(total)] persisted \(totalRows) rows across \(byPlayer.count) players")
            } else {
                syncLog("[fetchBulkBatch \(batchIndex)/\(total)] decode failed — falling back to individual fetches")
                await fetchLogsIndividually(playerIDs: playerIDs, season: season, maxAge: maxAge)
            }
        } catch {
            syncLog("[fetchBulkBatch \(batchIndex)/\(total)] error: \(error.localizedDescription) — falling back to individual fetches")
            await fetchLogsIndividually(playerIDs: playerIDs, season: season, maxAge: maxAge)
        }
    }

    /// Throttled individual fallback: max 4 concurrent requests.
    private func fetchLogsIndividually(playerIDs: [String],
                                       season: Int,
                                       maxAge: TimeInterval) async {
        syncLog("[fetchLogsIndividually] fetching \(playerIDs.count) players (max 4 concurrent)")
        await withTaskGroup(of: Void.self) { group in
            var active = 0
            for pid in playerIDs {
                if active >= 4 {
                    await group.next()
                    active -= 1
                }
                group.addTask { await self.silentFetchLogs(playerID: pid, season: season, maxAge: maxAge) }
                active += 1
            }
        }
    }

    /// Concurrently fetches and persists logs for any playerIDs that have no rows in the local DB.
    /// Does not update any published state — safe to call from any view.
    func prefetchMissingLogs(playerIDs: [String]) async {
        if !SportConfig.usesServerSync {
            syncLog("[prefetch] bundle-only mode — skipping network fetch")
            return
        }

        guard serverReachable else {
            syncLog("[prefetch] skipping — server marked unreachable")
            return
        }
        let ctx = modelContext
        let missing = playerIDs.filter { pid in
            var d = FetchDescriptor<StoredGameLog>(predicate: #Predicate { $0.playerID == pid })
            d.fetchLimit = 1
            return ((try? ctx.fetch(d)) ?? []).isEmpty
        }
        guard !missing.isEmpty else { return }
        syncLog("[prefetch] fetching logs for \(missing.count) player(s) with no local data")
        await fetchBulkPlayerLogs(
            playerIDs: missing,
            season: SportConfig.currentSeason,
            maxAge: Self.playerLogRefreshInterval
        )
    }

    /// Fetches and persists player logs from the server without touching published state.
    private func silentFetchLogs(playerID: String,
                                 season: Int = SportConfig.currentSeason,
                                 maxAge: TimeInterval) async {
        let base    = serverURL.trimmingCharacters(in: .whitespaces)
        let encoded = playerID.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? playerID
        let urlStr  = "\(base)\(SportConfig.playerLogsEndpoint)?player_id=\(encoded)&season=\(season)&days=\(Self.logFetchDays)"
        guard let url = URL(string: urlStr) else {
            syncLog("[silentFetchLogs] bad URL for playerID=\(playerID)")
            return
        }
        syncLog("[silentFetchLogs] GET \(urlStr)")
        do {
            let data = try await fetchDataWithCache(from: url,
                                                    maxAge: maxAge,
                                                    tag: "player_logs_silent_\(playerID)")
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

        // Merge the latest server payload into the existing local store instead of
        // wiping everything. This preserves historically stored games and lets newer
        // rows be added or refreshed in place.
        let rawGames = schedule?.games ?? []
        let existingGames = (try? ctx.fetch(FetchDescriptor<StoredGame>())) ?? []
        let existingMissingRows = (try? ctx.fetch(FetchDescriptor<StoredMissingPlayer>())) ?? []
        let existingLineupRows = (try? ctx.fetch(FetchDescriptor<StoredLineupPlayer>())) ?? []
        // gameID is unique per *source*, but the same matchup can arrive from
        // different sources with different IDs (ESPN vs the server's
        // balldontlie fallback). Index by gameID AND natural key (date|away|home)
        // so a game coming from a new source updates the existing row instead of
        // stacking a duplicate that would render twice in the Schedule list.
        var gameByID = Dictionary(
            existingGames.map { ($0.gameID, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        var gameByNaturalKey = Dictionary(
            existingGames.map { (Self.gameNaturalKey(date: $0.date, away: $0.awayTeam, home: $0.homeTeam), $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let lineupTimeByGameID: [String: String] = Dictionary(
            uniqueKeysWithValues: (lineups?.rows ?? []).compactMap { row in
                guard let gid = row.game_id, !gid.isEmpty else { return nil }
                return (gid, row.time ?? "")
            }
        )
        // The server can return today + upcoming games. Persist all returned dates
        // so Schedule can auto-roll to the next slate after final games complete.
        let serverDate = schedule?.date.flatMap { $0.isEmpty ? nil : $0 } ?? today
        syncLog("[persist] serverDate=\(serverDate)  total raw games=\(rawGames.count)")
        for g in rawGames {
            guard let away = g.away, !away.isEmpty,
                  let home = g.home, !home.isEmpty else {
                syncLog("[persist] skipping game — missing away/home: \(g)")
                continue
            }
            let gameDate = g.date?.isEmpty == false ? g.date! : serverDate
            let gid = g.game_id ?? "\(away)_\(home)"
            syncLog("[persist] game gid=\(gid) \(away)@\(home) time=\(g.time ?? "?") status=\(g.status ?? "?")")
            let resolvedTip = resolveGameTipTime(
                tip: g.tip,
                scheduleTime: g.time,
                lineupTime: lineupTimeByGameID[gid],
                gameDateString: g.date
            )
            let naturalKey = Self.gameNaturalKey(date: gameDate, away: away, home: home)
            if let existing = gameByID[gid] ?? gameByNaturalKey[naturalKey] {
                // Keep the stored gameID so lineup/prop/missing-player rows
                // already linked to this game stay valid even when the payload
                // arrived from a different source with a different ID.
                let targetGid = existing.gameID
                existing.date = gameDate
                existing.awayTeam = away
                existing.homeTeam = home
                // Never blank out a previously-resolved tip time with a failed parse —
                // keep the last known-good value until a real one replaces it.
                if let resolvedTip {
                    existing.gameTime = resolvedTip
                }
                existing.status = g.status
                existing.syncedAt = now
                gameByID[targetGid] = nil
                gameByNaturalKey[naturalKey] = nil

                for row in existingMissingRows.filter({ $0.gameID == targetGid }) {
                    ctx.delete(row)
                }
                for mp in g.missing_away_players ?? [] {
                    ctx.insert(StoredMissingPlayer(
                        gameID: targetGid, name: mp.name, status: mp.status,
                        reason: mp.reason, isAway: true, syncedAt: now))
                }
                for mp in g.missing_home_players ?? [] {
                    ctx.insert(StoredMissingPlayer(
                        gameID: targetGid, name: mp.name, status: mp.status,
                        reason: mp.reason, isAway: false, syncedAt: now))
                }
            } else {
                ctx.insert(StoredGame(
                    gameID: gid, date: gameDate,
                    awayTeam: away, homeTeam: home,
                    gameTime: resolvedTip, status: g.status, syncedAt: now
                ))
                gameByID[gid] = nil
                gameByNaturalKey[naturalKey] = nil

                for row in existingMissingRows.filter({ $0.gameID == gid }) {
                    ctx.delete(row)
                }
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
        }

        // The server is authoritative for any date it returned games for — a
        // stored game on one of those dates that wasn't touched above (rescheduled,
        // pulled from the feed, corrected to a different date) is stale and would
        // otherwise sit alongside the real slate forever, inflating that day's
        // game count on both the Schedule and Plays tabs.
        let syncedDates = Set(rawGames.map { $0.date?.isEmpty == false ? $0.date! : serverDate })
        let staleForSyncedDates = gameByID.values.filter { syncedDates.contains($0.date) }
        if !staleForSyncedDates.isEmpty {
            let staleIDs = Set(staleForSyncedDates.map(\.gameID))
            for row in existingMissingRows where staleIDs.contains(row.gameID) {
                ctx.delete(row)
            }
            for row in existingLineupRows where staleIDs.contains(row.gameID) {
                ctx.delete(row)
            }
            let propRows = (try? ctx.fetch(FetchDescriptor<StoredProp>())) ?? []
            for row in propRows {
                guard let pgid = row.gameID, staleIDs.contains(pgid) else { continue }
                ctx.delete(row)
            }
            let detailRows = (try? ctx.fetch(FetchDescriptor<StoredGameDetails>())) ?? []
            for row in detailRows where staleIDs.contains(row.gameID) {
                ctx.delete(row)
            }
            for row in staleForSyncedDates { ctx.delete(row) }
            syncLog("[persist] removed \(staleForSyncedDates.count) stale game row(s) no longer in synced dates \(syncedDates.sorted())")
        }

        // ── Persist lineups + upsert players from lineup data ────────────────────
        let existingPlayers = (try? ctx.fetch(FetchDescriptor<StoredPlayer>())) ?? []
        var playerByID = Dictionary(uniqueKeysWithValues:
            existingPlayers.map { ($0.playerID, $0) })

        var lineupRows     = 0
        var playersUpserted = 0
        for g in lineups?.rows ?? [] {
            let gid = g.game_id ?? ""
            for row in existingLineupRows.filter({ $0.gameID == gid }) {
                ctx.delete(row)
            }
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

    private func persistStandings(_ map: [String: StandingsEntry]) {
        let ctx = modelContext
        let now = Date()
        // Replace all rows wholesale — standings change frequently
        deleteAll(StoredStandings.self, from: ctx)
        for entry in map.values {
            ctx.insert(StoredStandings(
                abbr: entry.abbr, conference: entry.conference,
                wins: entry.wins, losses: entry.losses, pct: entry.pct,
                homeRecord: entry.homeRecord, roadRecord: entry.roadRecord,
                lastTen: entry.lastTen, streak: entry.streak,
                pointsPG: entry.pointsPG, oppPointsPG: entry.oppPointsPG,
                syncedAt: now
            ))
        }
        try? ctx.save()
        syncLog("[persist] stored \(map.count) standings rows")
    }

    private func deriveStandingsFromLocalLogs(lookbackGames: Int = 12) -> [String: StandingsEntry] {
        let ctx = modelContext
        let cutoff = Self.isoDateString(Calendar.current.date(byAdding: .day, value: -140, to: Date()) ?? Date())
        let desc = FetchDescriptor<StoredGameLog>(
            predicate: #Predicate { $0.gameDate >= cutoff }
        )
        let rows = (try? ctx.fetch(desc)) ?? []
        guard !rows.isEmpty else { return [:] }

        struct TeamGameKey: Hashable {
            let team: String
            let date: String
            let opponent: String
        }
        struct TeamGameSample {
            let date: String
            let opponent: String
            let points: Double
        }

        var grouped: [TeamGameKey: [StoredGameLog]] = [:]
        for row in rows {
            let team = (row.team ?? "").uppercased()
            let opp = (row.opponent ?? "").uppercased()
            guard !team.isEmpty, !opp.isEmpty else { continue }
            let key = TeamGameKey(team: team, date: row.gameDate, opponent: opp)
            grouped[key, default: []].append(row)
        }
        guard !grouped.isEmpty else { return [:] }

        var samplesByTeam: [String: [TeamGameSample]] = [:]
        for (key, gameRows) in grouped {
            let topRotation = gameRows
                .sorted { ($0.minutesSeconds ?? 0) > ($1.minutesSeconds ?? 0) }
                .prefix(10)
            let points = topRotation.reduce(0.0) { $0 + max(0, $1.pts ?? 0) }
            guard points >= 45 else { continue }
            samplesByTeam[key.team, default: []].append(
                TeamGameSample(date: key.date, opponent: key.opponent, points: points)
            )
        }

        // Fast lookup for reverse (opponent) team points in same game.
        var scoreByGameKey: [TeamGameKey: Double] = [:]
        for (team, samples) in samplesByTeam {
            for s in samples {
                scoreByGameKey[TeamGameKey(team: team, date: s.date, opponent: s.opponent)] = s.points
            }
        }

        var out: [String: StandingsEntry] = [:]
        for (team, samples) in samplesByTeam {
            let recent = samples.sorted { $0.date > $1.date }.prefix(lookbackGames)
            guard !recent.isEmpty else { continue }

            var ptsForVals: [Double] = []
            var ptsAllowedVals: [Double] = []
            var wins = 0
            var losses = 0
            var streakResults: [Bool] = []

            for s in recent {
                ptsForVals.append(s.points)
                let reverseKey = TeamGameKey(team: s.opponent, date: s.date, opponent: team)
                if let oppPts = scoreByGameKey[reverseKey] {
                    ptsAllowedVals.append(oppPts)
                    let won = s.points > oppPts
                    if won { wins += 1 } else { losses += 1 }
                    streakResults.append(won)
                }
            }

            let ppg = ptsForVals.reduce(0, +) / Double(ptsForVals.count)
            let oppPpg = ptsAllowedVals.isEmpty
                ? 84.0
                : (ptsAllowedVals.reduce(0, +) / Double(ptsAllowedVals.count))
            let games = max(1, wins + losses)
            let pct = Double(wins) / Double(games)
            let streak = formatStreak(streakResults)

            out[team] = StandingsEntry(
                abbr: team,
                conference: "",
                wins: wins,
                losses: losses,
                pct: pct,
                homeRecord: "0-0",
                roadRecord: "0-0",
                lastTen: "\(wins)-\(losses)",
                streak: streak,
                pointsPG: ppg,
                oppPointsPG: oppPpg
            )
        }
        return out
    }

    private func formatStreak(_ resultsNewestToOldest: [Bool]) -> String {
        guard let first = resultsNewestToOldest.first else { return "-" }
        var count = 0
        for r in resultsNewestToOldest {
            if r == first {
                count += 1
            } else {
                break
            }
        }
        return first ? "W\(max(1, count))" : "L\(max(1, count))"
    }

    private func persistGameDetails(_ map: [String: GameDetails]) {
        let ctx = modelContext
        let now = Date()
        // Load existing rows by gameID to upsert
        let existing = (try? ctx.fetch(FetchDescriptor<StoredGameDetails>())) ?? []
        var byID = Dictionary(uniqueKeysWithValues: existing.map { ($0.gameID, $0) })
        for (gid, d) in map {
            if let row = byID[gid] {
                row.gameType         = d.gameType
                row.seriesGameNumber = d.seriesGameNumber
                row.gameLabel        = d.gameLabel
                row.homeScore        = d.homeScore
                row.awayScore        = d.awayScore
                row.period           = d.period
                row.statusCode       = d.statusCode
                row.homeWins         = d.homeWins
                row.awayWins         = d.awayWins
                row.syncedAt         = now
            } else {
                let row = StoredGameDetails(
                    gameID: gid, gameType: d.gameType,
                    seriesGameNumber: d.seriesGameNumber, gameLabel: d.gameLabel,
                    homeScore: d.homeScore, awayScore: d.awayScore,
                    period: d.period, statusCode: d.statusCode,
                    homeWins: d.homeWins, awayWins: d.awayWins, syncedAt: now
                )
                ctx.insert(row)
                byID[gid] = row
            }
        }
        // Remove any stale gameIDs no longer in this sync's data
        for (gid, row) in byID where map[gid] == nil {
            ctx.delete(row)
        }
        try? ctx.save()
        syncLog("[persist] stored \(map.count) gameDetails rows")
    }

    private func updateGameDetails(from schedule: RawScheduleResponse?) {
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
        persistGameDetails(newGameDetails)
        syncLog("[fetchAll] gameDetails populated — \(newGameDetails.count) games")
    }

    private func mergeStatsAndRoster(stats: RawStatsResponse?, roster: RawStatsResponse?) -> RawStatsResponse? {
        var all = stats?.players ?? []
        let rosterPlayers = roster?.players ?? []
        if !rosterPlayers.isEmpty {
            let existingIDs = Set(all.compactMap { $0.player_id })
            for player in rosterPlayers {
                if let id = player.player_id, existingIDs.contains(id) {
                    all.removeAll { $0.player_id == id }
                }
                all.append(player)
            }
        }
        return all.isEmpty ? nil : RawStatsResponse(players: all)
    }

    private func hasAnyBundledData() -> Bool {
        var logDesc = FetchDescriptor<StoredGameLog>()
        logDesc.fetchLimit = 1
        if let oneLog = try? modelContext.fetch(logDesc), !oneLog.isEmpty {
            return true
        }
        var gameDesc = FetchDescriptor<StoredGame>()
        gameDesc.fetchLimit = 1
        if let oneGame = try? modelContext.fetch(gameDesc), !oneGame.isEmpty {
            return true
        }
        return false
    }

    private func hasAnyLocalLogs() -> Bool {
        var logDesc = FetchDescriptor<StoredGameLog>()
        logDesc.fetchLimit = 1
        return ((try? modelContext.fetch(logDesc)) ?? []).isEmpty == false
    }

    private func hasAnyStoredGames() -> Bool {
        var gameDesc = FetchDescriptor<StoredGame>()
        gameDesc.fetchLimit = 1
        return ((try? modelContext.fetch(gameDesc)) ?? []).isEmpty == false
    }

    private func refreshBundledScheduleRowsOnly() {
        let ctx = modelContext
        deleteAll(StoredGame.self, from: ctx)
        deleteAll(StoredMissingPlayer.self, from: ctx)
        deleteAll(StoredLineupPlayer.self, from: ctx)
        deleteAll(StoredProp.self, from: ctx)
        deleteAll(StoredGameDetails.self, from: ctx)
        deleteAll(StoredStandings.self, from: ctx)
        try? ctx.save()
    }

    private func resetBundleManagedTables(resetPlayers: Bool, resetGames: Bool) {
        let ctx = modelContext
        if resetGames {
            deleteAll(StoredGame.self, from: ctx)
            deleteAll(StoredMissingPlayer.self, from: ctx)
            deleteAll(StoredLineupPlayer.self, from: ctx)
            deleteAll(StoredProp.self, from: ctx)
            deleteAll(StoredGameDetails.self, from: ctx)
            deleteAll(StoredStandings.self, from: ctx)
        }
        if resetPlayers {
            deleteAll(StoredPlayer.self, from: ctx)
        }
        deleteAll(StoredGameLog.self, from: ctx)
        try? ctx.save()
    }

    private func persistBundledPlayers(_ players: [RawStatPlayer]) {
        let ctx = modelContext
        let now = Date()
        var upserted = 0
        for raw in players {
            guard let pid = raw.player_id, !pid.isEmpty,
                  let name = raw.name, !name.isEmpty else { continue }
            ctx.insert(StoredPlayer(
                playerID: pid,
                name: name,
                team: raw.team,
                position: raw.pos,
                syncedAt: now
            ))
            upserted += 1
        }
        try? ctx.save()
        syncLog("[bundleImport] stored \(upserted) bundled players")
    }

    private func persistDerivedPlayersFromLogs(_ logs: [RawGameLog]) {
        let ctx = modelContext
        let now = Date()
        let existingIDs = Set(((try? ctx.fetch(FetchDescriptor<StoredPlayer>())) ?? []).map(\.playerID))
        var byID: [String: String] = [:]
        for log in logs {
            guard let pid = log.player_id, !pid.isEmpty else { continue }
            if existingIDs.contains(pid) { continue }
            if byID[pid] == nil {
                byID[pid] = log.team ?? ""
            }
        }
        guard !byID.isEmpty else { return }

        var inserted = 0
        for pid in byID.keys.sorted() {
            let team = byID[pid]
            let fallbackName: String = {
                if let team, !team.isEmpty {
                    return "\(team) Player"
                }
                return "Unknown Player"
            }()
            ctx.insert(StoredPlayer(
                playerID: pid,
                name: fallbackName,
                team: team,
                position: nil,
                syncedAt: now
            ))
            inserted += 1
        }
        try? ctx.save()
        syncLog("[bundleImport] derived \(inserted) players from logs (name fallback = player_id)")
    }

    private func persistBundledGames(_ games: [RawGame], fallbackDate: String?) {
        let ctx = modelContext
        let now = Date()
        let today = Self.isoDateString(Date())
        let preferredDate = fallbackDate ?? today
        let cal = Calendar(identifier: .gregorian)
        let earliestKeptDate = Self.isoDateString(
            cal.date(byAdding: .day, value: -Self.schedulePastRetentionDays, to: now) ?? now
        )
        let latestKeptDate = Self.isoDateString(
            cal.date(byAdding: .day, value: Self.scheduleFutureRetentionDays, to: now) ?? now
        )
        let existingGames = (try? ctx.fetch(FetchDescriptor<StoredGame>())) ?? []
        let existingByGid = Dictionary(
            existingGames.map { ($0.gameID, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let existingByNaturalKey = Dictionary(
            existingGames.map { (Self.gameNaturalKey(date: $0.date, away: $0.awayTeam, home: $0.homeTeam), $0) },
            uniquingKeysWith: { first, _ in first }
        )

        var inserted = 0
        var updated = 0

        for raw in games {
            guard let away = raw.away, !away.isEmpty,
                  let home = raw.home, !home.isEmpty else { continue }

            let gameDate = raw.date?.isEmpty == false ? raw.date! : preferredDate
            guard !(gameDate < earliestKeptDate || gameDate > latestKeptDate) else { continue }

            let gid = raw.game_id ?? "\(away)_\(home)_\(gameDate)"
            let naturalKey = Self.gameNaturalKey(date: gameDate, away: away, home: home)
            let resolvedTip = resolveGameTipTime(
                tip: raw.tip,
                scheduleTime: raw.time,
                lineupTime: nil,
                gameDateString: gameDate
            )

            // Upsert: match on gameID or the date+matchup natural key so a
            // bundled refresh updates existing rows instead of stacking
            // duplicates beneath server-synced rows.
            if let existing = existingByGid[gid] ?? existingByNaturalKey[naturalKey] {
                existing.date = gameDate
                existing.awayTeam = away
                existing.homeTeam = home
                if let resolvedTip { existing.gameTime = resolvedTip }
                existing.status = raw.status ?? existing.status
                existing.syncedAt = now
                updated += 1
            } else {
                ctx.insert(StoredGame(
                    gameID: gid,
                    date: gameDate,
                    awayTeam: away,
                    homeTeam: home,
                    gameTime: resolvedTip,
                    status: raw.status ?? "Scheduled",
                    syncedAt: now
                ))
                inserted += 1
            }
        }

        try? ctx.save()
        syncLog("[bundleImport] bundled games: \(inserted) inserted, \(updated) updated in place")
    }

    private func updateBundledDataVersionMetadata(file: BundleLogsFile, logs: [RawGameLog]) {
        let latestDate = logs.compactMap { $0.game_date }.max() ?? ""
        let generatedAt = file.generated_at ?? ""
        let sourceSummary: String = {
            let source = file.source_status
            let espnRows = source?.espn_rows ?? 0
            let statsRows = source?.stats_wnba_rows ?? 0
            let carriedRows = source?.carried_existing_rows ?? 0
            if espnRows > 0 { return "ESPN (\(espnRows) rows)" }
            if statsRows > 0 { return "stats feed (\(statsRows) rows)" }
            if carriedRows > 0 { return "Carried existing data (\(carriedRows) rows)" }
            return "Unknown"
        }()

        bundledDataGeneratedAt = generatedAt
        bundledDataLatestGameDate = latestDate
        bundledDataSourceSummary = sourceSummary

        UserDefaults.standard.set(generatedAt, forKey: Self.bundleGeneratedAtKey)
        UserDefaults.standard.set(latestDate, forKey: Self.bundleLatestDateKey)
        UserDefaults.standard.set(sourceSummary, forKey: Self.bundleSourceSummaryKey)
    }

    private func loadBundledDataVersionFromDefaults() {
        bundledDataGeneratedAt = UserDefaults.standard.string(forKey: Self.bundleGeneratedAtKey) ?? ""
        bundledDataLatestGameDate = UserDefaults.standard.string(forKey: Self.bundleLatestDateKey) ?? ""
        bundledDataSourceSummary = UserDefaults.standard.string(forKey: Self.bundleSourceSummaryKey) ?? ""
    }

    private func shouldRunNameHydration() -> Bool {
        guard let last = UserDefaults.standard.object(forKey: Self.lastNameHydrationAtKey) as? Date else {
            return true
        }
        return Date().timeIntervalSince(last) >= 12 * 60 * 60
    }

    private func isPlaceholderPlayerName(_ value: String, playerID: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return true }
        if trimmed == "Unknown Player" { return true }
        if trimmed.hasSuffix(" Player") { return true }
        return isLikelyNumericID(trimmed, matching: playerID)
    }

    private func fetchDisplayNameFromESPNCore(playerID: String) async -> String? {
        guard let url = URL(string: "https://sports.core.api.espn.com/v2/sports/basketball/leagues/nba/athletes/\(playerID)") else {
            return nil
        }
        do {
            let (data, response) = try await session.data(from: url)
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode),
                  let root = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { return nil }

            if let display = root["displayName"] as? String,
               !display.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return display
            }
            if let full = root["fullName"] as? String,
               !full.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return full
            }
            return nil
        } catch {
            return nil
        }
    }

    /// One-shot bulk ID→name map for every NBA player, sourced from NBA Stats'
    /// public `commonallplayers` endpoint. Bundled player IDs are NBA.com
    /// person IDs, which ESPN's athlete API does not recognize — this endpoint
    /// is the canonical source for that ID space. Requires browser-like
    /// headers; default fingerprints get stalled by its CDN.
    private func fetchNBAPlayerNameMap() async -> [String: String] {
        // Season label uses the calendar year the season *ends* ("2025-26").
        let seasonLabel = "\(SportConfig.currentSeason - 1)-\(String(SportConfig.currentSeason).suffix(2))"
        guard let url = URL(string:
            "https://stats.nba.com/stats/commonallplayers?IsOnlyCurrentSeason=0&LeagueID=00&Season=\(seasonLabel)")
        else { return [:] }

        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.4 Safari/605.1.15",
            forHTTPHeaderField: "User-Agent"
        )
        request.setValue("application/json, text/plain, */*", forHTTPHeaderField: "Accept")
        request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
        request.setValue("https://www.nba.com/", forHTTPHeaderField: "Referer")
        request.setValue("https://www.nba.com", forHTTPHeaderField: "Origin")

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode) else {
                syncLog("[nameHydration] NBA map HTTP error: \((response as? HTTPURLResponse)?.statusCode ?? -1)")
                return [:]
            }

            // Shape: {"resultSets":[{"name":"CommonAllPlayers",
            //   "headers":["PERSON_ID","DISPLAY_FIRST_LAST",…],"rowSet":[[…],…]}]}
            guard let root  = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let sets   = root["resultSets"] as? [[String: Any]]
            else { return [:] }

            var map: [String: String] = [:]
            for set in sets {
                guard let headers = set["headers"] as? [String],
                      let idIdx   = headers.firstIndex(of: "PERSON_ID"),
                      let nameIdx = headers.firstIndex(of: "DISPLAY_FIRST_LAST"),
                      let rows    = set["rowSet"] as? [[Any]]
                else { continue }
                for row in rows {
                    guard row.count > max(idIdx, nameIdx),
                          let pidNum = row[idIdx] as? NSNumber else { continue }
                    let name = row[nameIdx] as? String ?? ""
                    if !name.isEmpty { map[pidNum.stringValue] = name }
                }
            }
            syncLog("[nameHydration] NBA map fetched: \(map.count) players")
            return map
        } catch {
            syncLog("[nameHydration] NBA map fetch failed: \(error.localizedDescription)")
            return [:]
        }
    }

    /// Resolves placeholder names ("CLE Player", "Unknown Player", raw IDs)
    /// to real display names. Runs regardless of sync mode: bundled seed logs
    /// carry IDs without names, and until a real roster/stats sync provides
    /// canonical names this keeps Player Search usable. A later server sync
    /// overwrites hydrated names through its normal upserts.
    ///
    /// Returns true when any stored player names were updated.
    @discardableResult
    private func hydratePlaceholderPlayerNamesIfNeeded() async -> Bool {
        guard shouldRunNameHydration() else { return false }

        let ctx = modelContext
        let allPlayers = (try? ctx.fetch(FetchDescriptor<StoredPlayer>())) ?? []
        let unresolvedIDs = Set(allPlayers
            .filter { isPlaceholderPlayerName($0.name, playerID: $0.playerID) }
            .map(\.playerID))
        guard !unresolvedIDs.isEmpty else {
            UserDefaults.standard.set(Date(), forKey: Self.lastNameHydrationAtKey)
            return false
        }

        let maxResolve = min(120, unresolvedIDs.count)
        syncLog("[nameHydration] resolving names for \(maxResolve)/\(unresolvedIDs.count) players")
        var updates: [String: String] = [:]

        // Pass 1: single bulk request covering the whole league — cheapest way
        // to resolve most/all of the bundled NBA.com-style IDs at once.
        let nbaMap = await fetchNBAPlayerNameMap()
        for pid in unresolvedIDs where updates.count < maxResolve {
            if let name = nbaMap[pid] { updates[pid] = name }
        }

        // Pass 2: ESPN core athlete API for whatever is left (only useful when
        // player IDs happen to be ESPN IDs, e.g. bundles sourced from ESPN).
        let stillMissing = unresolvedIDs.subtracting(updates.keys).sorted()
        for pid in stillMissing.prefix(maxResolve) {
            if let resolved = await fetchDisplayNameFromESPNCore(playerID: pid) {
                updates[pid] = resolved
            }
        }

        guard !updates.isEmpty else {
            // Do NOT stamp the throttle timer on total failure — an offline
            // first launch should retry on the next launch rather than wait
            // out the 12-hour window with placeholder names showing.
            syncLog("[nameHydration] no name updates found — will retry next sync")
            return false
        }

        for player in allPlayers {
            guard let newName = updates[player.playerID] else { continue }
            player.name = newName
            player.syncedAt = Date()
        }
        try? ctx.save()
        syncLog("[nameHydration] updated \(updates.count) player names")
        UserDefaults.standard.set(Date(), forKey: Self.lastNameHydrationAtKey)
        return true
    }

    private func publishSnapshotFromDatabase(fetchedAt: Date) -> DataSnapshot {
        let allStoredGames = (try? modelContext.fetch(FetchDescriptor<StoredGame>())) ?? []
        let activeDate = activeScheduleDate(from: allStoredGames)
        let games = allStoredGames.filter { $0.date == activeDate }
        let storedProps = (try? modelContext.fetch(FetchDescriptor<StoredProp>())) ?? []
        let storedPlayers = (try? modelContext.fetch(FetchDescriptor<StoredPlayer>())) ?? []
        let missing = (try? modelContext.fetch(FetchDescriptor<StoredMissingPlayer>())) ?? []
        let lineupRows = (try? modelContext.fetch(FetchDescriptor<StoredLineupPlayer>())) ?? []

        syncLog("[fetchAll] DB snapshot — activeDate: \(activeDate ?? "none") games: \(games.count)  players: \(storedPlayers.count)")

        let built = assembleSnapshot(
            games: games, storedProps: storedProps,
            players: storedPlayers, missing: missing,
            lineups: lineupRows, fetchedAt: fetchedAt
        )
        snapshot = built
        lastFetchDate = fetchedAt
        return built
    }

    private func applySupplementalSync(
        schedule: RawScheduleResponse?,
        lineupsURL: URL,
        statsURL: URL,
        rosterURL: URL,
        standingsURL: URL,
        teamAdvURL: URL,
        posSplitURL: URL
    ) async {
        async let lineupsTask  = fetchDataWithCache(from: lineupsURL, maxAge: 10 * 60, tag: "lineups")
        async let statsTask    = fetchDataWithCache(from: statsURL, maxAge: 6 * 60 * 60, tag: "stats")
        async let rosterTask   = fetchDataWithCache(from: rosterURL, maxAge: 6 * 60 * 60, tag: "roster")
        async let standTask    = fetchDataWithCache(from: standingsURL, maxAge: 20 * 60, tag: "standings")
        async let teamAdvTask  = fetchDataWithCache(from: teamAdvURL, maxAge: 30 * 60, tag: "team_advanced")
        async let posSplitTask = fetchDataWithCache(from: posSplitURL, maxAge: 30 * 60, tag: "team_position_splits")

        let lData        = try? await lineupsTask
        let stData       = try? await statsTask
        let roData       = try? await rosterTask
        let stndData     = try? await standTask
        let teamAdvData  = try? await teamAdvTask
        let posSplitData = try? await posSplitTask

        let decoder = JSONDecoder()
        var decodeErrors: [String] = []
        let lineups = lData.flatMap {
            decode(RawLineupsResponse.self, from: $0, tag: "lineups", errors: &decodeErrors, decoder: decoder)
        }
        let stats = stData.flatMap {
            decode(RawStatsResponse.self, from: $0, tag: "stats", errors: &decodeErrors, decoder: decoder)
        }
        let roster = roData.flatMap {
            decode(RawStatsResponse.self, from: $0, tag: "roster", errors: &decodeErrors, decoder: decoder)
        }

        lastLineupsRawJSON = lData.flatMap { String(data: $0, encoding: .utf8) } ?? "(no data)"
        syncLog("[supplemental] lineups: \(lData?.count ?? 0) bytes  stats: \(stData?.count ?? 0) bytes  roster: \(roData?.count ?? 0) bytes")

        if let stndData,
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
            persistStandings(map)
            syncLog("[supplemental] standingsMap populated — \(map.count) teams")
        }

        if let teamAdvData,
           let rawTeamAdv = try? JSONDecoder().decode(RawTeamAdvancedResponse.self, from: teamAdvData) {
            var map: [String: TeamAdvancedEntry] = [:]
            for t in rawTeamAdv.teams ?? [] {
                guard let abbr = t.team_abbreviation, !abbr.isEmpty else { continue }
                map[abbr] = TeamAdvancedEntry(
                    abbr: abbr,
                    pace: t.pace,
                    offRating: t.off_rating,
                    defRating: t.def_rating,
                    netRating: t.net_rating,
                    tsPct: t.ts_pct,
                    efgPct: t.efg_pct,
                    tovPct: t.tov_pct,
                    rebPct: t.reb_pct,
                    astRatio: t.ast_ratio
                )
            }
            teamAdvancedMap = map
            syncLog("[supplemental] teamAdvancedMap populated — \(map.count) teams")
        }

        if let posSplitData,
           let rawPos = try? JSONDecoder().decode(RawTeamPositionSplitsResponse.self, from: posSplitData) {
            var grouped: [String: [String: TeamPositionSplitEntry]] = [:]
            for s in rawPos.splits ?? [] {
                guard let team = s.team_abbreviation, !team.isEmpty,
                      let group = s.position_group, !group.isEmpty else { continue }
                let entry = TeamPositionSplitEntry(
                    teamAbbr: team,
                    positionGroup: group,
                    ptsAllowed: s.pts_allowed,
                    rebAllowed: s.reb_allowed,
                    astAllowed: s.ast_allowed,
                    threepmAllowed: s.threepm_allowed,
                    stlAllowed: s.stl_allowed,
                    blkAllowed: s.blk_allowed,
                    praAllowed: s.pra_allowed,
                    sampleSize: s.sample_size ?? 0
                )
                grouped[team, default: [:]][group] = entry
            }
            teamPositionSplitsMap = grouped
            syncLog("[supplemental] teamPositionSplitsMap populated — \(grouped.count) teams")
        }

        if !decodeErrors.isEmpty {
            syncLog("[supplemental] decode errors: \(decodeErrors.joined(separator: "; "))")
        }

        let mergedStats = mergeStatsAndRoster(stats: stats, roster: roster)
        persistToDatabase(schedule: schedule, lineups: lineups, stats: mergedStats)
        _ = publishSnapshotFromDatabase(fetchedAt: Date())
        syncLog("[supplemental] snapshot refreshed after supplemental sync")
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

    /// Prunes schedule rows outside a small rolling date window and drops transient
    /// rows no longer tied to any surviving game IDs.
    private func pruneOldGames() {
        let ctx   = modelContext
        let today = Self.isoDateString(Date())
        dedupeStoredGames()
        let cal = Calendar(identifier: .gregorian)
        let earliestKeptDate = Self.isoDateString(
            cal.date(byAdding: .day, value: -Self.schedulePastRetentionDays, to: Date()) ?? Date()
        )
        let latestKeptDate = Self.isoDateString(
            cal.date(byAdding: .day, value: Self.scheduleFutureRetentionDays, to: Date()) ?? Date()
        )

        // Fetch all games and filter in-memory — #Predicate with != is unreliable in SwiftData
        let allGames   = (try? ctx.fetch(FetchDescriptor<StoredGame>())) ?? []

        syncLog("[pruneOldGames] today=\(today) keep-range=\(earliestKeptDate)...\(latestKeptDate) total StoredGame rows=\(allGames.count)")
        let allDates = allGames.map { $0.date }
        syncLog("[pruneOldGames] dates in DB: \(allDates.isEmpty ? "[none]" : allDates.joined(separator: ", "))")

        let staleGames = allGames.filter { $0.date < earliestKeptDate || $0.date > latestKeptDate }
        syncLog("[pruneOldGames] stale (outside keep-range): \(staleGames.count)")
        for obj in staleGames {
            syncLog("[pruneOldGames]   deleting game date=\(obj.date) id=\(obj.gameID)")
            ctx.delete(obj)
        }

        let survivingGameIDs = Set(allGames
            .filter { !($0.date < earliestKeptDate || $0.date > latestKeptDate) }
            .map { $0.gameID }
        )

        if survivingGameIDs.isEmpty {
            deleteAll(StoredMissingPlayer.self,  from: ctx)
            deleteAll(StoredLineupPlayer.self,   from: ctx)
            deleteAll(StoredProp.self,           from: ctx)
            deleteAll(StoredGameDetails.self,    from: ctx)
        } else {
            let staleMissing = ((try? ctx.fetch(FetchDescriptor<StoredMissingPlayer>())) ?? []).filter {
                !survivingGameIDs.contains($0.gameID)
            }
            for obj in staleMissing { ctx.delete(obj) }

            let staleLineups = ((try? ctx.fetch(FetchDescriptor<StoredLineupPlayer>())) ?? []).filter {
                !survivingGameIDs.contains($0.gameID)
            }
            for obj in staleLineups { ctx.delete(obj) }

            let staleProps = ((try? ctx.fetch(FetchDescriptor<StoredProp>())) ?? []).filter { prop in
                guard let gid = prop.gameID, !gid.isEmpty else { return true }
                return !survivingGameIDs.contains(gid)
            }
            for obj in staleProps { ctx.delete(obj) }

            let staleDetails = ((try? ctx.fetch(FetchDescriptor<StoredGameDetails>())) ?? []).filter {
                !survivingGameIDs.contains($0.gameID)
            }
            for obj in staleDetails { ctx.delete(obj) }
        }

        let surviving = allGames.count - staleGames.count
        syncLog("[pruneOldGames] done — deleted \(staleGames.count) row(s), \(surviving) remain")
        try? ctx.save()

        // Rebuild the published snapshot from the now-clean database.
        loadFromDatabase()
        objectWillChange.send()
    }

    /// Stable identity for a matchup independent of the source-specific gameID
    /// (ESPN, balldontlie, and derived "AWAY_HOME" IDs all differ for the same game).
    private static func gameNaturalKey(date: String, away: String, home: String) -> String {
        "\(date)|\(away.uppercased())|\(home.uppercased())"
    }

    /// Removes StoredGame rows that describe the same matchup (same date +
    /// away + home) but came from different sources with different gameIDs.
    /// Keeps the row with the most canonical ID (ESPN's 9-digit event ID),
    /// migrates FK rows (lineups / props / details) to the survivor, and
    /// deletes the rest. Runs during pruneOldGames() so already-polluted
    /// stores are repaired on next launch.
    private func dedupeStoredGames() {
        let ctx = modelContext
        let allGames = (try? ctx.fetch(FetchDescriptor<StoredGame>())) ?? []
        guard allGames.count > 1 else { return }

        let groups = Dictionary(grouping: allGames) {
            Self.gameNaturalKey(date: $0.date, away: $0.awayTeam, home: $0.homeTeam)
        }

        /// ESPN event IDs are 9 digits (e.g. "401857148"); balldontlie IDs are
        /// smaller integers. Prefer the ESPN ID so server payloads match up.
        func idScore(_ gid: String) -> Int {
            guard gid.count == 9, gid.allSatisfy(\.isNumber) else { return 0 }
            return 1
        }

        var removedGameIDs: [String] = []
        for (_, rows) in groups where rows.count > 1 {
            let keeper = rows.sorted { a, b in
                let sa = idScore(a.gameID)
                let sb = idScore(b.gameID)
                if sa != sb { return sa > sb }
                return a.syncedAt > b.syncedAt   // tie-break: most recently synced
            }.first!
            for dupe in rows where dupe.gameID != keeper.gameID {
                removedGameIDs.append(dupe.gameID)
                ctx.delete(dupe)
            }
        }

        guard !removedGameIDs.isEmpty else { return }

        // Re-point child rows tied to the removed duplicates at the keeper.
        // Rows that can't be re-pointed (no matching keeper child) are simply
        // deleted — lineups/props/details are refreshed on every sync anyway.
        let removed = Set(removedGameIDs)
        let lineupRows  = (try? ctx.fetch(FetchDescriptor<StoredLineupPlayer>())) ?? []
        for row in lineupRows where removed.contains(row.gameID) {
            ctx.delete(row)
        }
        let missingRows = (try? ctx.fetch(FetchDescriptor<StoredMissingPlayer>())) ?? []
        for row in missingRows where removed.contains(row.gameID) {
            ctx.delete(row)
        }
        let propRows = (try? ctx.fetch(FetchDescriptor<StoredProp>())) ?? []
        for row in propRows {
            guard let gid = row.gameID, !gid.isEmpty else { continue }
            if removed.contains(gid) { ctx.delete(row) }
        }
        let detailRows = (try? ctx.fetch(FetchDescriptor<StoredGameDetails>())) ?? []
        for row in detailRows where removed.contains(row.gameID) {
            ctx.delete(row)
        }

        try? ctx.save()
        syncLog("[dedupeStoredGames] removed \(removedGameIDs.count) duplicate game row(s): \(removedGameIDs.joined(separator: ", "))")
    }

    private func activeScheduleDate(from games: [StoredGame]) -> String? {
        guard !games.isEmpty else { return nil }

        let byDate = Dictionary(grouping: games, by: \ .date)
        let sortedDates = byDate.keys.sorted()
        guard !sortedDates.isEmpty else { return nil }

        let today = Self.isoDateString(Date())
        if let todaysGames = byDate[today], !todaysGames.isEmpty {
            let allFinal = todaysGames.allSatisfy {
                isFinalGameStatus(
                    gameID: $0.gameID,
                    gameDate: $0.date,
                    gameTime: $0.gameTime,
                    statusText: $0.status
                )
            }
            if !allFinal {
                return today
            }
        }

        if let nextDate = sortedDates.first(where: { $0 > today }) {
            return nextDate
        }

        if byDate[today] != nil {
            return today
        }

        // No games today and nothing upcoming — an off day, or today's sync hasn't
        // landed yet. Show an empty slate for today instead of falling back to
        // yesterday's games, which previously surfaced stale matchups as current.
        return today
    }

    private func isFinalGameStatus(
        gameID: String,
        gameDate: String,
        gameTime: String?,
        statusText: String?
    ) -> Bool {
        if let details = gameDetails[gameID], details.statusCode == 3 {
            return true
        }
        let status = (statusText ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if status.isEmpty { return false }
        if status.contains("final") { return true }
        if status.contains("postponed") || status.contains("canceled") || status.contains("cancelled") || status.contains("ppd") {
            return true
        }
        if !SportConfig.usesServerSync && status.contains("4th") {
            return true
        }
        if status.contains("q") || status.contains("half") || status.contains("ot") || status.contains("-") || status.contains("live") {
            if shouldTreatStaleLiveGameAsFinal(gameDate: gameDate, gameTime: gameTime) {
                return true
            }
        }
        return false
    }

    private func shouldTreatStaleLiveGameAsFinal(gameDate: String, gameTime: String?) -> Bool {
        guard !SportConfig.usesServerSync else { return false }
        guard let gameStart = dateFromGameDateAndTime(gameDate: gameDate, gameTime: gameTime) else {
            return false
        }
        // NBA games almost always finish well inside this window.
        let rolloverGrace: TimeInterval = 4.5 * 60 * 60
        return Date().timeIntervalSince(gameStart) >= rolloverGrace
    }

    private func dateFromGameDateAndTime(gameDate: String, gameTime: String?) -> Date? {
        guard let gameTime, !gameTime.isEmpty else { return nil }

        let tz = TimeZone(identifier: SportConfig.appTimeZoneID) ?? .current
        let cal = Calendar(identifier: .gregorian)
        let parts = gameDate.split(separator: "-")
        guard parts.count == 3,
              let y = Int(parts[0]),
              let m = Int(parts[1]),
              let d = Int(parts[2]) else {
            return nil
        }

        let cleanedTime = gameTime
            .replacingOccurrences(of: " M", with: "M")
            .replacingOccurrences(of: "MT", with: "MST")
            .replacingOccurrences(of: "PT", with: "PDT")
            .replacingOccurrences(of: "ET", with: "EDT")
            .replacingOccurrences(of: "CT", with: "CDT")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let parser = DateFormatter()
        parser.locale = Locale(identifier: "en_US_POSIX")
        parser.timeZone = tz

        var parsedTime: Date? = nil
        for format in ["h:mm a zzz", "h:mm a"] {
            parser.dateFormat = format
            if let value = parser.date(from: cleanedTime) {
                parsedTime = value
                break
            }
        }

        guard let parsedTime else { return nil }
        let timeParts = cal.dateComponents(in: tz, from: parsedTime)
        var comps = DateComponents()
        comps.year = y
        comps.month = m
        comps.day = d
        comps.hour = timeParts.hour
        comps.minute = timeParts.minute
        comps.second = 0
        comps.timeZone = tz
        return cal.date(from: comps)
    }

    /// Public: nuke ALL schedule-related rows from the DB, then immediately re-sync from the server.
    /// Use this to recover from data inconsistencies (stale dates, bad rows, etc.).
    func clearAllGames() async {
        clearResponseCache()
        snapshot = nil
        syncLog("[clearAllGames] invalidated cache and snapshot — preserving local rows")
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
        deleteAll(StoredGameDetails.self,   from: ctx)
        deleteAll(StoredStandings.self,     from: ctx)
        try? ctx.save()
        clearResponseCache()
        logMemoryCache.removeAll()
        snapshot = nil
        gameDetails = [:]
        standingsMap = [:]
        syncLog("[nuclearReset] DB cleared — starting full sync")
        _ = try? await fetchAll(fetchLogs: true)
        syncLog("[nuclearReset] complete")
    }

    /// Public: wipe today's schedule from the local store and trigger a live sync.
    /// Called from the UI when the user wants a hard refresh.
    func clearScheduleCache() async {
        clearResponseCache()
        snapshot = nil          // clear visible list immediately
        syncLog("[clearScheduleCache] invalidated cache and snapshot — preserving local rows")
        _ = try? await fetchAll()
    }

    private static func isoDateString(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        // Keep all app-level "today" calculations aligned to the configured
        // display time zone so refresh and cache boundaries match user-facing time.
        f.timeZone = TimeZone(identifier: SportConfig.appTimeZoneID)
        return f.string(from: date)
    }

    private func persistLogs(_ rawLogs: [RawGameLog],
                             defaultPlayerID: String, defaultSeason: Int) {
        let ctx    = modelContext
        let now    = Date()
        var newRowCount = 0
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
            newRowCount += 1
        }
        try? ctx.save()
        // Invalidate the memory cache for this player so the next localLogs() call
        // re-reads the freshly written rows from SwiftData.
        logMemoryCache.removeValue(forKey: defaultPlayerID)
        if newRowCount > 0 {
            logsRevision &+= 1
        }
    }

    /// Public read of cached game logs. Checks the in-memory cache first so that
    /// returning to a previously-viewed player is instant with no SwiftData round-trip.
    func localLogs(playerID: String, season: Int = SportConfig.currentSeason) -> [GameLog] {
        if let cached = logMemoryCache[playerID], !cached.isEmpty { return cached }
        let result = loadLocalLogs(playerID: playerID, season: season)
        if !result.isEmpty { logMemoryCache[playerID] = result }
        return result
    }

    private func loadLocalLogs(playerID: String, season: Int) -> [GameLog] {
        let pid = playerID
        let cutoffStr = Self.isoDateString(
            Calendar.current.date(byAdding: .day,
                                  value: -Self.logRetentionDays, to: Date()) ?? Date()
        )
        // Filter by date only — intentionally omit season so 2025 seed data
        // is visible and feeds the prediction engine throughout the 2026 season.
        var desc = FetchDescriptor<StoredGameLog>(
            predicate: #Predicate { $0.playerID == pid && $0.gameDate >= cutoffStr },
            sortBy: [SortDescriptor(\.gameDate, order: .reverse)]
        )
        desc.fetchLimit = Self.logRetentionDays   // at most one game per day
        return ((try? modelContext.fetch(desc)) ?? []).map { $0.toGameLog() }
    }

    private func shouldRunFullSync() -> Bool {
        guard let lastSync = UserDefaults.standard.object(forKey: Self.lastFullSyncAtKey) as? Date else {
            return true
        }
        return Date().timeIntervalSince(lastSync) >= Self.fullSyncMinInterval
    }

    private func shouldRefreshPlayerLogs(playerID: String, maxAge: TimeInterval) -> Bool {
        let pid = playerID
        var desc = FetchDescriptor<StoredGameLog>(
            predicate: #Predicate { $0.playerID == pid },
            sortBy: [SortDescriptor(\.syncedAt, order: .reverse)]
        )
        desc.fetchLimit = 1
        guard let newest = (try? modelContext.fetch(desc))?.first?.syncedAt else {
            return true
        }
        return Date().timeIntervalSince(newest) >= maxAge
    }

    /// Rolling walk-forward backtest over local logs, then pushes global stat
    /// bias multipliers into the prediction engine.
    private func recomputeBacktestAndAutoTune() async {
        let players = (try? modelContext.fetch(FetchDescriptor<StoredPlayer>())) ?? []
        guard !players.isEmpty else { return }

        let statKeys = ["PTS", "REB", "AST", "3PM", "FTM", "STL", "BLK"]
        struct Agg {
            var ratioWeightedSum: Double = 0
            var apeWeightedSum: Double = 0
            var sumW: Double = 0
            var count: Int = 0
        }
        var aggByStat = Dictionary(uniqueKeysWithValues: statKeys.map { ($0, Agg()) })

        let samplePlayers = Array(players.prefix(120))
        for sp in samplePlayers {
            let logs = localLogs(playerID: sp.playerID)
            guard logs.count >= 14 else { continue }
            let windows = min(10, logs.count - 8)
            guard windows > 0 else { continue }

            for idx in 0..<windows {
                let target = logs[idx]
                let history = Array(logs[(idx + 1)...].prefix(10))
                guard history.count >= 6 else { continue }

                for stat in statKeys {
                    let histVals = history.map { $0.value(for: stat) }.filter { $0 >= 0 }
                    guard histVals.count >= 4 else { continue }
                    let pred = recencyWeightedAverage(histVals)
                    guard pred > 0 else { continue }

                    let actual = target.value(for: stat)
                    let ratio = actual / pred
                    let ape = abs(actual - pred) / max(1.0, pred)
                    let w = exp(-Double(idx) * 0.30)

                    var agg = aggByStat[stat] ?? Agg()
                    agg.ratioWeightedSum += ratio * w
                    agg.apeWeightedSum += ape * w
                    agg.sumW += w
                    agg.count += 1
                    aggByStat[stat] = agg
                }
            }
        }

        var tuning: [String: Double] = [:]
        var biasMap: [String: Double] = [:]
        var maeMap: [String: Double] = [:]
        var totalSamples = 0

        for stat in statKeys {
            guard let agg = aggByStat[stat], agg.sumW > 0, agg.count >= 20 else { continue }
            let rawBias = agg.ratioWeightedSum / agg.sumW
            let rawMAE = agg.apeWeightedSum / agg.sumW
            let strength = min(1.0, Double(agg.count) / 120.0)
            let shrunk = 1.0 + ((rawBias - 1.0) * strength * 0.9)
            let tuned = max(0.90, min(1.10, shrunk))

            tuning[stat] = tuned
            biasMap[stat] = rawBias
            maeMap[stat] = rawMAE
            totalSamples += agg.count
        }

        guard !tuning.isEmpty else { return }

        PredictionEngine.shared.updateGlobalStatTuning(tuning)
        latestBacktestSummary = BacktestSummary(
            generatedAt: Date(),
            sampleCount: totalSamples,
            statBias: biasMap,
            statMAE: maeMap
        )
        let tuneLine = tuning
            .sorted { $0.key < $1.key }
            .map { "\($0.key):\(String(format: "%.3f", $0.value))" }
            .joined(separator: ", ")
        syncLog("[backtest] samples=\(totalSamples) tuning=\(tuneLine)")
    }

    private func recencyWeightedAverage(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        var sumW = 0.0
        var sum = 0.0
        for (idx, v) in values.enumerated() {
            let w = exp(-Double(idx) * 0.08)
            sumW += w
            sum += v * w
        }
        return sumW > 0 ? (sum / sumW) : 0
    }

    private func fetchScheduleData(serverURL: URL) async throws -> Data {
        do {
            let serverData = try await fetchDataWithCache(from: serverURL, maxAge: 60, tag: "schedule")
            let serverGameCount = scheduleGameCount(in: serverData)
            if serverGameCount > 0 {
                return serverData
            }

            syncLog("[schedule-fallback] server schedule contained 0 games — trying ESPN directly")
            let fallbackData = try await fetchESPNFallbackScheduleData()
            let fallbackGameCount = scheduleGameCount(in: fallbackData)
            if fallbackGameCount > 0 {
                saveCachedPayload(fallbackData, for: serverURL)
                syncLog("[schedule-fallback] ESPN provided \(fallbackGameCount) games")
                return fallbackData
            }

            return serverData
        } catch {
            syncLog("[schedule-fallback] server schedule failed: \(error.localizedDescription) — trying ESPN directly")
            let data = try await fetchESPNFallbackScheduleData()
            saveCachedPayload(data, for: serverURL)
            return data
        }
    }

    private func scheduleGameCount(in data: Data) -> Int {
        guard let decoded = try? JSONDecoder().decode(RawScheduleResponse.self, from: data) else {
            return 0
        }
        return decoded.games?.count ?? 0
    }

    private func fetchESPNFallbackScheduleData() async throws -> Data {
        let date = Self.isoDateString(Date())
        let dateToken = date.replacingOccurrences(of: "-", with: "")
        guard let url = URL(string: "https://site.api.espn.com/apis/site/v2/sports/basketball/nba/scoreboard?dates=\(dateToken)") else {
            throw URLError(.badURL)
        }

        let (data, response) = try await session.data(from: url)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw URLError(.badServerResponse)
        }

        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw URLError(.cannotParseResponse)
        }

        let events = root["events"] as? [[String: Any]] ?? []
        var games: [[String: Any]] = []

        for event in events {
            guard let competitions = event["competitions"] as? [[String: Any]],
                  let comp = competitions.first,
                  let competitors = comp["competitors"] as? [[String: Any]],
                  let home = competitors.first(where: { ($0["homeAway"] as? String) == "home" }),
                  let away = competitors.first(where: { ($0["homeAway"] as? String) == "away" }),
                  let homeTeam = home["team"] as? [String: Any],
                  let awayTeam = away["team"] as? [String: Any]
            else { continue }

            let statusType = ((comp["status"] as? [String: Any])?["type"] as? [String: Any]) ?? [:]
            let state = statusType["state"] as? String ?? "pre"
            let statusCode = state == "in" ? 2 : (state == "post" ? 3 : 1)

            games.append([
                "game_id": espnIDString(comp["id"]) ?? espnIDString(event["id"]) ?? "",
                "date": date,
                "away": normTeamAbbreviation(awayTeam["abbreviation"] as? String ?? ""),
                "home": normTeamAbbreviation(homeTeam["abbreviation"] as? String ?? ""),
                "tip": parseESPNTip(event["date"] as? String ?? ""),
                "status": statusType["description"] as? String ?? "Scheduled",
                "game_type": "regular",
                "status_code": statusCode,
                "home_score": Int(home["score"] as? String ?? "0") ?? 0,
                "away_score": Int(away["score"] as? String ?? "0") ?? 0,
                "period": (comp["status"] as? [String: Any])?["period"] as? Int ?? 0,
                "missing_away_players": [],
                "missing_home_players": []
            ])
        }

        let payload: [String: Any] = ["date": date, "games": games]
        return try JSONSerialization.data(withJSONObject: payload)
    }

    /// ESPN IDs arrive as JSON numbers; JSONSerialization bridges them to
    /// NSNumber, so `as? String` always fails. Coerce to a canonical string.
    private func espnIDString(_ value: Any?) -> String? {
        if let s = value as? String, !s.isEmpty { return s }
        if let n = value as? NSNumber { return n.stringValue }
        if let i = value as? Int { return String(i) }
        return nil
    }

    private func parseESPNTip(_ eventDateString: String) -> String {
        guard !eventDateString.isEmpty else { return "" }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = iso.date(from: eventDateString) {
            return formatDisplayTip(from: date)
        }
        iso.formatOptions = [.withInternetDateTime]
        if let date = iso.date(from: eventDateString) {
            return formatDisplayTip(from: date)
        }
        // ESPN sometimes omits seconds (e.g. "2026-08-09T16:30Z"), which the
        // strict ISO8601DateFormatter options above refuse to parse.
        let noSecondsFormatter = DateFormatter()
        noSecondsFormatter.locale = Locale(identifier: "en_US_POSIX")
        noSecondsFormatter.timeZone = TimeZone(secondsFromGMT: 0)
        noSecondsFormatter.dateFormat = "yyyy-MM-dd'T'HH:mm'Z'"
        if let date = noSecondsFormatter.date(from: eventDateString) {
            return formatDisplayTip(from: date)
        }
        return ""
    }

    private func resolveGameTipTime(
        tip: String?,
        scheduleTime: String?,
        lineupTime: String?,
        gameDateString: String?
    ) -> String? {
        let rawCandidates = [tip, scheduleTime, lineupTime]

        for raw in rawCandidates {
            guard let value = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
                continue
            }
            if isTBDTime(value) { continue }
            if let parsed = parseAnyDateStringToDisplayTip(value, gameDateString: gameDateString) {
                return parsed
            }
            return value
        }

        if let fromGameDate = parseAnyDateStringToDisplayTip(gameDateString, gameDateString: gameDateString) {
            return fromGameDate
        }

        return nil
    }

    private func isTBDTime(_ value: String) -> Bool {
        let normalized = value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return normalized == "tbd"
            || normalized == "tba"
            || normalized == "to be determined"
            || normalized == "to-be-determined"
    }

    private func parseAnyDateStringToDisplayTip(_ raw: String?, gameDateString: String?) -> String? {
        guard let raw, !raw.isEmpty else { return nil }

        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return nil }

        // Handles most API date/timestamp strings.
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = iso.date(from: trimmed) {
            return formatDisplayTip(from: date)
        }
        iso.formatOptions = [.withInternetDateTime]
        if let date = iso.date(from: trimmed) {
            return formatDisplayTip(from: date)
        }

        // Handles fallback values like "2026-08-05 19:00:00".
        let fallback = DateFormatter()
        fallback.locale = Locale(identifier: "en_US_POSIX")
        fallback.timeZone = TimeZone(secondsFromGMT: 0)
        fallback.dateFormat = "yyyy-MM-dd HH:mm:ss"
        if let date = fallback.date(from: trimmed) {
            return formatDisplayTip(from: date)
        }

        // Handles clock strings like "7:00 PM ET" by treating ET as source,
        // then converting to configured app time zone for display.
        let upper = trimmed.uppercased()
        let sourceTimeZoneID: String = {
            if upper.contains(" ET") || upper.contains(" EDT") || upper.contains(" EST") {
                return "America/New_York"
            }
            if upper.contains(" MST") || upper.contains(" MDT") {
                return SportConfig.appTimeZoneID
            }
            // Server schedule strings are typically ET when no suffix is provided.
            return "America/New_York"
        }()

        let cleanedClock = trimmed
            .replacingOccurrences(of: " ET", with: "", options: .caseInsensitive)
            .replacingOccurrences(of: " EDT", with: "", options: .caseInsensitive)
            .replacingOccurrences(of: " EST", with: "", options: .caseInsensitive)
            .replacingOccurrences(of: " MST", with: "", options: .caseInsensitive)
            .replacingOccurrences(of: " MDT", with: "", options: .caseInsensitive)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if let date = parseClockTime(cleanedClock, gameDateString: gameDateString, sourceTimeZoneID: sourceTimeZoneID) {
            return formatDisplayTip(from: date)
        }

        return nil
    }

    private func parseClockTime(_ clock: String,
                                gameDateString: String?,
                                sourceTimeZoneID: String) -> Date? {
        guard let sourceTZ = TimeZone(identifier: sourceTimeZoneID) else { return nil }

        let timeFmt = DateFormatter()
        timeFmt.locale = Locale(identifier: "en_US_POSIX")
        timeFmt.timeZone = sourceTZ
        timeFmt.dateFormat = "h:mm a"
        guard let parsedTime = timeFmt.date(from: clock) else { return nil }

        let cal = Calendar(identifier: .gregorian)
        let baseDate = parseGameDate(gameDateString) ?? Date()
        var comps = cal.dateComponents(in: sourceTZ, from: baseDate)
        let tipComps = cal.dateComponents(in: sourceTZ, from: parsedTime)
        comps.hour = tipComps.hour
        comps.minute = tipComps.minute
        comps.second = 0
        return cal.date(from: comps)
    }

    private func parseGameDate(_ str: String?) -> Date? {
        guard let str, !str.isEmpty else { return nil }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(secondsFromGMT: 0)
        f.dateFormat = "yyyy-MM-dd"
        return f.date(from: str)
    }

    private func formatDisplayTip(from date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm a '\(SportConfig.appTimeZoneLabel)'"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: SportConfig.appTimeZoneID)
        return formatter.string(from: date)
    }

    private func normTeamAbbreviation(_ value: String) -> String {
        switch value.uppercased() {
        case "LV": return "LVA"
        case "NY": return "NYL"
        case "LA": return "LAS"
        case "WAS": return "WSH"
        case "GS": return "GSV"
        case "CONN", "CONNECTICU": return "CON"
        default: return value.uppercased()
        }
    }

    private func fetchDataWithCache(from url: URL,
                                    maxAge: TimeInterval,
                                    tag: String) async throws -> Data {
        if let fresh = loadCachedPayload(for: url, maxAge: maxAge) {
            if isValidJSONData(fresh.body) {
                syncLog("[cache] hit (fresh) for \(tag)")
                return fresh.body
            }
            syncLog("[cache] invalid JSON in fresh cache for \(tag) — purging")
            deleteCachedPayload(for: url)
        }

        do {
            let (data, resp) = try await authenticatedData(from: url)
            if let http = resp as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                let body = String(data: data.prefix(300), encoding: .utf8) ?? "<binary>"
                syncLog("[cache] HTTP \(http.statusCode) for \(tag) — \(body)")
                throw URLError(.badServerResponse)
            }
            guard isValidJSONData(data) else {
                syncLog("[cache] invalid JSON from network for \(tag)")
                throw URLError(.cannotParseResponse)
            }
            saveCachedPayload(data, for: url)
            return data
        } catch {
            if let stale = loadCachedPayload(for: url, maxAge: nil),
               isValidJSONData(stale.body) {
                syncLog("[cache] using stale fallback for \(tag) after network error: \(error.localizedDescription)")
                return stale.body
            }
            throw error
        }
    }

    private func saveCachedPayload(_ body: Data, for url: URL) {
        guard let fileURL = cacheFileURL(for: url) else { return }
        let payload = CachedHTTPPayload(savedAt: Date(), body: body)
        do {
            let data = try JSONEncoder().encode(payload)
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: fileURL, options: .atomic)
        } catch {
            syncLog("[cache] failed to write cache for \(url.absoluteString): \(error.localizedDescription)")
        }
    }

    private func loadCachedPayload(for url: URL, maxAge: TimeInterval?) -> CachedHTTPPayload? {
        guard let fileURL = cacheFileURL(for: url),
              let data = try? Data(contentsOf: fileURL),
              let payload = try? JSONDecoder().decode(CachedHTTPPayload.self, from: data)
        else { return nil }

        if let maxAge,
           Date().timeIntervalSince(payload.savedAt) > maxAge {
            return nil
        }
        return payload
    }

    private func cacheFileURL(for url: URL) -> URL? {
        guard let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else { return nil }

        let cacheDir = appSupport.appendingPathComponent(Self.responseCacheDirName, isDirectory: true)
        let digest = SHA256.hash(data: Data(url.absoluteString.utf8))
        let fileName = digest.map { String(format: "%02x", $0) }.joined() + ".json"
        return cacheDir.appendingPathComponent(fileName)
    }

    private func deleteCachedPayload(for url: URL) {
        guard let fileURL = cacheFileURL(for: url) else { return }
        try? FileManager.default.removeItem(at: fileURL)
    }

    private func isValidJSONData(_ data: Data) -> Bool {
        guard !data.isEmpty else { return false }
        return (try? JSONSerialization.jsonObject(with: data)) != nil
    }

    private func clearResponseCache() {
        guard let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else { return }
        let cacheDir = appSupport.appendingPathComponent(Self.responseCacheDirName, isDirectory: true)
        try? FileManager.default.removeItem(at: cacheDir)
        UserDefaults.standard.removeObject(forKey: Self.lastFullSyncAtKey)
        syncLog("[cache] response cache cleared")
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
            Player(
                playerID: $0.playerID,
                name: resolvedPlayerName(rawName: $0.name, playerID: $0.playerID, team: $0.team),
                team: $0.team,
                position: $0.position
            )
        }

        // Chronological order by tip time so the Schedule tab reads top-to-bottom
        // by start time. Games with unknown/TBD tips sort last, tie-broken by
        // matchup for deterministic ordering (Swift's sort is not guaranteed stable).
        let sortedScheduleGames = scheduleGames.sorted {
            let l = $0.tipTimeSortKey
            let r = $1.tipTimeSortKey
            switch (l, r) {
            case let (l?, r?): return l < r
            case (_?, nil):    return true
            case (nil, _?):    return false
            default:           return ($0.awayTeam + $0.homeTeam) < ($1.awayTeam + $1.homeTeam)
            }
        }

        let sortedGameLineups = gameLineups.sorted {
            let l = ScheduleGame.tipMinutesSinceMidnight(from: $0.gameTime)
            let r = ScheduleGame.tipMinutesSinceMidnight(from: $1.gameTime)
            switch (l, r) {
            case let (l?, r?): return l < r
            case (_?, nil):    return true
            case (nil, _?):    return false
            default:           return ($0.awayTeam ?? "") + ($0.homeTeam ?? "")
                                 < ($1.awayTeam ?? "") + ($1.homeTeam ?? "")
            }
        }

        return DataSnapshot(
            fetchedAt: fetchedAt,
            games: sortedScheduleGames,
            players: playersList,
            lineups: sortedGameLineups,
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

    private func resolvedPlayerName(rawName: String, playerID: String, team: String?) -> String {
        let trimmed = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !isLikelyNumericID(trimmed, matching: playerID) {
            return trimmed.isEmpty ? "Unknown Player" : trimmed
        }
        if let team, !team.isEmpty {
            return "\(team) Player"
        }
        return "Unknown Player"
    }

    private func isLikelyNumericID(_ value: String, matching playerID: String) -> Bool {
        guard !value.isEmpty else { return true }
        if value == playerID { return true }
        let digits = CharacterSet.decimalDigits
        let scalarSet = CharacterSet(charactersIn: value)
        return scalarSet.isSubset(of: digits) && value.count >= 5
    }

    // MARK: - Direct server test (debug panel)

    /// Fetches play-by-play JSON for a game and persists it to local response cache.
    /// Returns cached data when fresh, falls back to stale cache if offline.
    func fetchPlayByPlayRaw(gameID: String) async -> String {
        if !SportConfig.usesServerSync {
            return "Bundle-only mode enabled (SportConfig.usesServerSync=false). Play-by-play server endpoint is disabled."
        }
        let base = serverURL.trimmingCharacters(in: .whitespaces)
        let encoded = gameID.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? gameID
        guard let url = URL(string: "\(base)\(SportConfig.playByPlayEndpoint)?game_id=\(encoded)") else {
            return "Bad URL"
        }
        do {
            let data = try await fetchDataWithCache(from: url, maxAge: 60 * 60, tag: "play_by_play_\(gameID)")
            return String(data: data, encoding: .utf8) ?? "<non-UTF8 body>"
        } catch {
            return "ERROR: \(error.localizedDescription)"
        }
    }

    /// Fetches box-score JSON for a game and persists it to local response cache.
    /// Returns cached data when fresh, falls back to stale cache if offline.
    func fetchBoxScoreRaw(gameID: String) async -> String {
        if !SportConfig.usesServerSync {
            return "Bundle-only mode enabled (SportConfig.usesServerSync=false). Box-score server endpoint is disabled."
        }
        let base = serverURL.trimmingCharacters(in: .whitespaces)
        let encoded = gameID.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? gameID
        guard let url = URL(string: "\(base)\(SportConfig.boxScoreEndpoint)?game_id=\(encoded)") else {
            return "Bad URL"
        }
        do {
            let data = try await fetchDataWithCache(from: url, maxAge: 60 * 60, tag: "box_score_\(gameID)")
            return String(data: data, encoding: .utf8) ?? "<non-UTF8 body>"
        } catch {
            return "ERROR: \(error.localizedDescription)"
        }
    }

    /// Fetches box-score JSON for pick tracking. Unlike fetchBoxScoreRaw(), this
    /// is allowed in bundle-only mode so Picks can still track live progress.
    func fetchBoxScoreRawForTracking(gameID: String) async -> String {
        let base = serverURL.trimmingCharacters(in: .whitespaces)
        let encoded = gameID.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? gameID
        guard let url = URL(string: "\(base)\(SportConfig.boxScoreEndpoint)?game_id=\(encoded)") else {
            return "Bad URL"
        }
        do {
            // Keep tracking updates relatively fresh while still cache-friendly.
            let data = try await fetchDataWithCache(from: url, maxAge: 45, tag: "box_track_\(gameID)")
            return String(data: data, encoding: .utf8) ?? "<non-UTF8 body>"
        } catch {
            return "ERROR: \(error.localizedDescription)"
        }
    }

    /// Fires a raw GET to /nba/schedule and returns the response body as a String.
    /// Safe to call from the UI — never throws, surfaces any error inline.
    func testScheduleRaw() async -> String {
        if !SportConfig.usesServerSync {
            return "Bundle-only mode enabled (SportConfig.usesServerSync=false). No schedule server ping is performed."
        }
        let base = serverURL.trimmingCharacters(in: .whitespaces)
        guard let url = URL(string: base + SportConfig.scheduleEndpoint + "?date=" + Self.isoDateString(Date())) else {
            return "Bad URL: \(base + SportConfig.scheduleEndpoint)"
        }
        do {
            let (data, resp) = try await authenticatedData(from: url)
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

//
//  SportConfig.swift — NBA configuration.
//

import Foundation

struct SportConfig {
    // ── Identity ───────────────────────────────────────────────────────────────
    static let sportName        = "NBA"
    static let appDisplayName   = "Shattered Backboard"

    // ── App time zone (all user-facing times) ─────────────────────────────────
    static let appTimeZoneID    = "America/Phoenix"
    static let appTimeZoneLabel = "MST"

    // ── Data mode ─────────────────────────────────────────────────────────────
    // When true, the app syncs from the server at runtime and uses local SwiftData
    // as an offline cache. When false, the app falls back to bundled seed data.
    static let usesServerSync   = true

    // ── Remote server base URL ─────────────────────────────────────────────────
    // Render-hosted feed service. Debug builds can override this URL from the
    // hidden developer settings screen when testing a local server.
    static let baseURL          = "https://shattered-backboard-nba.onrender.com"

    // ── API endpoints (appended to baseURL) ────────────────────────────────────
    static let scheduleEndpoint      = "/nba/schedule"
    static let standingsEndpoint     = "/nba/standings"
    static let teamAdvancedEndpoint  = "/nba/team_advanced"
    static let playerAdvancedEndpoint = "/nba/player_advanced"
    static let teamPositionSplitsEndpoint = "/nba/team_position_splits"
    static let lineupsEndpoint       = "/nba/lineups"
    static let statsEndpoint         = "/nba/stats"
    static let rosterEndpoint        = "/nba/roster"
    static let playerLogsEndpoint     = "/nba/player_logs"        // ?player_id=X&season=Y&days=N
    static let playerLogsBulkEndpoint = "/nba/player_logs_bulk"   // ?player_ids=X,Y,Z&season=Y&days=N
    static let playByPlayEndpoint     = "/nba/play_by_play"       // ?game_id=X
    static let boxScoreEndpoint       = "/nba/box_score"          // ?game_id=X

    // ── Current NBA season year (e.g. 2026 for the 2025–26 season) ────────────
    // NBA season IDs use the calendar year in which the season *ends*.
    // October–December roll forward one year; January–September use current year.
    nonisolated static var currentSeason: Int {
        let cal   = Calendar(identifier: .gregorian)
        let now   = Date()
        let month = cal.component(.month, from: now)
        let year  = cal.component(.year,  from: now)
        return month >= 10 ? year + 1 : year
    }

    // ── Playoff configuration ──────────────────────────────────────────────────
    // NOTE: server-provided game_type is the primary playoff signal; these two
    // values only feed the offline fallback heuristic in ScheduleGame.
    //
    // All 30 NBA franchises — used by the offline playoff heuristic once the
    // bracket is confirmed each season.
    static let playoffTeams2026: Set<String> = [
        "ATL", "BOS", "BKN", "CHA", "CHI", "CLE", "DAL", "DEN",
        "DET", "GSW", "HOU", "IND", "LAC", "LAL", "MEM", "MIA",
        "MIL", "MIN", "NOP", "NYK", "OKC", "ORL", "PHI", "PHX",
        "POR", "SAC", "SAS", "TOR", "UTA", "WAS",
    ]

    // ── Team display names ──────────────────────────────────────────────────────
    // Maps internal team codes (used as data keys for standings, sims, and sync)
    // to the nicknames shown in the UI. Keys cover the server's codes plus the
    // ESPN fallback codes that appear before `normTeamAbbreviation` runs.
    static let teamNicknames: [String: String] = [
        "ATL": "Hawks",         // Atlanta
        "BOS": "Celtics",       // Boston
        "BKN": "Nets",          // Brooklyn
        "CHA": "Hornets",       // Charlotte
        "CHI": "Bulls",         // Chicago
        "CLE": "Cavaliers",     // Cleveland
        "DAL": "Mavericks",     // Dallas
        "DEN": "Nuggets",       // Denver
        "DET": "Pistons",       // Detroit
        "GSW": "Warriors",      // Golden State
        "HOU": "Rockets",       // Houston
        "IND": "Pacers",        // Indiana
        "LAC": "Clippers",      // Los Angeles Clippers
        "LAL": "Lakers",        // Los Angeles Lakers
        "MEM": "Grizzlies",     // Memphis
        "MIA": "Heat",          // Miami
        "MIL": "Bucks",         // Milwaukee
        "MIN": "Timberwolves",  // Minnesota
        "NOP": "Pelicans",      // New Orleans
        "NYK": "Knicks",        // New York
        "OKC": "Thunder",       // Oklahoma City
        "ORL": "Magic",         // Orlando
        "PHI": "76ers",         // Philadelphia
        "PHX": "Suns",          // Phoenix
        "POR": "Trail Blazers", // Portland
        "SAC": "Kings",         // Sacramento
        "SAS": "Spurs",         // San Antonio
        "TOR": "Raptors",       // Toronto
        "UTA": "Jazz",          // Utah
        "WAS": "Wizards",       // Washington
        // ESPN-style codes seen before normalization
        "NY":   "Knicks",
        "NO":   "Pelicans",
        "SA":   "Spurs",
        "GS":   "Warriors",
        "UTAH": "Jazz",
    ]

    /// User-facing team nickname for an internal team code.
    /// Falls back to the raw code when unknown (e.g. off-season exhibition data).
    static func teamNickname(for code: String) -> String {
        let key = code.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        return teamNicknames[key] ?? code
    }

    /// First-round window end for the current season's playoffs (games dated
    /// on/before this are Round 1). NBA first round typically ends around
    /// April 30 – May 2. Rolls automatically with `currentSeason`.
    static var firstRoundEndDate: String { "\(currentSeason)-04-30" }

    // ── Remote server auth ──────────────────────────────────────────────────────
    // Shared secret sent as the `X-API-Key` header on server requests. The
    // server requires it only when its NBA_API_KEY env var is set, so leaving
    // this empty keeps the app working against an unauthenticated server.
    static let serverAPIKey = ""

    // ── StoreKit ───────────────────────────────────────────────────────────────
    static let monthlyProductID = "com.shatteredbackboard.nba.monthly"

    // ── Prediction / simulation defaults ──────────────────────────────────────
    static let predictionSimulationCount = 500
    static let predictionModelVersion = "nba-2026.1"

    // ── UserDefaults keys ──────────────────────────────────────────────────────
    static let serverURLKey     = "nba_server_url"
}

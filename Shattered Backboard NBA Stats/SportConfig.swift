//
//  SportConfig.swift — NBA configuration.
//

import Foundation

struct SportConfig {
    // ── Identity ───────────────────────────────────────────────────────────────
    static let sportName        = "NBA"
    static let appDisplayName   = "Shattered Backboard"

    // ── Remote server base URL ─────────────────────────────────────────────────
    // Point this at your Mac NBA data server (NBA1/mobile_sync/server.py).
    // Run: cd NBA1 && python -m mobile_sync.server   (serves on port 8787)
    static let baseURL          = "http://192.168.0.7:8000"

    // ── API endpoints (appended to baseURL) ────────────────────────────────────
    static let scheduleEndpoint      = "/nba/schedule"
    static let standingsEndpoint     = "/nba/standings"
    static let lineupsEndpoint       = "/nba/lineups"
    static let statsEndpoint         = "/nba/stats"
    static let rosterEndpoint        = "/nba/roster"
    static let playerLogsEndpoint    = "/nba/player_logs"  // ?player_id=X&season=Y  |  ?season=Y&days=N (bulk)

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

    // ── 2026 Playoff configuration ─────────────────────────────────────────────
    // All 16 teams that qualified for the 2025–26 NBA Playoffs.
    // Used to auto-detect playoff games and apply engine adjustments.
    // Update this set once the full bracket is confirmed.
    static let playoffTeams2026: Set<String> = [
        // East — confirmed from April 22 slate
        "ATL", "CLE", "DET", "NYK", "ORL", "TOR",
        // East — expected qualifiers
        "MIL", "IND",
        // West — confirmed from April 22 slate
        "DEN", "MIN", "OKC", "PHX",
        // West — expected qualifiers
        "MEM", "LAL", "GSW", "DAL",
    ]

    // Hard-coded first-round end date (games before this date are Round 1).
    // NBA first round typically ends around April 30 – May 2.
    static let firstRoundEndDate = "2026-04-30"

    // ── StoreKit ───────────────────────────────────────────────────────────────
    static let monthlyProductID = "com.shatteredbackboard.nba.monthly"

    // ── UserDefaults keys ──────────────────────────────────────────────────────
    static let serverURLKey     = "nba_server_url"
}

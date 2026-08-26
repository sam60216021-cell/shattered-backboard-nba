//
//  AppRouter.swift — App-wide navigation + parlay state.
//

import Combine
import Foundation
import SwiftUI
import UIKit

@MainActor
final class AppRouter: ObservableObject {
    static let shared = AppRouter()
    private init() {
        let stored = UserDefaults.standard.stringArray(forKey: watchlistKey) ?? []
        watchlistPlayerIDs = Set(stored)
        let threshold = UserDefaults.standard.double(forKey: watchThresholdKey)
        if threshold > 0 { watchAlertThreshold = threshold }
        loadParlayPicks()
        loadTrackedPlayers()
    }

    private let watchlistKey = "watchlistPlayerIDs"
    private let watchThresholdKey = "watchAlertThreshold"
    private let parlayPicksKey = "parlayPicks_v1"
    private let trackedPlayersKey = "trackedPlayers_v1"

    // MARK: - Tab selection

    @Published var selectedTab: Int = 0

    // MARK: - Parlay builder state

    @Published private(set) var parlayPicks: [PlayerProp] = []
    @Published private(set) var trackedPlayers: [TrackedPlayer] = []

    // MARK: - Watchlist

    @Published private(set) var watchlistPlayerIDs: Set<String> = []
    @Published var watchAlertThreshold: Double = 0.70

    // MARK: - Computed

    var combinedProbability: Double {
        guard !parlayPicks.isEmpty else { return 0 }
        return parlayPicks.reduce(1.0) { $0 * $1.selectedProbability }
    }

    func isInParlay(_ prop: PlayerProp) -> Bool {
        parlayPicks.contains(where: { $0.id == prop.id })
    }

    /// Returns nil when the prop can be added, or a human-readable reason why it can't.
    func blockedReason(for prop: PlayerProp) -> String? {
        if isInParlay(prop) { return "Already added" }
        return nil
    }

    func canAdd(_ prop: PlayerProp) -> Bool {
        blockedReason(for: prop) == nil
    }

    // MARK: - Mutations

    @discardableResult
    func addToParlay(_ prop: PlayerProp) -> Bool {
        guard canAdd(prop) else { return false }
        parlayPicks.append(prop)
        track(prop)
        persistParlayPicks()
        haptic(.medium)
        return true
    }

    func removeFromParlay(_ prop: PlayerProp) {
        parlayPicks.removeAll { $0.id == prop.id }
        persistParlayPicks()
        haptic(.light)
    }

    func removeFromParlay(at offsets: IndexSet) {
        parlayPicks.remove(atOffsets: offsets)
        persistParlayPicks()
        haptic(.light)
    }

    func clearParlay() {
        parlayPicks.removeAll()
        persistParlayPicks()
        haptic(.light)
    }

    func track(_ prop: PlayerProp) {
        let tracked = TrackedPlayer(prop: prop)
        guard !tracked.name.isEmpty else { return }
        guard !trackedPlayers.contains(where: { $0.idKey == tracked.idKey }) else { return }
        trackedPlayers.append(tracked)
        trackedPlayers.sort { $0.name < $1.name }
        persistTrackedPlayers()
    }

    func addTrackedPlayer(_ tracked: TrackedPlayer) {
        guard !trackedPlayers.contains(where: { $0.idKey == tracked.idKey }) else { return }
        trackedPlayers.append(tracked)
        trackedPlayers.sort { $0.name < $1.name }
        persistTrackedPlayers()
    }

    func removeTrackedPlayer(idKey: String) {
        trackedPlayers.removeAll { $0.idKey == idKey }
        persistTrackedPlayers()
        haptic(.light)
    }

    /// Removes picks whose game has completed (status=final) or whose game date
    /// is in the past relative to app time zone.
    func pruneCompletedPicks() {
        guard !parlayPicks.isEmpty else { return }

        let dataService = LocalDataService.shared
        let detailsByGameID = dataService.gameDetails
        let games = dataService.snapshot?.games ?? []

        let today: String = {
            let f = DateFormatter()
            f.dateFormat = "yyyy-MM-dd"
            f.timeZone = TimeZone(identifier: SportConfig.appTimeZoneID)
            return f.string(from: Date())
        }()

        func isCompleted(_ pick: PlayerProp) -> Bool {
            guard let gid = pick.gameID, !gid.isEmpty else { return false }

            if let details = detailsByGameID[gid], details.statusCode == 3 {
                return true
            }

            if let game = games.first(where: { ($0.gameID ?? "") == gid || $0.id == gid }) {
                if game.date < today { return true }
                let status = (game.status ?? "").lowercased()
                if status.contains("final") { return true }
            }
            return false
        }

        let before = parlayPicks.count
        parlayPicks.removeAll(where: isCompleted)
        if parlayPicks.count != before {
            persistParlayPicks()
        }

        pruneCompletedTrackedPlayers(games: games, detailsByGameID: detailsByGameID, today: today)
    }

    private func pruneCompletedTrackedPlayers(
        games: [ScheduleGame],
        detailsByGameID: [String: GameDetails],
        today: String
    ) {
        guard !trackedPlayers.isEmpty else { return }

        let finishedTeams = Set(games.compactMap { game -> String? in
            let gid = game.gameID ?? ""
            let isFinalByDetails = (!gid.isEmpty && detailsByGameID[gid]?.statusCode == 3)
            let isFinalByStatus = (game.status ?? "").lowercased().contains("final")
            let isPast = game.date < today
            guard isFinalByDetails || isFinalByStatus || isPast else { return nil }
            return [game.awayTeam.uppercased(), game.homeTeam.uppercased()].joined(separator: "|")
        }.flatMap { $0.split(separator: "|").map(String.init) })

        guard !finishedTeams.isEmpty else { return }
        let before = trackedPlayers.count
        trackedPlayers.removeAll { finishedTeams.contains($0.teamAbbrev.uppercased()) }
        if trackedPlayers.count != before {
            persistTrackedPlayers()
        }
    }

    // MARK: - Watchlist mutations

    func isWatched(playerID: String) -> Bool {
        watchlistPlayerIDs.contains(playerID)
    }

    func toggleWatch(playerID: String) {
        if watchlistPlayerIDs.contains(playerID) {
            watchlistPlayerIDs.remove(playerID)
        } else {
            watchlistPlayerIDs.insert(playerID)
        }
        persistWatchlist()
        haptic(.light)
    }

    func setWatchAlertThreshold(_ value: Double) {
        watchAlertThreshold = min(0.95, max(0.50, value))
        UserDefaults.standard.set(watchAlertThreshold, forKey: watchThresholdKey)
    }

    private func persistWatchlist() {
        UserDefaults.standard.set(Array(watchlistPlayerIDs).sorted(), forKey: watchlistKey)
    }

    private func persistParlayPicks() {
        let encoder = JSONEncoder()
        guard let data = try? encoder.encode(parlayPicks) else { return }
        UserDefaults.standard.set(data, forKey: parlayPicksKey)
    }

    private func loadParlayPicks() {
        guard let data = UserDefaults.standard.data(forKey: parlayPicksKey) else {
            parlayPicks = []
            return
        }
        let decoder = JSONDecoder()
        parlayPicks = (try? decoder.decode([PlayerProp].self, from: data)) ?? []
    }

    private func persistTrackedPlayers() {
        let encoder = JSONEncoder()
        guard let data = try? encoder.encode(trackedPlayers) else { return }
        UserDefaults.standard.set(data, forKey: trackedPlayersKey)
    }

    private func loadTrackedPlayers() {
        guard let data = UserDefaults.standard.data(forKey: trackedPlayersKey) else {
            trackedPlayers = []
            return
        }
        trackedPlayers = (try? JSONDecoder().decode([TrackedPlayer].self, from: data)) ?? []
    }
}


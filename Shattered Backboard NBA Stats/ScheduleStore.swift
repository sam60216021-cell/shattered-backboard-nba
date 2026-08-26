//
//  ScheduleStore.swift — Realistic game simulations for Schedule tab.
//
//  Runs Monte Carlo 500-trial simulations per game to display realistic
//  projected scores, spreads, moneylines, and win probabilities.
//

import Foundation
import Combine

@MainActor
final class ScheduleStore: ObservableObject {
    static let shared = ScheduleStore()
    private init() {}

    @Published private(set) var simulations: [String: GameSimulationResult] = [:]
    @Published private(set) var isLoading = false

    private var lastComputedDay: String = ""
    private var lastStandingsSignature: String = ""

    func computeIfNeeded(games: [ScheduleGame]) {
        guard !isLoading else { return }
        let today = isoToday()
        let unchanged = games.map(\.id).sorted() == simulations.keys.sorted()
        let standingsChanged = standingsSignature() != lastStandingsSignature
        guard !unchanged || lastComputedDay != today || simulations.isEmpty || standingsChanged else { return }

        Task { await compute(games: games) }
    }

    private func compute(games: [ScheduleGame]) async {
        isLoading = true

        let dataService = LocalDataService.shared
        guard let snapshot = dataService.snapshot else {
            isLoading = false
            return
        }

        var newSims: [String: GameSimulationResult] = [:]

        for game in games {
            // Build matchup-specific projections so player means include opponent context.
            let gameProjs = PredictionEngine.shared.projectGame(
                game: game,
                players: snapshot.players,
                isPlayoffs: game.isPlayoffGame,
                isFirstRound: game.isFirstRound
            )

            if let sim = SimulationEngine.shared.simulateGame(
                game: game, projections: gameProjs
            ) {
                newSims[game.id] = sim
            }
        }

        simulations = newSims
        isLoading = false
        lastComputedDay = isoToday()
        lastStandingsSignature = standingsSignature()
    }

    private func standingsSignature() -> String {
        let pairs = LocalDataService.shared.standingsMap
            .values
            .map {
                "\($0.abbr):\($0.wins)-\($0.losses):\(String(format: "%.3f", $0.pct)):\(String(format: "%.2f", $0.pointsPG)):\(String(format: "%.2f", $0.oppPointsPG))"
            }
            .sorted()
        return pairs.joined(separator: "|")
    }

    private func isoToday() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = TimeZone(identifier: SportConfig.appTimeZoneID)
        return f.string(from: Date())
    }

}

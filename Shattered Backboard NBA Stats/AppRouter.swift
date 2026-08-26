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
    private init() {}

    // MARK: - Tab selection

    @Published var selectedTab: Int = 0

    // MARK: - Parlay builder state

    @Published private(set) var parlayPicks: [PlayerProp] = []

    // MARK: - Computed

    var combinedProbability: Double {
        guard !parlayPicks.isEmpty else { return 0 }
        return parlayPicks.reduce(1.0) { $0 * ($1.overPct ?? 0.5) }
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
        haptic(.medium)
        return true
    }

    func removeFromParlay(_ prop: PlayerProp) {
        parlayPicks.removeAll { $0.id == prop.id }
        haptic(.light)
    }

    func removeFromParlay(at offsets: IndexSet) {
        parlayPicks.remove(atOffsets: offsets)
        haptic(.light)
    }

    func clearParlay() {
        parlayPicks.removeAll()
        haptic(.light)
    }
}


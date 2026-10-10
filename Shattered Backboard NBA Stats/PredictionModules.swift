//
//  PredictionModules.swift — Independent Analytics, AI, and Blended forecasts.
//

import Foundation
import Observation

enum ProjectionModelSource: String, Codable, CaseIterable, Hashable {
    case analytics = "Analytics"
    case ai = "AI"
    case blended = "Blended"

    var shortLabel: String {
        switch self {
        case .analytics: return "AN"
        case .ai: return "AI"
        case .blended: return "BLEND"
        }
    }
}

struct ModuleProjection: Identifiable, Hashable {
    let id: String
    let projectionID: String
    let modelVersion: String
    let source: ProjectionModelSource
    let gameID: String
    let gameDate: String
    let playerID: String
    let playerName: String
    let team: String?
    let opponent: String?
    let stat: String
    let direction: PropDirection
    let line: Double
    let projectedValue: Double
    let confidence: Double
    let sampleSize: Int
    let reasoning: [String]
}

struct ProjectionNumberSet: Equatable {
    let analytics: Double
    let ai: Double
    let blended: Double
}

struct PredictionNumberEngine {
    static func numbers(
        player: Player,
        stat: String,
        projection: PlayerProjection,
        logs: [GameLog],
        game: ScheduleGame?,
        defenderMatchup: DefenderMatchup?,
        playerAdvanced: PlayerAdvancedEntry?
    ) -> ProjectionNumberSet? {
        let analytics = projection.value(for: stat)
        let values = logs.prefix(16).map { max(0, $0.value(for: stat)) }
        guard analytics > 0, values.count >= 5 else { return nil }

        let baseline = robustMean(values)
        let lastFive = mean(values.prefix(5))
        let lastThree = mean(values.prefix(3))
        var ai = baseline * 0.35 + lastFive * 0.35 + lastThree * 0.30

        let recent = mean(values.prefix(3))
        let older = mean(values.dropFirst(3).prefix(5))
        let trendBaseline = max(1, (recent + older) / 2)
        ai *= max(0.88, min(1.12, 1 + ((recent - older) / trendBaseline) * 0.16))

        let recentMinutes = mean(logs.prefix(3).map(\.min))
        let stableMinutes = mean(logs.prefix(10).map(\.min))
        if stableMinutes > 0 {
            ai *= max(0.88, min(1.12, recentMinutes / stableMinutes))
        }
        if let defenderMatchup {
            ai *= defenderMatchup.multiplier(for: stat)
        }
        if let usage = playerAdvanced?.estimatedUsagePct {
            ai *= max(0.96, min(1.04, 1 + (usage - 20) / 500))
        }
        if let game {
            let isHome = player.team?.uppercased() == game.homeTeam.uppercased()
            ai *= isHome ? 1.012 : 0.994
        }

        ai = max(0, ai)
        let analyticsConfidence = max(0.01, projection.confidence(for: stat))
        let volatility = coefficientOfVariation(values)
        let sampleStrength = min(1, Double(values.count) / 12)
        let stability = max(0, 1 - min(1, volatility))
        let aiConfidence = max(0.35, min(0.90, 0.38 + sampleStrength * 0.30 + stability * 0.24))
        let blended = (analytics * analyticsConfidence + ai * aiConfidence)
            / (analyticsConfidence + aiConfidence)

        return ProjectionNumberSet(analytics: analytics, ai: ai, blended: blended)
    }

    private static func robustMean(_ values: [Double]) -> Double {
        guard values.count >= 7 else { return mean(values) }
        let sorted = values.sorted()
        return mean(sorted.dropFirst().dropLast())
    }

    private static func mean<S: Sequence>(_ values: S) -> Double where S.Element == Double {
        let array = Array(values)
        return array.isEmpty ? 0 : array.reduce(0, +) / Double(array.count)
    }

    private static func coefficientOfVariation(_ values: [Double]) -> Double {
        let average = mean(values)
        guard values.count >= 3, average > 0 else { return 1 }
        let variance = values.reduce(0) { $0 + pow($1 - average, 2) } / Double(values.count)
        return sqrt(variance) / average
    }
}

struct AnalyticsPredictionModule {
    let modelVersion = "nba-analytics-v1"

    func projections(from entries: [TopPickEntry]) -> [ModuleProjection] {
        entries.compactMap { entry in
            guard let game = entry.game else { return nil }
            return ModuleProjection(
                id: "\(modelVersion)|analytics|\(entry.id)",
                projectionID: entry.id,
                modelVersion: modelVersion,
                source: .analytics,
                gameID: game.gameID ?? game.id,
                gameDate: game.date,
                playerID: entry.player.playerID,
                playerName: entry.player.name,
                team: entry.player.team,
                opponent: opponent(for: entry.player, in: game),
                stat: entry.stat,
                direction: entry.direction,
                line: entry.suggestedLine,
                projectedValue: entry.projection.value(for: entry.stat),
                confidence: entry.confidence,
                sampleSize: entry.projection.gameCount,
                reasoning: [
                    "Analytics combines recency-weighted production, opponent context, simulations, and availability."
                ]
            )
        }
    }
}

struct OnDeviceAIPredictionModule {
    let modelVersion = "nba-local-ai-v1"

    func projections(
        from entries: [TopPickEntry],
        playerAdvanced: [String: PlayerAdvancedEntry]
    ) -> [ModuleProjection] {
        entries.compactMap { entry in
            guard let game = entry.game else { return nil }
            let values = entry.logs.prefix(16).map { max(0, $0.value(for: entry.stat)) }
            guard values.count >= 5 else { return nil }

            let baseline = robustMean(values)
            let lastFive = mean(Array(values.prefix(5)))
            let lastThree = mean(Array(values.prefix(3)))
            var value = baseline * 0.35 + lastFive * 0.35 + lastThree * 0.30
            var reasoning = [
                "Independent history model: L3 \(lastThree.cleanLine), L5 \(lastFive.cleanLine), robust baseline \(baseline.cleanLine)."
            ]

            let trend = trendMultiplier(values)
            value *= trend
            reasoning.append(multiplierReason(
                trend,
                positive: "Recent form is rising",
                negative: "Recent form is falling",
                neutral: "Recent form is stable"
            ))

            let recentMinutes = mean(entry.logs.prefix(3).map(\.min))
            let stableMinutes = mean(entry.logs.prefix(10).map(\.min))
            let minutesMultiplier = stableMinutes > 0
                ? max(0.88, min(1.12, recentMinutes / stableMinutes))
                : 1.0
            value *= minutesMultiplier
            reasoning.append(multiplierReason(
                minutesMultiplier,
                positive: "Recent minutes are above the established role",
                negative: "Recent minutes are below the established role",
                neutral: "Minutes are stable"
            ))

            if let matchup = entry.defenderMatchup {
                let matchupMultiplier = matchup.multiplier(for: entry.stat)
                value *= matchupMultiplier
                reasoning.append(multiplierReason(
                    matchupMultiplier,
                    positive: "Individual matchup is favorable",
                    negative: "Individual matchup adds resistance",
                    neutral: "Individual matchup is neutral"
                ))
            }

            if let usage = playerAdvanced[entry.player.playerID]?.estimatedUsagePct {
                let usageMultiplier = max(0.96, min(1.04, 1 + (usage - 20) / 500))
                value *= usageMultiplier
                reasoning.append("Estimated usage is \(usage.cleanLine)% of recorded team possessions.")
            }

            let isHome = entry.player.team?.uppercased() == game.homeTeam.uppercased()
            value *= isHome ? 1.012 : 0.994
            reasoning.append(isHome ? "Small home-court adjustment applied." : "Small road adjustment applied.")

            let volatility = coefficientOfVariation(values)
            let sampleStrength = min(1, Double(values.count) / 12)
            let stability = max(0, 1 - min(1, volatility))
            let confidence = max(0.35, min(0.90, 0.38 + sampleStrength * 0.30 + stability * 0.24))

            return ModuleProjection(
                id: "\(modelVersion)|ai|\(entry.id)",
                projectionID: entry.id,
                modelVersion: modelVersion,
                source: .ai,
                gameID: game.gameID ?? game.id,
                gameDate: game.date,
                playerID: entry.player.playerID,
                playerName: entry.player.name,
                team: entry.player.team,
                opponent: opponent(for: entry.player, in: game),
                stat: entry.stat,
                direction: entry.direction,
                line: entry.suggestedLine,
                projectedValue: max(0, value),
                confidence: confidence,
                sampleSize: values.count,
                reasoning: reasoning
            )
        }
    }

    private func robustMean(_ values: [Double]) -> Double {
        guard values.count >= 7 else { return mean(values) }
        let sorted = values.sorted()
        return mean(Array(sorted.dropFirst().dropLast()))
    }

    private func mean<S: Sequence>(_ values: S) -> Double where S.Element == Double {
        let array = Array(values)
        return array.isEmpty ? 0 : array.reduce(0, +) / Double(array.count)
    }

    private func trendMultiplier(_ newestFirst: [Double]) -> Double {
        let recent = mean(newestFirst.prefix(3))
        let older = mean(newestFirst.dropFirst(3).prefix(5))
        let baseline = max(1, (recent + older) / 2)
        return max(0.88, min(1.12, 1 + ((recent - older) / baseline) * 0.16))
    }

    private func coefficientOfVariation(_ values: [Double]) -> Double {
        let average = mean(values)
        guard values.count >= 3, average > 0 else { return 1 }
        let variance = values.reduce(0) { $0 + pow($1 - average, 2) } / Double(values.count)
        return sqrt(variance) / average
    }

    private func multiplierReason(
        _ multiplier: Double,
        positive: String,
        negative: String,
        neutral: String
    ) -> String {
        let delta = (multiplier - 1) * 100
        if delta > 0.75 { return "\(positive) (+\(abs(delta).formatted(.number.precision(.fractionLength(1))))%)." }
        if delta < -0.75 { return "\(negative) (-\(abs(delta).formatted(.number.precision(.fractionLength(1))))%)." }
        return "\(neutral)."
    }
}

struct BlendedPredictionModule {
    let modelVersion = "nba-blended-v1"

    func projections(analytics: [ModuleProjection], ai: [ModuleProjection]) -> [ModuleProjection] {
        let aiByProjection = Dictionary(uniqueKeysWithValues: ai.map { ($0.projectionID, $0) })
        return analytics.compactMap { analyticsResult in
            guard let aiResult = aiByProjection[analyticsResult.projectionID] else { return nil }
            let analyticsWeight = max(0.01, analyticsResult.confidence)
            let aiWeight = max(0.01, aiResult.confidence)
            let totalWeight = analyticsWeight + aiWeight
            let value = (analyticsResult.projectedValue * analyticsWeight
                         + aiResult.projectedValue * aiWeight) / totalWeight
            return ModuleProjection(
                id: "\(modelVersion)|blend|\(analyticsResult.projectionID)",
                projectionID: analyticsResult.projectionID,
                modelVersion: modelVersion,
                source: .blended,
                gameID: analyticsResult.gameID,
                gameDate: analyticsResult.gameDate,
                playerID: analyticsResult.playerID,
                playerName: analyticsResult.playerName,
                team: analyticsResult.team,
                opponent: analyticsResult.opponent,
                stat: analyticsResult.stat,
                direction: analyticsResult.direction,
                line: analyticsResult.line,
                projectedValue: value,
                confidence: min(0.95, (analyticsResult.confidence + aiResult.confidence) / 2),
                sampleSize: max(analyticsResult.sampleSize, aiResult.sampleSize),
                reasoning: [
                    "Confidence-weighted blend of Analytics (\(analyticsResult.projectedValue.cleanLine)) and AI (\(aiResult.projectedValue.cleanLine))."
                ] + Array(aiResult.reasoning.prefix(3))
            )
        }
    }
}

@MainActor
@Observable
final class PredictionPipeline {
    static let shared = PredictionPipeline()

    private(set) var latestOutputs: [ModuleProjection] = []
    private(set) var lastRunAt: Date?

    private init() {}

    @discardableResult
    func run(
        entries: [TopPickEntry],
        playerAdvanced: [String: PlayerAdvancedEntry],
        now: Date = Date()
    ) -> [ModuleProjection] {
        let analytics = AnalyticsPredictionModule().projections(from: entries)
        let ai = OnDeviceAIPredictionModule().projections(from: entries, playerAdvanced: playerAdvanced)
        let blended = BlendedPredictionModule().projections(analytics: analytics, ai: ai)
        latestOutputs = analytics + ai + blended
        lastRunAt = now
        return latestOutputs
    }

    func output(projectionID: String, source: ProjectionModelSource) -> ModuleProjection? {
        latestOutputs.first { $0.projectionID == projectionID && $0.source == source }
    }
}

private func opponent(for player: Player, in game: ScheduleGame) -> String? {
    let team = player.team?.uppercased()
    if team == game.awayTeam.uppercased() { return game.homeTeam }
    if team == game.homeTeam.uppercased() { return game.awayTeam }
    return nil
}

//
//  ProjectionTracker.swift — Durable pregame projection capture and grading.
//

import Foundation
import Observation

enum ProjectionGrade: String, Codable {
    case hit
    case miss
    case push
}

struct TrackedNBAProjection: Identifiable, Codable, Equatable {
    let id: String
    let modelVersion: String
    let source: ProjectionModelSource?
    let capturedAt: Date
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
    var actualValue: Double?
    var gradedAt: Date?

    var grade: ProjectionGrade? {
        guard let actualValue else { return nil }
        if actualValue == line { return .push }
        switch direction {
        case .over: return actualValue > line ? .hit : .miss
        case .under: return actualValue < line ? .hit : .miss
        }
    }

    var absoluteError: Double? {
        actualValue.map { abs(projectedValue - $0) }
    }
}

struct ProjectionAccuracySummary: Identifiable, Equatable {
    let id: String
    let label: String
    let total: Int
    let graded: Int
    let hits: Int
    let pushes: Int
    let meanAbsoluteError: Double?

    var decisions: Int { max(0, graded - pushes) }

    var accuracy: Double? {
        guard decisions > 0 else { return nil }
        return Double(hits) / Double(decisions)
    }
}

@MainActor
@Observable
final class ProjectionTracker {
    static let shared = ProjectionTracker()

    private(set) var records: [TrackedNBAProjection] = []
    private(set) var overallSummary = ProjectionAccuracySummary(
        id: "overall", label: "All tracked plays", total: 0,
        graded: 0, hits: 0, pushes: 0, meanAbsoluteError: nil
    )
    private(set) var statSummaries: [ProjectionAccuracySummary] = []
    private(set) var sourceSummaries: [ProjectionAccuracySummary] = []
    private(set) var recentGradedRecords: [TrackedNBAProjection] = []
    private(set) var lastUpdated: Date?

    private let fileManager = FileManager.default
    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()
    private let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    private init() {
        load()
        rebuildSummaries()
    }

    func update(outputs: [ModuleProjection], dataService: LocalDataService, now: Date = Date()) {
        var changed = capture(outputs: outputs, now: now)
        changed = gradePending(dataService: dataService, now: now) || changed
        guard changed else { return }
        lastUpdated = now
        rebuildSummaries()
        persist()
    }

    func regrade(dataService: LocalDataService, now: Date = Date()) {
        guard gradePending(dataService: dataService, now: now) else { return }
        lastUpdated = now
        rebuildSummaries()
        persist()
    }

    private func capture(outputs: [ModuleProjection], now: Date) -> Bool {
        var knownIDs = Set(records.map(\.id))
        var additions: [TrackedNBAProjection] = []

        for output in outputs where output.line > 0 {
            let lineKey = String(format: "%.1f", output.line)
            let id = [output.gameID, output.playerID, output.stat,
                      output.direction.rawValue, lineKey, output.modelVersion]
                .joined(separator: "|")
            guard knownIDs.insert(id).inserted else { continue }

            additions.append(TrackedNBAProjection(
                id: id,
                modelVersion: output.modelVersion,
                source: output.source,
                capturedAt: now,
                gameID: output.gameID,
                gameDate: output.gameDate,
                playerID: output.playerID,
                playerName: output.playerName,
                team: output.team,
                opponent: output.opponent,
                stat: output.stat,
                direction: output.direction,
                line: output.line,
                projectedValue: output.projectedValue,
                confidence: output.confidence,
                sampleSize: output.sampleSize,
                actualValue: nil,
                gradedAt: nil
            ))
        }

        guard !additions.isEmpty else { return false }
        records.append(contentsOf: additions)
        return true
    }

    private func gradePending(dataService: LocalDataService, now: Date) -> Bool {
        var changed = false
        var logsByPlayer: [String: [GameLog]] = [:]

        for index in records.indices where records[index].actualValue == nil {
            let playerID = records[index].playerID
            let logs = logsByPlayer[playerID] ?? dataService.localLogs(playerID: playerID)
            logsByPlayer[playerID] = logs
            guard let log = logs.first(where: { $0.gameDate == records[index].gameDate }) else { continue }
            records[index].actualValue = log.value(for: records[index].stat)
            records[index].gradedAt = now
            changed = true
        }
        return changed
    }

    private func rebuildSummaries() {
        overallSummary = summary(id: "overall", label: "All tracked plays", rows: records)
        statSummaries = Dictionary(grouping: records, by: \.stat)
            .map { stat, rows in summary(id: stat, label: stat, rows: rows) }
            .sorted {
                if $0.graded == $1.graded { return $0.label < $1.label }
                return $0.graded > $1.graded
            }
        sourceSummaries = ProjectionModelSource.allCases.map { source in
            summary(
                id: "source-\(source.rawValue)",
                label: source.rawValue,
                rows: records.filter { ($0.source ?? .analytics) == source }
            )
        }
        recentGradedRecords = records
            .filter { $0.actualValue != nil }
            .sorted { ($0.gradedAt ?? .distantPast) > ($1.gradedAt ?? .distantPast) }
            .prefix(30)
            .map { $0 }
    }

    private func summary(id: String, label: String, rows: [TrackedNBAProjection]) -> ProjectionAccuracySummary {
        let graded = rows.filter { $0.grade != nil }
        let errors = graded.compactMap(\.absoluteError)
        return ProjectionAccuracySummary(
            id: id,
            label: label,
            total: rows.count,
            graded: graded.count,
            hits: graded.filter { $0.grade == .hit }.count,
            pushes: graded.filter { $0.grade == .push }.count,
            meanAbsoluteError: errors.isEmpty ? nil : errors.reduce(0, +) / Double(errors.count)
        )
    }

    private var storageURL: URL? {
        guard let root = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        let directory = root.appendingPathComponent("ShatteredBackboard", isDirectory: true)
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("projection_history.json")
    }

    private func load() {
        guard let url = storageURL, let data = try? Data(contentsOf: url) else { return }
        records = (try? decoder.decode([TrackedNBAProjection].self, from: data)) ?? []
    }

    private func persist() {
        guard let url = storageURL, let data = try? encoder.encode(records) else { return }
        try? data.write(to: url, options: .atomic)
    }
}

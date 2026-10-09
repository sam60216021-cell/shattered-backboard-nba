//
//  ProjectionAccuracyView.swift — Results for predictions saved before tipoff.
//

import SwiftUI

struct AnalyticsCenterToolbarItem: ToolbarContent {
    var body: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            NavigationLink {
                AnalyticsCenterView()
            } label: {
                Image(systemName: "brain.head.profile")
                    .foregroundStyle(Color.skyBright)
            }
            .accessibilityLabel("Analytics Center")
        }
    }
}

struct AnalyticsCenterView: View {
    @State private var pipeline = PredictionPipeline.shared
    @ObservedObject private var dataService = LocalDataService.shared

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                AnalyticsModelStackSection(outputs: pipeline.latestOutputs)
                AnalyticsDataCoverageSection(
                    players: dataService.snapshot?.players.count ?? 0,
                    playerAdvanced: dataService.playerAdvancedMap.count,
                    teamAdvanced: dataService.teamAdvancedMap.count,
                    positionSplits: dataService.teamPositionSplitsMap.count
                )

                NavigationLink {
                    ProjectionAccuracyView()
                } label: {
                    Label("Open Projection Accuracy", systemImage: "target")
                        .font(.headline)
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(14)
                        .background(Color.skyBright.opacity(0.75), in: RoundedRectangle(cornerRadius: 14))
                }
                .buttonStyle(.plain)
            }
            .padding(16)
        }
        .background(NightSkyBackground())
        .navigationTitle("Analytics Center")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct AnalyticsModelStackSection: View {
    let outputs: [ModuleProjection]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Prediction Stack", systemImage: "brain.head.profile")
                .font(.headline)
                .foregroundStyle(.white)

            ForEach(ProjectionModelSource.allCases, id: \.self) { source in
                AnalyticsModelStatusRow(
                    source: source,
                    count: outputs.lazy.filter { $0.source == source }.count
                )
            }

            Text(outputs.isEmpty
                 ? "Open Plays to calculate the current slate. Analytics, AI, and Blended results will then be available throughout the app."
                 : "The Blended model confidence-weights the independent Analytics and AI projections.")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.55))
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Color.skyCard, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.skyBorder, lineWidth: 1))
    }
}

private struct AnalyticsModelStatusRow: View {
    let source: ProjectionModelSource
    let count: Int

    var body: some View {
        HStack(spacing: 12) {
            Text(source.shortLabel)
                .font(.caption.bold())
                .foregroundStyle(source == .blended ? Color.mint : Color.skyBright)
                .frame(width: 52, alignment: .leading)
            Text(source.rawValue)
                .font(.subheadline.bold())
                .foregroundStyle(.white)
            Spacer()
            Text("\(count) projections")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.white.opacity(0.55))
        }
        .padding(10)
        .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
    }
}

private struct AnalyticsDataCoverageSection: View {
    let players: Int
    let playerAdvanced: Int
    let teamAdvanced: Int
    let positionSplits: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Advanced Data Coverage", systemImage: "chart.xyaxis.line")
                .font(.headline)
                .foregroundStyle(.white)

            AnalyticsCoverageRow(label: "Roster players", value: players)
            AnalyticsCoverageRow(label: "Player advanced", value: playerAdvanced)
            AnalyticsCoverageRow(label: "Team advanced", value: teamAdvanced)
            AnalyticsCoverageRow(label: "Position splits", value: positionSplits)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Color.skyCard, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.skyBorder, lineWidth: 1))
    }
}

private struct AnalyticsCoverageRow: View {
    let label: String
    let value: Int

    var body: some View {
        HStack {
            Text(label)
                .foregroundStyle(.white.opacity(0.75))
            Spacer()
            Text("\(value)")
                .font(.subheadline.bold().monospacedDigit())
                .foregroundStyle(value > 0 ? Color.mint : Color.orange)
        }
        .font(.subheadline)
    }
}

struct ProjectionAccuracyView: View {
    @State private var tracker = ProjectionTracker.shared
    @ObservedObject private var dataService = LocalDataService.shared

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                ProjectionAccuracyOverview(summary: tracker.overallSummary)
                ProjectionSourceSummarySection(summaries: tracker.sourceSummaries)
                ProjectionStatSummarySection(summaries: tracker.statSummaries)
                ProjectionRecentResultsSection(records: tracker.recentGradedRecords)
            }
            .padding(16)
        }
        .background(NightSkyBackground())
        .navigationTitle("Projection Accuracy")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            tracker.regrade(dataService: dataService)
        }
        .onChange(of: dataService.logsRevision) { _, _ in
            tracker.regrade(dataService: dataService)
        }
    }
}

private struct ProjectionSourceSummarySection: View {
    let summaries: [ProjectionAccuracySummary]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("By Model")
                .font(.headline)
                .foregroundStyle(.white)

            ForEach(summaries) { summary in
                ProjectionStatSummaryRow(summary: summary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Color.skyCard, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.skyBorder, lineWidth: 1))
    }
}
private struct ProjectionAccuracyOverview: View {
    let summary: ProjectionAccuracySummary

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Live Model Record", systemImage: "checkmark.seal.fill")
                .font(.headline)
                .foregroundStyle(.white)

            HStack(spacing: 12) {
                ProjectionMetricTile(
                    value: summary.accuracy.map { "\(Int(($0 * 100).rounded()))%" } ?? "—",
                    label: "Accuracy"
                )
                ProjectionMetricTile(value: "\(summary.hits)-\(summary.decisions - summary.hits)", label: "Hit–Miss")
                ProjectionMetricTile(
                    value: summary.meanAbsoluteError.map { String(format: "%.1f", $0) } ?? "—",
                    label: "Avg Error"
                )
            }

            Text("\(summary.graded) graded of \(summary.total) saved plays · \(summary.pushes) pushes")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.55))
        }
        .padding(16)
        .background(Color.skyCard, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.skyBorder, lineWidth: 1))
    }
}

private struct ProjectionMetricTile: View {
    let value: String
    let label: String

    var body: some View {
        VStack(spacing: 4) {
            Text(value)
                .font(.title3.bold())
                .foregroundStyle(Color.skyBright)
            Text(label)
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.5))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
    }
}

private struct ProjectionStatSummarySection: View {
    let summaries: [ProjectionAccuracySummary]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("By Stat")
                .font(.headline)
                .foregroundStyle(.white)

            if summaries.isEmpty {
                Text("Predictions will appear after the Plays tab calculates an upcoming slate.")
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.55))
            } else {
                ForEach(summaries) { summary in
                    ProjectionStatSummaryRow(summary: summary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Color.skyCard, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.skyBorder, lineWidth: 1))
    }
}

private struct ProjectionStatSummaryRow: View {
    let summary: ProjectionAccuracySummary

    var body: some View {
        HStack {
            Text(summary.label)
                .font(.subheadline.bold())
                .foregroundStyle(.white)
                .frame(width: 50, alignment: .leading)
            Text("\(summary.hits)-\(summary.decisions - summary.hits)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.white.opacity(0.6))
            Spacer()
            if let error = summary.meanAbsoluteError {
                Text("MAE \(error, specifier: "%.1f")")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.45))
            }
            Text(summary.accuracy.map { "\(Int(($0 * 100).rounded()))%" } ?? "—")
                .font(.subheadline.bold().monospacedDigit())
                .foregroundStyle(Color.skyBright)
                .frame(width: 46, alignment: .trailing)
        }
        .padding(.vertical, 5)
    }
}

private struct ProjectionRecentResultsSection: View {
    let records: [TrackedNBAProjection]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Recent Results")
                .font(.headline)
                .foregroundStyle(.white)

            if records.isEmpty {
                Text("Saved plays will be graded when completed game logs sync.")
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.55))
            } else {
                ForEach(records) { record in
                    ProjectionResultRow(record: record)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Color.skyCard, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.skyBorder, lineWidth: 1))
    }
}

private struct ProjectionResultRow: View {
    let record: TrackedNBAProjection

    private var gradeColor: Color {
        switch record.grade {
        case .hit: return .green
        case .miss: return .red
        case .push: return .orange
        case nil: return .secondary
        }
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: gradeIcon)
                .foregroundStyle(gradeColor)
            VStack(alignment: .leading, spacing: 2) {
                Text(record.playerName)
                    .font(.subheadline.bold())
                    .foregroundStyle(.white)
                Text("\((record.source ?? .analytics).shortLabel) · \(record.stat) \(record.direction.rawValue) \(record.line, specifier: "%.1f") · \(record.gameDate)")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.5))
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(record.actualValue.map { String(format: "%.1f", $0) } ?? "—")
                    .font(.subheadline.bold().monospacedDigit())
                    .foregroundStyle(gradeColor)
                Text("actual")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.4))
            }
        }
        .padding(.vertical, 5)
    }

    private var gradeIcon: String {
        switch record.grade {
        case .hit: return "checkmark.circle.fill"
        case .miss: return "xmark.circle.fill"
        case .push: return "minus.circle.fill"
        case nil: return "clock.circle.fill"
        }
    }
}

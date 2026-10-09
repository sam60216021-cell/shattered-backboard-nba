//
//  ProjectionSourceComparisonView.swift — Analytics, AI, and Blend values.
//

import SwiftUI

struct ProjectionSourceComparisonView: View {
    @State private var pipeline = PredictionPipeline.shared
    @State private var showsReasoning = false

    let projectionID: String
    var showReasoning = false

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                ForEach(ProjectionModelSource.allCases, id: \.self) { source in
                    ProjectionSourceValue(
                        label: source.shortLabel,
                        value: pipeline.output(projectionID: projectionID, source: source)?.projectedValue,
                        isFinal: source == .blended
                    )
                }
            }

            if showReasoning, let reasoningOutput {
                Button {
                    showsReasoning.toggle()
                } label: {
                    Label(
                        showsReasoning ? "Hide model reasoning" : "Why the models differ",
                        systemImage: showsReasoning ? "chevron.up" : "brain.head.profile"
                    )
                    .font(.caption2.bold())
                    .foregroundStyle(Color.skyBright)
                }
                .buttonStyle(.plain)

                if showsReasoning {
                    ProjectionReasoningList(reasons: reasoningOutput.reasoning)
                }
            }
        }
        .accessibilityElement(children: .contain)
    }

    private var reasoningOutput: ModuleProjection? {
        pipeline.output(projectionID: projectionID, source: .blended)
            ?? pipeline.output(projectionID: projectionID, source: .ai)
    }
}

private struct ProjectionSourceValue: View {
    let label: String
    let value: Double?
    let isFinal: Bool

    var body: some View {
        VStack(spacing: 2) {
            Text(label)
                .font(.caption2.bold())
                .foregroundStyle(isFinal ? Color.mint : Color.white.opacity(0.45))
            Text(value?.cleanLine ?? "—")
                .font(.caption.bold().monospacedDigit())
                .foregroundStyle(isFinal ? Color.mint : Color.white.opacity(0.85))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
        .background(
            (isFinal ? Color.mint : Color.skyBright).opacity(isFinal ? 0.12 : 0.06),
            in: RoundedRectangle(cornerRadius: 8)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke((isFinal ? Color.mint : Color.skyBorder).opacity(0.55), lineWidth: 1)
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label) projection")
        .accessibilityValue(value?.cleanLine ?? "Unavailable")
    }
}

private struct ProjectionReasoningList: View {
    let reasons: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(reasons, id: \.self) { reason in
                Text("• \(reason)")
                    .font(.caption2)
                    .foregroundStyle(Color.white.opacity(0.55))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

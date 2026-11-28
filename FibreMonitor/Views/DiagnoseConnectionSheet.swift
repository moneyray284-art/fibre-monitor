import SwiftUI

struct DiagnoseConnectionSheet: View {
    let diagnosis: ConnectionDiagnosis
    let perform: (ConnectionDiagnosisAction) -> Void

    @Environment(\.linkWaveThemePalette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var polishedSummary: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    verdictCard

                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(diagnosis.checks.enumerated()), id: \.element.id) { index, check in
                            DiagnosisCheckRow(check: check, perform: perform)
                            if index < diagnosis.checks.count - 1 {
                                LinkWaveHairlineDivider(leading: 42)
                            }
                        }
                    }
                    .linkWaveGlassCard(padding: 4)
                }
                .padding(.horizontal)
                .padding(.top, 12)
                .padding(.bottom, 12)
            }
            .background { LiquidGlassBackground() }
            .navigationTitle("Connection Diagnosis")
            .navigationBarTitleDisplayMode(.inline)
        }
        .task {
            guard let summary = await ConnectionDiagnosisNarrative.polish(diagnosis) else { return }
            polishedSummary = summary
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: polishedSummary)
    }

    private var verdictCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 9) {
                Image(systemName: verdictSymbol)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(verdictColor)
                    .accessibilityHidden(true)
                Text(diagnosis.severity.label.uppercased())
                    .font(.caption.weight(.bold))
                    .tracking(0.6)
                    .foregroundStyle(verdictColor)
                    .monospacedDigit()
            }
            Text(diagnosis.verdictTitle)
                .font(.title3.weight(.bold))
            Text(polishedSummary ?? diagnosis.summary)
                .font(.subheadline)
                .linkWaveText(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .linkWaveGlassCard()
        .accessibilityElement(children: .combine)
    }

    private var verdictSymbol: String {
        switch diagnosis.severity {
        case .optimal: "checkmark.circle.fill"
        case .pending: "clock"
        case .warning: "exclamationmark.triangle.fill"
        case .critical: "xmark.octagon.fill"
        }
    }

    private var verdictColor: Color {
        switch diagnosis.severity {
        case .optimal: .green
        case .pending: palette.textSecondary.color
        case .warning: .orange
        case .critical: .red
        }
    }

}

private struct DiagnosisCheckRow: View {
    let check: ConnectionDiagnosisCheck
    let perform: (ConnectionDiagnosisAction) -> Void
    @Environment(\.linkWaveThemePalette) private var palette

    @ViewBuilder
    var body: some View {
        if let action = check.action {
            Button {
                perform(action)
            } label: {
                rowContent(action: action)
            }
            .buttonStyle(.plain)
            .accessibilityHint(actionHint(for: action))
        } else {
            rowContent(action: nil)
        }
    }

    private func rowContent(action: ConnectionDiagnosisAction?) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: check.symbol)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(statusColor)
                .frame(width: 26, height: 26)
                .background(statusColor.opacity(0.12), in: Circle())
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                Text(check.title)
                    .font(.subheadline.weight(.semibold))
                Text(check.detail)
                    .font(.caption)
                    .linkWaveText(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if let action {
                HStack(spacing: 4) {
                    Image(systemName: statusSymbol)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(statusColor)
                        .accessibilityLabel(statusLabel)
                    Text(action.rowLabel)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(palette.textAccent)
                        .lineLimit(1)
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(palette.textAccent)
                        .accessibilityHidden(true)
                }
                .fixedSize()
                .padding(.top, 3)
            } else {
                Image(systemName: statusSymbol)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(statusColor)
                    .accessibilityLabel(statusLabel)
                    .padding(.top, 3)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 11)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    private func actionHint(for action: ConnectionDiagnosisAction) -> String {
        switch action {
        case .reviewWiFiBands: "Dismisses this sheet and opens Wi-Fi settings."
        case .runSpeedTest: "Dismisses this sheet and starts a speed test on Home."
        }
    }

    private var statusSymbol: String {
        switch check.status {
        case .optimal: "checkmark.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .critical: "xmark.octagon.fill"
        case .pending: "clock"
        }
    }

    private var statusLabel: String {
        switch check.status {
        case .optimal: "Optimal"
        case .warning: "Needs attention"
        case .critical: "Action needed"
        case .pending: "Pending"
        }
    }

    private var statusColor: Color {
        switch check.status {
        case .optimal: .green
        case .warning: .orange
        case .critical: .red
        case .pending: palette.textSecondary.color
        }
    }
}

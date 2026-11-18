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
                            DiagnosisCheckRow(check: check)
                            if index < diagnosis.checks.count - 1 {
                                Divider().padding(.leading, 42)
                            }
                        }
                    }
                    .linkWaveGlassCard(padding: 4)

                    if !diagnosis.actions.isEmpty {
                        VStack(spacing: 9) {
                            ForEach(diagnosis.actions) { action in
                                Button {
                                    perform(action)
                                } label: {
                                    Label(action.title, systemImage: action.symbol)
                                        .font(.subheadline.weight(.semibold))
                                        .frame(maxWidth: .infinity, minHeight: 44)
                                }
                                .liquidGlassActionButton(tint: palette.textAccent)
                                .accessibilityHint(actionHint(for: action))
                            }
                        }
                    }
                }
                .padding(.horizontal)
                .padding(.top, 12)
                .padding(.bottom, 24)
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

    private func actionHint(for action: ConnectionDiagnosisAction) -> String {
        switch action {
        case .reviewWiFiBands: "Opens Wi-Fi settings to review the active bands."
        case .runSpeedTest: "Closes this sheet and starts a speed test on Home."
        }
    }
}

private struct DiagnosisCheckRow: View {
    let check: ConnectionDiagnosisCheck
    @Environment(\.linkWaveThemePalette) private var palette

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: check.symbol)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(statusColor)
                .frame(width: 26, height: 26)
                .background(statusColor.opacity(0.12), in: Circle())
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(check.title)
                        .font(.subheadline.weight(.semibold))
                    Spacer(minLength: 6)
                    Image(systemName: statusSymbol)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(statusColor)
                        .accessibilityLabel(statusLabel)
                }
                Text(check.detail)
                    .font(.caption)
                    .linkWaveText(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 11)
        .accessibilityElement(children: .combine)
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

import SwiftUI

struct ConnectionHistoryCard: View {
    let events: [ConnectionInterruption]

    private var visibleEvents: [ConnectionInterruption] { Array(events.prefix(4)) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            CardHeader(icon: "clock.arrow.circlepath", title: "Router Connection History") {
                EmptyView()
            }

            if visibleEvents.isEmpty {
                Label("No interruptions observed", systemImage: "checkmark.circle.fill")
                    .font(.subheadline.weight(.medium))
                    .foregroundColor(.green)
                Text("The app records router connection changes while it is open and checking.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else {
                ForEach(visibleEvents) { event in
                    interruptionRow(event)
                    if event.id != visibleEvents.last?.id { Divider() }
                }
                Text("History reflects checks made while the app was polling. Time away from the app may be unknown.")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }
        .linkWaveGlassCard()
        .accessibilityElement(children: .contain)
    }

    private func interruptionRow(_ event: ConnectionInterruption) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Label("Router became unreachable", systemImage: "exclamationmark.triangle.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundColor(.orange)
            Text("First detected \(event.startedAt.formatted(date: .abbreviated, time: .shortened))")
                .font(.caption)
                .foregroundColor(.secondary)

            if let restoredAt = event.restoredAt {
                Text("Router responded again \(restoredAt.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption)
                    .foregroundColor(.primary)
                if let duration = event.observedDurationSeconds {
                    Text("Observed interruption: about \(Self.durationText(duration))")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                } else {
                    Text("Duration unknown because the app missed part of the interval.")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            } else {
                Text("No recovery has been observed yet.")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private static func durationText(_ duration: TimeInterval) -> String {
        let seconds = max(0, Int(duration.rounded()))
        if seconds < 60 { return "\(seconds) seconds" }
        let minutes = seconds / 60
        let remainingSeconds = seconds % 60
        if minutes < 60 {
            return remainingSeconds == 0 ? "\(minutes) min" : "\(minutes) min \(remainingSeconds) sec"
        }
        let hours = minutes / 60
        let remainingMinutes = minutes % 60
        return remainingMinutes == 0 ? "\(hours) hr" : "\(hours) hr \(remainingMinutes) min"
    }
}


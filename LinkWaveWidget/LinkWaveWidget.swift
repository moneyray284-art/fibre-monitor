import Foundation
import SwiftUI
import UIKit
import WidgetKit

private struct WidgetSnapshot: Codable {
    var rxPowerDbm: Double?
    var todayDownloadBytes: UInt64
    var todayUploadBytes: UInt64
    var todayTotalBytes: UInt64
    var onlineClientCount: Int
    var pppoeUptimeSeconds: Int?
    var updatedAt: Date

    static let empty = WidgetSnapshot(
        rxPowerDbm: nil,
        todayDownloadBytes: 0,
        todayUploadBytes: 0,
        todayTotalBytes: 0,
        onlineClientCount: 0,
        pppoeUptimeSeconds: nil,
        updatedAt: .distantPast
    )

    static func load() -> WidgetSnapshot {
        guard let defaults = UserDefaults(suiteName: "group.dev.mattdev0.fibremonitor"),
              let data = defaults.data(forKey: "linkwave.widget.snapshot.v1"),
              let snapshot = try? JSONDecoder().decode(WidgetSnapshot.self, from: data) else {
            return .empty
        }
        return snapshot
    }
}

private struct LinkWaveWidgetEntry: TimelineEntry {
    var date: Date
    var snapshot: WidgetSnapshot
}

private struct LinkWaveWidgetProvider: TimelineProvider {
    func placeholder(in context: Context) -> LinkWaveWidgetEntry {
        LinkWaveWidgetEntry(
            date: Date(),
            snapshot: WidgetSnapshot(
                rxPowerDbm: -15.8,
                todayDownloadBytes: 880_000_000,
                todayUploadBytes: 120_000_000,
                todayTotalBytes: 1_000_000_000,
                onlineClientCount: 7,
                pppoeUptimeSeconds: 86_400,
                updatedAt: Date()
            )
        )
    }

    func getSnapshot(in context: Context, completion: @escaping (LinkWaveWidgetEntry) -> Void) {
        completion(LinkWaveWidgetEntry(date: Date(), snapshot: .load()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<LinkWaveWidgetEntry>) -> Void) {
        let now = Date()
        let entry = LinkWaveWidgetEntry(date: now, snapshot: .load())
        completion(Timeline(entries: [entry], policy: .after(now.addingTimeInterval(30 * 60))))
    }
}

private struct LinkWaveWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: LinkWaveWidgetEntry

    @ViewBuilder
    var body: some View {
        switch family {
        case .systemSmall:
            smallView
        case .systemMedium:
            mediumView
        case .accessoryRectangular:
            lockScreenView
        default:
            smallView
        }
    }

    private var smallView: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 5) {
                Image(systemName: "wave.3.right")
                    .foregroundStyle(Color.cyan)
                Text("LinkWave")
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                Spacer(minLength: 0)
                FibreBars(rx: entry.snapshot.rxPowerDbm)
            }
            Text(entry.snapshot.rxPowerDbm.map { String(format: "%.1f dBm", $0) } ?? "Fibre —")
                .font(.headline.monospacedDigit())
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Spacer(minLength: 0)
            Text("TODAY")
                .font(.caption2.weight(.medium))
                .foregroundStyle(.secondary)
            Text(WidgetFormat.bytes(entry.snapshot.todayTotalBytes))
                .font(.title2.bold().monospacedDigit())
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .padding(14)
    }

    private var mediumView: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .firstTextBaseline) {
                Label("LinkWave", systemImage: "wave.3.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.cyan)
                Spacer()
                if entry.snapshot.updatedAt == .distantPast {
                    Text("Waiting for first sync")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                } else {
                    HStack(spacing: 3) {
                        Text("Updated")
                        Text(entry.snapshot.updatedAt, style: .relative)
                    }
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            HStack(spacing: 6) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("FIBRE RX")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.secondary)
                    HStack(spacing: 5) {
                        FibreBars(rx: entry.snapshot.rxPowerDbm)
                        Text(entry.snapshot.rxPowerDbm.map { String(format: "%.1f", $0) } ?? "—")
                            .font(.caption.monospacedDigit().weight(.semibold))
                            .lineLimit(1)
                        Text("dBm")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                Rectangle()
                    .fill(.quaternary)
                    .frame(width: 1, height: 34)
                HStack(spacing: 6) {
                    usageColumn(title: "DOWNLOAD", bytes: entry.snapshot.todayDownloadBytes, symbol: "arrow.down")
                    usageColumn(title: "UPLOAD", bytes: entry.snapshot.todayUploadBytes, symbol: "arrow.up")
                }
                Spacer(minLength: 0)
                VStack(alignment: .trailing, spacing: 4) {
                    Text("ONLINE")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.secondary)
                    Label("\(entry.snapshot.onlineClientCount)", systemImage: "circle.fill")
                        .labelStyle(OnlineCountLabelStyle())
                        .font(.headline.monospacedDigit())
                        .foregroundStyle(.green)
                    if let uptime = entry.snapshot.pppoeUptimeSeconds, uptime > 0 {
                        Text("PPPoE \(WidgetFormat.uptime(uptime))")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }
        }
        .padding(14)
    }

    private func usageColumn(title: String, bytes: UInt64, symbol: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption2.weight(.medium))
                .foregroundStyle(.secondary)
            HStack(spacing: 3) {
                Image(systemName: symbol)
                    .font(.caption2.weight(.semibold))
                Text(WidgetFormat.bytes(bytes))
                    .font(.caption.monospacedDigit().weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.65)
            }
        }
    }

    private var lockScreenView: some View {
        HStack(spacing: 8) {
            FibreBars(rx: entry.snapshot.rxPowerDbm)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.snapshot.rxPowerDbm.map { String(format: "RX %.1f dBm", $0) } ?? "Fibre unavailable")
                    .font(.headline)
                    .lineLimit(1)
                Text("Today \(WidgetFormat.bytes(entry.snapshot.todayTotalBytes)) · \(entry.snapshot.onlineClientCount) online")
                    .font(.caption)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
        }
    }
}

private struct OnlineCountLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 5) {
            configuration.icon.font(.system(size: 7))
            configuration.title
        }
    }
}

private struct FibreBars: View {
    let rx: Double?

    private var level: Int {
        guard let rx else { return 0 }
        if rx >= -24 { return 4 }
        if rx > -27 { return 3 }
        if rx > -29 { return 2 }
        return 1
    }

    private var color: Color {
        switch level {
        case 4, 3: .green
        case 2: .orange
        case 1: .red
        default: .secondary
        }
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(1...4, id: \.self) { bar in
                Capsule()
                    .fill(bar <= level ? color : Color.secondary.opacity(0.25))
                    .frame(width: 3, height: CGFloat(4 + bar * 3))
            }
        }
        .accessibilityLabel("Fibre signal, \(level) of 4 bars")
    }
}

private struct LinkWaveWidgetBackground: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOSApplicationExtension 17.0, *) {
            content.containerBackground(for: .widget) {
                Color(uiColor: .secondarySystemBackground)
            }
        } else {
            content.background(Color(uiColor: .secondarySystemBackground))
        }
    }
}

private enum WidgetFormat {
    static func bytes(_ value: UInt64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .decimal
        formatter.allowedUnits = [.useKB, .useMB, .useGB, .useTB]
        return formatter.string(fromByteCount: Int64(clamping: value))
    }

    static func uptime(_ seconds: Int) -> String {
        let days = seconds / 86_400
        let hours = (seconds % 86_400) / 3_600
        return days > 0 ? "\(days)d \(hours)h" : "\(hours)h"
    }
}

private struct LinkWaveWidget: Widget {
    let kind = "LinkWaveWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: LinkWaveWidgetProvider()) { entry in
            LinkWaveWidgetView(entry: entry)
                .modifier(LinkWaveWidgetBackground())
        }
        .configurationDisplayName("LinkWave")
        .description("Fibre signal, today's usage and connected devices.")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryRectangular])
    }
}

@main
struct LinkWaveWidgetBundle: WidgetBundle {
    var body: some Widget {
        LinkWaveWidget()
    }
}

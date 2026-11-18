import AppIntents
import SwiftUI
import WidgetKit

struct LinkWaveWidgetConfigIntent: WidgetConfigurationIntent {
    static var title: LocalizedStringResource = "LinkWave Router"
    static var description = IntentDescription("Choose the router shown in your LinkWave widget.")

    @Parameter(title: "Router Name", default: "MTN FIBRE") var routerName: String
    @Parameter(title: "Gateway URL", default: "http://192.168.100.1") var gatewayURL: String
    @Parameter(title: "Username", default: "root") var username: String
    @Parameter(title: "Password", description: "Saved in the widget extension's Keychain.", default: "") var password: String

    func perform() async throws -> some IntentResult {
        let configuration = WidgetRouterConfiguration(
            routerName: routerName,
            gatewayURL: gatewayURL,
            username: username
        )
        WidgetLocalStore.saveConfiguration(configuration)
        WidgetCredentialStore.save(password: password, for: configuration)
        return .result()
    }
}

struct RefreshWidgetIntent: AppIntent {
    static var title: LocalizedStringResource = "Sync LinkWave Widget"
    static var description = IntentDescription("Refresh router readings in the LinkWave widget.")
    static var openAppWhenRun = false

    @Parameter(title: "Router Name") var routerName: String
    @Parameter(title: "Gateway URL") var gatewayURL: String
    @Parameter(title: "Username") var username: String

    init() {
        routerName = "MTN FIBRE"
        gatewayURL = "http://192.168.100.1"
        username = "root"
    }

    init(routerName: String, gatewayURL: String, username: String) {
        self.routerName = routerName
        self.gatewayURL = gatewayURL
        self.username = username
    }

    func perform() async throws -> some IntentResult {
        let configuration = WidgetRouterConfiguration(
            routerName: routerName,
            gatewayURL: gatewayURL,
            username: username
        )
        WidgetLocalStore.saveConfiguration(configuration)
        _ = await WidgetRefreshService.shared.refresh(for: configuration)
        WidgetCenter.shared.reloadAllTimelines()
        return .result()
    }
}

struct LinkWaveWidgetEntry: TimelineEntry {
    var date: Date
    var configuration: WidgetRouterConfiguration
    var snapshot: LinkWaveWidgetSnapshot
}

struct LinkWaveWidgetProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> LinkWaveWidgetEntry {
        let configuration = WidgetRouterConfiguration(
            routerName: "MTN FIBRE",
            gatewayURL: "http://192.168.100.1",
            username: "root"
        )
        return LinkWaveWidgetEntry(
            date: Date(),
            configuration: configuration,
            snapshot: LinkWaveWidgetSnapshot.empty(routerName: configuration.routerName)
        )
    }

    func snapshot(for configurationIntent: LinkWaveWidgetConfigIntent, in context: Context) async -> LinkWaveWidgetEntry {
        let configuration = makeConfiguration(configurationIntent)
        WidgetLocalStore.saveConfiguration(configuration)
        WidgetCredentialStore.save(password: configurationIntent.password, for: configuration)
        let snapshot = await WidgetRefreshService.shared.refresh(for: configuration)
            ?? WidgetLocalStore.snapshot(for: configuration)
            ?? LinkWaveWidgetSnapshot.empty(routerName: configuration.routerName)
        return LinkWaveWidgetEntry(date: Date(), configuration: configuration, snapshot: snapshot)
    }

    func timeline(for configurationIntent: LinkWaveWidgetConfigIntent, in context: Context) async -> Timeline<LinkWaveWidgetEntry> {
        let entry = await snapshot(for: configurationIntent, in: context)
        return Timeline(entries: [entry], policy: .after(Date().addingTimeInterval(30 * 60)))
    }

    private func makeConfiguration(_ intent: LinkWaveWidgetConfigIntent) -> WidgetRouterConfiguration {
        WidgetRouterConfiguration(
            routerName: intent.routerName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "MTN FIBRE" : intent.routerName,
            gatewayURL: intent.gatewayURL,
            username: intent.username
        )
    }
}

struct LinkWaveRouterWidget: Widget {
    let kind = "LinkWaveRouterWidget"

    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: kind, intent: LinkWaveWidgetConfigIntent.self, provider: LinkWaveWidgetProvider()) { entry in
            LinkWaveWidgetEntryView(entry: entry)
        }
        .configurationDisplayName("LinkWave Router")
        .description("See today's router usage, connected devices and fibre signal.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

@main
struct LinkWaveWidgetExtension: WidgetBundle {
    var body: some Widget {
        LinkWaveRouterWidget()
    }
}

private struct LinkWaveWidgetEntryView: View {
    let entry: LinkWaveWidgetEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        Group {
            if family == .systemMedium {
                mediumLayout
            } else {
                smallLayout
            }
        }
        .padding(14)
        .containerBackground(for: .widget) {
            ZStack {
                Color(uiColor: .systemBackground)
                LinearGradient(
                    colors: [cyan.opacity(0.12), .clear, Color.mint.opacity(0.08)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            }
        }
    }

    private var smallLayout: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Circle().fill(.green).frame(width: 7, height: 7)
                Text(entry.snapshot.routerName)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                Spacer(minLength: 2)
                refreshButton
            }

            Spacer(minLength: 0)
            Text("TODAY'S USAGE")
                .font(.system(size: 9, weight: .bold, design: .rounded))
                .foregroundStyle(.secondary)
            Text(gigabytes(saturatedSum(entry.snapshot.todayDownloadBytes, entry.snapshot.todayUploadBytes)))
                .font(.system(size: 27, weight: .bold, design: .rounded))
                .monospacedDigit()
                .minimumScaleFactor(0.75)
                .lineLimit(1)
            Spacer(minLength: 0)

            HStack(spacing: 8) {
                Label("\(entry.snapshot.onlineClientCount) online", systemImage: "person.2.fill")
                Spacer(minLength: 0)
            }
            .font(.system(size: 9, weight: .medium))
            Text(opticalRxText)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(entry.snapshot.rxPowerDbm == nil ? Color.secondary : Color.green)
            syncCaption
        }
    }

    private var mediumLayout: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(entry.snapshot.routerName)
                    .font(.headline.weight(.semibold))
                    .lineLimit(1)
                Text(entry.snapshot.model)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                syncCaption
                Spacer(minLength: 1)
                Text("TODAY'S USAGE")
                    .font(.system(size: 9, weight: .bold, design: .rounded))
                    .foregroundStyle(.secondary)
                Text(gigabytes(saturatedSum(entry.snapshot.todayDownloadBytes, entry.snapshot.todayUploadBytes)))
                    .font(.system(size: 25, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .minimumScaleFactor(0.75)
                    .lineLimit(1)
                Text("↓ \(compactBytes(entry.snapshot.todayDownloadBytes))  ·  ↑ \(compactBytes(entry.snapshot.todayUploadBytes))")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)

            Rectangle().fill(.primary.opacity(0.1)).frame(width: 1)

            VStack(alignment: .leading, spacing: 7) {
                HStack(alignment: .top) {
                    Text("THIS MONTH")
                        .font(.system(size: 9, weight: .bold, design: .rounded))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    refreshButton
                }
                Text(gigabytes(saturatedSum(entry.snapshot.monthDownloadBytes, entry.snapshot.monthUploadBytes)))
                    .font(.system(size: 19, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .minimumScaleFactor(0.75)
                    .lineLimit(1)
                Label("\(entry.snapshot.onlineClientCount) online", systemImage: "person.2.fill")
                    .font(.caption2.weight(.medium))
                    .lineLimit(1)
                HStack(spacing: 5) {
                    Image(systemName: "dot.radiowaves.left.and.right")
                    Text("Fibre RX")
                    Spacer(minLength: 0)
                    Text(rxValue).foregroundStyle(entry.snapshot.rxPowerDbm == nil ? Color.secondary : Color.green)
                }
                .font(.caption2.weight(.medium))
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        }
    }

    private var refreshButton: some View {
        Button(intent: RefreshWidgetIntent(
            routerName: entry.configuration.routerName,
            gatewayURL: entry.configuration.gatewayURL,
            username: entry.configuration.username
        )) {
            Image(systemName: "arrow.clockwise")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(cyan)
                .frame(width: 27, height: 27)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Sync router now")
    }

    private var syncCaption: some View {
        Group {
            if let date = entry.snapshot.lastSyncAt {
                Text("Synced ") + Text(date, style: .relative)
            } else {
                Text("Waiting for first sync")
            }
        }
        .font(.system(size: 9, weight: .regular))
        .foregroundStyle(.secondary)
        .lineLimit(1)
    }

    private var rxValue: String {
        guard let value = entry.snapshot.rxPowerDbm else { return "RX —" }
        return String(format: "RX %.2f dBm", value)
    }

    private var opticalRxText: String {
        guard let value = entry.snapshot.rxPowerDbm else { return "Optical RX —" }
        return String(format: "Optical RX %.2f dBm", value)
    }

    private var cyan: Color { Color(red: 0.13, green: 0.82, blue: 0.91) }

    private func gigabytes(_ bytes: UInt64) -> String {
        String(format: "%.2f GB", Double(bytes) / 1_000_000_000)
    }

    private func saturatedSum(_ first: UInt64, _ second: UInt64) -> UInt64 {
        let (sum, overflow) = first.addingReportingOverflow(second)
        return overflow ? UInt64.max : sum
    }

    private func compactBytes(_ bytes: UInt64) -> String {
        if bytes >= 1_000_000_000 { return String(format: "%.1f GB", Double(bytes) / 1_000_000_000) }
        if bytes >= 1_000_000 { return String(format: "%.0f MB", Double(bytes) / 1_000_000) }
        return String(format: "%.0f KB", Double(bytes) / 1_000)
    }
}

import SwiftUI

public struct UsageTabView: View {
    @ObservedObject var viewModel: MonitorViewModel
    @ObservedObject var settings: SettingsStore
    @State private var showSettings = false

    public init(viewModel: MonitorViewModel) {
        self.viewModel = viewModel
        self.settings = viewModel.settings
    }

    public var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    if settings.isConfigured {
                        SyncStatusCard(summary: settings.dataUsageSummary)
                        UsageTotalsCard(summary: settings.dataUsageSummary)
                        DailyUsageHistoryCard(
                            points: settings.dataUsageSummary.dailyHistory,
                            todayDownloadBytes: settings.dataUsageSummary.todayDownloadBytes,
                            todayUploadBytes: settings.dataUsageSummary.todayUploadBytes,
                            missingDayCount: settings.dataUsageSummary.missingHistoryDayCount
                        )
                    } else {
                        noRouterCard
                    }
                }
                .padding(.horizontal)
                .padding(.top, 8)
                .padding(.bottom, 24)
            }
            .background { LiquidGlassBackground() }
            .liquidGlassScrollEdges()
            .refreshable { await viewModel.refreshAll() }
            .navigationTitle("Usage")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    RouterSwitcherMenu(viewModel: viewModel, settings: settings) {
                        showSettings = true
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task { await viewModel.refreshAll() }
                    } label: {
                        if viewModel.isRefreshing {
                            ProgressView()
                        } else {
                            Label("Refresh", systemImage: "arrow.clockwise")
                        }
                    }
                    .disabled(viewModel.isRefreshing || !settings.isConfigured)
                }
            }
            .navigationDestination(isPresented: $showSettings) {
                SettingsTabView(viewModel: viewModel)
            }
        }
    }

    private var noRouterCard: some View {
        VStack(spacing: 12) {
            Image(systemName: "arrow.up.arrow.down.circle")
                .font(.system(size: 36))
                .foregroundColor(.accentColor)
                .accessibilityHidden(true)
            Text("Usage tracking needs a router")
                .font(.headline)
            Text("Add a router in Settings to see downloaded and uploaded data.")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
            Button("Open Settings") { showSettings = true }
                .liquidGlassActionButton()
        }
        .frame(maxWidth: .infinity)
        .liquidGlassCard()
    }
}

private struct SyncStatusCard: View {
    let summary: DataUsageSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            CardHeader(icon: "arrow.triangle.2.circlepath", title: "Router Sync") {
                if let syncDate = summary.lastSuccessfulSyncAt {
                    Text(syncDate, style: .relative)
                        .font(.caption.weight(.semibold))
                        .foregroundColor(.secondary)
                }
            }

            if let syncDate = summary.lastSuccessfulSyncAt {
                Text("Last successful check: \(syncDate.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else {
                Text("No successful router check has been recorded yet.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            if summary.missingHistoryDayCount > 0 {
                if hasPartialTodayUsage {
                    Label(
                        "Today is partial; \(incompletePreviousDayCount) of the previous 6 days incomplete",
                        systemImage: "exclamationmark.circle.fill"
                    )
                    .font(.caption.weight(.medium))
                    .foregroundColor(.orange)
                } else {
                    Label(
                        "No complete reading for \(summary.missingHistoryDayCount) of the last 7 days",
                        systemImage: "exclamationmark.circle.fill"
                    )
                    .font(.caption.weight(.medium))
                    .foregroundColor(.orange)
                }
            } else {
                Label("Daily history has readings for the last 7 days", systemImage: "checkmark.circle.fill")
                    .font(.caption.weight(.medium))
                    .foregroundColor(.green)
            }

            Text("The iPhone checks the router while LinkWave is active. A long gap can leave the daily split incomplete.")
                .font(.caption2)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .liquidGlassCard()
        .accessibilityElement(children: .combine)
    }

    private var hasPartialTodayUsage: Bool {
        let hasTraffic = summary.todayDownloadBytes > 0 || summary.todayUploadBytes > 0
        guard hasTraffic,
              let today = summary.dailyHistory.first(where: { Calendar.current.isDateInToday($0.date) }) else {
            return false
        }
        return today.totalBytes == nil
    }

    private var incompletePreviousDayCount: Int {
        max(0, summary.missingHistoryDayCount - (hasPartialTodayUsage ? 1 : 0))
    }
}

private struct UsageTotalsCard: View {
    let summary: DataUsageSummary

    var body: some View {
        VStack(spacing: 10) {
            HStack {
                Label("Data Usage", systemImage: "arrow.up.arrow.down.circle")
                    .font(.headline)
                Spacer()
                Text("UNLIMITED PLAN")
                    .font(.caption2.weight(.bold))
                    .foregroundColor(.secondary)
            }

            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text(Self.format(Self.total(summary.monthDownloadBytes, summary.monthUploadBytes)))
                    .font(.system(.largeTitle, design: .rounded).weight(.bold))
                    .monospacedDigit()
                Text("this month")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer(minLength: 0)
            }

            HStack {
                Text("Period")
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text("Download")
                    .frame(maxWidth: .infinity, alignment: .trailing)
                Text("Upload")
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .font(.caption2.weight(.medium))
            .foregroundColor(.secondary)

            usageRow("Today", download: summary.todayDownloadBytes, upload: summary.todayUploadBytes)
            usageRow("This month", download: summary.monthDownloadBytes, upload: summary.monthUploadBytes)
            usageRow("Since tracking", download: summary.totalDownloadBytes, upload: summary.totalUploadBytes)

            Text("Totals start from the first counter check. Long sync gaps or router counter resets can affect date allocation.")
                .font(.caption2)
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .liquidGlassCard()
        .accessibilityElement(children: .combine)
    }

    private func usageRow(_ title: String, download: UInt64, upload: UInt64) -> some View {
        HStack {
            Text(title)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(Self.format(download))
                .frame(maxWidth: .infinity, alignment: .trailing)
            Text(Self.format(upload))
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .font(.subheadline.monospacedDigit())
    }

    private static func total(_ download: UInt64, _ upload: UInt64) -> UInt64 {
        let (total, overflow) = download.addingReportingOverflow(upload)
        return overflow ? UInt64.max : total
    }

    private static func format(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: bytes), countStyle: .file)
    }
}

private struct DailyUsageHistoryCard: View {
    let points: [DailyUsagePoint]
    let todayDownloadBytes: UInt64
    let todayUploadBytes: UInt64
    let missingDayCount: Int

    private var maximumBytes: Double {
        max(1, Double(points.compactMap { barBytes(for: $0) }.max() ?? 0))
    }

    private var todayTotalBytes: UInt64 {
        let (total, overflow) = todayDownloadBytes.addingReportingOverflow(todayUploadBytes)
        return overflow ? UInt64.max : total
    }

    private var hasPartialTodayUsage: Bool {
        todayTotalBytes > 0
            && points.contains { Calendar.current.isDateInToday($0.date) && $0.totalBytes == nil }
    }

    private func barBytes(for point: DailyUsagePoint) -> UInt64? {
        if let total = point.totalBytes { return total }
        if Calendar.current.isDateInToday(point.date), todayTotalBytes > 0 { return todayTotalBytes }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            CardHeader(icon: "chart.bar.fill", title: "Daily Usage") {
                Text("Last 7 days")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            if points.isEmpty {
                Text("Daily history will appear after the router has been checked.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else {
                HStack(alignment: .bottom, spacing: 7) {
                    ForEach(points) { point in
                        dayBar(point)
                    }
                }
                .frame(height: 138)
            }

            if hasPartialTodayUsage {
                Text("Today’s bar shows recorded usage so far. Blank bars are days without a complete reading.")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            } else if missingDayCount > 0 {
                Text("Blank days have no complete reading. If the app missed a long interval, the router can provide the overall counter change, but it cannot split that amount accurately by day.")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .liquidGlassCard()
    }

    private func dayBar(_ point: DailyUsagePoint) -> some View {
        let displayedBytes = barBytes(for: point)
        return VStack(spacing: 6) {
            GeometryReader { geometry in
                ZStack(alignment: .bottom) {
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(Color.secondary.opacity(0.1))

                    if let total = displayedBytes {
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(Color.accentColor)
                            .frame(height: total == 0 ? 3 : max(3, geometry.size.height * CGFloat(Double(total) / maximumBytes)))
                    } else {
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .stroke(Color.secondary.opacity(0.45), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                            .overlay {
                                Text("–")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }
                    }
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(point.date.formatted(date: .complete, time: .omitted))
            .accessibilityValue(accessibilityValue(for: point, displayedBytes: displayedBytes))

            Text(point.label)
                .font(.caption2)
                .foregroundColor(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity)
    }

    private func accessibilityValue(for point: DailyUsagePoint, displayedBytes: UInt64?) -> String {
        guard let displayedBytes else { return "No complete reading" }
        let value = Self.format(displayedBytes)
        return Calendar.current.isDateInToday(point.date) && point.totalBytes == nil
            ? "\(value) so far, partial today"
            : value
    }

    private static func format(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: bytes), countStyle: .file)
    }
}


import Charts
import SwiftUI

public struct UsageTabView: View {
    @ObservedObject var viewModel: MonitorViewModel
    @ObservedObject var settings: SettingsStore
    @Environment(\.linkWaveThemePalette) private var palette
    @State private var showSettings = false
    @State private var selectedUsageDay = Calendar.current.startOfDay(for: Date())
    @State private var selectedUsageMonth = Calendar.current.dateInterval(of: .month, for: Date())?.start ?? Calendar.current.startOfDay(for: Date())

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
                        UsageForecastCard(
                            forecast: selectedMonthForecast,
                            onInspect: { date in
                                selectedUsageMonth = Calendar.current.dateInterval(of: .month, for: date)?.start ?? date
                                selectedUsageDay = Calendar.current.startOfDay(for: date)
                            }
                        )
                        DailyUsageHistoryCard(
                            history: settings.dataUsageSummary.historicalDailyHistory,
                            todayDownloadBytes: settings.dataUsageSummary.todayDownloadBytes,
                            todayUploadBytes: settings.dataUsageSummary.todayUploadBytes,
                            selectedDate: $selectedUsageDay,
                            selectedMonth: $selectedUsageMonth,
                            onLocalDayRollover: { settings.refreshUsageSummaryForCurrentLocalDay() }
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
            .alwaysScrollBounce()
            .refreshable { await viewModel.refreshAll(forceReauthIfNeeded: true) }
            .navigationTitle("Usage")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                StandaloneTopBarTrailingItem(
                    content: AnyView(RouterRefreshToolbarButton(viewModel: viewModel, isEnabled: settings.isConfigured))
                )
            }
            .navigationDestination(isPresented: $showSettings) {
                SettingsTabView(viewModel: viewModel)
                    .toolbar(.hidden, for: .tabBar)
            }
        }
        .onChange(of: showSettings) { isPresented in
            if !isPresented { viewModel.settingsDidDismiss() }
        }
    }

    private var selectedMonthForecast: UsageForecast {
        NetworkInsightsAnalyzer.forecast(
            history: settings.dataUsageSummary.historicalDailyHistory,
            selectedMonth: selectedUsageMonth,
            todayDownloadBytes: settings.dataUsageSummary.todayDownloadBytes,
            todayUploadBytes: settings.dataUsageSummary.todayUploadBytes
        )
    }

    private var noRouterCard: some View {
        VStack(spacing: 12) {
            Image(systemName: "arrow.up.arrow.down.circle")
                .font(.system(size: 36))
                .foregroundColor(palette.textAccent)
                .accessibilityHidden(true)
            Text("Usage tracking needs a router")
                .font(.headline)
            Text("Add a router in Settings to see downloaded and uploaded data.")
                .font(.subheadline)
                .linkWaveText(.secondary)
                .multilineTextAlignment(.center)
            Button("Open Settings") { showSettings = true }
                .liquidGlassActionButton()
        }
        .frame(maxWidth: .infinity)
        .linkWaveGlassCard()
    }
}

private struct UsageForecastCard: View {
    let forecast: UsageForecast
    let onInspect: (Date) -> Void
    @Environment(\.linkWaveThemePalette) private var palette

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                CardHeader(icon: "chart.line.uptrend.xyaxis", title: "Usage Forecast") {
                    Text("\(forecast.activeReadingDayCount) reading day\(forecast.activeReadingDayCount == 1 ? "" : "s")")
                        .font(.caption2.weight(.medium))
                        .monospacedDigit()
                        .linkWaveText(.secondary)
                }
            }

            HStack(alignment: .top, spacing: 8) {
                forecastMetric("Daily Average", value: formatGB(forecast.dailyAverageGb))
                forecastMetric("Projected Month", value: formatGB(forecast.projectedMonthGb))
                forecastMetric("Peak Day", value: peakDayText)
            }

            if let spike = forecast.spikeDays.first {
                HStack(alignment: .center, spacing: 9) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Spike Detected")
                            .font(.subheadline.weight(.semibold))
                        Text("\(spike.date.formatted(.dateTime.month(.abbreviated).day())) · \(formatGB(spike.totalGb)) · \(String(format: "%.2f×", spike.multiplier)) average")
                            .font(.caption.monospacedDigit())
                            .linkWaveText(.secondary)
                            .lineLimit(2)
                    }
                    Spacer(minLength: 4)
                    Button {
                        onInspect(spike.date)
                    } label: {
                        Text("Inspect \(spike.date.formatted(.dateTime.month(.abbreviated).day()))")
                            .font(.caption.weight(.semibold))
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }
                    .frame(minHeight: 44)
                    .liquidGlassSmallButton()
                }
                .padding(.top, 2)
            }

            Text(forecast.paceNote)
                .font(.caption)
                .linkWaveText(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .linkWaveGlassCard()
        .accessibilityElement(children: .contain)
    }

    private var peakDayText: String {
        guard let peak = forecast.peakDay else { return "--" }
        return "\(formatGB(peak.totalGb)) · \(peak.date.formatted(.dateTime.month(.abbreviated).day()))"
    }

    private func forecastMetric(_ title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.caption2)
                .linkWaveText(.secondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            Text(value)
                .font(.system(.subheadline, design: .rounded).weight(.semibold))
                .monospacedDigit()
                .lineLimit(2)
                .minimumScaleFactor(0.78)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func formatGB(_ value: Double?) -> String {
        guard let value else { return "--" }
        return String(format: "%.2f GB", value)
    }

    private func formatGB(_ value: Double) -> String {
        String(format: "%.2f GB", value)
    }
}

private struct SyncStatusCard: View {
    let summary: DataUsageSummary
    @Environment(\.linkWaveThemePalette) private var palette

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            CardHeader(icon: "arrow.triangle.2.circlepath", title: "Router Sync") { EmptyView() }

            if let syncDate = summary.lastSuccessfulSyncAt {
                Text("Last successful check: \(syncDate.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption)
                    .linkWaveText(.secondary)
            } else {
                Text("No successful router check has been recorded yet.")
                    .font(.caption)
                    .linkWaveText(.secondary)
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
                    .foregroundColor(palette.textAccent)
            }

            Text("The iPhone checks the router while LinkWave is active. A long gap can leave the daily split incomplete.")
                .font(.caption2)
                .linkWaveText(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .linkWaveGlassCard()
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
                    .linkWaveText(.secondary)
            }

            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text(Self.format(Self.total(summary.monthDownloadBytes, summary.monthUploadBytes)))
                    .font(.system(.largeTitle, design: .rounded).weight(.bold))
                    .monospacedDigit()
                Text("this month")
                    .font(.caption)
                    .linkWaveText(.secondary)
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
            .linkWaveText(.secondary)

            usageRow("Today", download: summary.todayDownloadBytes, upload: summary.todayUploadBytes)
            usageRow("This month", download: summary.monthDownloadBytes, upload: summary.monthUploadBytes)
            usageRow("Since tracking", download: summary.totalDownloadBytes, upload: summary.totalUploadBytes)

            Text("Totals start from the first counter check. Long sync gaps or router counter resets can affect date allocation.")
                .font(.caption2)
                .linkWaveText(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .linkWaveGlassCard()
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
    let history: [DailyUsagePoint]
    let todayDownloadBytes: UInt64
    let todayUploadBytes: UInt64
    let onLocalDayRollover: () -> Void
    @Binding var selectedDate: Date
    @Binding var selectedMonth: Date
    @Environment(\.linkWaveThemePalette) private var palette

    private var calendar: Calendar { Calendar.current }

    private var currentMonth: Date {
        calendar.dateInterval(of: .month, for: Date())?.start ?? calendar.startOfDay(for: Date())
    }

    private var selectedMonthStart: Date {
        calendar.dateInterval(of: .month, for: selectedMonth)?.start ?? currentMonth
    }

    private var monthOptions: [Date] {
        let recordedMonths = history.compactMap { calendar.dateInterval(of: .month, for: $0.date)?.start }
        return Array(Set(recordedMonths + [currentMonth])).sorted(by: >)
    }

    private var monthPoints: [DailyUsagePoint] {
        points(in: selectedMonthStart)
    }

    private func points(in month: Date) -> [DailyUsagePoint] {
        guard let range = calendar.range(of: .day, in: .month, for: month) else { return [] }
        let historyByDate = Dictionary(uniqueKeysWithValues: history.map {
            (calendar.startOfDay(for: $0.date), $0)
        })
        return range.compactMap { dayNumber in
            guard let date = calendar.date(byAdding: .day, value: dayNumber - 1, to: month) else { return nil }
            let saved = historyByDate[date]
            let isToday = calendar.isDateInToday(date)
            let hasTodayUsage = todayDownloadBytes > 0 || todayUploadBytes > 0
            return DailyUsagePoint(
                date: date,
                label: String(dayNumber),
                downloadBytes: isToday && hasTodayUsage ? todayDownloadBytes : saved?.downloadBytes,
                uploadBytes: isToday && hasTodayUsage ? todayUploadBytes : saved?.uploadBytes,
                isPartial: saved?.isPartial ?? (isToday && hasTodayUsage)
            )
        }
    }

    private var selectedPoint: DailyUsagePoint? {
        monthPoints.first { calendar.isDate($0.date, inSameDayAs: selectedDate) }
    }

    private var chartTopGB: Double {
        let maximumGB = Double(monthPoints.compactMap(\.totalBytes).max() ?? 0) / 1_000_000_000
        return max(20, ceil((maximumGB * 1.15) / 10) * 10)
    }

    private var axisLabels: (String, String, String) {
        let month = selectedMonthStart.formatted(.dateTime.month(.abbreviated))
        let lastDay = monthPoints.count
        return ("1 \(month)", "15 \(month)", "\(lastDay) \(month)")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            CardHeader(icon: "chart.bar.fill", title: "Daily Usage") {
                monthMenu
            }

            monthlyChart
            selectedUsageDetails
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .linkWaveGlassCard()
        .onAppear {
            onLocalDayRollover()
        }
        .onChange(of: currentMonth) { newMonth in
            selectedMonth = newMonth
            selectedDate = calendar.startOfDay(for: Date())
        }
        .task {
            while !Task.isCancelled {
                let now = Date()
                let startOfToday = calendar.startOfDay(for: now)
                guard let nextDay = calendar.date(byAdding: .day, value: 1, to: startOfToday) else { return }
                let delay = max(1, nextDay.timeIntervalSince(now) + 0.5)
                do {
                    try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                } catch {
                    return
                }
                onLocalDayRollover()
                selectedMonth = currentMonth
                selectedDate = calendar.startOfDay(for: Date())
            }
        }
    }

    private var monthMenu: some View {
        let index = monthOptions.firstIndex(where: {
            calendar.isDate($0, equalTo: selectedMonthStart, toGranularity: .month)
        }) ?? 0
        let earlierMonth = monthOptions.indices.contains(index + 1) ? monthOptions[index + 1] : nil
        let laterMonth = index > 0 ? monthOptions[index - 1] : nil

        return HStack(spacing: 8) {
            Button {
                if let earlierMonth { selectMonth(earlierMonth) }
            } label: {
                Image(systemName: "chevron.left")
                    .font(.caption.weight(.semibold))
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .disabled(earlierMonth == nil)
            .accessibilityLabel("Previous month")

            Text(selectedMonthStart.formatted(.dateTime.month(.wide).year()))
                .font(.caption.weight(.medium))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .fixedSize(horizontal: true, vertical: false)

            Button {
                if let laterMonth { selectMonth(laterMonth) }
            } label: {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .disabled(laterMonth == nil)
            .accessibilityLabel("Next month")
        }
        .buttonStyle(.plain)
        .foregroundStyle(palette.textSecondary.color)
        .padding(.horizontal, 4)
        .padding(.vertical, 2)
        .background(
            palette.backgroundTertiary.opacity(0.42),
            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
        )
        .accessibilityElement(children: .contain)
    }

    private func selectMonth(_ month: Date) {
        let monthStart = calendar.dateInterval(of: .month, for: month)?.start ?? currentMonth
        selectedMonth = monthStart
        if calendar.isDate(monthStart, equalTo: currentMonth, toGranularity: .month) {
            selectedDate = calendar.startOfDay(for: Date())
        } else if let mostRecentUsage = points(in: monthStart).last(where: { ($0.totalBytes ?? 0) > 0 }) {
            selectedDate = mostRecentUsage.date
        } else {
            selectedDate = points(in: monthStart).last?.date ?? monthStart
        }
    }

    private var monthlyChart: some View {
        VStack(spacing: 2) {
            Chart {
                ForEach(monthPoints) { point in
                    let totalGB = Double(point.totalBytes ?? 0) / 1_000_000_000
                    let baselineCapGB = chartTopGB * 0.018
                    let isRecorded = point.totalBytes != nil
                    let plottedValue = isRecorded ? max(totalGB, baselineCapGB) : baselineCapGB
                    let isSelected = calendar.isDate(point.date, inSameDayAs: selectedDate)
                    let dayCenter = calendar.date(bySettingHour: 12, minute: 0, second: 0, of: point.date) ?? point.date

                    BarMark(
                        x: .value("Day", dayCenter, unit: .day),
                        yStart: .value("Baseline", 0),
                        yEnd: .value("Usage", plottedValue),
                        width: .fixed(7)
                    )
                    .foregroundStyle(
                        isRecorded
                            ? palette.textAccent.opacity(isSelected ? 1 : 0.62)
                            : palette.textTertiary.color.opacity(0.38)
                    )
                }

                let selectedDayCenter = calendar.date(bySettingHour: 12, minute: 0, second: 0, of: selectedDate) ?? selectedDate
                RuleMark(x: .value("Selected day", selectedDayCenter, unit: .day))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    .foregroundStyle(palette.textAccent.opacity(0.8))
            }
            .chartXScale(domain: selectedMonthStart...monthEnd)
            .chartYScale(domain: 0...chartTopGB)
            .chartXAxis(.hidden)
            .chartYAxis {
                AxisMarks(position: .trailing, values: [0, chartTopGB / 2, chartTopGB]) { value in
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 0.75, dash: [2, 3]))
                        .foregroundStyle(palette.textSecondary.color.opacity(0.28))
                    AxisValueLabel {
                        if let amount = value.as(Double.self) {
                            Text("\(Int(amount.rounded())) GB")
                                .font(.system(size: 9, weight: .medium))
                                .monospacedDigit()
                                .foregroundStyle(palette.textSecondary.color)
                        }
                    }
                }
            }
            .chartOverlay { proxy in
                GeometryReader { geometry in
                    if #available(iOS 17.0, *) {
                        if let plotFrame = proxy.plotFrame {
                            chartScrubOverlay(proxy: proxy, geometry: geometry, frame: plotFrame)
                        }
                    } else {
                        chartScrubOverlay(proxy: proxy, geometry: geometry, frame: proxy.plotAreaFrame)
                    }
                }
            }
            .frame(height: 138)
            .modifier(UsageChartSelectionFeedback(selectedDay: selectedDate))
            monthAxisLabels
        }
        .padding(.bottom, 4)
    }

    private func chartScrubOverlay(
        proxy: ChartProxy,
        geometry: GeometryProxy,
        frame: Anchor<CGRect>
    ) -> some View {
        let plotRect = geometry[frame]
        return Rectangle()
            .fill(Color.clear)
            .contentShape(Rectangle())
            .frame(width: plotRect.width, height: plotRect.height)
            .position(x: plotRect.midX, y: plotRect.midY)
            .simultaneousGesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let distance = hypot(value.translation.width, value.translation.height)
                        if distance > 5 && abs(value.translation.width) < abs(value.translation.height) {
                            return
                        }
                        let plotX = min(max(value.location.x, 0), plotRect.width)
                        guard let date = proxy.value(atX: plotX, as: Date.self) else { return }
                        selectNearestDay(to: date)
                    }
            )
            .accessibilityLabel("Daily usage chart. Touch or drag horizontally to select a day.")
    }

    private var monthEnd: Date {
        calendar.date(byAdding: .day, value: max(1, monthPoints.count), to: selectedMonthStart) ?? selectedMonthStart
    }

    private var monthAxisLabels: some View {
        HStack(spacing: 5) {
            Text(axisLabels.0).frame(maxWidth: .infinity, alignment: .leading)
            Text(axisLabels.1).frame(maxWidth: .infinity, alignment: .center)
            Text(axisLabels.2).frame(maxWidth: .infinity, alignment: .trailing)
            Color.clear.frame(width: 42)
        }
        .font(.system(size: 9, weight: .medium))
        .monospacedDigit()
        .linkWaveText(.secondary)
        .accessibilityHidden(true)
    }

    private func selectNearestDay(to date: Date) {
        guard !monthPoints.isEmpty else { return }
        let index = monthPoints.indices.min { lhs, rhs in
            abs(monthPoints[lhs].date.timeIntervalSince(date)) < abs(monthPoints[rhs].date.timeIntervalSince(date))
        } ?? 0
        selectedDate = monthPoints[index].date
    }

    private var selectedUsageDetails: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 7) {
                Text(selectedDate.formatted(date: .long, time: .omitted))
                    .font(.subheadline.weight(.semibold))
                if selectedPoint?.isPartial == true && selectedPoint?.totalBytes != nil {
                    Text("Partial")
                        .font(.caption2.weight(.medium))
                        .linkWaveText(.secondary)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(palette.textTertiary.color.opacity(0.18), in: Capsule())
                }
            }

            Text(hasSelectedReading ? " " : "No reading recorded")
                .font(.caption)
                .linkWaveText(.secondary)
                .frame(height: 14, alignment: .leading)

            HStack(spacing: 8) {
                usageValue("Download", bytes: selectedPoint?.downloadBytes)
                usageValue("Upload", bytes: selectedPoint?.uploadBytes)
                usageValue("Total", bytes: selectedPoint?.totalBytes)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 2)
    }

    private func usageValue(_ title: String, bytes: UInt64?) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.caption2)
                .linkWaveText(.secondary)
            Text(bytes.map(Self.format) ?? "0.00 GB")
                .font(.caption.weight(.semibold).monospacedDigit())
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var hasSelectedReading: Bool { selectedPoint?.totalBytes != nil }

    private static func format(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: bytes), countStyle: .file)
    }
}

private struct UsageChartSelectionFeedback: ViewModifier {
    let selectedDay: Date

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 17.0, *) {
            content.sensoryFeedback(.selection, trigger: selectedDay)
        } else {
            content
        }
    }
}

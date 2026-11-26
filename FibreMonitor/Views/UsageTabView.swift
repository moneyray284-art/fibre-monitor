import Charts
import SwiftUI

private struct UsageMonthSummary: Identifiable, Equatable {
    let monthStart: Date
    let downloadBytes: UInt64
    let uploadBytes: UInt64
    let activeDaysCount: Int

    var id: Date { monthStart }

    var totalBytes: UInt64 {
        let (total, overflow) = downloadBytes.addingReportingOverflow(uploadBytes)
        return overflow ? UInt64.max : total
    }

    var downloadGB: Double { Double(downloadBytes) / 1_000_000_000 }
    var uploadGB: Double { Double(uploadBytes) / 1_000_000_000 }
    var totalGB: Double { Double(totalBytes) / 1_000_000_000 }

    static func previousMonths(
        from history: [DailyUsagePoint],
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> [UsageMonthSummary] {
        let currentMonth = calendar.dateInterval(of: .month, for: now)?.start ?? calendar.startOfDay(for: now)
        let recordedPoints = history.filter {
            $0.date < currentMonth && ($0.totalBytes ?? 0) > 0
        }
        let grouped = Dictionary(grouping: recordedPoints) {
            calendar.dateInterval(of: .month, for: $0.date)?.start ?? calendar.startOfDay(for: $0.date)
        }

        return grouped.map { monthStart, points in
            UsageMonthSummary(
                monthStart: monthStart,
                downloadBytes: sum(points.compactMap(\.downloadBytes)),
                uploadBytes: sum(points.compactMap(\.uploadBytes)),
                activeDaysCount: points.count
            )
        }
        .sorted { $0.monthStart > $1.monthStart }
    }

    private static func sum(_ values: [UInt64]) -> UInt64 {
        values.reduce(0) { total, value in
            let (next, overflow) = total.addingReportingOverflow(value)
            return overflow ? UInt64.max : next
        }
    }
}

private struct UsageScreenDerivedData {
    var previousMonths: [UsageMonthSummary]
    var selectedMonthSummary: UsageMonthSummary?
    var forecast: UsageForecast

    static func make(summary: DataUsageSummary, selectedMonth: Date) -> UsageScreenDerivedData {
        let previousMonths = UsageMonthSummary.previousMonths(from: summary.historicalDailyHistory)
        let current = matchingMonth(in: previousMonths, selectedMonth: selectedMonth)
        let forecast = NetworkInsightsAnalyzer.forecast(
            history: summary.historicalDailyHistory,
            selectedMonth: selectedMonth,
            todayDownloadBytes: summary.todayDownloadBytes,
            todayUploadBytes: summary.todayUploadBytes
        )
        return UsageScreenDerivedData(
            previousMonths: previousMonths,
            selectedMonthSummary: current,
            forecast: forecast
        )
    }

    static func matchingMonth(in months: [UsageMonthSummary], selectedMonth: Date) -> UsageMonthSummary? {
        let calendar = Calendar.current
        return months.first {
            calendar.isDate($0.monthStart, equalTo: selectedMonth, toGranularity: .month)
        }
    }
}

public struct UsageTabView: View {
    @ObservedObject var viewModel: MonitorViewModel
    @ObservedObject var settings: SettingsStore
    @Environment(\.linkWaveThemePalette) private var palette
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var showSettings = false
    @State private var selectedUsageDay: Date
    @State private var selectedUsageMonth: Date
    @State private var derivedData: UsageScreenDerivedData

    public init(viewModel: MonitorViewModel) {
        self.viewModel = viewModel
        self.settings = viewModel.settings
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let currentMonth = calendar.dateInterval(of: .month, for: today)?.start ?? today
        _selectedUsageDay = State(initialValue: today)
        _selectedUsageMonth = State(initialValue: currentMonth)
        _derivedData = State(initialValue: UsageScreenDerivedData.make(
            summary: viewModel.settings.dataUsageSummary,
            selectedMonth: currentMonth
        ))
    }

    public var body: some View {
        NavigationStack {
            ScrollViewReader { scrollProxy in
                ScrollView {
                    VStack(spacing: 14) {
                        if settings.isConfigured {
                            SyncStatusCard(
                                summary: settings.dataUsageSummary,
                                isChecking: viewModel.isRefreshing,
                                checkNow: { Task { await viewModel.refreshAll(forceReauthIfNeeded: true) } }
                            )
                            UsageAnalyticsHeroCard(
                                summary: settings.dataUsageSummary,
                                selectedMonthSummary: selectedMonthSummary,
                                history: settings.dataUsageSummary.historicalDailyHistory,
                                historyRevision: settings.usageHistoryRevision,
                                todayDownloadBytes: settings.dataUsageSummary.todayDownloadBytes,
                                todayUploadBytes: settings.dataUsageSummary.todayUploadBytes,
                                onLocalDayRollover: { settings.refreshUsageSummaryForCurrentLocalDay() },
                                selectedDate: $selectedUsageDay,
                                selectedMonth: $selectedUsageMonth,
                                onBackToCurrentMonth: { selectUsageMonth(Date()) }
                            )
                            .id("usage-chart")

                            supportCards(scrollProxy: scrollProxy)
                        } else {
                            noRouterCard
                        }
                    }
                    .padding(.horizontal)
                    .padding(.top, 8)
                    .padding(.bottom, 24)
                }
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
        .onChange(of: settings.usageHistoryRevision) { _ in
            refreshHistoricalDerivedData()
        }
        .onChange(of: selectedUsageMonth) { month in
            derivedData.selectedMonthSummary = UsageScreenDerivedData.matchingMonth(
                in: derivedData.previousMonths,
                selectedMonth: month
            )
            refreshForecast()
        }
    }

    @ViewBuilder
    private func supportCards(scrollProxy: ScrollViewProxy) -> some View {
        let forecastCard = UsageForecastCard(
            forecast: selectedMonthForecast,
            selectedMonth: selectedUsageMonth,
            selectedMonthTotalGB: selectedMonthSummary?.totalGB,
            onInspect: { date in
                selectedUsageMonth = Calendar.current.dateInterval(of: .month, for: date)?.start ?? date
                selectedUsageDay = Calendar.current.startOfDay(for: date)
                withAnimation(.easeInOut(duration: 0.28)) {
                    scrollProxy.scrollTo("usage-chart", anchor: .top)
                }
            }
        )
        let periodCard = PeriodBreakdownCard(
            summary: settings.dataUsageSummary,
            selectedMonth: selectedUsageMonth,
            selectedMonthSummary: selectedMonthSummary,
            previousMonths: previousMonthSummaries,
            onSelectMonth: selectUsageMonth
        )

        if horizontalSizeClass == .regular {
            HStack(alignment: .top, spacing: 14) {
                forecastCard.frame(maxWidth: .infinity, alignment: .top)
                periodCard.frame(maxWidth: .infinity, alignment: .top)
            }
        } else {
            VStack(spacing: 14) {
                forecastCard
                periodCard
            }
        }
    }

    private var selectedMonthForecast: UsageForecast {
        derivedData.forecast
    }

    private var previousMonthSummaries: [UsageMonthSummary] {
        derivedData.previousMonths
    }

    private var selectedMonthSummary: UsageMonthSummary? {
        derivedData.selectedMonthSummary
    }

    private func refreshHistoricalDerivedData() {
        derivedData.previousMonths = UsageMonthSummary.previousMonths(
            from: settings.dataUsageSummary.historicalDailyHistory
        )
        derivedData.selectedMonthSummary = UsageScreenDerivedData.matchingMonth(
            in: derivedData.previousMonths,
            selectedMonth: selectedUsageMonth
        )
        refreshForecast()
    }

    private func refreshForecast() {
        let summary = settings.dataUsageSummary
        derivedData.forecast = NetworkInsightsAnalyzer.forecast(
            history: summary.historicalDailyHistory,
            selectedMonth: selectedUsageMonth,
            todayDownloadBytes: summary.todayDownloadBytes,
            todayUploadBytes: summary.todayUploadBytes
        )
    }

    private func selectUsageMonth(_ month: Date) {
        let calendar = Calendar.current
        let monthStart = calendar.dateInterval(of: .month, for: month)?.start ?? month
        let currentMonth = calendar.dateInterval(of: .month, for: Date())?.start ?? calendar.startOfDay(for: Date())
        selectedUsageMonth = monthStart

        if calendar.isDate(monthStart, equalTo: currentMonth, toGranularity: .month) {
            selectedUsageDay = calendar.startOfDay(for: Date())
            return
        }

        let recordedDays = settings.dataUsageSummary.historicalDailyHistory.filter {
            calendar.isDate($0.date, equalTo: monthStart, toGranularity: .month) && ($0.totalBytes ?? 0) > 0
        }
        selectedUsageDay = recordedDays.max(by: { $0.date < $1.date })?.date ?? monthStart
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
    let selectedMonth: Date
    let selectedMonthTotalGB: Double?
    let onInspect: (Date) -> Void
    @Environment(\.linkWaveThemePalette) private var palette

    private var isCurrentMonth: Bool {
        Calendar.current.isDate(selectedMonth, equalTo: Date(), toGranularity: .month)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            CardHeader(icon: "chart.line.uptrend.xyaxis", title: isCurrentMonth ? "Usage Forecast" : "Monthly Summary") {
                Text(selectedMonth.formatted(.dateTime.month(.abbreviated)))
                    .font(.caption2.monospacedDigit())
                    .linkWaveText(.secondary)
            }

            HStack(alignment: .top, spacing: 8) {
                forecastMetric("Daily Average", value: formatGB(forecast.dailyAverageGb))
                LinkWaveHairlineDivider()
                    .frame(width: 0.5, height: 48)
                forecastMetric(
                    isCurrentMonth ? "Projected Month" : "Month Total",
                    value: isCurrentMonth ? formatGB(forecast.projectedMonthGb) : formatGB(selectedMonthTotalGB)
                )
                LinkWaveHairlineDivider()
                    .frame(width: 0.5, height: 48)
                forecastMetric("Peak Day", value: peakDayValue, subtitle: peakDayDate)
            }

            if let spike = forecast.spikeDays.first {
                HStack(alignment: .center, spacing: 9) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .accessibilityHidden(true)
                    Text("Spike (\(String(format: "%.1f×", spike.multiplier))) · \(spike.date.formatted(.dateTime.month(.abbreviated).day())) (\(formatGB(spike.totalGb)))")
                        .font(.caption.monospacedDigit())
                        .lineLimit(1)
                        .minimumScaleFactor(0.72)
                    Spacer(minLength: 4)
                    Button {
                        onInspect(spike.date)
                    } label: {
                        Text("Inspect")
                            .font(.caption.weight(.semibold))
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }
                    .frame(minHeight: 44)
                    .liquidGlassSmallButton()
                }
                .padding(.top, 2)
            }

            LinkWaveHairlineDivider()
            Text(forecast.paceNote)
                .font(.caption)
                .linkWaveText(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .linkWaveGlassCard()
        .accessibilityElement(children: .contain)
    }

    private var peakDayValue: String {
        guard let peak = forecast.peakDay else { return "--" }
        return formatGB(peak.totalGb)
    }

    private var peakDayDate: String? {
        forecast.peakDay?.date.formatted(.dateTime.month(.abbreviated).day())
    }

    private func forecastMetric(_ title: String, value: String, subtitle: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.caption2)
                .linkWaveText(.secondary)
                .lineLimit(1)
                .frame(height: 15, alignment: .topLeading)
            Text(value)
                .font(.system(.subheadline, design: .rounded).weight(.semibold))
                .monospacedDigit()
                .tracking(-0.25)
                .lineLimit(1)
                .minimumScaleFactor(0.78)
            Text(subtitle ?? " ")
                .font(.caption2)
                .linkWaveText(.secondary)
                .lineLimit(1)
                .frame(height: 13, alignment: .topLeading)
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
    let isChecking: Bool
    let checkNow: () -> Void
    @Environment(\.linkWaveThemePalette) private var palette
    @State private var showsSyncGapDetails = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text(syncStatus)
                    .font(.caption.weight(.semibold))
                    .monospacedDigit()
                    .lineLimit(1)
                Spacer(minLength: 4)
                Button {
                    showsSyncGapDetails.toggle()
                } label: {
                    Image(systemName: "info.circle")
                        .font(.subheadline)
                        .foregroundStyle(palette.textSecondary.color)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(showsSyncGapDetails ? "Hide sync gap information" : "Show sync gap information")
                Button(isChecking ? "Checking…" : "Check Now", action: checkNow)
                    .font(.caption.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(palette.textAccent)
                    .buttonStyle(.plain)
                    .disabled(isChecking)
            }

            Text("\(activeDayCount) active day\(activeDayCount == 1 ? "" : "s") recorded in \(currentMonth.formatted(.dateTime.month(.abbreviated)))")
                .font(.caption2.monospacedDigit())
                .linkWaveText(.secondary)
                .lineLimit(1)

            if showsSyncGapDetails {
                LinkWaveHairlineDivider()
                Text("The iPhone checks the router while LinkWave is active. A long gap can leave the daily split incomplete.")
                    .font(.caption2)
                    .linkWaveText(.secondary)
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .linkWaveGlassCard()
        .accessibilityElement(children: .contain)
    }

    private var currentMonth: Date {
        Calendar.current.dateInterval(of: .month, for: Date())?.start ?? Date()
    }

    private var activeDayCount: Int {
        summary.historicalDailyHistory.filter {
            Calendar.current.isDate($0.date, equalTo: currentMonth, toGranularity: .month) && $0.totalBytes != nil
        }.count
    }

    private var syncStatus: String {
        guard let syncDate = summary.lastSuccessfulSyncAt else { return "Synced —" }
        return "Synced \(syncDate, style: .relative)"
    }
}

private struct PeriodBreakdownCard: View {
    let summary: DataUsageSummary
    let selectedMonth: Date
    let selectedMonthSummary: UsageMonthSummary?
    let previousMonths: [UsageMonthSummary]
    let onSelectMonth: (Date) -> Void
    @Environment(\.linkWaveThemePalette) private var palette
    @State private var isPreviousMonthsExpanded = false

    private var isCurrentMonth: Bool {
        Calendar.current.isDate(selectedMonth, equalTo: Date(), toGranularity: .month)
    }

    private var selectedMonthDownloadBytes: UInt64 {
        isCurrentMonth ? summary.monthDownloadBytes : (selectedMonthSummary?.downloadBytes ?? 0)
    }

    private var selectedMonthUploadBytes: UInt64 {
        isCurrentMonth ? summary.monthUploadBytes : (selectedMonthSummary?.uploadBytes ?? 0)
    }

    private var selectedMonthTitle: String {
        selectedMonth.formatted(.dateTime.month(.wide).year())
    }

    var body: some View {
        VStack(spacing: 10) {
            CardHeader(icon: "calendar", title: "Period Breakdown") {
                Text(isCurrentMonth ? "This month" : selectedMonth.formatted(.dateTime.month(.abbreviated)))
                    .font(.caption2.monospacedDigit())
                    .linkWaveText(.secondary)
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
            LinkWaveHairlineDivider()
                .padding(.leading, 8)

            if isCurrentMonth {
                usageRow("Today", download: summary.todayDownloadBytes, upload: summary.todayUploadBytes)
                LinkWaveHairlineDivider(leading: 8)
                usageRow("This month", download: summary.monthDownloadBytes, upload: summary.monthUploadBytes)
            } else {
                usageRow(selectedMonthTitle, download: selectedMonthDownloadBytes, upload: selectedMonthUploadBytes)
            }

            if isCurrentMonth && !sinceTrackingMatchesMonth {
                LinkWaveHairlineDivider(leading: 8)
                usageRow("Since tracking", download: summary.totalDownloadBytes, upload: summary.totalUploadBytes)
            }

            if !previousMonths.isEmpty {
                LinkWaveHairlineDivider()
                previousMonthsDrawer
            }
        }
        .linkWaveGlassCard()
        .accessibilityElement(children: .contain)
    }

    private var previousMonthsDrawer: some View {
        VStack(spacing: 0) {
            Button {
                withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) {
                    isPreviousMonthsExpanded.toggle()
                }
            } label: {
                HStack(spacing: 8) {
                    Text("Previous Months")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(palette.textPrimary.color)
                    Spacer(minLength: 6)
                    if let latest = previousMonths.first {
                        Text("\(latest.monthStart.formatted(.dateTime.month(.abbreviated).year())) · \(formatGB(latest.totalBytes))")
                            .font(.caption.monospacedDigit())
                            .linkWaveText(.secondary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.75)
                    }
                    Image(systemName: isPreviousMonthsExpanded ? "chevron.up" : "chevron.down")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(palette.textTertiary.color)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint(isPreviousMonthsExpanded ? "Collapse previous months" : "Show previous months")

            if isPreviousMonthsExpanded {
                VStack(spacing: 0) {
                    ForEach(Array(previousMonths.enumerated()), id: \.element.id) { index, month in
                        previousMonthRow(month)
                        if index < previousMonths.count - 1 {
                            LinkWaveHairlineDivider(leading: 8)
                        }
                    }

                    Text("Only months with synced readings are stored. Tap any month to inspect its daily breakdown.")
                        .font(.caption2)
                        .linkWaveText(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .lineLimit(1)
                        .minimumScaleFactor(0.78)
                        .padding(.top, 9)
                }
                .padding(.top, 8)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    private func previousMonthRow(_ month: UsageMonthSummary) -> some View {
        let isViewing = Calendar.current.isDate(month.monthStart, equalTo: selectedMonth, toGranularity: .month)

        return Button {
            onSelectMonth(month.monthStart)
        } label: {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(month.monthStart.formatted(.dateTime.month(.wide).year()))
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(palette.textPrimary.color)
                            .lineLimit(1)
                        if isViewing {
                            Text("Viewing")
                                .font(.caption2.weight(.medium))
                                .linkWaveText(.secondary)
                        }
                    }
                    Text("↓ \(Self.format(month.downloadBytes)) · ↑ \(Self.format(month.uploadBytes)) · \(month.activeDaysCount) active days")
                        .font(.caption2.monospacedDigit())
                        .linkWaveText(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.72)
                }
                Spacer(minLength: 4)
                HStack(spacing: 6) {
                    Text(formatGB(month.totalBytes))
                        .font(.subheadline.weight(.semibold).monospacedDigit())
                        .foregroundStyle(palette.textPrimary.color)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(palette.textTertiary.color)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 7)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var sinceTrackingMatchesMonth: Bool {
        isWithinDisplayTolerance(summary.totalDownloadBytes, summary.monthDownloadBytes)
            && isWithinDisplayTolerance(summary.totalUploadBytes, summary.monthUploadBytes)
    }

    private func isWithinDisplayTolerance(_ lhs: UInt64, _ rhs: UInt64) -> Bool {
        let difference = lhs >= rhs ? lhs - rhs : rhs - lhs
        return Double(difference) <= 50_000_000
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

    private func formatGB(_ bytes: UInt64) -> String {
        String(format: "%.2f GB", Double(bytes) / 1_000_000_000)
    }
}

private struct DailyUsageChartData {
    let monthPoints: [DailyUsagePoint]
    let monthOptions: [Date]
    let chartTopGB: Double

    static func make(
        history: [DailyUsagePoint],
        todayDownloadBytes: UInt64,
        todayUploadBytes: UInt64,
        selectedMonth: Date,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> DailyUsageChartData {
        let currentMonth = calendar.dateInterval(of: .month, for: now)?.start ?? calendar.startOfDay(for: now)
        let selectedMonthStart = calendar.dateInterval(of: .month, for: selectedMonth)?.start ?? currentMonth
        let monthOptions = Set(history.compactMap { point -> Date? in
            guard point.date < currentMonth, (point.totalBytes ?? 0) > 0 else { return nil }
            return calendar.dateInterval(of: .month, for: point.date)?.start
        } + [currentMonth]).sorted(by: >)

        let historyByDate = Dictionary(
            history.map { (calendar.startOfDay(for: $0.date), $0) },
            uniquingKeysWith: { _, latest in latest }
        )
        let monthPoints: [DailyUsagePoint]
        if let range = calendar.range(of: .day, in: .month, for: selectedMonthStart) {
            let hasTodayUsage = todayDownloadBytes > 0 || todayUploadBytes > 0
            monthPoints = range.compactMap { dayNumber in
                guard let date = calendar.date(byAdding: .day, value: dayNumber - 1, to: selectedMonthStart) else {
                    return nil
                }
                let saved = historyByDate[calendar.startOfDay(for: date)]
                let isToday = calendar.isDateInToday(date)
                return DailyUsagePoint(
                    date: date,
                    label: String(dayNumber),
                    downloadBytes: isToday && hasTodayUsage ? todayDownloadBytes : saved?.downloadBytes,
                    uploadBytes: isToday && hasTodayUsage ? todayUploadBytes : saved?.uploadBytes,
                    isPartial: isToday || saved?.isPartial == true
                )
            }
        } else {
            monthPoints = []
        }

        let maximumGB = Double(monthPoints.compactMap(\.totalBytes).max() ?? 0) / 1_000_000_000
        return DailyUsageChartData(
            monthPoints: monthPoints,
            monthOptions: monthOptions,
            chartTopGB: max(20, ceil((maximumGB * 1.15) / 10) * 10)
        )
    }
}

private struct UsageAnalyticsHeroCard: View {
    let summary: DataUsageSummary
    let selectedMonthSummary: UsageMonthSummary?
    let history: [DailyUsagePoint]
    let historyRevision: Int
    let todayDownloadBytes: UInt64
    let todayUploadBytes: UInt64
    let onLocalDayRollover: () -> Void
    let onBackToCurrentMonth: () -> Void
    @Binding var selectedDate: Date
    @Binding var selectedMonth: Date
    @Environment(\.linkWaveThemePalette) private var palette
    @State private var chartData: DailyUsageChartData
    @State private var showsCounterNote = false

    init(
        summary: DataUsageSummary,
        selectedMonthSummary: UsageMonthSummary?,
        history: [DailyUsagePoint],
        historyRevision: Int,
        todayDownloadBytes: UInt64,
        todayUploadBytes: UInt64,
        onLocalDayRollover: @escaping () -> Void,
        selectedDate: Binding<Date>,
        selectedMonth: Binding<Date>,
        onBackToCurrentMonth: @escaping () -> Void
    ) {
        self.summary = summary
        self.selectedMonthSummary = selectedMonthSummary
        self.history = history
        self.historyRevision = historyRevision
        self.todayDownloadBytes = todayDownloadBytes
        self.todayUploadBytes = todayUploadBytes
        self.onLocalDayRollover = onLocalDayRollover
        self.onBackToCurrentMonth = onBackToCurrentMonth
        self._selectedDate = selectedDate
        self._selectedMonth = selectedMonth
        _chartData = State(initialValue: DailyUsageChartData.make(
            history: history,
            todayDownloadBytes: todayDownloadBytes,
            todayUploadBytes: todayUploadBytes,
            selectedMonth: selectedMonth.wrappedValue
        ))
    }

    private var calendar: Calendar { Calendar.current }

    private var currentMonth: Date {
        calendar.dateInterval(of: .month, for: Date())?.start ?? calendar.startOfDay(for: Date())
    }

    private var selectedMonthStart: Date {
        calendar.dateInterval(of: .month, for: selectedMonth)?.start ?? currentMonth
    }

    private var isCurrentMonth: Bool {
        calendar.isDate(selectedMonthStart, equalTo: currentMonth, toGranularity: .month)
    }

    private var selectedDownloadBytes: UInt64 {
        isCurrentMonth ? summary.monthDownloadBytes : (selectedMonthSummary?.downloadBytes ?? 0)
    }

    private var selectedUploadBytes: UInt64 {
        isCurrentMonth ? summary.monthUploadBytes : (selectedMonthSummary?.uploadBytes ?? 0)
    }

    private var selectedTotalBytes: UInt64 {
        let (total, overflow) = selectedDownloadBytes.addingReportingOverflow(selectedUploadBytes)
        return overflow ? UInt64.max : total
    }

    private var downloadShare: CGFloat {
        guard selectedTotalBytes > 0 else { return 0.5 }
        let raw = CGFloat(Double(selectedDownloadBytes) / Double(selectedTotalBytes))
        return min(0.97, max(0.03, raw))
    }

    private var monthOptions: [Date] {
        chartData.monthOptions
    }

    private var monthPoints: [DailyUsagePoint] {
        chartData.monthPoints
    }

    private var selectedPoint: DailyUsagePoint? {
        monthPoints.first { calendar.isDate($0.date, inSameDayAs: selectedDate) }
    }

    private var chartTopGB: Double {
        chartData.chartTopGB
    }

    private var axisLabels: (String, String, String) {
        let month = selectedMonthStart.formatted(.dateTime.month(.abbreviated))
        let lastDay = monthPoints.count
        return ("1 \(month)", "15 \(month)", "\(lastDay) \(month)")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 7) {
                Image(systemName: "chart.bar.fill")
                    .foregroundStyle(palette.textAccent)
                Text("Data Usage")
                    .font(.subheadline.weight(.bold))
                Button {
                    showsCounterNote.toggle()
                } label: {
                    Image(systemName: "info.circle")
                        .font(.subheadline)
                        .foregroundStyle(palette.textSecondary.color)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(showsCounterNote ? "Hide counter information" : "Show counter information")
                Spacer(minLength: 4)
                monthMenu
            }

            if showsCounterNote {
                Text("Usage is allocated from cumulative router counters and stays available across month changes.")
                    .font(.caption2)
                    .linkWaveText(.secondary)
                    .transition(.opacity)
            }

            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(Self.format(selectedTotalBytes))
                    .font(.system(.largeTitle, design: .rounded).weight(.bold))
                    .monospacedDigit()
                    .tracking(-0.45)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                Text(isCurrentMonth ? "this month" : "in \(selectedMonthStart.formatted(.dateTime.month(.wide).year()))")
                    .font(.caption)
                    .linkWaveText(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }

            if !isCurrentMonth {
                Button("Back to this month", action: onBackToCurrentMonth)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(palette.textAccent)
                    .buttonStyle(.plain)
            }

            proportionalSplit
            splitLegend
            LinkWaveHairlineDivider()
            monthlyChart
            LinkWaveHairlineDivider()
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
        .onChange(of: historyRevision) { _ in rebuildChartData() }
        .onChange(of: selectedMonth) { _ in rebuildChartData() }
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

    private var proportionalSplit: some View {
        GeometryReader { proxy in
            HStack(spacing: 0) {
                Rectangle()
                    .fill(palette.textAccent)
                    .frame(width: proxy.size.width * downloadShare)
                Rectangle()
                    .fill(.green)
                    .frame(width: proxy.size.width * (1 - downloadShare))
            }
            .clipShape(Capsule())
        }
        .frame(height: 6)
        .accessibilityLabel("Download \(Int((downloadShare * 100).rounded())) percent, upload \(Int(((1 - downloadShare) * 100).rounded())) percent")
    }

    private var splitLegend: some View {
        HStack(spacing: 10) {
            legendItem("Download", bytes: selectedDownloadBytes, percentage: downloadShare, tint: palette.textAccent)
            Spacer(minLength: 4)
            legendItem("Upload", bytes: selectedUploadBytes, percentage: 1 - downloadShare, tint: .green)
        }
    }

    private func legendItem(_ title: String, bytes: UInt64, percentage: CGFloat, tint: Color) -> some View {
        HStack(spacing: 4) {
            Circle().fill(tint).frame(width: 6, height: 6)
            Text("\(title) \(Self.format(bytes)) (\(Int((percentage * 100).rounded()))%)")
                .font(.caption2.monospacedDigit())
                .linkWaveText(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.72)
        }
    }

    private func rebuildChartData() {
        chartData = DailyUsageChartData.make(
            history: history,
            todayDownloadBytes: todayDownloadBytes,
            todayUploadBytes: todayUploadBytes,
            selectedMonth: selectedMonth
        )
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
        } else {
            let mostRecentUsage = history
                .filter {
                    calendar.isDate($0.date, equalTo: monthStart, toGranularity: .month)
                        && ($0.totalBytes ?? 0) > 0
                }
                .max(by: { $0.date < $1.date })
            if let mostRecentUsage {
                selectedDate = mostRecentUsage.date
            } else if let dayRange = calendar.range(of: .day, in: .month, for: monthStart),
                      let lastDay = calendar.date(byAdding: .day, value: dayRange.count - 1, to: monthStart) {
                selectedDate = lastDay
            } else {
                selectedDate = monthStart
            }
        }
    }

    private var monthlyChart: some View {
        VStack(spacing: 2) {
            Chart {
                ForEach(monthPoints) { point in
                    let totalGB = Double(point.totalBytes ?? 0) / 1_000_000_000
                    let baselineCapGB = chartTopGB * 0.009
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
                            ? palette.textAccent.opacity(isSelected ? 1 : 0.36)
                            : palette.textTertiary.color.opacity(0.24)
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
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [2, 3]))
                        .foregroundStyle(palette.textSecondary.color.opacity(0.20))
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
            Color.clear.frame(width: 56)
        }
        .font(.system(size: 9, weight: .medium))
        .monospacedDigit()
        .linkWaveText(.secondary)
        .accessibilityHidden(true)
    }

    private func selectNearestDay(to date: Date) {
        guard !monthPoints.isEmpty else { return }
        let dayOffset = calendar.dateComponents([.day], from: selectedMonthStart, to: date).day ?? 0
        let index = min(max(dayOffset, 0), monthPoints.count - 1)
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
                LinkWaveHairlineDivider()
                    .frame(width: 0.5, height: 36)
                usageValue("Upload", bytes: selectedPoint?.uploadBytes)
                LinkWaveHairlineDivider()
                    .frame(width: 0.5, height: 36)
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

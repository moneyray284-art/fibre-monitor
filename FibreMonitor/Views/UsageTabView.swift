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
        let billingCard = BillingHistoryCard(
            summary: settings.dataUsageSummary,
            selectedMonth: selectedUsageMonth,
            previousMonths: previousMonthSummaries,
            onSelectMonth: selectUsageMonth
        )

        if horizontalSizeClass == .regular {
            HStack(alignment: .top, spacing: 14) {
                forecastCard.frame(maxWidth: .infinity, alignment: .top)
                billingCard.frame(maxWidth: .infinity, alignment: .top)
            }
        } else {
            VStack(spacing: 14) {
                forecastCard
                billingCard
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
                Button(action: checkNow) {
                    HStack(spacing: 6) {
                        if isChecking {
                            ProgressView()
                                .controlSize(.small)
                        }
                        Text(isChecking ? "Checking" : "Check Now")
                            .lineLimit(1)
                    }
                    .font(.caption.weight(.semibold).monospacedDigit())
                    .foregroundStyle(palette.textAccent)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(palette.textAccent.opacity(0.10), in: Capsule())
                }
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
        let relativeDate = RelativeDateTimeFormatter().localizedString(for: syncDate, relativeTo: Date())
        return "Synced \(relativeDate)"
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
            HStack(spacing: 10) {
                ZStack {
                    Circle().fill(palette.textAccent.opacity(0.12))
                    Image(systemName: "chart.line.uptrend.xyaxis")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(palette.textAccent)
                }
                .frame(width: 34, height: 34)

                VStack(alignment: .leading, spacing: 2) {
                    Text(isCurrentMonth ? "Usage Forecast" : "Monthly Summary")
                        .font(.subheadline.weight(.bold))
                    Text("\(forecast.completedDayCount) completed day\(forecast.completedDayCount == 1 ? "" : "s") analyzed")
                        .font(.caption2.monospacedDigit())
                        .linkWaveText(.secondary)
                }
                Spacer()
                Text(selectedMonth.formatted(.dateTime.month(.abbreviated)))
                    .font(.caption.weight(.semibold).monospacedDigit())
                    .linkWaveText(.secondary)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 6)
                    .background(palette.backgroundTertiary.opacity(0.55), in: Capsule())
            }

            HStack(spacing: 0) {
                forecastMetric("Daily Avg", formatGB(forecast.dailyAverageGb))
                LinkWaveHairlineDivider().frame(width: 0.5, height: 46)
                forecastMetric(
                    isCurrentMonth ? "Projected" : "Total",
                    isCurrentMonth ? formatGB(forecast.projectedMonthGb) : formatGB(selectedMonthTotalGB),
                    highlighted: true
                )
                LinkWaveHairlineDivider().frame(width: 0.5, height: 46)
                forecastMetric("Peak Day", peakDayValue, subtitle: peakDayDate)
            }

            if let spike = forecast.spikeDays.first {
                HStack(alignment: .center, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Spike \(String(format: "%.1fx", spike.multiplier)) · \(spike.date.formatted(.dateTime.month(.abbreviated).day()))")
                            .font(.caption.weight(.semibold).monospacedDigit())
                        Text(formatGB(spike.totalGb))
                            .font(.caption2.monospacedDigit())
                            .linkWaveText(.secondary)
                    }
                    Spacer(minLength: 4)
                    Button("Inspect →") { onInspect(spike.date) }
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(palette.textAccent)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 7)
                        .background(palette.textAccent.opacity(0.10), in: Capsule())
                        .buttonStyle(.plain)
                }
                .padding(9)
                .background(Color.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }

            LinkWaveHairlineDivider()
            Text(forecast.paceNote)
                .font(.caption.monospacedDigit())
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

    private func forecastMetric(_ title: String, _ value: String, subtitle: String? = nil, highlighted: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption2)
                .linkWaveText(.secondary)
            Text(value)
                .font(.system(.subheadline, design: .rounded).weight(.bold))
                .foregroundStyle(highlighted ? palette.textAccent : palette.textPrimary.color)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.72)
            Text(subtitle ?? " ")
                .font(.caption2.monospacedDigit())
                .linkWaveText(.secondary)
                .frame(height: 13)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 8)
    }

    private func formatGB(_ value: Double?) -> String {
        guard let value else { return "--" }
        return String(format: "%.1f GB", value)
    }
}

private struct BillingHistoryCard: View {
    let summary: DataUsageSummary
    let selectedMonth: Date
    let previousMonths: [UsageMonthSummary]
    let onSelectMonth: (Date) -> Void
    @Environment(\.linkWaveThemePalette) private var palette

    private var isCurrentMonth: Bool {
        Calendar.current.isDate(selectedMonth, equalTo: Date(), toGranularity: .month)
    }

    private var sinceTrackingMatchesMonth: Bool {
        let differenceDown = summary.totalDownloadBytes >= summary.monthDownloadBytes
            ? summary.totalDownloadBytes - summary.monthDownloadBytes
            : summary.monthDownloadBytes - summary.totalDownloadBytes
        let differenceUp = summary.totalUploadBytes >= summary.monthUploadBytes
            ? summary.totalUploadBytes - summary.monthUploadBytes
            : summary.monthUploadBytes - summary.totalUploadBytes
        return Double(differenceDown) <= 50_000_000 && Double(differenceUp) <= 50_000_000
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                ZStack {
                    Circle().fill(palette.textAccent.opacity(0.12))
                    Image(systemName: "arrow.down.arrow.up")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(palette.textAccent)
                }
                .frame(width: 34, height: 34)
                Text("Billing History")
                    .font(.subheadline.weight(.bold))
                Spacer()
                if isCurrentMonth {
                    Text("Today \(formatGB(summary.todayDownloadBytes + summary.todayUploadBytes))")
                        .font(.caption.monospacedDigit())
                        .linkWaveText(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                }
            }

            if isCurrentMonth && !sinceTrackingMatchesMonth {
                BillingRow(
                    title: "Since tracking",
                    downloadBytes: summary.totalDownloadBytes,
                    uploadBytes: summary.totalUploadBytes,
                    activeDays: nil,
                    totalBytes: summary.totalDownloadBytes + summary.totalUploadBytes,
                    isViewing: false,
                    action: nil
                )
                LinkWaveHairlineDivider(leading: 8)
            }

            ForEach(Array(previousMonths.enumerated()), id: \.element.id) { index, month in
                let isViewing = Calendar.current.isDate(month.monthStart, equalTo: selectedMonth, toGranularity: .month)
                BillingRow(
                    title: month.monthStart.formatted(.dateTime.month(.wide).year()),
                    downloadBytes: month.downloadBytes,
                    uploadBytes: month.uploadBytes,
                    activeDays: month.activeDaysCount,
                    totalBytes: month.totalBytes,
                    isViewing: isViewing,
                    action: { onSelectMonth(month.monthStart) }
                )
                if index < previousMonths.count - 1 {
                    LinkWaveHairlineDivider(leading: 8)
                }
            }

            LinkWaveHairlineDivider()
            Text("Only months with synced readings are stored. Tap a past cycle to load its chart.")
                .font(.caption2.monospacedDigit())
                .linkWaveText(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .linkWaveGlassCard()
        .accessibilityElement(children: .contain)
    }

    private func formatGB(_ bytes: UInt64) -> String {
        String(format: "%.2f GB", Double(bytes) / 1_000_000_000)
    }
}

private struct BillingRow: View {
    let title: String
    let downloadBytes: UInt64
    let uploadBytes: UInt64
    let activeDays: Int?
    let totalBytes: UInt64
    let isViewing: Bool
    let action: (() -> Void)?
    @Environment(\.linkWaveThemePalette) private var palette

    var body: some View {
        Button(action: action ?? {}) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(title)
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(palette.textPrimary.color)
                            .lineLimit(1)
                        if isViewing {
                            Text("Viewing")
                                .font(.caption2.weight(.semibold).monospacedDigit())
                                .foregroundStyle(palette.textAccent)
                        }
                    }
                    Text("↓ \(format(downloadBytes)) · ↑ \(format(uploadBytes))\(activeDays.map { " · \($0) days" } ?? "")")
                        .font(.caption2.monospacedDigit())
                        .linkWaveText(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.72)
                }
                Spacer(minLength: 4)
                if action != nil {
                    HStack(spacing: 5) {
                        Text(formatGB(totalBytes))
                            .font(.subheadline.weight(.semibold).monospacedDigit())
                            .foregroundStyle(palette.textPrimary.color)
                        Image(systemName: "chevron.right")
                            .font(.caption2.weight(.semibold))
                            .linkWaveText(.tertiary)
                    }
                } else {
                    Text(formatGB(totalBytes))
                        .font(.subheadline.weight(.semibold).monospacedDigit())
                        .foregroundStyle(palette.textPrimary.color)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 7)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(action == nil)
    }

    private func format(_ bytes: UInt64) -> String {
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
    @Environment(\.colorScheme) private var colorScheme
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
        VStack(alignment: .leading, spacing: 0) {
            cycleSummaryBand
            dailyBreakdownBody
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .linkWaveGlassCard(padding: 0)
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

    private var cycleSummaryBand: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 7) {
                ZStack {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(palette.textAccent.opacity(0.12))
                    Image(systemName: "chart.bar.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(palette.textAccent)
                }
                .frame(width: 34, height: 34)
                Text("Data Usage")
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(palette.textPrimary.color)
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
                    .padding(.top, 2)
                    .transition(.opacity)
            }

            HStack(alignment: .center, spacing: 10) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(isCurrentMonth ? "This Month" : "\(selectedMonthStart.formatted(.dateTime.month(.wide).year())) Total")
                        .font(.caption.weight(.medium))
                        .linkWaveText(.secondary)
                    Text(Self.format(selectedTotalBytes))
                        .font(.system(.title2, design: .rounded).weight(.bold))
                        .foregroundStyle(palette.textPrimary.color)
                        .monospacedDigit()
                        .tracking(-0.35)
                        .lineLimit(1)
                        .minimumScaleFactor(0.72)
                    splitLegend
                    if !isCurrentMonth {
                        Button("Back to current", action: onBackToCurrentMonth)
                            .font(.caption.weight(.semibold).monospacedDigit())
                            .foregroundStyle(palette.textAccent)
                            .buttonStyle(.plain)
                            .padding(.top, 2)
                    }
                }
                Spacer(minLength: 4)
                DualSplitDonut(
                    downloadShare: downloadShare,
                    downloadColor: palette.textAccent,
                    uploadColor: .green
                )
                .frame(width: 92, height: 92)
            }
        }
        .padding(16)
        .background(cycleSummaryBackground)
        .overlay(alignment: .bottom) {
            LinkWaveHairlineDivider()
        }
    }

    @ViewBuilder
    private var cycleSummaryBackground: some View {
        let shape = RoundedRectangle(cornerRadius: 22, style: .continuous)
        if colorScheme == .dark {
            ZStack {
                shape.fill(palette.backgroundPrimary)
                RadialGradient(
                    colors: [palette.textAccent.opacity(0.16), .clear],
                    center: .topTrailing,
                    startRadius: 2,
                    endRadius: 190
                )
                .clipShape(shape)
            }
        } else {
            ZStack {
                shape.fill(palette.backgroundSecondary.opacity(0.96))
                shape.fill(palette.textAccent.opacity(0.07))
                RadialGradient(
                    colors: [palette.textAccent.opacity(0.10), .clear],
                    center: .topTrailing,
                    startRadius: 2,
                    endRadius: 190
                )
                .clipShape(shape)
            }
        }
    }

    private var dailyBreakdownBody: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 7) {
                Image(systemName: "calendar")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(palette.textAccent)
                Text("Daily Breakdown")
                    .font(.subheadline.weight(.bold))
                Spacer()
                Text("Drag or tap bars to inspect")
                    .font(.caption2.monospacedDigit())
                    .linkWaveText(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
            }
            monthlyChart
            selectedUsageDetails
        }
        .padding(16)
    }

    private var splitLegend: some View {
        HStack(spacing: 8) {
            legendItem("Download", bytes: selectedDownloadBytes, percentage: downloadShare, tint: palette.textAccent)
            legendItem("Upload", bytes: selectedUploadBytes, percentage: 1 - downloadShare, tint: .green)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func legendItem(_ title: String, bytes: UInt64, percentage: CGFloat, tint: Color) -> some View {
        HStack(spacing: 3) {
            Circle().fill(tint).frame(width: 6, height: 6)
            Text(title == "Upload"
                 ? "Up \(Self.format(bytes)) (\(Int((percentage * 100).rounded()))%)"
                 : "Down \(Self.format(bytes))")
                .font(.caption.monospacedDigit())
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
                    let isSelected = calendar.isDate(point.date, inSameDayAs: selectedDate)
                    let dayCenter = calendar.date(bySettingHour: 12, minute: 0, second: 0, of: point.date) ?? point.date
                    if let download = point.downloadBytes, let upload = point.uploadBytes {
                        let downloadGB = Double(download) / 1_000_000_000
                        let uploadGB = Double(upload) / 1_000_000_000
                        let barOpacity = isSelected ? 1 : 0.40
                        BarMark(
                            x: .value("Day", dayCenter, unit: .day),
                            yStart: .value("Baseline", 0),
                            yEnd: .value("Download", downloadGB),
                            width: .fixed(7)
                        )
                        .foregroundStyle(palette.textAccent.opacity(barOpacity))

                        BarMark(
                            x: .value("Day", dayCenter, unit: .day),
                            yStart: .value("Download", downloadGB),
                            yEnd: .value("Upload", downloadGB + uploadGB),
                            width: .fixed(7)
                        )
                        .foregroundStyle(.green.opacity(barOpacity))
                    } else {
                        BarMark(
                            x: .value("Day", dayCenter, unit: .day),
                            yStart: .value("Baseline", 0),
                            yEnd: .value("No reading", chartTopGB * 0.012),
                            width: .fixed(7)
                        )
                        .foregroundStyle(palette.textTertiary.color.opacity(0.30))
                    }
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
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text(selectedDate.formatted(.dateTime.weekday(.abbreviated).month(.wide).day().year()))
                    .font(.caption.weight(.semibold).monospacedDigit())
                    .lineLimit(1)
                    .minimumScaleFactor(0.78)
                if selectedPoint?.isPartial == true && selectedPoint?.totalBytes != nil {
                    Text("· Partial day")
                        .font(.caption2.monospacedDigit())
                        .linkWaveText(.secondary)
                } else if !hasSelectedReading {
                    Text("· No reading recorded")
                        .font(.caption2.monospacedDigit())
                        .linkWaveText(.secondary)
                }
                Spacer()
                Text("Selected day")
                    .font(.caption2.monospacedDigit())
                    .linkWaveText(.tertiary)
            }

            HStack(spacing: 8) {
                usageValue("Download", bytes: selectedPoint?.downloadBytes, tint: palette.textAccent)
                LinkWaveHairlineDivider()
                    .frame(width: 0.5, height: 36)
                usageValue("Upload", bytes: selectedPoint?.uploadBytes, tint: .green)
                LinkWaveHairlineDivider()
                    .frame(width: 0.5, height: 36)
                usageValue("Total", bytes: selectedPoint?.totalBytes, tint: palette.textAccent)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(palette.backgroundTertiary.opacity(colorScheme == .dark ? 0.32 : 0.48),
                    in: RoundedRectangle(cornerRadius: 13, style: .continuous))
    }

    private func usageValue(_ title: String, bytes: UInt64?, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.caption2)
                .linkWaveText(.secondary)
            Text(formatSelectedValue(title: title, bytes: bytes))
                .font(.caption.weight(.semibold).monospacedDigit())
                .foregroundStyle(title == "Total" ? tint : palette.textPrimary.color)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func formatSelectedValue(title: String, bytes: UInt64?) -> String {
        guard let bytes else { return "0.00 GB" }
        if title == "Upload" && bytes < 1_000_000_000 {
            return String(format: "%.0f MB", Double(bytes) / 1_000_000)
        }
        return String(format: "%.2f GB", Double(bytes) / 1_000_000_000)
    }

    private var hasSelectedReading: Bool { selectedPoint?.totalBytes != nil }

    private static func format(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: bytes), countStyle: .file)
    }
}

private struct DualSplitDonut: View {
    let downloadShare: CGFloat
    let downloadColor: Color
    let uploadColor: Color

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.primary.opacity(0.08), lineWidth: 9)
            Circle()
                .trim(from: 0, to: downloadShare)
                .stroke(downloadColor, style: StrokeStyle(lineWidth: 9, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Circle()
                .trim(from: downloadShare, to: 1)
                .stroke(uploadColor, style: StrokeStyle(lineWidth: 9, lineCap: .round))
                .rotationEffect(.degrees(-90))
            VStack(spacing: 1) {
                Text("\(Int((downloadShare * 100).rounded()))%")
                    .font(.system(.subheadline, design: .rounded).weight(.bold).monospacedDigit())
                Text("Down")
                    .font(.caption2)
                    .linkWaveText(.secondary)
            }
        }
        .accessibilityLabel("Download \(Int((downloadShare * 100).rounded())) percent")
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

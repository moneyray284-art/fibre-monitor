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
                        PersonalUsageCard(
                            snapshot: settings.personalUsageSnapshot,
                            householdSummary: settings.dataUsageSummary,
                            routerName: settings.activeProfile?.name ?? "your router"
                        )
                        DailyUsageHistoryCard(
                            history: settings.dataUsageSummary.historicalDailyHistory,
                            todayDownloadBytes: settings.dataUsageSummary.todayDownloadBytes,
                            todayUploadBytes: settings.dataUsageSummary.todayUploadBytes,
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
            .onAppear { settings.refreshPersonalUsageForCurrentLocalPeriod() }
            .navigationTitle("Usage")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    RouterSwitcherMenu(viewModel: viewModel, settings: settings) {
                        showSettings = true
                    }
                }
                StandaloneTopBarTrailingItem(
                    content: AnyView(RouterRefreshToolbarButton(viewModel: viewModel, isEnabled: settings.isConfigured))
                )
            }
            .navigationDestination(isPresented: $showSettings) {
                SettingsTabView(viewModel: viewModel)
                    .toolbar(.hidden, for: .tabBar)
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
        .linkWaveGlassCard()
    }
}

private struct SyncStatusCard: View {
    let summary: DataUsageSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            CardHeader(icon: "arrow.triangle.2.circlepath", title: "Router Sync") { EmptyView() }

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

private struct PersonalUsageCard: View {
    let snapshot: PersonalUsageSnapshot
    let householdSummary: DataUsageSummary
    let routerName: String

    private var householdMonthlyBytes: UInt64 {
        Self.total(householdSummary.monthDownloadBytes, householdSummary.monthUploadBytes)
    }

    private var personalMonthlyBytes: UInt64 {
        Self.total(snapshot.monthDownloadBytes, snapshot.monthUploadBytes)
    }

    private var householdShare: Double {
        guard householdMonthlyBytes > 0 else { return 0 }
        return min(1, Double(personalMonthlyBytes) / Double(householdMonthlyBytes))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack(spacing: 8) {
                Image(systemName: "iphone")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.purple)
                Text("Personal Usage (This iPhone)")
                    .font(.headline)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Spacer(minLength: 4)
                Text("LOCAL TRACKING")
                    .font(.system(size: 9, weight: .bold))
                    .tracking(0.35)
                    .foregroundStyle(.purple)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(Color.purple.opacity(0.12), in: Capsule())
            }

            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(Self.format(personalMonthlyBytes))
                    .font(.system(.title, design: .rounded).weight(.bold))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                Text("this month")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }

            if householdMonthlyBytes > 0 {
                VStack(alignment: .leading, spacing: 6) {
                    GeometryReader { geometry in
                        ZStack(alignment: .leading) {
                            Capsule(style: .continuous)
                                .fill(Color.purple.opacity(0.14))
                            Capsule(style: .continuous)
                                .fill(Color.purple.gradient)
                                .frame(width: geometry.size.width * householdShare)
                        }
                    }
                    .frame(height: 8)
                    Text("\(householdShare * 100, specifier: "%.1f")% of \(Self.format(householdMonthlyBytes)) household total")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                .accessibilityElement(children: .combine)
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
            .foregroundStyle(.secondary)

            usageRow("Today", download: snapshot.todayDownloadBytes, upload: snapshot.todayUploadBytes)
            Divider().opacity(0.55)
            usageRow("This month", download: snapshot.monthDownloadBytes, upload: snapshot.monthUploadBytes)
            Divider().opacity(0.55)
            usageRow("Since tracking", download: snapshot.totalDownloadBytes, upload: snapshot.totalUploadBytes)

            Text("Estimated by monitoring this iPhone's Wi-Fi network traffic while connected to \(routerName)")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
    @State private var selectedDate = Calendar.current.startOfDay(for: Date())
    @State private var selectedMonth = Calendar.current.dateInterval(of: .month, for: Date())?.start ?? Calendar.current.startOfDay(for: Date())

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
        return max(50, ceil(maximumGB / 50) * 50)
    }

    private var chartTopBytes: Double { chartTopGB * 1_000_000_000 }

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
            selectedMonth = currentMonth
            selectedDate = calendar.startOfDay(for: Date())
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
        Menu {
            ForEach(monthOptions, id: \.self) { month in
                Button {
                    selectMonth(month)
                } label: {
                    HStack {
                        Text(month.formatted(.dateTime.month(.wide).year()))
                        if calendar.isDate(month, equalTo: selectedMonthStart, toGranularity: .month) {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 6) {
                Text(selectedMonthStart.formatted(.dateTime.month(.wide).year()))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .bold))
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(Color.accentColor)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .liquidGlassCapsule()
        }
        .accessibilityLabel("Select usage month")
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
        GeometryReader { geometry in
            let labelWidth: CGFloat = 38
            let plotWidth = max(1, geometry.size.width - labelWidth - 5)
            let plotHeight = geometry.size.height
            let dayCount = max(1, monthPoints.count)
            let barWidth = min(9, max(2, (plotWidth - CGFloat(dayCount - 1) * 2) / CGFloat(dayCount)))
            let barSpacing = dayCount > 1 ? max(2, (plotWidth - barWidth * CGFloat(dayCount)) / CGFloat(dayCount - 1)) : 0

            HStack(spacing: 5) {
                ZStack(alignment: .bottomLeading) {
                    HStack(alignment: .bottom, spacing: barSpacing) {
                        ForEach(monthPoints) { point in
                            monthBar(point, width: barWidth, height: plotHeight)
                        }
                    }

                    Path { path in
                        path.move(to: CGPoint(x: 0, y: 1))
                        path.addLine(to: CGPoint(x: plotWidth, y: 1))
                        path.move(to: CGPoint(x: 0, y: plotHeight / 2))
                        path.addLine(to: CGPoint(x: plotWidth, y: plotHeight / 2))
                    }
                    .stroke(Color.secondary.opacity(0.34), style: StrokeStyle(lineWidth: 0.8, dash: [2, 3]))
                    .allowsHitTesting(false)
                }
                .frame(width: plotWidth, height: plotHeight, alignment: .bottomLeading)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in selectDay(at: value.location.x, plotWidth: plotWidth) }
                )
                .accessibilityElement(children: .contain)

                VStack(spacing: 0) {
                    Text("\(Int(chartTopGB)) GB")
                        .frame(maxWidth: .infinity, alignment: .trailing)
                    Spacer(minLength: 0)
                    Text("\(Int(chartTopGB / 2)) GB")
                        .frame(maxWidth: .infinity, alignment: .trailing)
                    Spacer(minLength: 0)
                }
                .font(.system(size: 9, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: labelWidth, height: plotHeight)
            }
        }
        .frame(height: 132)
        .overlay(alignment: .bottom) {
            monthAxisLabels
                .offset(y: 17)
        }
        .padding(.bottom, 16)
    }

    private var monthAxisLabels: some View {
        HStack(spacing: 5) {
            HStack {
                Text(axisLabels.0).frame(maxWidth: .infinity, alignment: .leading)
                Text(axisLabels.1).frame(maxWidth: .infinity, alignment: .center)
                Text(axisLabels.2).frame(maxWidth: .infinity, alignment: .trailing)
            }
            .frame(maxWidth: .infinity)
            Color.clear.frame(width: 38)
        }
        .font(.system(size: 9, weight: .medium))
        .monospacedDigit()
        .foregroundStyle(.secondary)
        .accessibilityHidden(true)
    }

    private func monthBar(_ point: DailyUsagePoint, width: CGFloat, height: CGFloat) -> some View {
        let isSelected = calendar.isDate(point.date, inSameDayAs: selectedDate)
        let total = Double(point.totalBytes ?? 0)
        let usageHeight = total > 0 ? max(2, height * CGFloat(min(1, total / chartTopBytes))) : 0

        return Button {
            selectedDate = point.date
        } label: {
            Capsule(style: .continuous)
                .fill(Color.accentColor.opacity(isSelected ? 0.16 : 0.10))
                .overlay(alignment: .bottom) {
                    if total > 0 {
                        Capsule(style: .continuous)
                            .fill(Color.accentColor.opacity(isSelected ? 1 : 0.58))
                            .frame(height: usageHeight)
                    }
                }
                .overlay {
                    if isSelected {
                        Capsule(style: .continuous)
                            .stroke(Color.accentColor.opacity(0.9), lineWidth: 1)
                    }
                }
                .frame(width: width, height: height)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(point.date.formatted(date: .complete, time: .omitted))
        .accessibilityValue(accessibilityValue(for: point))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func selectDay(at x: CGFloat, plotWidth: CGFloat) {
        guard !monthPoints.isEmpty else { return }
        let index = min(monthPoints.count - 1, max(0, Int((x / plotWidth) * CGFloat(monthPoints.count))))
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
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(Color.secondary.opacity(0.12), in: Capsule())
                }
            }

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
                .foregroundStyle(.secondary)
            Text(bytes.map(Self.format) ?? "—")
                .font(.caption.weight(.semibold).monospacedDigit())
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func accessibilityValue(for point: DailyUsagePoint) -> String {
        guard let total = point.totalBytes else { return "No recorded usage" }
        let value = Self.format(total)
        return point.isPartial ? "\(value), partial day" : value
    }

    private static func format(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: bytes), countStyle: .file)
    }
}

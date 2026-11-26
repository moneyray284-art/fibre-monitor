import SwiftUI

public struct DashboardView: View {
    @ObservedObject var viewModel: MonitorViewModel
    @ObservedObject var settings: SettingsStore
    @State private var showSettings = false
    @State private var showConnectionDiagnosis = false
    @State private var startSpeedTestRequested = false
    @State private var speedTestDownloadMbps: Double?
    @State private var speedTestUploadMbps: Double?
    @Environment(\.colorScheme) private var colorScheme

    public init(viewModel: MonitorViewModel) {
        self.viewModel = viewModel
        self.settings = viewModel.settings
    }

    public var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    if !settings.isConfigured {
                        NoRouterCard {
                            showSettings = true
                        }
                    } else {
                        RouterHeaderCard(
                            viewModel: viewModel,
                            settings: settings,
                            testDownloadMbps: speedTestDownloadMbps,
                            testUploadMbps: speedTestUploadMbps
                        )

                        if !viewModel.isConnectedToWiFi {
                            NetworkStatusBanner(
                                message: "Not connected to Wi-Fi — turn on Wi-Fi to connect to your router",
                                symbol: "wifi.slash"
                            )
                        } else if !viewModel.hasInternetPath {
                            NetworkStatusBanner(
                                message: "Wi-Fi is connected, but no internet path is available",
                                symbol: "network"
                            )
                        }

                        if let err = viewModel.errorMessage, !viewModel.isLoggedOut, viewModel.isConnectedToWiFi {
                            ErrorBanner(
                                message: err,
                                suggestFallback: viewModel.shouldSuggestFallbackHost,
                                onTryFallback: { Task { await viewModel.useFallbackHost() } },
                                openSettings: { showSettings = true }
                            )
                        }

                        HomeSummaryRow(
                            summary: settings.dataUsageSummary,
                            onlineCount: viewModel.homeOnlineDeviceCount,
                            offlineCount: viewModel.homeOfflineDeviceCount,
                            openUsage: { viewModel.selectedTab = .usage },
                            openClients: { viewModel.selectedTab = .clients }
                        )
                        SpeedTestCard(
                            viewModel: viewModel,
                            testDownloadMbps: $speedTestDownloadMbps,
                            testUploadMbps: $speedTestUploadMbps,
                            startRequested: $startSpeedTestRequested
                        )
                        ConnectionCheckCard(
                            diagnosis: connectionDiagnosis,
                            openDiagnosis: { showConnectionDiagnosis = true }
                        )
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
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                StandaloneTopBarLeadingItem(content: AnyView(
                    ProfileAvatarPickerButton(viewModel: viewModel)
                        .frame(width: 44, height: 44)
                ))
                ToolbarItem(placement: .principal) {
                    LinkWaveWordmark(
                        nodesArePulsing: false,
                        white: settings.themePalette(for: colorScheme).textPrimary.color,
                        cyan: settings.logoColor.color(for: colorScheme),
                        fontSize: 18
                    )
                }
                StandaloneTopBarTrailingItem(
                    content: AnyView(homeToolbarButton(
                        symbol: "arrow.clockwise",
                        label: "Refresh router data",
                        isDisabled: viewModel.isRefreshing || !settings.isConfigured,
                        isRefreshing: viewModel.isRefreshing
                    ) {
                        Task { await viewModel.refreshAll(forceReauthIfNeeded: true) }
                    })
                )
                StandaloneTopBarTrailingItem(
                    content: AnyView(homeToolbarButton(symbol: "gearshape", label: "Settings") {
                        showSettings = true
                    })
                )
            }
            .navigationDestination(isPresented: $showSettings) {
                SettingsTabView(viewModel: viewModel)
                    .toolbar(.hidden, for: .tabBar)
            }
            .sheet(isPresented: $showConnectionDiagnosis) {
                DiagnoseConnectionSheet(diagnosis: connectionDiagnosis, perform: performDiagnosisAction)
                    .presentationDetents([.medium, .large])
            }
            .onChange(of: showSettings) { isPresented in
                if !isPresented { viewModel.settingsDidDismiss() }
            }
        }
    }

    private var connectionDiagnosis: ConnectionDiagnosis {
        let summary = settings.dataUsageSummary
        let snapshot = RouterSnapshot(
            routerProfileID: settings.activeProfile?.id.uuidString,
            routerHost: settings.activeProfile?.host,
            routerModel: viewModel.displayModelName,
            rxPowerDbm: viewModel.optical.rxPowerDbm,
            todayDownloadBytes: summary.todayDownloadBytes,
            todayUploadBytes: summary.todayUploadBytes,
            onlineClientCount: viewModel.homeOnlineDeviceCount,
            offlineClientCount: viewModel.homeOfflineDeviceCount,
            pppoeUptimeSeconds: viewModel.wan.uptimeSeconds,
            updatedAt: viewModel.lastUpdate ?? Date()
        )
        return NetworkInsightsAnalyzer.diagnose(
            snapshot: snapshot,
            devices: viewModel.devices,
            blockedDevices: viewModel.blockedDevices,
            wifi: viewModel.wifi,
            speedTest: viewModel.activeSpeedTestRecord?.result
        )
    }

    private func performDiagnosisAction(_ action: ConnectionDiagnosisAction) {
        showConnectionDiagnosis = false
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 280_000_000)
            switch action {
            case .reviewWiFiBands:
                viewModel.selectedTab = .wifi
            case .runSpeedTest:
                viewModel.selectedTab = .home
                startSpeedTestRequested = true
            }
        }
    }

    private func homeToolbarButton(
        symbol: String,
        label: String,
        isDisabled: Bool = false,
        isRefreshing: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Group {
                if isRefreshing {
                    ProgressView().controlSize(.mini)
                } else {
                    Image(systemName: symbol)
                        .font(.system(size: 15, weight: .semibold))
                }
            }
            .frame(width: 38, height: 38)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .modifier(LiquidGlassToolbarCircleModifier())
        .frame(width: 44, height: 44)
        .accessibilityLabel(label)
        .disabled(isDisabled)
    }
}

private struct RouterHeaderCard: View {
    @ObservedObject var viewModel: MonitorViewModel
    @ObservedObject var settings: SettingsStore
    let testDownloadMbps: Double?
    let testUploadMbps: Double?
    @Environment(\.linkWaveThemePalette) private var palette

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(LinearGradient(
                            colors: [
                                palette.backgroundSecondary.opacity(0.94),
                                palette.backgroundTertiary.opacity(0.78)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ))
                        .frame(width: 66, height: 54)
                    HuaweiOptiXstarIllustration(isOnline: viewModel.isConnected, wifiOnline: wifiOnline)
                }
                .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 2) {
                    Text(settings.activeProfile?.routerDisplayName ?? "Fibre Router")
                        .font(.headline)
                        .lineLimit(1)
                    Text(viewModel.displayModelName)
                        .font(.caption)
                        .linkWaveText(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 8)

                if let rxPower = viewModel.optical.rxPowerDbm {
                    FibreSignalMeter(rxPowerDbm: rxPower)
                } else {
                    RouterConnectivityFallback(
                        isOnline: viewModel.isConnected,
                        responseTimeMs: viewModel.routerResponseTimeMs
                    )
                }
            }

            HStack(spacing: 8) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 8, height: 8)
                    .shadow(color: statusColor.opacity(0.7), radius: 3)
                Text(statusText)
                    .font(.caption.weight(.bold))
                    .foregroundColor(statusColor)
                if let lastUpdate = viewModel.lastUpdate {
                    Text("• Updated \(lastUpdate, style: .relative)")
                        .font(.caption2)
                        .linkWaveText(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
                Spacer()
                if viewModel.isLoggedOut {
                    Button("Reconnect") {
                        viewModel.reconnectSession()
                    }
                    .font(.caption.weight(.semibold))
                    .liquidGlassSmallButton()
                }
            }
            CompactSpeedCard(
                traffic: viewModel.traffic,
                downloadOverrideMbps: testDownloadMbps,
                uploadOverrideMbps: testUploadMbps
            )
        }
        .linkWaveGlassCard()
        .accessibilityElement(children: .combine)
    }

    private var statusColor: Color {
        if !viewModel.isConnectedToWiFi { return .red }
        if !viewModel.hasInternetPath { return .orange }
        if viewModel.isLoggedOut { return .secondary }
        switch viewModel.connectionState {
        case .connected: return .green
        case .connecting, .temporarilyLocked: return .orange
        case .invalidCredentials, .offline: return .red
        }
    }

    private var statusText: String {
        if !viewModel.isConnectedToWiFi { return "NO WI-FI" }
        if !viewModel.hasInternetPath { return "NO INTERNET" }
        if viewModel.isLoggedOut { return "LOGGED OUT" }
        switch viewModel.connectionState {
        case .connected:
            return viewModel.isLiveTrafficActive && !viewModel.isSpeedTestRunning ? "CONNECTED · Live" : "CONNECTED"
        case .connecting:
            return "CONNECTING"
        case .temporarilyLocked:
            return "LOGIN PAUSED"
        case .invalidCredentials:
            return "LOGIN REJECTED"
        case .offline:
            return "OFFLINE"
        }
    }

    private var wifiOnline: Bool {
        let reportedStates = viewModel.wifi.radios.map(\.enabled) + viewModel.wifi.networks.map(\.enabled)
        return reportedStates.isEmpty ? viewModel.isConnected : reportedStates.contains(true)
    }
}

private struct ConnectionCheckCard: View {
    let diagnosis: ConnectionDiagnosis
    let openDiagnosis: () -> Void
    @Environment(\.linkWaveThemePalette) private var palette

    var body: some View {
        Button(action: openDiagnosis) {
            HStack(spacing: 10) {
                Image(systemName: "stethoscope")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(statusColor)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 3) {
                    Text("Connection Check · \(diagnosis.severity.label)")
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    Text(diagnosis.inlineHint)
                        .font(.caption)
                        .linkWaveText(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                HStack(spacing: 4) {
                    Text("Diagnose")
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.bold))
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(palette.textAccent)
                .fixedSize()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .linkWaveGlassCard(padding: 14)
        .accessibilityLabel("Connection Check, \(diagnosis.severity.label). \(diagnosis.inlineHint). Diagnose.")
    }

    private var statusColor: Color {
        switch diagnosis.severity {
        case .optimal: .green
        case .pending: palette.textSecondary.color
        case .warning: .orange
        case .critical: .red
        }
    }
}

private struct NetworkStatusBanner: View {
    let message: String
    let symbol: String

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: symbol)
                .foregroundStyle(.orange)
            Text(message)
                .font(.caption)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .linkWaveGlassCard(padding: 12)
        .accessibilityElement(children: .combine)
    }
}

private struct HuaweiOptiXstarIllustration: View {
    let isOnline: Bool
    let wifiOnline: Bool
    @Environment(\.linkWaveThemePalette) private var palette

    private var ponLight: Color { isOnline ? .green : .red }
    private var wlanLight: Color { isOnline && wifiOnline ? .green : .orange }

    var body: some View {
        ZStack {
            Capsule()
                .fill(LinearGradient(colors: [Color(red: 0.82, green: 0.86, blue: 0.90), Color(red: 0.43, green: 0.49, blue: 0.57)], startPoint: .leading, endPoint: .trailing))
                .frame(width: 3, height: 22)
                .rotationEffect(.degrees(-12))
                .offset(x: -20, y: -14)
            Capsule()
                .fill(LinearGradient(colors: [Color(red: 0.82, green: 0.86, blue: 0.90), Color(red: 0.43, green: 0.49, blue: 0.57)], startPoint: .leading, endPoint: .trailing))
                .frame(width: 3, height: 22)
                .rotationEffect(.degrees(12))
                .offset(x: 20, y: -14)

            Image(systemName: "wifi")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(palette.textAccent)
                .offset(y: -18)

            RouterChassis()
                .fill(LinearGradient(
                    colors: [Color(red: 0.84, green: 0.87, blue: 0.91), Color(red: 0.60, green: 0.66, blue: 0.73)],
                    startPoint: .top,
                    endPoint: .bottom
                ))
                .frame(width: 60, height: 23)
                .overlay {
                    RouterChassis().stroke(Color.white.opacity(0.50), lineWidth: 0.8)
                }
                .overlay(alignment: .bottomLeading) {
                    HStack(spacing: 5) {
                        Circle().fill(ponLight).frame(width: 4, height: 4)
                            .shadow(color: ponLight.opacity(0.9), radius: 2)
                        Circle().fill(wlanLight).frame(width: 4, height: 4)
                            .shadow(color: wlanLight.opacity(0.9), radius: 2)
                    }
                    .padding(.leading, 9)
                    .padding(.bottom, 5)
                }
                .overlay(alignment: .topTrailing) {
                    VStack(alignment: .trailing, spacing: 2) {
                        ForEach(0..<3, id: \.self) { _ in
                            Capsule().fill(Color.black.opacity(0.20)).frame(width: 11, height: 1)
                        }
                    }
                    .padding(.top, 8)
                    .padding(.trailing, 7)
                }
                .overlay {
                    Rectangle()
                        .fill(Color.black.opacity(0.12))
                        .frame(height: 1)
                        .padding(.horizontal, 8)
                        .offset(y: 1)
                }
                .shadow(color: .black.opacity(0.16), radius: 3, y: 2)
        }
        .frame(width: 66, height: 50)
        .accessibilityLabel("Huawei OptiXstar HG8145X6 router with PON and WLAN status lights")
    }
}

private struct RouterChassis: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX + 7, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - 7, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - 4))
        path.addQuadCurve(to: CGPoint(x: rect.maxX - 4, y: rect.maxY), control: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX + 4, y: rect.maxY))
        path.addQuadCurve(to: CGPoint(x: rect.minX, y: rect.maxY - 4), control: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

private struct FibreSignalMeter: View {
    let rxPowerDbm: Double
    @Environment(\.linkWaveThemePalette) private var palette

    private var level: Int {
        if rxPowerDbm >= -24 { return 4 }
        if rxPowerDbm > -27 { return 3 }
        if rxPowerDbm > -29 { return 2 }
        return 1
    }

    private var tint: Color {
        switch level {
        case 4, 3: .green
        case 2: .yellow
        default: .red
        }
    }

    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            HStack(alignment: .bottom, spacing: 2) {
                ForEach(0..<4, id: \.self) { index in
                    Capsule()
                        .fill(index < level ? tint : palette.textTertiary.color.opacity(0.55))
                        .frame(width: 4, height: CGFloat(7 + index * 4))
                }
            }
            Text(String(format: "%.2f dBm", rxPowerDbm))
                .font(.caption2.weight(.semibold).monospacedDigit())
                .foregroundStyle(tint)
            Text("FIBRE RX")
                .font(.system(size: 8, weight: .bold, design: .rounded))
                .foregroundStyle(.tertiary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Fibre signal")
        .accessibilityValue("\(level) of 4 bars, \(String(format: "%.2f", rxPowerDbm)) dBm")
    }
}

private struct RouterConnectivityFallback: View {
    let isOnline: Bool
    let responseTimeMs: Int?

    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            Label(isOnline ? "ONLINE" : "OFFLINE", systemImage: "circle.fill")
                .font(.caption2.weight(.bold))
                .foregroundStyle(isOnline ? Color.green : Color.red)
            Text(isOnline ? responseLabel : "Router unreachable")
                .font(.caption2)
                .linkWaveText(.secondary)
                .lineLimit(1)
        }
        .accessibilityElement(children: .combine)
    }

    private var responseLabel: String {
        if let responseTimeMs { return "Latency \(responseTimeMs) ms" }
        return "Latency unavailable"
    }
}

private struct CompactSpeedCard: View {
    let traffic: TrafficState
    var downloadOverrideMbps: Double? = nil
    var uploadOverrideMbps: Double? = nil
    @State private var idleDownloadMbps = 0.0
    @State private var idleUploadMbps = 0.0
    @Environment(\.linkWaveThemePalette) private var palette

    private var displayedDownloadMbps: Double { downloadOverrideMbps ?? idleDownloadMbps }
    private var displayedUploadMbps: Double { uploadOverrideMbps ?? idleUploadMbps }

    var body: some View {
        HStack(spacing: 13) {
            speedMetric(
                title: "Download",
                value: displayedDownloadMbps,
                icon: "arrow.down",
                tint: palette.textAccent,
                isInterpolated: downloadOverrideMbps != nil
            )

            Rectangle()
                .fill(palette.textTertiary.color.opacity(0.45))
                .frame(width: 1, height: 35)

            speedMetric(
                title: "Upload",
                value: displayedUploadMbps,
                icon: "arrow.up",
                tint: palette.textAccent.opacity(0.72),
                isInterpolated: uploadOverrideMbps != nil
            )
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Live speed")
        .accessibilityValue(
            "Download \(Self.accessibilitySpeed(displayedDownloadMbps)), upload \(Self.accessibilitySpeed(displayedUploadMbps))"
        )
        .onAppear {
            if downloadOverrideMbps == nil { idleDownloadMbps = traffic.downloadMbps }
            if uploadOverrideMbps == nil { idleUploadMbps = traffic.uploadMbps }
        }
        .onChange(of: traffic.downloadMbps) { sample in
            withAnimation(.linear(duration: 0.24)) {
                idleDownloadMbps = smoothedIdleValue(sample, previous: idleDownloadMbps)
            }
        }
        .onChange(of: traffic.uploadMbps) { sample in
            withAnimation(.linear(duration: 0.24)) {
                idleUploadMbps = smoothedIdleValue(sample, previous: idleUploadMbps)
            }
        }
        .onChange(of: downloadOverrideMbps) { override in
            if override == nil { idleDownloadMbps = traffic.downloadMbps }
        }
        .onChange(of: uploadOverrideMbps) { override in
            if override == nil { idleUploadMbps = traffic.uploadMbps }
        }
    }

    private func speedMetric(title: String, value: Double, icon: String, tint: Color, isInterpolated: Bool) -> some View {
        HStack(spacing: 9) {
            Image(systemName: icon)
                .font(.subheadline.weight(.bold))
                .foregroundStyle(tint)
                .frame(width: 30, height: 30)
                .background(tint.opacity(0.12), in: Circle())

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption)
                    .linkWaveText(.secondary)
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(value >= 1 ? String(format: value >= 100 ? "%.0f" : "%.1f", value) : String(format: "%.0f", value * 1_000))
                        .font(.system(.title3, design: .rounded).weight(.bold))
                        .monospacedDigit()
                        .tracking(-0.3)
                        .animation(.linear(duration: isInterpolated ? 0.025 : 0.22), value: value)
                    Text(value >= 1 ? "Mbps" : "Kbps")
                        .font(.caption2.weight(.medium))
                        .linkWaveText(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private static func accessibilitySpeed(_ mbps: Double) -> String {
        if mbps < 1 { return String(format: "%.0f kilobits per second", mbps * 1_000) }
        return String(format: "%.1f megabits per second", mbps)
    }

    private func smoothedIdleValue(_ sample: Double, previous: Double) -> Double {
        if sample <= 0 { return 0 }
        return previous == 0 ? sample : previous * 0.72 + sample * 0.28
    }
}

private struct SpeedTestCard: View {
    @ObservedObject var viewModel: MonitorViewModel
    @Binding var testDownloadMbps: Double?
    @Binding var testUploadMbps: Double?
    @Binding var startRequested: Bool
    @State private var pendingResult: SpeedTestResult?
    @State private var progress = SpeedTestProgress(phase: .ping, fraction: 0, detail: "Preparing test")
    @State private var errorMessage: String?
    @State private var isRunning = false
    @State private var testTask: Task<Void, Never>?
    @State private var interpolationTask: Task<Void, Never>?
    @State private var overrideCleanupTask: Task<Void, Never>?
    @State private var measuredPingMs: Double?
    @State private var measuredJitterMs: Double?
    @State private var emaDownloadMbps = 0.0
    @State private var emaUploadMbps = 0.0
    @State private var targetDownloadMbps = 0.0
    @State private var targetUploadMbps = 0.0
    @State private var displayedDownloadMbps = 0.0
    @State private var displayedUploadMbps = 0.0
    @State private var gatewayDownloadReturnMbps = 0.0
    @State private var gatewayDownloadReturnTargetMbps = 0.0
    @State private var isReturningGatewayDownloadToLive = false
    @State private var hasDownloadReading = false
    @State private var hasUploadReading = false
    @State private var isHistoryExpanded = false
    @State private var inspectedHistoryID: UUID?
    @State private var selectedActivity: SpeedTestActivity?
    @Environment(\.linkWaveThemePalette) private var palette

    private var inspectedRecord: SpeedTestRecord? {
        viewModel.speedHistory.first { $0.id == inspectedHistoryID }
    }

    private var displayedRecord: SpeedTestRecord? {
        inspectedRecord ?? (pendingResult == nil ? viewModel.activeSpeedTestRecord : nil)
    }

    private var isInspectingSavedRun: Bool { inspectedRecord != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            HStack(spacing: 9) {
                Image(systemName: "speedometer")
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(palette.textAccent)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Speed Test")
                        .font(.headline.weight(.semibold))
                        .linkWaveText(.primary)
                    if let inspectedRecord {
                        Text("Saved · \(Self.formattedTime(inspectedRecord.timestamp))")
                            .font(.caption2)
                            .linkWaveText(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer()
                if isRunning {
                    Text(progress.phase.rawValue.uppercased())
                        .font(.system(size: 9, weight: .bold, design: .rounded))
                        .foregroundStyle(palette.textAccent)
                        .lineLimit(1)
                    Button("Stop", action: stopTest)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(palette.textAccent)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .buttonStyle(.plain)
                        .linkWaveInteractiveGlassCapsule()
                } else {
                    Button(action: startTest) {
                        Label(displayedRecord == nil ? "Start Test" : "Run Again", systemImage: startButtonSymbol)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(viewModel.canRunSpeedTest ? palette.textAccent : palette.textSecondary.color)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                    }
                    .buttonStyle(.plain)
                    .linkWaveInteractiveGlassCapsule()
                    .disabled(!viewModel.settings.isConfigured || !viewModel.canRunSpeedTest)
                    .accessibilityLabel(startButtonTitle)
                }
            }

            HStack(spacing: 0) {
                resultMetric(
                    "Ping",
                    value: displayedRecord.map { String(format: "%.0f ms", $0.pingMs) }
                        ?? measuredPingMs.map { String(format: "%.0f ms", $0) } ?? "-- ms",
                    tint: palette.textPrimary.color
                )
                resultMetric(
                    "Jitter",
                    value: displayedRecord.map { String(format: "%.0f ms", $0.jitterMs) }
                        ?? measuredJitterMs.map { String(format: "%.0f ms", $0) } ?? "-- ms",
                    tint: palette.textPrimary.color
                )
                resultMetric(
                    "Downlink",
                    value: displayedRecord.map { Self.speed($0.downMbps) }
                        ?? (hasDownloadReading ? Self.speed(displayedDownloadMbps) : "-- Mbps"),
                    tint: isRunning && progress.phase == .download ? palette.textAccent : palette.textSecondary.color
                )
                resultMetric(
                    "Uplink",
                    value: displayedRecord.map { Self.speed($0.upMbps) }
                        ?? (hasUploadReading ? Self.speed(displayedUploadMbps) : "-- Mbps"),
                    tint: isRunning && progress.phase == .upload ? palette.textAccent : palette.textSecondary.color
                )
            }

            if !isRunning, pendingResult == nil, let displayedRecord {
                LinkWaveHairlineDivider()
                activityStrengthSection(for: displayedRecord)
            }

            if isRunning {
                ProgressView(value: progress.fraction)
                    .tint(palette.textAccent)
                    .accessibilityLabel("Speed test progress")
            } else if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if isRunning {
                HStack(spacing: 8) {
                    ProgressView().tint(palette.textAccent)
                    Text(phaseStatus)
                        .font(.caption.weight(.medium))
                        .linkWaveText(.secondary)
                    Spacer()
                    Text("\(Int(progress.fraction * 100))%")
                        .font(.caption.monospacedDigit().weight(.semibold))
                        .linkWaveText(.secondary)
                }
            }

            if !isRunning, pendingResult == nil, !viewModel.speedHistory.isEmpty {
                LinkWaveHairlineDivider()
                previousTestsSection
            }
        }
        .linkWaveGlassCard()
        .accessibilityElement(children: .contain)
        .onChange(of: viewModel.canRunSpeedTest) { isAvailable in
            guard !isAvailable, isRunning else { return }
            testTask?.cancel()
            errorMessage = viewModel.isConnectedToWiFi
                ? "Speed test stopped because the internet path was lost."
                : "Speed test stopped because Wi-Fi disconnected."
        }
        .onChange(of: viewModel.traffic.downloadMbps) { sample in
            guard isReturningGatewayDownloadToLive else { return }
            gatewayDownloadReturnTargetMbps = max(0, sample)
            scheduleInterpolation()
        }
        .onChange(of: startRequested) { requested in
            guard requested else { return }
            startRequested = false
            startTest()
        }
        .onDisappear {
            testTask?.cancel()
            if pendingResult == nil { interpolationTask?.cancel() }
            overrideCleanupTask?.cancel()
        }
    }

    private var startButtonTitle: String {
        if !viewModel.isConnectedToWiFi { return "Connect to Wi-Fi to run Speed Test" }
        if !viewModel.hasInternetPath { return "No Internet for Speed Test" }
        return displayedRecord == nil ? "Start Speed Test" : "Run Speed Test Again"
    }

    private var startButtonSymbol: String {
        viewModel.canRunSpeedTest ? (displayedRecord == nil ? "play.fill" : "arrow.clockwise") : "wifi.slash"
    }

    private var phaseStatus: String {
        switch progress.phase {
        case .ping: "Measuring ping & jitter…"
        case .download: "Testing download…"
        case .upload: "Testing upload…"
        }
    }

    private func stopTest() {
        errorMessage = "Speed test stopped."
        testTask?.cancel()
    }

    private var previousTestsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    isHistoryExpanded.toggle()
                }
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: "clock.arrow.circlepath")
                        .foregroundStyle(palette.textSecondary.color)
                    Text("Previous Tests")
                        .foregroundStyle(palette.textPrimary.color)
                    Text("(\(viewModel.speedHistory.count))")
                        .foregroundStyle(palette.textSecondary.color)
                        .monospacedDigit()
                    Spacer(minLength: 4)
                    if !isHistoryExpanded, let latest = viewModel.speedHistory.first {
                        Text("\(Int(latest.downMbps.rounded())) / \(Int(latest.upMbps.rounded())) Mbps")
                            .foregroundStyle(palette.textSecondary.color)
                            .monospacedDigit()
                            .lineLimit(1)
                            .minimumScaleFactor(0.75)
                    }
                    Image(systemName: "chevron.down")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(palette.textSecondary.color)
                        .rotationEffect(.degrees(isHistoryExpanded ? 180 : 0))
                }
                .font(.caption.weight(.medium))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint(isHistoryExpanded ? "Collapse previous speed tests" : "Show previous speed tests")

            if isHistoryExpanded {
                VStack(spacing: 0) {
                    ForEach(Array(viewModel.speedHistory.enumerated()), id: \.element.id) { index, entry in
                        Button {
                            inspectedHistoryID = inspectedHistoryID == entry.id ? nil : entry.id
                            selectedActivity = nil
                        } label: {
                            historyRow(entry)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 9)
                                .background(
                                    inspectedHistoryID == entry.id
                                        ? Color.primary.opacity(0.06)
                                        : Color.clear,
                                    in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                                )
                        }
                        .buttonStyle(.plain)
                        if index < viewModel.speedHistory.count - 1 {
                            LinkWaveHairlineDivider(leading: 8)
                        }
                    }
                }

                HStack {
                    Text("Tap a run to inspect")
                        .font(.caption2)
                        .linkWaveText(.secondary)
                    Spacer()
                    Button("Clear") {
                        viewModel.clearSpeedTestHistory()
                        inspectedHistoryID = nil
                        isHistoryExpanded = false
                        selectedActivity = nil
                    }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(palette.textAccent)
                    .buttonStyle(.plain)
                }
                .padding(.top, 2)
            }
        }
    }

    private func historyRow(_ record: SpeedTestRecord) -> some View {
        let tiers = SpeedTestActivity.allCases.map { ActivityStrengthTier.rating(for: $0, record: record) }
        let summary: String
        let summaryColor: Color
        if tiers.allSatisfy({ $0 == .great }) {
            summary = "Great"
            summaryColor = .green
        } else if tiers.contains(.poor) {
            summary = "Slow"
            summaryColor = .red
        } else {
            summary = "Steady"
            summaryColor = .blue
        }

        return HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                Text(Self.formattedTime(record.timestamp))
                    .font(.caption.weight(.medium))
                    .foregroundStyle(palette.textPrimary.color)
                    .lineLimit(1)
                Text(summary)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(summaryColor)
            }
            Spacer(minLength: 6)
            VStack(alignment: .trailing, spacing: 3) {
                Text("\(Int(record.downMbps.rounded())) ↓ / \(Int(record.upMbps.rounded())) ↑")
                    .font(.caption.monospacedDigit().weight(.medium))
                    .foregroundStyle(palette.textPrimary.color)
                    .lineLimit(1)
                Text(String(format: "%.1f ms", record.pingMs))
                    .font(.caption2.monospacedDigit())
                    .linkWaveText(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    private func activityStrengthSection(for record: SpeedTestRecord) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Activity Strength")
                    .font(.caption.weight(.medium))
                    .linkWaveText(.secondary)
                Spacer()
                if isInspectingSavedRun {
                    Button("Close") {
                        inspectedHistoryID = nil
                        selectedActivity = nil
                    }
                    .font(.caption.weight(.medium))
                    .foregroundStyle(palette.textAccent)
                    .buttonStyle(.plain)
                } else {
                    Text("Tap to inspect")
                        .font(.caption2)
                        .linkWaveText(.secondary)
                }
            }

            LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                ForEach(SpeedTestActivity.allCases) { activity in
                    let tier = ActivityStrengthTier.rating(for: activity, record: record)
                    Button {
                        selectedActivity = activity
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: activity.symbol)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(tier.color)
                                .frame(width: 14)
                            Text(activity.title)
                                .font(.caption2.weight(.medium))
                                .foregroundStyle(palette.textPrimary.color)
                                .lineLimit(1)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            HStack(alignment: .bottom, spacing: 2) {
                                ForEach(0..<4, id: \.self) { index in
                                    Capsule()
                                        .fill(index < tier.rawValue ? tier.color : palette.textTertiary.color.opacity(0.34))
                                        .frame(width: 2.5, height: CGFloat(7 + index * 2))
                                }
                            }
                            Text(tier.title)
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(tier.color)
                                .frame(width: 34, alignment: .trailing)
                        }
                        .padding(.horizontal, 6)
                        .padding(.vertical, 7)
                        .frame(maxWidth: .infinity, minHeight: 34)
                        .background {
                            if selectedActivity == activity {
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(Color.primary.opacity(0.06))
                            }
                        }
                        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
            }

            Text(activityExplanation(for: selectedActivity, record: record))
                .font(.caption2)
                .linkWaveText(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.72)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func activityExplanation(for activity: SpeedTestActivity?, record: SpeedTestRecord) -> String {
        let ping = String(format: "%.0f", record.pingMs)
        let jitter = String(format: "%.0f", record.jitterMs)
        let down = String(format: "%.1f", record.downMbps)
        let up = String(format: "%.1f", record.upMbps)

        guard let activity else {
            let tiers = SpeedTestActivity.allCases.map { ActivityStrengthTier.rating(for: $0, record: record) }
            if tiers.allSatisfy({ $0 == .great }) { return "Ready for streaming, calls & low-lag gaming" }
            if tiers.contains(.poor) { return "High latency or weak uplink may disrupt calls & gaming" }
            return "Smooth for daily streaming, calls & play"
        }

        let tier = ActivityStrengthTier.rating(for: activity, record: record)
        switch activity {
        case .gaming:
            if tier == .poor { return "High \(ping) ms ping · \(jitter) ms jitter causes lag spikes" }
            if tier == .fair { return "\(ping) ms ping · \(jitter) ms jitter — playable with slight delay" }
            return "\(ping) ms ping · \(jitter) ms jitter for responsive online play"
        case .streaming:
            if record.downMbps >= 50 { return "\(down) Mbps downlink handles multiple 4K HDR streams" }
            if record.downMbps >= 25 { return "\(down) Mbps downlink handles smooth 4K streaming" }
            if record.downMbps >= 10 { return "\(down) Mbps downlink handles HD 1080p streaming" }
            return "\(down) Mbps downlink may buffer on HD streams"
        case .videoCalls:
            if tier == .poor { return "\(up) Mbps uplink & \(ping) ms ping may freeze video calls" }
            if tier == .fair { return "\(up) Mbps uplink works for calls; disable HD if choppy" }
            return "\(up) Mbps uplink keeps HD calls clear without dropouts"
        case .browsing:
            if tier == .poor { return "\(down) Mbps down feels sluggish on media-heavy pages" }
            if tier == .fair { return "\(down) Mbps down handles web browsing; large files take longer" }
            return "\(down) Mbps down loads pages and updates fast"
        }
    }

    private static func formattedTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = .current
        if Calendar.current.isDateInToday(date) {
            formatter.dateFormat = "'Today, 'h:mm a"
        } else {
            formatter.dateFormat = "MMM d, h:mm a"
        }
        return formatter.string(from: date)
            .replacingOccurrences(of: "AM", with: "am")
            .replacingOccurrences(of: "PM", with: "pm")
    }

    private func resultMetric(_ title: String, value: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption2)
                .linkWaveText(.secondary)
                .lineLimit(1)
            Text(value)
                .font(.system(.subheadline, design: .rounded).weight(.bold))
                .foregroundStyle(tint)
                .monospacedDigit()
                .tracking(-0.2)
                .animation(.linear(duration: 0.025), value: value)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func receiveProgress(_ update: SpeedTestProgress) {
        let previousPhase = progress.phase
        progress = update

        if let pingMs = update.pingMs { measuredPingMs = pingMs }
        if let jitterMs = update.jitterMs { measuredJitterMs = jitterMs }

        if update.phase != previousPhase {
            switch update.phase {
            case .ping:
                break
            case .download:
                emaDownloadMbps = 0
                targetDownloadMbps = 0
                displayedDownloadMbps = 0
                hasDownloadReading = false
                testDownloadMbps = 0
            case .upload:
                isReturningGatewayDownloadToLive = true
                gatewayDownloadReturnMbps = displayedDownloadMbps
                gatewayDownloadReturnTargetMbps = max(0, viewModel.traffic.downloadMbps)
                emaUploadMbps = 0
                targetUploadMbps = 0
                displayedUploadMbps = 0
                hasUploadReading = false
                testUploadMbps = 0
                scheduleInterpolation()
            }
        }

        guard let sampleMbps = update.currentMbps else { return }
        let elapsed = update.elapsed ?? 0
        guard elapsed >= 0.4 || update.fraction >= 1 else { return }

        let boundedSample = max(0, sampleMbps)
        switch update.phase {
        case .ping:
            return
        case .download:
            emaDownloadMbps = update.fraction >= 1
                ? boundedSample
                : (emaDownloadMbps == 0 ? boundedSample : emaDownloadMbps * 0.72 + boundedSample * 0.28)
            targetDownloadMbps = emaDownloadMbps
            hasDownloadReading = true
        case .upload:
            emaUploadMbps = update.fraction >= 1
                ? boundedSample
                : (emaUploadMbps == 0 ? boundedSample : emaUploadMbps * 0.72 + boundedSample * 0.28)
            targetUploadMbps = emaUploadMbps
            hasUploadReading = true
        }
        scheduleInterpolation()
    }

    private func scheduleInterpolation() {
        guard interpolationTask == nil else { return }
        interpolationTask = Task { @MainActor in
            while !Task.isCancelled {
                let downloadDelta = targetDownloadMbps - displayedDownloadMbps
                let uploadDelta = targetUploadMbps - displayedUploadMbps
                let gatewayDownloadDelta = gatewayDownloadReturnTargetMbps - gatewayDownloadReturnMbps
                let gatewayDownloadIsSettled = !isReturningGatewayDownloadToLive || abs(gatewayDownloadDelta) < 0.04

                if abs(downloadDelta) < 0.04 && abs(uploadDelta) < 0.04 && gatewayDownloadIsSettled {
                    withAnimation(.linear(duration: 0.04)) {
                        displayedDownloadMbps = targetDownloadMbps
                        displayedUploadMbps = targetUploadMbps
                        if isReturningGatewayDownloadToLive {
                            gatewayDownloadReturnMbps = gatewayDownloadReturnTargetMbps
                            testDownloadMbps = nil
                            isReturningGatewayDownloadToLive = false
                        } else if progress.phase == .download {
                            testDownloadMbps = displayedDownloadMbps
                        }
                        testUploadMbps = displayedUploadMbps
                    }
                    break
                }

                withAnimation(.linear(duration: 1.0 / 30.0)) {
                    displayedDownloadMbps += downloadDelta * 0.22
                    displayedUploadMbps += uploadDelta * 0.22
                    if isReturningGatewayDownloadToLive {
                        gatewayDownloadReturnMbps += gatewayDownloadDelta * 0.22
                        testDownloadMbps = gatewayDownloadReturnMbps
                    } else if progress.phase == .download {
                        testDownloadMbps = displayedDownloadMbps
                    }
                    testUploadMbps = displayedUploadMbps
                }
                try? await Task.sleep(nanoseconds: 33_333_333)
            }

            interpolationTask = nil
            guard !Task.isCancelled else { return }
            if let pendingResult {
                selectedActivity = nil
                self.pendingResult = nil
                scheduleOverrideCleanup()
            } else if !isRunning {
                scheduleOverrideCleanup()
            }
        }
    }

    private func scheduleOverrideCleanup() {
        overrideCleanupTask?.cancel()
        overrideCleanupTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_100_000_000)
            guard !isRunning else { return }
            withAnimation(.easeOut(duration: 0.2)) {
                testDownloadMbps = nil
                testUploadMbps = nil
            }
            overrideCleanupTask = nil
        }
    }

    private func startTest() {
        guard !isRunning, viewModel.canRunSpeedTest else { return }
        isRunning = true
        viewModel.clearActiveSpeedTestRecord()
        pendingResult = nil
        inspectedHistoryID = nil
        isHistoryExpanded = false
        selectedActivity = nil
        measuredPingMs = nil
        measuredJitterMs = nil
        emaDownloadMbps = 0
        emaUploadMbps = 0
        targetDownloadMbps = 0
        targetUploadMbps = 0
        displayedDownloadMbps = 0
        displayedUploadMbps = 0
        gatewayDownloadReturnMbps = 0
        gatewayDownloadReturnTargetMbps = 0
        isReturningGatewayDownloadToLive = false
        hasDownloadReading = false
        hasUploadReading = false
        overrideCleanupTask?.cancel()
        overrideCleanupTask = nil
        testDownloadMbps = 0
        testUploadMbps = 0
        errorMessage = nil
        progress = SpeedTestProgress(phase: .ping, fraction: 0, detail: "Preparing test")
        viewModel.setSpeedTestRunning(true)

        testTask = Task { @MainActor in
            defer {
                isRunning = false
                viewModel.setSpeedTestRunning(false)
                testTask = nil
                if pendingResult == nil {
                    targetDownloadMbps = 0
                    targetUploadMbps = 0
                    scheduleInterpolation()
                }
            }
            do {
                let completedResult = try await SpeedTestService.run { update in
                    receiveProgress(update)
                }
                viewModel.completeSpeedTest(completedResult)
                pendingResult = completedResult
                targetDownloadMbps = completedResult.downloadMbps
                targetUploadMbps = completedResult.uploadMbps
                hasDownloadReading = true
                hasUploadReading = true
                scheduleInterpolation()
            } catch is CancellationError {
                if errorMessage == nil { errorMessage = "Speed test stopped." }
            } catch let error as URLError where error.code == .cancelled {
                if errorMessage == nil { errorMessage = "Speed test stopped." }
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private static func speed(_ mbps: Double) -> String {
        if mbps >= 1_000 { return String(format: "%.2f Gbps", mbps / 1_000) }
        return String(format: "%.1f Mbps", mbps)
    }
}

private enum SpeedTestActivity: String, CaseIterable, Identifiable {
    case gaming
    case streaming
    case videoCalls
    case browsing

    var id: String { rawValue }

    var title: String {
        switch self {
        case .gaming: "Gaming"
        case .streaming: "Streaming"
        case .videoCalls: "Video Calls"
        case .browsing: "Browsing"
        }
    }

    var symbol: String {
        switch self {
        case .gaming: "gamecontroller.fill"
        case .streaming: "tv.fill"
        case .videoCalls: "video.fill"
        case .browsing: "globe"
        }
    }
}

private enum ActivityStrengthTier: Int {
    case poor = 1
    case fair = 2
    case good = 3
    case great = 4

    var title: String {
        switch self {
        case .great: "Great"
        case .good: "Good"
        case .fair: "Fair"
        case .poor: "Poor"
        }
    }

    var color: Color {
        switch self {
        case .great: .green
        case .good: .cyan
        case .fair: .orange
        case .poor: .red
        }
    }

    static func rating(for activity: SpeedTestActivity, record: SpeedTestRecord) -> ActivityStrengthTier {
        let ping = record.pingMs
        let jitter = record.jitterMs
        let down = record.downMbps
        let up = record.upMbps

        switch activity {
        case .gaming:
            if ping <= 20 && jitter <= 5 && down >= 15 && up >= 5 { return .great }
            if ping <= 45 && jitter <= 12 && down >= 10 && up >= 3 { return .good }
            if ping <= 80 && jitter <= 25 && down >= 5 && up >= 1 { return .fair }
            return .poor
        case .streaming:
            if down >= 50 { return .great }
            if down >= 25 { return .good }
            if down >= 10 { return .fair }
            return .poor
        case .videoCalls:
            if up >= 15 && down >= 15 && ping <= 40 && jitter <= 10 { return .great }
            if up >= 5 && down >= 8 && ping <= 75 && jitter <= 20 { return .good }
            if up >= 2 && down >= 3 && ping <= 120 { return .fair }
            return .poor
        case .browsing:
            if down >= 40 && ping <= 50 { return .great }
            if down >= 15 && ping <= 100 { return .good }
            if down >= 5 { return .fair }
            return .poor
        }
    }
}

private struct HomeSummaryRow: View {
    let summary: DataUsageSummary
    let onlineCount: Int
    let offlineCount: Int
    let openUsage: () -> Void
    let openClients: () -> Void
    @Environment(\.linkWaveThemePalette) private var palette

    private var todayTotalBytes: UInt64 {
        let (total, overflow) = summary.todayDownloadBytes.addingReportingOverflow(summary.todayUploadBytes)
        return overflow ? UInt64.max : total
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Button(action: openUsage) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Today’s Usage")
                        .font(.caption.weight(.semibold))
                        .linkWaveText(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    Text(Self.format(todayTotalBytes))
                        .font(.system(.title3, design: .rounded).weight(.bold))
                        .monospacedDigit()
                        .tracking(-0.3)
                        .lineLimit(1)
                        .minimumScaleFactor(0.72)
                        .contentTransition(.numericText())
                    HStack(spacing: 7) {
                        usageLine(
                            value: Self.formatGB(summary.todayDownloadBytes),
                            icon: "arrow.down",
                            tint: palette.textAccent
                        )
                        usageLine(
                            value: Self.formatUpload(summary.todayUploadBytes),
                            icon: "arrow.up",
                            tint: palette.textSecondary.color
                        )
                    }
                    .font(.system(size: 9, weight: .medium, design: .rounded))
                    .lineLimit(1)
                    HStack(spacing: 4) {
                        Text("Month: \(Self.formatGB(monthTotalBytes))")
                            .font(.caption2.monospacedDigit())
                            .linkWaveText(.secondary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                        Spacer(minLength: 0)
                        HStack(spacing: 3) {
                            Text("View usage")
                            Image(systemName: "chevron.right")
                        }
                        .font(.system(size: 9, weight: .medium, design: .rounded))
                        .foregroundStyle(palette.textAccent)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 108, maxHeight: .infinity, alignment: .topLeading)
                .linkWaveGlassCard()
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Today's usage, \(Self.format(todayTotalBytes)). Open Usage tab.")

            Button(action: openClients) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Connected Devices")
                        .font(.caption.weight(.semibold))
                        .linkWaveText(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                    HStack(spacing: 6) {
                        Circle()
                            .fill(.green)
                            .frame(width: 7, height: 7)
                            .shadow(color: .green.opacity(0.6), radius: 3)
                        Text("\(onlineCount) online")
                            .font(.system(.title3, design: .rounded).weight(.bold))
                            .monospacedDigit()
                            .tracking(-0.3)
                            .lineLimit(1)
                            .minimumScaleFactor(0.75)
                    }
                    Text("\(offlineCount) offline")
                        .font(.caption)
                        .linkWaveText(.secondary)
                    Spacer(minLength: 0)
                    Label("View clients", systemImage: "chevron.right")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(palette.textAccent)
                }
                .frame(maxWidth: .infinity, minHeight: 108, maxHeight: .infinity, alignment: .topLeading)
                .linkWaveGlassCard()
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Connected devices, \(onlineCount) online and \(offlineCount) offline. Open Clients tab.")
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private static func format(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: bytes), countStyle: .file)
    }

    private static func formatGB(_ bytes: UInt64) -> String {
        String(format: "%.2f GB", Double(bytes) / 1_000_000_000)
    }

    private static func formatUpload(_ bytes: UInt64) -> String {
        if bytes < 1_000_000_000 {
            return String(format: "%.0f MB", Double(bytes) / 1_000_000)
        }
        return formatGB(bytes)
    }

    private var monthTotalBytes: UInt64 {
        let (total, overflow) = summary.monthDownloadBytes.addingReportingOverflow(summary.monthUploadBytes)
        return overflow ? UInt64.max : total
    }

    private func usageLine(value: String, icon: String, tint: Color) -> some View {
        Label(value, systemImage: icon)
            .foregroundStyle(tint)
    }
}

private struct MetricsTileGrid: View {
    @ObservedObject var viewModel: MonitorViewModel
    @Environment(\.linkWaveThemePalette) private var palette

    private let columns = [
        GridItem(.flexible(), spacing: 12),
        GridItem(.flexible(), spacing: 12)
    ]

    var body: some View {
        let wan = viewModel.wan
        let optical = viewModel.optical
        let health = viewModel.health

        LazyVGrid(columns: columns, spacing: 12) {
            MetricTile(
                icon: "globe",
                iconTint: wan.isConnected ? .green : .orange,
                title: "WAN IP",
                value: wan.ipAddress.isEmpty ? "—" : wan.ipAddress,
                pill: wan.isCarrierNat ? ("CGNAT", .orange) : (wan.isConnected ? ("Up", .green) : nil),
                subtitle: [wan.connectionType, wan.vlanId.isEmpty ? "" : "VLAN \(wan.vlanId)"]
                    .filter { !$0.isEmpty }
                    .joined(separator: " · ")
            )

            MetricTile(
                icon: "clock.arrow.circlepath",
                iconTint: palette.textAccent,
                title: wan.connectionType == "IPoE" ? "WAN Uptime" : "PPPoE Uptime",
                value: InternetCard.uptime(wan.uptimeSeconds),
                subtitle: wan.connectionStatus.isEmpty ? nil : wan.connectionStatus
            )

            if let ontUptime = health.uptimeSeconds, ontUptime > 0 {
                MetricTile(
                    icon: "timer",
                    iconTint: palette.textAccent.opacity(0.72),
                    title: "ONT Uptime",
                    value: InternetCard.uptime(ontUptime),
                    subtitle: health.model.isEmpty ? nil : health.model
                )
            }

            if let tx = optical.txPowerDbm {
                MetricTile(
                    icon: "arrow.up.forward.circle",
                    iconTint: .purple,
                    title: "Tx Laser Power",
                    value: String(format: "%.2f dBm", tx),
                    subtitle: optical.temperatureC.map { String(format: "Temp %.0f °C", $0) }
                )
            } else if let temp = optical.temperatureC {
                MetricTile(
                    icon: "thermometer.medium",
                    iconTint: .orange,
                    title: "Optics Temp",
                    value: String(format: "%.0f °C", temp)
                )
            }

            Button {
                viewModel.selectedTab = .clients
            } label: {
                MetricTile(
                    icon: "laptopcomputer.and.iphone",
                    iconTint: palette.textAccent,
                    title: "Active Devices",
                    value: "\(viewModel.onlineDevices.count)",
                    pill: ("Clients", palette.textAccent),
                    subtitle: viewModel.devices.count > viewModel.onlineDevices.count
                        ? "\(viewModel.devices.count - viewModel.onlineDevices.count) offline"
                        : "Tap to view all"
                )
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Active devices: \(viewModel.onlineDevices.count). Open Clients tab.")
        }
    }
}

private struct WanExtrasCard: View {
    let wan: WanInfo

    var body: some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
            if !wan.gateway.isEmpty {
                Readout(label: "Gateway", value: wan.gateway)
            }
            if !wan.dnsServers.isEmpty {
                Readout(label: "ISP DNS", value: wan.dnsServers.joined(separator: ", "))
            }
        }
        .linkWaveGlassCard()
    }
}

private struct RebootSection: View {
    let isEnabled: Bool
    let action: () -> Void

    var body: some View {
        Button(role: .destructive, action: action) {
            Label("Restart Fibre Router", systemImage: "power")
                .font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity)
        }
        .liquidGlassActionButton(tint: .red)
        .disabled(!isEnabled)
        .padding(.top, 4)
        .accessibilityHint("Shows a confirmation prompt before restarting the router")
    }
}

private struct NoRouterCard: View {
    let openSettings: () -> Void
    @Environment(\.linkWaveThemePalette) private var palette

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "wifi.router")
                .font(.system(size: 40))
                .foregroundColor(palette.textAccent)
            Text("No Router Configured")
                .font(.headline)
            Text("Add a Huawei OptiXstar router profile in Settings to start live fibre monitoring.")
                .font(.subheadline)
                .linkWaveText(.secondary)
                .multilineTextAlignment(.center)
            Button("Open Settings", action: openSettings)
                .liquidGlassActionButton()
        }
        .frame(maxWidth: .infinity)
        .linkWaveGlassCard()
    }
}

private struct ErrorBanner: View {
    let message: String
    let suggestFallback: Bool
    let onTryFallback: () -> Void
    let openSettings: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(.orange)
                Text(message)
                    .font(.caption)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button("Settings", action: openSettings)
                    .font(.caption.weight(.semibold))
            }
            if suggestFallback {
                Button("Try 192.168.100.1", action: onTryFallback)
                    .font(.caption.weight(.semibold))
                    .liquidGlassSmallButton()
            }
        }
        .linkWaveGlassCard(padding: 12)
    }
}

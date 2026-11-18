import SwiftUI

public struct DashboardView: View {
    @ObservedObject var viewModel: MonitorViewModel
    @ObservedObject var settings: SettingsStore
    @State private var showSettings = false
    @State private var showConnectionDiagnosis = false
    @State private var startSpeedTestRequested = false
    @State private var latestSpeedTestResult: SpeedTestResult?
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
                            startRequested: $startSpeedTestRequested,
                            onCompleted: { latestSpeedTestResult = $0 }
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
            speedTest: latestSpeedTestResult
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
                        .fill(palette.textAccent.opacity(0.12))
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
        HStack(spacing: 10) {
            Image(systemName: statusSymbol)
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
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Button("Diagnose", action: openDiagnosis)
                .font(.caption.weight(.semibold))
                .frame(minHeight: 40)
                .liquidGlassSmallButton()
        }
        .linkWaveGlassCard(padding: 14)
        .accessibilityElement(children: .contain)
    }

    private var statusSymbol: String {
        switch diagnosis.severity {
        case .optimal: "checkmark.circle.fill"
        case .pending: "clock"
        case .warning: "exclamationmark.triangle.fill"
        case .critical: "xmark.octagon.fill"
        }
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
                .fill(LinearGradient(colors: [.white, Color(red: 0.80, green: 0.84, blue: 0.88)], startPoint: .top, endPoint: .bottom))
                .frame(width: 3, height: 22)
                .offset(x: -16, y: -13)
            Capsule()
                .fill(LinearGradient(colors: [.white, Color(red: 0.80, green: 0.84, blue: 0.88)], startPoint: .top, endPoint: .bottom))
                .frame(width: 3, height: 22)
                .offset(x: 16, y: -13)

            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(LinearGradient(
                    colors: [.white, Color(red: 0.94, green: 0.96, blue: 0.98)],
                    startPoint: .top,
                    endPoint: .bottom
                ))
                .frame(width: 62, height: 25)
                .overlay {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .stroke(palette.textPrimary.color.opacity(0.12), lineWidth: 0.8)
                }
                .overlay(alignment: .bottomLeading) {
                    HStack(spacing: 5) {
                        led("PON", color: ponLight)
                        led("WLAN", color: wlanLight)
                    }
                    .padding(.leading, 7)
                    .padding(.bottom, 5)
                }
                .overlay(alignment: .topTrailing) {
                    HStack(spacing: 2) {
                        ForEach(0..<3, id: \.self) { _ in
                            Capsule().fill(Color.gray.opacity(0.38)).frame(width: 1.5, height: 5)
                        }
                    }
                    .padding(.top, 5)
                    .padding(.trailing, 7)
                }
                .shadow(color: .black.opacity(0.16), radius: 3, y: 2)
        }
        .frame(width: 66, height: 50)
        .accessibilityLabel("Huawei OptiXstar HG8145X6 router with PON and WLAN status lights")
    }

    private func led(_ label: String, color: Color) -> some View {
        HStack(spacing: 2) {
            Circle()
                .fill(color)
                .frame(width: 4, height: 4)
                .shadow(color: color.opacity(0.8), radius: 2)
            Text(label)
                .font(.system(size: 4.5, weight: .bold, design: .rounded))
                .foregroundStyle(Color.gray)
        }
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
    @Environment(\.linkWaveThemePalette) private var palette

    var body: some View {
        HStack(spacing: 13) {
            speedMetric(
                title: "Download",
                value: downloadOverrideMbps ?? traffic.downloadMbps,
                icon: "arrow.down",
                tint: palette.textAccent
            )

            Rectangle()
                .fill(palette.textTertiary.color.opacity(0.45))
                .frame(width: 1, height: 35)

            speedMetric(
                title: "Upload",
                value: uploadOverrideMbps ?? traffic.uploadMbps,
                icon: "arrow.up",
                tint: palette.textAccent.opacity(0.72)
            )
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Live speed")
        .accessibilityValue(
            "Download \(Self.accessibilitySpeed(traffic.downloadMbps)), upload \(Self.accessibilitySpeed(traffic.uploadMbps))"
        )
    }

    private func speedMetric(title: String, value: Double, icon: String, tint: Color) -> some View {
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
                        .contentTransition(.numericText())
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
}

private struct SpeedTestCard: View {
    @ObservedObject var viewModel: MonitorViewModel
    @Binding var testDownloadMbps: Double?
    @Binding var testUploadMbps: Double?
    @Binding var startRequested: Bool
    let onCompleted: (SpeedTestResult) -> Void
    @State private var result: SpeedTestResult?
    @State private var progress = SpeedTestProgress(phase: .ping, fraction: 0, detail: "Preparing test")
    @State private var errorMessage: String?
    @State private var isRunning = false
    @State private var testTask: Task<Void, Never>?
    @Environment(\.linkWaveThemePalette) private var palette

    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            HStack(spacing: 9) {
                Image(systemName: "speedometer")
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(palette.textAccent)
                Text("Speed Test")
                    .font(.headline.weight(.semibold))
                    .linkWaveText(.primary)
                Spacer()
                if isRunning {
                    Text(progress.phase.rawValue.uppercased())
                        .font(.system(size: 9, weight: .bold, design: .rounded))
                        .foregroundStyle(palette.textAccent)
                        .lineLimit(1)
                }
            }

            if let result {
                HStack(spacing: 0) {
                    resultMetric("Ping", value: String(format: "%.0f ms", result.pingMs), tint: palette.textPrimary.color)
                    resultMetric("Jitter", value: String(format: "%.0f ms", result.jitterMs), tint: palette.textPrimary.color)
                    resultMetric("Downlink", value: Self.speed(result.downloadMbps), tint: palette.textAccent)
                    resultMetric("Uplink", value: Self.speed(result.uploadMbps), tint: palette.textAccent.opacity(0.72))
                }
            } else {
                HStack(spacing: 0) {
                    resultMetric("Ping", value: "-- ms", tint: palette.textPrimary.color)
                    resultMetric("Jitter", value: "-- ms", tint: palette.textPrimary.color)
                    if isRunning {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(progress.phase == .ping ? "Latency" : (progress.phase == .download ? "Download" : "Upload"))
                                .font(.caption2)
                                .linkWaveText(.secondary)
                            Text(progress.detail)
                                .font(.system(.caption, design: .rounded).weight(.semibold))
                                .linkWaveText(.primary)
                                .lineLimit(1)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
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
                    Button("Stop", action: stopTest)
                        .font(.caption.weight(.semibold))
                        .buttonStyle(.bordered)
                        .tint(palette.textAccent)
                }
            } else {
                Button(action: startTest) {
                    Label(startButtonTitle, systemImage: startButtonSymbol)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(viewModel.canRunSpeedTest ? palette.textAccent : palette.textSecondary.color)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                }
                .buttonStyle(.plain)
                .linkWaveInteractiveGlassCapsule()
                .disabled(!viewModel.settings.isConfigured || !viewModel.canRunSpeedTest)
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
        .onChange(of: startRequested) { requested in
            guard requested else { return }
            startRequested = false
            startTest()
        }
        .onDisappear { testTask?.cancel() }
    }

    private var startButtonTitle: String {
        if !viewModel.isConnectedToWiFi { return "Connect to Wi-Fi to run Speed Test" }
        if !viewModel.hasInternetPath { return "No Internet for Speed Test" }
        return result == nil ? "Start Test" : "Run Again"
    }

    private var startButtonSymbol: String {
        viewModel.canRunSpeedTest ? (result == nil ? "play.fill" : "arrow.clockwise") : "wifi.slash"
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
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func startTest() {
        guard !isRunning, viewModel.canRunSpeedTest else { return }
        isRunning = true
        testDownloadMbps = 0
        testUploadMbps = 0
        result = nil
        errorMessage = nil
        progress = SpeedTestProgress(phase: .ping, fraction: 0, detail: "Preparing test")
        viewModel.setSpeedTestRunning(true)

        testTask = Task { @MainActor in
            defer {
                isRunning = false
                viewModel.setSpeedTestRunning(false)
                testTask = nil
                testDownloadMbps = 0
                testUploadMbps = 0
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 1_100_000_000)
                    guard !isRunning else { return }
                    testDownloadMbps = nil
                    testUploadMbps = nil
                }
            }
            do {
                let completedResult = try await SpeedTestService.run { update in
                    progress = update
                    switch update.phase {
                    case .ping:
                        testDownloadMbps = 0
                        testUploadMbps = 0
                    case .download:
                        testDownloadMbps = update.currentMbps ?? 0
                        testUploadMbps = 0
                    case .upload:
                        testDownloadMbps = 0
                        testUploadMbps = update.currentMbps ?? 0
                    }
                }
                result = completedResult
                onCompleted(completedResult)
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
                        .lineLimit(1)
                        .minimumScaleFactor(0.72)
                        .contentTransition(.numericText())
                    HStack(spacing: 7) {
                        Label(Self.format(summary.todayDownloadBytes), systemImage: "arrow.down")
                            .foregroundStyle(palette.textAccent)
                        Label(Self.format(summary.todayUploadBytes), systemImage: "arrow.up")
                            .foregroundStyle(palette.textSecondary.color)
                    }
                    .font(.system(size: 9, weight: .medium, design: .rounded))
                    .lineLimit(1)
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

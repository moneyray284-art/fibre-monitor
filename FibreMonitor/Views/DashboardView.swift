import SwiftUI

public struct DashboardView: View {
    @ObservedObject var viewModel: MonitorViewModel
    @ObservedObject var settings: SettingsStore
    @State private var showSettings = false
    @State private var showConnectionDiagnosis = false
    @State private var startSpeedTestRequested = false
    @StateObject private var speedTestCoordinator: SpeedTestCoordinator
    @Environment(\.colorScheme) private var colorScheme

    public init(viewModel: MonitorViewModel) {
        self.viewModel = viewModel
        self.settings = viewModel.settings
        _speedTestCoordinator = StateObject(wrappedValue: SpeedTestCoordinator(viewModel: viewModel))
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
                            testDownloadMbps: speedTestCoordinator.liveDownloadMbps,
                            testUploadMbps: speedTestCoordinator.liveUploadMbps,
                            testPhase: speedTestCoordinator.phase == .idle ? nil : speedTestCoordinator.phase
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
                            coordinator: speedTestCoordinator,
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
    let testPhase: SpeedTestPhase?
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.linkWaveThemePalette) private var palette

    private var darkPalette: ThemePalette { settings.themePalette(for: .dark) }
    private var lightPalette: ThemePalette { settings.themePalette(for: .light) }
    private var activeAccent: Color {
        colorScheme == .dark ? darkPalette.textAccent : lightPalette.textAccent
    }
    private var darkBase: Color { darkPalette.backgroundPrimary }
    private var heroPrimary: Color {
        colorScheme == .dark ? .white : lightPalette.textPrimary.color
    }
    private var heroSecondary: Color {
        colorScheme == .dark ? Color.white.opacity(0.66) : lightPalette.textSecondary.color
    }
    private var heroSurfaceBase: Color {
        colorScheme == .dark ? darkBase : lightPalette.backgroundSecondary
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            heroHeader
            CompactSpeedCard(
                traffic: viewModel.traffic,
                downloadOverrideMbps: testDownloadMbps,
                uploadOverrideMbps: testUploadMbps,
                activePhase: testPhase,
                isTestRunning: viewModel.isSpeedTestRunning,
                accent: activeAccent,
                primary: heroPrimary,
                secondary: heroSecondary,
                isDark: colorScheme == .dark
            )
            Rectangle()
                .fill(heroPrimary.opacity(colorScheme == .dark ? 0.13 : 0.10))
                .frame(height: 0.5)
            HStack(spacing: 6) {
                Image(systemName: "clock")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(activeAccent)
                Text("Last updated: \(viewModel.lastUpdate?.formatted(date: .omitted, time: .shortened) ?? "—")")
                    .font(.caption2)
                    .monospacedDigit()
                    .foregroundStyle(heroSecondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Spacer(minLength: 4)
                if viewModel.isLoggedOut {
                    Button("Reconnect") {
                        viewModel.reconnectSession()
                    }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(activeAccent)
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(16)
        .background {
            gatewayAtmosphere
        }
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .linkWaveGlassCard(padding: 0)
        .overlay {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(activeAccent.opacity(colorScheme == .dark ? 0.30 : 0.16), lineWidth: 0.8)
        }
        .shadow(color: activeAccent.opacity(colorScheme == .dark ? 0.11 : 0.06), radius: 18, y: 7)
        .accessibilityElement(children: .combine)
    }

    private var gatewayAtmosphere: some View {
        GeometryReader { geometry in
            ZStack {
                if colorScheme == .dark {
                    darkBase
                } else {
                    Color.clear
                }
                RadialGradient(
                    colors: [activeAccent.opacity(colorScheme == .dark ? 0.25 : 0.10), .clear],
                    center: .topLeading,
                    startRadius: 0,
                    endRadius: geometry.size.width * 0.78
                )
                RadialGradient(
                    colors: [activeAccent.opacity(colorScheme == .dark ? 0.18 : 0.075), .clear],
                    center: .bottomTrailing,
                    startRadius: 0,
                    endRadius: geometry.size.width * 0.68
                )
                GatewayWave()
                    .fill(LinearGradient(
                        colors: [
                            activeAccent.opacity(colorScheme == .dark ? 0.09 : 0.045),
                            heroSurfaceBase.opacity(colorScheme == .dark ? 0.48 : 0.12)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ))
            }
        }
        .accessibilityHidden(true)
    }

    private var heroHeader: some View {
        HStack(spacing: 10) {
            HuaweiOptiXstarIllustration(
                isOnline: viewModel.isConnected,
                wifiOnline: wifiOnline,
                accent: activeAccent,
                surfaceBase: heroSurfaceBase,
                chassisTop: palette.backgroundElevated,
                chassisBottom: palette.backgroundTertiary,
                foreground: heroPrimary,
                isDark: colorScheme == .dark
            )
            .frame(width: 70, height: 70)
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 5) {
                    Circle()
                        .fill(statusColor)
                        .frame(width: 6, height: 6)
                        .shadow(color: statusColor.opacity(0.8), radius: 3)
                    Text(statusText)
                        .font(.system(size: 9, weight: .bold, design: .rounded))
                        .foregroundStyle(statusColor)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(statusColor.opacity(0.13), in: Capsule())
                .overlay(Capsule().stroke(statusColor.opacity(0.28), lineWidth: 0.7))

                Text(settings.activeProfile?.routerDisplayName ?? "Fibre Router")
                    .font(.system(.subheadline, design: .rounded).weight(.bold))
                    .foregroundStyle(heroPrimary)
                    .lineLimit(2)
                    .minimumScaleFactor(0.82)
                Text(viewModel.displayModelName)
                    .font(.caption2.monospaced())
                    .foregroundStyle(heroSecondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            FibreSignalMeter(
                rxPowerDbm: viewModel.optical.rxPowerDbm,
                accent: activeAccent,
                primary: heroPrimary,
                secondary: heroSecondary
            )
        }
    }

    private var statusColor: Color {
        if !viewModel.isConnectedToWiFi { return .red }
        if !viewModel.hasInternetPath { return .orange }
        if viewModel.isLoggedOut { return heroSecondary }
        switch viewModel.connectionState {
        case .connected: return .green
        case .connecting, .temporarilyLocked: return .orange
        case .invalidCredentials, .offline: return .red
        }
    }

    private var statusText: String {
        if !viewModel.isConnectedToWiFi { return "No Wi-Fi" }
        if !viewModel.hasInternetPath { return "No internet" }
        if viewModel.isLoggedOut { return "Reconnect" }
        switch viewModel.connectionState {
        case .connected:
            return "Connected"
        case .connecting:
            return "Connecting"
        case .temporarilyLocked:
            return "Login paused"
        case .invalidCredentials:
            return "Login rejected"
        case .offline:
            return "Offline"
        }
    }

    private var wifiOnline: Bool {
        let reportedStates = viewModel.wifi.radios.map(\.enabled) + viewModel.wifi.networks.map(\.enabled)
        return reportedStates.isEmpty ? viewModel.isConnected : reportedStates.contains(true)
    }
}

private struct GatewayWave: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.height * 0.82))
        path.addCurve(
            to: CGPoint(x: rect.maxX, y: rect.height * 0.70),
            control1: CGPoint(x: rect.width * 0.34, y: rect.height * 0.62),
            control2: CGPoint(x: rect.width * 0.68, y: rect.height * 0.98)
        )
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

private struct ConnectionCheckCard: View {
    let diagnosis: ConnectionDiagnosis
    let openDiagnosis: () -> Void
    @Environment(\.linkWaveThemePalette) private var palette

    var body: some View {
        Button(action: openDiagnosis) {
            HStack(spacing: 10) {
                Image(systemName: "dot.radiowaves.left.and.right")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(statusColor)
                    .frame(width: 36, height: 36)
                    .background(statusColor.opacity(0.13), in: Circle())
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 3) {
                    Text("Connection Check · \(diagnosis.severity.label)")
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(2)
                    Text(diagnosis.inlineHint)
                        .font(.caption.monospacedDigit())
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
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(palette.backgroundTertiary.opacity(0.72), in: Capsule())
            }
            .contentShape(Rectangle())
            .padding(2)
            .background(statusColor.opacity(0.07), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
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
        case .critical: .pink
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
    let accent: Color
    let surfaceBase: Color
    let chassisTop: Color
    let chassisBottom: Color
    let foreground: Color
    let isDark: Bool

    private var ponLight: Color { isOnline ? .green : .red }
    private var wlanLight: Color { isOnline && wifiOnline ? accent : .orange }

    var body: some View {
        ZStack {
            ForEach(0..<3, id: \.self) { index in
                Circle()
                    .stroke(accent.opacity(0.17 - Double(index) * 0.04), lineWidth: 0.8)
                    .frame(width: CGFloat(42 + index * 13), height: CGFloat(42 + index * 13))
                    .offset(y: 3)
            }

            Circle()
                .fill(
                    RadialGradient(
                        colors: [accent.opacity(0.14), surfaceBase.opacity(0.06), .clear],
                        center: .center,
                        startRadius: 0,
                        endRadius: 35
                    )
                )
                .frame(width: 70, height: 70)

            Capsule()
                .fill(LinearGradient(colors: [accent.opacity(0.88), accent.opacity(0.38)], startPoint: .leading, endPoint: .trailing))
                .frame(width: 2, height: 22)
                .rotationEffect(.degrees(-12))
                .offset(x: -20, y: -16)
            Capsule()
                .fill(LinearGradient(colors: [accent.opacity(0.88), accent.opacity(0.38)], startPoint: .leading, endPoint: .trailing))
                .frame(width: 2, height: 22)
                .rotationEffect(.degrees(12))
                .offset(x: 20, y: -16)

            Image(systemName: "wifi")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(accent.opacity(0.8))
                .offset(y: -24)

            RouterChassis()
                .fill(LinearGradient(
                    colors: [chassisTop, chassisBottom],
                    startPoint: .top,
                    endPoint: .bottom
                ))
                .frame(width: 58, height: 22)
                .overlay {
                    RouterChassis().stroke(accent.opacity(isDark ? 0.48 : 0.34), lineWidth: 0.8)
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
                            Capsule().fill(foreground.opacity(isDark ? 0.22 : 0.18)).frame(width: 11, height: 1)
                        }
                    }
                    .padding(.top, 8)
                    .padding(.trailing, 7)
                }
                .overlay {
                    Rectangle()
                        .fill(foreground.opacity(isDark ? 0.12 : 0.08))
                        .frame(height: 1)
                        .padding(.horizontal, 8)
                        .offset(y: 1)
                }
                .shadow(color: foreground.opacity(isDark ? 0.20 : 0.09), radius: 5, y: 3)
        }
        .frame(width: 70, height: 70)
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
    let rxPowerDbm: Double?
    let accent: Color
    let primary: Color
    let secondary: Color

    private var level: Int {
        guard let rxPowerDbm else { return 0 }
        if rxPowerDbm >= -24 { return 4 }
        if rxPowerDbm > -27 { return 3 }
        if rxPowerDbm > -29 { return 2 }
        return 1
    }

    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            HStack(alignment: .bottom, spacing: 2) {
                ForEach(0..<4, id: \.self) { index in
                    Capsule()
                        .fill(index < level ? accent : accent.opacity(0.20))
                        .frame(width: 4, height: CGFloat(7 + index * 4))
                }
            }
            Text(rxPowerDbm.map { String(format: "%.2f dBm", $0) } ?? "— dBm")
                .font(.caption2.weight(.semibold).monospacedDigit())
                .foregroundStyle(rxPowerDbm == nil ? secondary : primary)
            Text("FIBRE RX")
                .font(.system(size: 8, weight: .bold, design: .rounded))
                .foregroundStyle(secondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Fibre signal")
        .accessibilityValue(rxPowerDbm.map { "\(level) of 4 bars, \(String(format: "%.2f", $0)) dBm" } ?? "Unavailable")
    }
}

private struct CompactSpeedCard: View {
    let traffic: TrafficState
    var downloadOverrideMbps: Double? = nil
    var uploadOverrideMbps: Double? = nil
    let activePhase: SpeedTestProgress.Phase?
    let isTestRunning: Bool
    let accent: Color
    let primary: Color
    let secondary: Color
    let isDark: Bool
    @State private var idleDownloadMbps = 0.0
    @State private var idleUploadMbps = 0.0

    private var displayedDownloadMbps: Double { downloadOverrideMbps ?? idleDownloadMbps }
    private var displayedUploadMbps: Double { uploadOverrideMbps ?? idleUploadMbps }
    private var downloadTint: Color {
        isTestRunning && activePhase == .download ? accent : accent.opacity(0.68)
    }
    private var uploadTint: Color {
        isTestRunning && activePhase == .upload ? .green : accent.opacity(0.52)
    }

    var body: some View {
        HStack(spacing: 13) {
            speedMetric(
                title: "Download",
                value: displayedDownloadMbps,
                icon: "arrow.down",
                tint: downloadTint,
                isActive: isTestRunning && activePhase == .download
            )

            Rectangle()
                .fill(primary.opacity(isDark ? 0.16 : 0.12))
                .frame(width: 1, height: 35)

            speedMetric(
                title: "Upload",
                value: displayedUploadMbps,
                icon: "arrow.up",
                tint: uploadTint,
                isActive: isTestRunning && activePhase == .upload
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

    private func speedMetric(title: String, value: Double, icon: String, tint: Color, isActive: Bool) -> some View {
        HStack(spacing: 9) {
            Image(systemName: icon)
                .font(.subheadline.weight(.bold))
                .foregroundStyle(tint)
                .frame(width: 30, height: 30)
                .background(tint.opacity(0.12), in: Circle())

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(secondary)
                Text(value >= 1 ? String(format: value >= 100 ? "%.0f" : "%.1f", value) : String(format: "%.0f", value * 1_000))
                    .font(.system(.title3, design: .rounded).weight(.bold))
                    .foregroundStyle(isActive ? tint : primary)
                    .monospacedDigit()
                    .tracking(-0.3)
                    .transaction { $0.animation = nil }
                Text(value >= 1 ? "Mbps" : "Kbps")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(secondary)
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
    @ObservedObject var coordinator: SpeedTestCoordinator
    @Binding var startRequested: Bool
    @State private var isHistoryExpanded = false
    @State private var isResultsDrawerExpanded = false
    @State private var selectedActivity: SpeedTestActivity?
    @Environment(\.linkWaveThemePalette) private var palette
    @Environment(\.colorScheme) private var colorScheme

    private var instrumentAccentOpacity: Double {
        colorScheme == .dark ? 0.12 : 0.08
    }

    private var inspectedRecord: SpeedTestRecord? {
        viewModel.speedHistory.first { $0.id == coordinator.inspectedHistoryID }
    }

    private var displayedRecord: SpeedTestRecord? {
        inspectedRecord ?? coordinator.completedRecord ?? viewModel.activeSpeedTestRecord
    }

    private var isInspectingSavedRun: Bool { inspectedRecord != nil }

    private var shouldShowResultsDrawer: Bool {
        coordinator.isRunning || coordinator.phase != .idle
            || (isResultsDrawerExpanded && (coordinator.hasCompletedRun || inspectedRecord != nil))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            instrumentBay
            if shouldShowResultsDrawer {
                LinkWaveHairlineDivider()
                VStack(alignment: .leading, spacing: 13) {
                    telemetryProgressBody
                    if !coordinator.isRunning,
                       let record = inspectedRecord ?? coordinator.completedRecord {
                        activityStrengthSection(for: record)
                    }
                }
                .transition(.move(edge: .top).combined(with: .opacity))
            }

            if let errorMessage = coordinator.errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !coordinator.isRunning, !viewModel.speedHistory.isEmpty {
                LinkWaveHairlineDivider()
                previousTestsSection
            }
        }
        .animation(.easeOut(duration: 0.28), value: shouldShowResultsDrawer)
        .linkWaveGlassCard()
        .accessibilityElement(children: .contain)
        .onChange(of: viewModel.canRunSpeedTest) { isAvailable in
            guard !isAvailable, coordinator.isRunning else { return }
            coordinator.cancelSpeedTest(message: viewModel.isConnectedToWiFi
                ? "Speed test stopped because the internet path was lost."
                : "Speed test stopped because Wi-Fi disconnected.")
        }
        .onChange(of: startRequested) { requested in
            guard requested else { return }
            startRequested = false
            startTest()
        }
        .onDisappear {
            coordinator.cancelSpeedTest()
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

    private var instrumentBay: some View {
        VStack(alignment: .leading, spacing: 15) {
            HStack(spacing: 9) {
                Image(systemName: "speedometer")
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(palette.textAccent)
                    .frame(width: 36, height: 36)
                    .background(palette.textAccent.opacity(0.11), in: RoundedRectangle(cornerRadius: 11, style: .continuous))

                VStack(alignment: .leading, spacing: 2) {
                    Text("Speed Test")
                        .font(.headline.weight(.semibold))
                        .linkWaveText(.primary)
                    Text(consoleStatus)
                        .font(.caption2.monospacedDigit())
                        .linkWaveText(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
                Spacer(minLength: 4)
                if coordinator.isRunning {
                    Button("Stop", action: stopTest)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(palette.textAccent)
                        .padding(.horizontal, 11)
                        .padding(.vertical, 7)
                        .buttonStyle(.plain)
                        .linkWaveInteractiveGlassCapsule()
                } else {
                    Button(action: startTest) {
                        Label(displayedRecord == nil ? "Start Test" : "Run Again", systemImage: startButtonSymbol)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(viewModel.canRunSpeedTest ? palette.textAccent : palette.textSecondary.color)
                            .padding(.horizontal, 11)
                            .padding(.vertical, 7)
                    }
                    .buttonStyle(.plain)
                    .linkWaveInteractiveGlassCapsule()
                    .disabled(!viewModel.settings.isConfigured || !viewModel.canRunSpeedTest)
                    .accessibilityLabel(startButtonTitle)
                }
            }

            HStack(spacing: 9) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(primarySpeedTitle)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(coordinator.isRunning && coordinator.phase == .upload ? Color.green : palette.textSecondary.color)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .frame(height: 14, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(primarySpeedValue)
                        .font(.system(.title2, design: .rounded).weight(.bold))
                        .foregroundStyle(coordinator.isRunning && coordinator.phase == .upload ? Color.green : palette.textPrimary.color)
                        .monospacedDigit()
                        .tracking(-0.4)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                        .transaction { $0.animation = nil }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                latencyTile(
                    title: "Ping",
                    value: displayedRecord.map { String(format: "%.0f ms", $0.pingMs) }
                        ?? coordinator.measuredPingMs.map { String(format: "%.0f ms", $0) } ?? "-- ms"
                )
                latencyTile(
                    title: "Jitter",
                    value: displayedRecord.map { String(format: "%.0f ms", $0.jitterMs) }
                        ?? coordinator.measuredJitterMs.map { String(format: "%.0f ms", $0) } ?? "-- ms"
                )
            }
        }
        .padding(14)
        .background {
            ZStack {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(LinearGradient(
                        colors: [
                            palette.textAccent.opacity(instrumentAccentOpacity),
                            palette.textAccent.opacity(instrumentAccentOpacity * 0.25),
                            .clear
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ))
                SpeedTestMicroGrid(accent: palette.textAccent)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                RadialGradient(
                    colors: [palette.textAccent.opacity(instrumentAccentOpacity), .clear],
                    center: .topTrailing,
                    startRadius: 0,
                    endRadius: 150
                )
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
        }
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(palette.textAccent.opacity(0.11), lineWidth: 0.7)
        }
    }

    private var telemetryProgressBody: some View {
        VStack(alignment: .leading, spacing: 12) {
            speedProgressRow(
                title: "Download",
                phase: .download,
                tint: palette.textAccent,
                recordSpeed: displayedRecord?.downMbps
            )
            speedProgressRow(
                title: "Upload",
                phase: .upload,
                tint: .green,
                recordSpeed: displayedRecord?.upMbps
            )
        }
    }

    private var consoleStatus: String {
        if coordinator.isRunning {
            switch coordinator.phase {
            case .ping: return "Preparing..."
            case .download: return "Testing download"
            case .upload: return "Testing upload link..."
            case .idle: return "Ready to benchmark"
            }
        } else if let inspectedRecord {
            return "Saved · \(Self.formattedTime(inspectedRecord.timestamp))"
        } else if coordinator.hasCompletedRun || displayedRecord != nil {
            return "Benchmark complete"
        } else {
            return "Ready to benchmark"
        }
    }

    private var primarySpeedTitle: String {
        guard coordinator.isRunning else { return "Peak Download" }
        switch coordinator.phase {
        case .ping: return "Throughput"
        case .download: return "Live Download"
        case .upload: return "Live Upload"
        case .idle: return "Peak Download"
        }
    }

    private var primarySpeedValue: String {
        if coordinator.isRunning {
            switch coordinator.phase {
            case .ping: return "-- Mbps"
            case .download:
                return coordinator.hasDownloadReading ? Self.speed(coordinator.progress.liveDownKbps / 1_000) : "-- Mbps"
            case .upload:
                return coordinator.hasUploadReading ? Self.speed(coordinator.progress.liveUpKbps / 1_000) : "-- Mbps"
            case .idle: return "-- Mbps"
            }
        }
        return displayedRecord.map { Self.speed($0.downMbps) } ?? "-- Mbps"
    }

    private func latencyTile(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.caption2.weight(.medium))
                .linkWaveText(.secondary)
            Text(value)
                .font(.system(.caption, design: .rounded).weight(.bold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(width: 68, alignment: .leading)
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .background(palette.backgroundTertiary.opacity(0.46), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .stroke(palette.textSecondary.color.opacity(0.13), lineWidth: 0.7)
        }
    }

    private func speedProgressRow(
        title: String,
        phase: SpeedTestProgress.Phase,
        tint: Color,
        recordSpeed: Double?
    ) -> some View {
        let currentMbps: Double
        let status: String
        if !coordinator.isRunning {
            currentMbps = recordSpeed ?? 0
            status = recordSpeed.map { String(format: "%.1f Mbps", $0) } ?? "Ready"
        } else {
            switch coordinator.phase {
            case .ping:
                currentMbps = 0
                status = phase == .download ? "Preparing..." : "Queued"
            case .download:
                if phase == .download {
                    currentMbps = coordinator.progress.liveDownKbps / 1_000
                    status = coordinator.hasDownloadReading ? String(format: "%.1f Mbps", currentMbps) : "Measuring..."
                } else {
                    currentMbps = 0
                    status = "Queued"
                }
            case .upload:
                if phase == .download {
                    currentMbps = coordinator.progress.testDownMbps ?? 0
                    status = coordinator.hasDownloadReading ? String(format: "%.1f Mbps", currentMbps) : "Preparing..."
                } else {
                    currentMbps = coordinator.progress.liveUpKbps / 1_000
                    status = coordinator.hasUploadReading
                        ? String(format: "%.1f Mbps", currentMbps)
                        : "Measuring..."
                }
            case .idle:
                currentMbps = recordSpeed ?? 0
                status = recordSpeed.map { String(format: "%.1f Mbps", $0) } ?? "Ready"
            }
        }
        let fraction = min(1, max(0, currentMbps / coordinator.speedScale))

        return VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(tint)
                Spacer(minLength: 4)
                Text(status)
                    .font(.caption2.monospacedDigit().weight(.medium))
                    .linkWaveText(.secondary)
                    .lineLimit(1)
            }
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(palette.backgroundTertiary.opacity(0.78))
                        .frame(height: 10)
                    Capsule()
                        .fill(tint.opacity(0.86))
                        .frame(width: geometry.size.width * CGFloat(min(max(fraction, 0), 1)), height: 10)
                        .animation(.easeOut(duration: 0.12), value: fraction)
                    ForEach([0.25, 0.5, 0.75], id: \.self) { tick in
                        Rectangle()
                            .fill(palette.textSecondary.color.opacity(0.34))
                            .frame(width: 1, height: 10)
                            .position(x: geometry.size.width * CGFloat(tick), y: 5)
                    }
                }
            }
            .frame(height: 14)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(title) speed test progress")
            .accessibilityValue(status)
        }
    }

    private func stopTest() {
        coordinator.cancelSpeedTest(message: "Speed test stopped.")
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
                            withAnimation(.easeOut(duration: 0.28)) {
                                coordinator.inspectedHistoryID = entry.id
                                selectedActivity = nil
                                isResultsDrawerExpanded = true
                            }
                        } label: {
                            historyRow(entry)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 9)
                                .background(
                                    coordinator.inspectedHistoryID == entry.id
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
                        coordinator.inspectedHistoryID = nil
                        isHistoryExpanded = false
                        selectedActivity = nil
                        isResultsDrawerExpanded = false
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
                    .font(.caption.weight(.medium).monospacedDigit())
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
                        coordinator.inspectedHistoryID = nil
                        selectedActivity = nil
                        isResultsDrawerExpanded = false
                    }
                    .font(.caption.weight(.medium))
                    .foregroundStyle(palette.textAccent)
                    .buttonStyle(.plain)
                } else {
                    Button("Hide") {
                        isResultsDrawerExpanded = false
                    }
                    .font(.caption.weight(.medium))
                    .foregroundStyle(palette.textAccent)
                    .buttonStyle(.plain)
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
                .monospacedDigit()
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

    private func startTest() {
        guard !coordinator.isRunning, viewModel.canRunSpeedTest else { return }
        isResultsDrawerExpanded = true
        coordinator.inspectedHistoryID = nil
        isHistoryExpanded = false
        selectedActivity = nil
        let host = viewModel.settings.host
        let gatewayURL = URL(string: host.contains("://") ? host : "http://\(host)")
        coordinator.startSpeedTest(gatewayURL: gatewayURL)
    }

    private static func speed(_ mbps: Double) -> String {
        if mbps >= 1_000 { return String(format: "%.2f Gbps", mbps / 1_000) }
        return String(format: "%.1f Mbps", mbps)
    }
}

private struct SpeedTestMicroGrid: View {
    let accent: Color

    var body: some View {
        Canvas { context, size in
            var path = Path()
            stride(from: 0.0, through: size.width, by: 14).forEach { x in
                path.move(to: CGPoint(x: x, y: 0))
                path.addLine(to: CGPoint(x: x, y: size.height))
            }
            stride(from: 0.0, through: size.height, by: 14).forEach { y in
                path.move(to: CGPoint(x: 0, y: y))
                path.addLine(to: CGPoint(x: size.width, y: y))
            }
            context.stroke(path, with: .color(accent.opacity(0.055)), lineWidth: 0.5)
        }
        .accessibilityHidden(true)
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
    @Environment(\.colorScheme) private var colorScheme

    private var todayTotalBytes: UInt64 {
        let (total, overflow) = summary.todayDownloadBytes.addingReportingOverflow(summary.todayUploadBytes)
        return overflow ? UInt64.max : total
    }

    private var todayTotalGb: Double {
        Double(todayTotalBytes) / 1_000_000_000
    }

    private var avgCompletedDayGb: Double {
        let calendar = Calendar.current
        let completedDays = summary.historicalDailyHistory.filter {
            !calendar.isDateInToday($0.date) && !$0.isPartial && $0.totalBytes != nil
        }
        guard !completedDays.isEmpty else { return 50.0 }
        let totalGb = completedDays.reduce(0.0) { total, point in
            total + Double(point.totalBytes ?? 0) / 1_000_000_000
        }
        return totalGb / Double(completedDays.count)
    }

    private var dailyPaceCeiling: Double {
        max(max(30.0, avgCompletedDayGb * 1.6), todayTotalGb * 1.12)
    }

    private var todayUsageProgress: Double {
        min(0.95, max(0.08, todayTotalGb / dailyPaceCeiling))
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Button(action: openUsage) {
                VStack(alignment: .leading, spacing: 9) {
                    Text("Today's Usage")
                        .font(.caption.weight(.semibold))
                        .linkWaveText(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    HStack(spacing: 7) {
                        CircularStatRing(
                            progress: todayUsageProgress,
                            tint: palette.textAccent,
                            showsUsageBars: true,
                            foreground: palette.textPrimary.color
                        )
                        Text(Self.formatGB(todayTotalBytes))
                            .font(.system(.title3, design: .rounded).weight(.bold))
                            .monospacedDigit()
                            .tracking(-0.35)
                            .lineLimit(1)
                            .minimumScaleFactor(0.72)
                            .contentTransition(.numericText())
                    }
                    VStack(alignment: .leading, spacing: 3) {
                        usageLine(label: "Down", value: Self.formatGB(summary.todayDownloadBytes), icon: "arrow.down", tint: palette.textAccent)
                        usageLine(label: "Up", value: Self.formatUpload(summary.todayUploadBytes), icon: "arrow.up", tint: palette.textSecondary.color)
                    }
                    Spacer(minLength: 0)
                    HStack(spacing: 4) {
                        Image(systemName: "calendar")
                            .font(.system(size: 9, weight: .semibold))
                        Text("Month")
                        Spacer(minLength: 2)
                        Text(Self.formatGB(monthTotalBytes))
                            .monospacedDigit()
                            .lineLimit(1)
                            .minimumScaleFactor(0.68)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(palette.textAccent)
                    }
                    .font(.system(size: 9, weight: .medium, design: .rounded))
                    .foregroundStyle(palette.textSecondary.color)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 7)
                    .background(neutralPillFill, in: Capsule())
                }
                .frame(maxWidth: .infinity, minHeight: 146, alignment: .topLeading)
                .linkWaveGlassCard(padding: 12)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Today's usage, \(Self.formatGB(todayTotalBytes)). Open Usage tab.")

            Button(action: openClients) {
                VStack(alignment: .leading, spacing: 9) {
                    Text("Connected Devices")
                        .font(.caption.weight(.semibold))
                        .linkWaveText(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    HStack(spacing: 6) {
                        CircularStatRing(
                            progress: deviceTotalCount == 0 ? 0 : Double(onlineCount) / Double(deviceTotalCount),
                            tint: .green,
                            symbol: "laptopcomputer"
                        )
                        Text("\(onlineCount) online")
                            .font(.system(.title3, design: .rounded).weight(.bold))
                            .monospacedDigit()
                            .tracking(-0.3)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                    }
                    Text("\(offlineCount) offline")
                        .font(.caption2.monospacedDigit())
                        .linkWaveText(.secondary)
                    Spacer(minLength: 0)
                    HStack(spacing: 4) {
                        Image(systemName: "person.2")
                            .font(.system(size: 9, weight: .semibold))
                        Text("View Clients")
                        Spacer(minLength: 2)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(palette.textAccent)
                    }
                    .font(.system(size: 9, weight: .medium, design: .rounded))
                    .foregroundStyle(palette.textSecondary.color)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 7)
                    .background(neutralPillFill, in: Capsule())
                }
                .frame(maxWidth: .infinity, minHeight: 146, alignment: .topLeading)
                .linkWaveGlassCard(padding: 12)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Connected devices, \(onlineCount) online and \(offlineCount) offline. Open Clients tab.")
        }
        .frame(maxWidth: .infinity, alignment: .top)
    }

    private var deviceTotalCount: Int {
        max(0, onlineCount) + max(0, offlineCount)
    }

    private var neutralPillFill: Color {
        palette.backgroundTertiary.opacity(colorScheme == .dark ? 0.62 : 0.68)
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

    private func usageLine(label: String, value: String, icon: String, tint: Color) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 8, weight: .bold))
            Text(label)
                .font(.system(size: 9, weight: .medium, design: .rounded))
            Text(value)
                .font(.system(size: 9, weight: .medium, design: .rounded).monospacedDigit())
                .lineLimit(1)
                .minimumScaleFactor(0.75)
            Spacer(minLength: 0)
        }
        .foregroundStyle(tint)
    }
}

private struct CircularStatRing: View {
    let progress: Double
    let tint: Color
    var symbol: String?
    var showsUsageBars = false
    var foreground: Color = .primary

    var body: some View {
        ZStack {
            Circle()
                .stroke(tint.opacity(0.18), lineWidth: 3)
            Circle()
                .trim(from: 0, to: min(max(progress, 0), 1))
                .stroke(tint, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.easeOut(duration: 0.3), value: progress)
            if showsUsageBars {
                HStack(alignment: .bottom, spacing: 2) {
                    ForEach(0..<3, id: \.self) { index in
                        Capsule()
                            .fill(foreground)
                            .frame(width: 3, height: CGFloat(6 + index * 3))
                    }
                }
            } else if let symbol {
                Image(systemName: symbol)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(tint)
            }
        }
        .frame(width: 32, height: 32)
        .accessibilityHidden(true)
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

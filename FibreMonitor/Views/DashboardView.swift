import SwiftUI

public struct DashboardView: View {
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
                    if !settings.isConfigured {
                        NoRouterCard {
                            showSettings = true
                        }
                    } else {
                        RouterHeaderCard(viewModel: viewModel, settings: settings)

                        if let err = viewModel.errorMessage, !viewModel.isLoggedOut {
                            ErrorBanner(
                                message: err,
                                suggestFallback: viewModel.shouldSuggestFallbackHost,
                                onTryFallback: { Task { await viewModel.useFallbackHost() } },
                                openSettings: { showSettings = true }
                            )
                        }

                        CompactSpeedCard(traffic: viewModel.traffic)
                        HomeSummaryRow(
                            summary: settings.dataUsageSummary,
                            onlineCount: viewModel.onlineDevices.count,
                            openUsage: { viewModel.selectedTab = .usage },
                            openClients: { viewModel.selectedTab = .clients }
                        )
                        ConnectionHistoryCard(events: settings.connectionHistory)
                    }
                }
                .padding(.horizontal)
                .padding(.top, 8)
                .padding(.bottom, 24)
            }
            .background { LiquidGlassBackground() }
            .liquidGlassScrollEdges()
            .refreshable { await viewModel.refreshAll() }
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        showSettings = true
                    } label: {
                        HStack(spacing: 9) {
                            ProfileAvatarView(size: 36)
                            VStack(alignment: .leading, spacing: 0) {
                                Text("LinkWave")
                                    .font(.caption2.weight(.medium))
                                    .foregroundStyle(.secondary)
                                Text("Home")
                                    .font(.headline.weight(.semibold))
                                    .foregroundStyle(.primary)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("LinkWave Home. Open profile and settings.")
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button {
                        showSettings = true
                    } label: {
                        Image(systemName: "gearshape")
                    }
                    .accessibilityLabel("Settings")

                    Button {
                        Task { await viewModel.refreshAll() }
                    } label: {
                        if viewModel.isRefreshing {
                            ProgressView()
                        } else {
                            Image(systemName: "arrow.clockwise")
                        }
                    }
                    .accessibilityLabel("Refresh")
                    .disabled(viewModel.isRefreshing || !settings.isConfigured)
                }
            }
            .navigationDestination(isPresented: $showSettings) {
                SettingsTabView(viewModel: viewModel)
            }
        }
    }
}

private struct RouterHeaderCard: View {
    @ObservedObject var viewModel: MonitorViewModel
    @ObservedObject var settings: SettingsStore

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Color.green.opacity(0.16))
                        .frame(width: 66, height: 54)
                    HuaweiOptiXstarIllustration(isOnline: viewModel.isConnected, wifiOnline: wifiOnline)
                }
                .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 2) {
                    Text(settings.activeProfile?.name ?? "Fibre Router")
                        .font(.headline)
                        .lineLimit(1)
                    Text(viewModel.displayModelName)
                        .font(.caption)
                        .foregroundColor(.secondary)
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
                if let last = viewModel.lastUpdate, viewModel.isConnected, !viewModel.isLoggedOut {
                    Text("• Updated \(last.formatted(date: .omitted, time: .standard))")
                        .font(.caption2)
                        .foregroundColor(.secondary)
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
        }
        .liquidGlassCard()
        .accessibilityElement(children: .combine)
    }

    private var statusColor: Color {
        if viewModel.isLoggedOut { return .secondary }
        return viewModel.isConnected ? .green : (viewModel.isRefreshing ? .orange : .red)
    }

    private var statusText: String {
        if viewModel.isLoggedOut { return "LOGGED OUT" }
        return viewModel.isConnected ? "CONNECTED" : (viewModel.isRefreshing ? "CONNECTING" : "OFFLINE")
    }

    private var wifiOnline: Bool {
        let reportedStates = viewModel.wifi.radios.map(\.enabled) + viewModel.wifi.networks.map(\.enabled)
        return reportedStates.isEmpty ? viewModel.isConnected : reportedStates.contains(true)
    }
}

private struct HuaweiOptiXstarIllustration: View {
    let isOnline: Bool
    let wifiOnline: Bool

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
                        .stroke(Color.primary.opacity(0.12), lineWidth: 0.8)
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
                        .fill(index < level ? tint : Color.secondary.opacity(0.18))
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
                .foregroundStyle(.secondary)
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

    var body: some View {
        HStack(spacing: 13) {
            speedMetric(
                title: "Download",
                value: traffic.downloadMbps,
                icon: "arrow.down",
                tint: .blue
            )

            Rectangle()
                .fill(Color.primary.opacity(0.1))
                .frame(width: 1, height: 35)

            speedMetric(
                title: "Upload",
                value: traffic.uploadMbps,
                icon: "arrow.up",
                tint: .green
            )
        }
        .padding(.vertical, 2)
        .liquidGlassCard()
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Live speed")
        .accessibilityValue(
            String(format: "Download %.1f megabits per second, upload %.1f megabits per second", traffic.downloadMbps, traffic.uploadMbps)
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
                    .foregroundStyle(.secondary)
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(value >= 100 ? String(format: "%.0f", value) : String(format: "%.1f", value))
                        .font(.system(.title3, design: .rounded).weight(.bold))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                    Text("Mbps")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct HomeSummaryRow: View {
    let summary: DataUsageSummary
    let onlineCount: Int
    let openUsage: () -> Void
    let openClients: () -> Void

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
                        .foregroundStyle(.secondary)
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
                            .foregroundStyle(.blue)
                        Label(Self.format(summary.todayUploadBytes), systemImage: "arrow.up")
                            .foregroundStyle(.green)
                    }
                    .font(.system(size: 9, weight: .medium, design: .rounded))
                    .lineLimit(1)
                }
                .frame(maxWidth: .infinity, minHeight: 108, alignment: .leading)
                .liquidGlassCard()
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Today's usage, \(Self.format(todayTotalBytes)). Open Usage tab.")

            Button(action: openClients) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Connected Devices")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
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
                    Spacer(minLength: 0)
                    Label("View clients", systemImage: "chevron.right")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(Color.accentColor)
                }
                .frame(maxWidth: .infinity, minHeight: 108, alignment: .leading)
                .liquidGlassCard()
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Connected devices, \(onlineCount) online. Open Clients tab.")
        }
    }

    private static func format(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: bytes), countStyle: .file)
    }
}

private struct MetricsTileGrid: View {
    @ObservedObject var viewModel: MonitorViewModel

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
                iconTint: .blue,
                title: wan.connectionType == "IPoE" ? "WAN Uptime" : "PPPoE Uptime",
                value: InternetCard.uptime(wan.uptimeSeconds),
                subtitle: wan.connectionStatus.isEmpty ? nil : wan.connectionStatus
            )

            if let ontUptime = health.uptimeSeconds, ontUptime > 0 {
                MetricTile(
                    icon: "timer",
                    iconTint: .teal,
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
                    iconTint: .accentColor,
                    title: "Active Devices",
                    value: "\(viewModel.onlineDevices.count)",
                    pill: ("Clients", .accentColor),
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
        .liquidGlassCard()
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

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "wifi.router")
                .font(.system(size: 40))
                .foregroundColor(.accentColor)
            Text("No Router Configured")
                .font(.headline)
            Text("Add a Huawei OptiXstar router profile in Settings to start live fibre monitoring.")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
            Button("Open Settings", action: openSettings)
                .liquidGlassActionButton()
        }
        .frame(maxWidth: .infinity)
        .liquidGlassCard()
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
        .liquidGlassPanel(padding: 12)
    }
}


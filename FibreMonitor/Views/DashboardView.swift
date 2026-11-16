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
                        HomeUsageCard(summary: settings.dataUsageSummary) {
                            viewModel.selectedTab = .usage
                        }
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
            .navigationTitle("Home")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    RouterSwitcherMenu(viewModel: viewModel, settings: settings) {
                        showSettings = true
                    }
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
                        .frame(width: 44, height: 44)
                    Image(systemName: "wifi.router")
                        .font(.title3.weight(.semibold))
                        .foregroundColor(.green)
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

                if !viewModel.optical.registrationState.isEmpty {
                    Pill(
                        text: viewModel.optical.registrationText,
                        color: viewModel.optical.isRegistered ? .green : .orange
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
        .liquidGlassCard(padding: 13)
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

private struct HomeUsageCard: View {
    let summary: DataUsageSummary
    let openUsage: () -> Void

    private var monthTotalBytes: UInt64 {
        let (total, overflow) = summary.monthDownloadBytes.addingReportingOverflow(summary.monthUploadBytes)
        return overflow ? UInt64.max : total
    }

    var body: some View {
        Button(action: openUsage) {
            HStack(spacing: 12) {
                Image(systemName: "arrow.up.arrow.down.circle.fill")
                    .font(.title3)
                    .foregroundStyle(.accentColor)
                    .frame(width: 38, height: 38)
                    .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))

                VStack(alignment: .leading, spacing: 3) {
                    Text("THIS MONTH · UNLIMITED PLAN")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.secondary)
                    Text(ByteCountFormatter.string(fromByteCount: Int64(clamping: monthTotalBytes), countStyle: .file))
                        .font(.headline.weight(.bold))
                        .monospacedDigit()
                    Text("Router counter total · View Usage")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .liquidGlassCard(padding: 13)
        }
        .buttonStyle(.plain)
        .accessibilityHint("Opens the Usage tab")
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


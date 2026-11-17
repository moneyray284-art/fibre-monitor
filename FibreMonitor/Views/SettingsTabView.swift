import SwiftUI

public struct SettingsTabView: View {
    @ObservedObject var viewModel: MonitorViewModel
    @ObservedObject var settings: SettingsStore
    @State private var editorMode: RouterProfileEditorView.Mode?
    @State private var pendingDelete: RouterProfile?
    @State private var showRebootAlert = false

    public init(viewModel: MonitorViewModel) {
        self.viewModel = viewModel
        self.settings = viewModel.settings
    }

    public var body: some View {
        Form {
            routersSection
            updatesSection
            appearanceSection
            networkDetailsSection
            diagnosticsSection
            toolsSection
            if settings.isConfigured {
                routerControlsSection
                sessionSection
            }
            aboutSection
        }
        .liquidGlassScrollEdges()
        .toolbar(.hidden, for: .tabBar)
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await viewModel.refreshAll() }
        .alert("Restart Router?", isPresented: $showRebootAlert) {
            Button("Cancel", role: .cancel) {}
            Button("Restart", role: .destructive) {
                Task { await viewModel.reboot() }
            }
        } message: {
            Text("Internet and Wi-Fi drop for about 2 minutes while the router restarts.")
        }
        .sheet(item: $editorMode) { mode in
            RouterProfileEditorView(mode: mode, settings: settings) { savedProfile in
                switch mode {
                case .add:
                    viewModel.selectRouterAndStart(savedProfile)
                case .edit:
                    if savedProfile.id == settings.activeProfile?.id {
                        viewModel.settingsChanged()
                    }
                }
            }
        }
        .confirmationDialog(
            pendingDelete.map { "Delete \($0.name)?" } ?? "",
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
            titleVisibility: .visible
        ) {
            Button("Delete Profile", role: .destructive) {
                if let profile = pendingDelete {
                    let wasActive = profile.id == settings.activeProfile?.id
                    settings.deleteProfile(profile.id)
                    Haptics.notify(.warning)
                    if wasActive { viewModel.settingsChanged() }
                }
                pendingDelete = nil
            }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        } message: {
            Text("This removes the profile, its Keychain password, and its saved device names from this iPhone.")
        }
    }

    private var routersSection: some View {
        Section {
            if settings.profiles.isEmpty {
                Text("No routers saved yet. Add your router to connect.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            } else {
                ForEach(settings.profiles) { profile in
                    HStack(spacing: 10) {
                        Button {
                            guard profile.id != settings.activeProfile?.id else { return }
                            viewModel.selectRouterAndStart(profile)
                        } label: {
                            RouterProfileRow(profile: profile, isActive: profile.id == settings.activeProfile?.id)
                        }
                        .buttonStyle(.plain)

                        Button {
                            editorMode = .edit(profile)
                        } label: {
                            Image(systemName: "pencil.circle")
                                .font(.title3)
                                .foregroundColor(.secondary)
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Edit \(profile.name)")
                    }
                }
                .onMove { source, destination in
                    settings.moveProfiles(fromOffsets: source, toOffset: destination)
                }
                .onDelete { offsets in
                    if let index = offsets.first, settings.profiles.indices.contains(index) {
                        pendingDelete = settings.profiles[index]
                    }
                }
            }

            Button {
                editorMode = .add
            } label: {
                Label("Add Router", systemImage: "plus.circle.fill")
            }
        } header: {
            HStack {
                Text("Routers")
                Spacer()
                if !settings.profiles.isEmpty { EditButton() }
            }
        } footer: {
            Text("Tap a router to switch to it. Switching logs out of the current router session first. Swipe or tap Edit to reorder or remove a profile.")
        }
    }

    private var updatesSection: some View {
        Section("Updates") {
            Label("Syncs on launch, when the app returns, and when a tab is more than 10 seconds out of date.", systemImage: "arrow.triangle.2.circlepath")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    private var appearanceSection: some View {
        Section("Appearance") {
            Picker("Theme", selection: $settings.theme) {
                ForEach(AppTheme.allCases) { theme in
                    Text(theme.title).tag(theme)
                }
            }
            .pickerStyle(.segmented)

            Picker("Accent Color", selection: $settings.accentColor) {
                ForEach(AppAccentColor.allCases) { accent in
                    HStack(spacing: 8) {
                        Circle()
                            .fill(accent.color)
                            .frame(width: 12, height: 12)
                        Text(accent.title)
                    }
                    .tag(accent)
                }
            }
            .pickerStyle(.menu)

            Picker("App Icon", selection: $settings.appIconChoice) {
                ForEach(AppIconChoice.allCases) { choice in
                    Text(choice.title).tag(choice)
                }
            }
            .pickerStyle(.menu)
            .disabled(settings.autoMatchAppIconToAccentColor)

            Toggle("Auto-Match Accent Theme", isOn: $settings.autoMatchAppIconToAccentColor)
                .accessibilityHint("Automatically uses the app icon that matches the selected accent color.")
        }
    }

    private var networkDetailsSection: some View {
        Section("Network Details") {
            LabeledContent("Gateway", value: viewModel.wan.gateway.isEmpty ? "—" : viewModel.wan.gateway)
            LabeledContent(
                "ISP DNS",
                value: viewModel.wan.dnsServers.isEmpty ? "—" : viewModel.wan.dnsServers.joined(separator: ", ")
            )
            LabeledContent("WAN IP", value: viewModel.wan.ipAddress.isEmpty ? "—" : viewModel.wan.ipAddress)
            if !viewModel.wan.connectionType.isEmpty {
                LabeledContent("Connection type", value: viewModel.wan.connectionType)
            }
        }
    }

    private var diagnosticsSection: some View {
        Section("Advanced Diagnostics") {
            if !viewModel.wan.connectionStatus.isEmpty {
                LabeledContent(
                    viewModel.wan.connectionType == "IPoE" ? "WAN status" : "PPPoE status",
                    value: viewModel.wan.connectionStatus
                )
            }
            if viewModel.wan.uptimeSeconds > 0 {
                LabeledContent(
                    viewModel.wan.connectionType == "IPoE" ? "WAN uptime" : "PPPoE uptime",
                    value: InternetCard.uptime(viewModel.wan.uptimeSeconds)
                )
            }
            if let rx = viewModel.optical.rxPowerDbm {
                LabeledContent("Optical Rx power", value: String(format: "%.2f dBm", rx))
            }
            if let cpu = viewModel.health.cpuPercent {
                LabeledContent("CPU load", value: "\(cpu)%")
            }
            if let memory = viewModel.health.memoryPercent {
                LabeledContent("Memory load", value: "\(memory)%")
            }
            if viewModel.wan.connectionStatus.isEmpty,
               viewModel.wan.uptimeSeconds <= 0,
               viewModel.optical.rxPowerDbm == nil,
               !viewModel.health.hasCpuOrMemory {
                Text("Connect to the router to view available diagnostics.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var toolsSection: some View {
        Section("Tools & Network") {
            NavigationLink {
                DiagnosticsScreen(viewModel: viewModel)
            } label: {
                Label("Diagnostics (Ping & Traceroute)", systemImage: "stethoscope")
            }
            NavigationLink {
                LanScreen(viewModel: viewModel)
            } label: {
                Label("Home Network (LAN & DHCP)", systemImage: "network")
            }
        }
    }

    private var routerControlsSection: some View {
        Section("Router Controls") {
            Button(role: .destructive) {
                showRebootAlert = true
            } label: {
                Label("Restart Fibre Router", systemImage: "power")
            }
            .disabled(!viewModel.isConnected || viewModel.isLoggedOut)
        }
    }

    private var sessionSection: some View {
        Section {
            if viewModel.isLoggedOut {
                Button {
                    viewModel.reconnectSession()
                } label: {
                    Label("Reconnect to Router", systemImage: "arrow.clockwise.circle")
                }
            } else {
                Button(role: .destructive) {
                    Task { await viewModel.logoutSession() }
                } label: {
                    Label("Log Out of Router", systemImage: "rectangle.portrait.and.arrow.right")
                }
            }
        } header: {
            Text("Session")
        } footer: {
            Text("Logging out frees the router's single-session web interface so you can open it in a browser.")
        }
    }

    private var aboutSection: some View {
        Section("About") {
            LabeledContent("Version") {
                HStack(spacing: 7) {
                    Text(appVersion)
                        .font(.subheadline.monospacedDigit())
                }
            }
            LabeledContent("Router", value: activeRouterDescription)
            if let config = settings.activeProfile?.cfgMode, !config.isEmpty {
                LabeledContent("Configuration", value: config)
            }
            if !viewModel.health.firmware.isEmpty {
                LabeledContent("Firmware", value: viewModel.health.firmware)
            }
            if !viewModel.health.hardware.isEmpty {
                LabeledContent("Hardware", value: viewModel.health.hardware)
            }
        }
    }

    private var activeRouterDescription: String {
        if !viewModel.health.model.isEmpty {
            return "Huawei OptiXstar \(viewModel.health.model)"
        }
        if let model = settings.activeProfile?.detectedModel, !model.isEmpty {
            return "Huawei OptiXstar \(model)"
        }
        return "Huawei OptiXstar ONT"
    }

    private var appVersion: String {
        let info = Bundle.main.infoDictionary
        return "\(info?["CFBundleShortVersionString"] as? String ?? "?") (\(info?["CFBundleVersion"] as? String ?? "?"))"
    }
}

private struct DiagnosticsScreen: View {
    @ObservedObject var viewModel: MonitorViewModel

    var body: some View {
        ScrollView {
            DiagnosticsCard(viewModel: viewModel)
                .padding()
        }
        .background { LiquidGlassBackground() }
        .liquidGlassScrollEdges()
        .navigationTitle("Diagnostics")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)
    }
}

private struct LanScreen: View {
    @ObservedObject var viewModel: MonitorViewModel

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                if !viewModel.settings.isConfigured {
                    Text("Add a router in Settings to inspect LAN & DHCP configuration.")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity)
                        .multilineTextAlignment(.center)
                        .linkWaveGlassCard()
                } else {
                    LanCard(lan: viewModel.lan)
                    if viewModel.lan.routerIp.isEmpty {
                        Text(viewModel.isLoggedOut
                             ? "Session logged out. Reconnect and pull down to load LAN settings."
                             : "Pull down to refresh LAN & DHCP settings.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .frame(maxWidth: .infinity)
                            .multilineTextAlignment(.center)
                            .linkWaveGlassCard()
                    }
                }
            }
            .padding()
        }
        .background { LiquidGlassBackground() }
        .liquidGlassScrollEdges()
        .refreshable { await viewModel.refreshAll() }
        .navigationTitle("Home Network")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)
    }
}

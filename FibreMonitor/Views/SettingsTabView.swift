import SwiftUI

public struct SettingsTabView: View {
    @ObservedObject var viewModel: MonitorViewModel
    @ObservedObject var settings: SettingsStore
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage("linkwave.surfaceStyle") private var surfaceStyleRawValue = LinkWaveSurfaceStyle.liquidGlass.rawValue
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
            networkAndToolsSection
            appearanceSection
            preferencesSection
            systemAndAboutSection
        }
        .environment(\.linkWaveThemePalette, palette)
        .environment(\.linkWaveSurfaceStyle, surfaceStyle)
        .linkWaveThemedListSurface()
        .linkWaveText(.primary)
        .liquidGlassScrollEdges()
        .toolbar(.hidden, for: .tabBar)
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await viewModel.refreshAll(forceReauthIfNeeded: true) }
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
                    .linkWaveText(.secondary)
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
                                .linkWaveText(.secondary)
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
            if settings.isConfigured {
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
            }
        } header: {
            HStack {
                Text("Routers & Session")
                Spacer()
                if !settings.profiles.isEmpty { EditButton() }
            }
        } footer: {
            Text("Tap a router to switch, use its pencil to edit, or tap Edit to reorder and remove profiles. Logging out frees the router's single-session web interface so it can be used in a browser.")
                .linkWaveText(.secondary)
        }
    }

    private var appearanceSection: some View {
        Section("Appearance") {
            VStack(alignment: .leading, spacing: 7) {
                Label("Mode", systemImage: "circle.lefthalf.filled")
                    .font(.caption)
                    .foregroundStyle(palette.textSecondary.color)

                Picker("Mode", selection: Binding(
                    get: { settings.theme },
                    set: { newTheme in
                        withAnimation(.easeInOut(duration: 0.25)) {
                            settings.theme = newTheme
                        }
                    }
                )) {
                    ForEach(AppTheme.allCases) { theme in
                        Text(theme.title).tag(theme)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
            }

            VStack(alignment: .leading, spacing: 7) {
                Label("Surface", systemImage: "square.stack.3d.up")
                    .font(.caption)
                    .foregroundStyle(palette.textSecondary.color)

                Picker("Surface", selection: $surfaceStyleRawValue) {
                    ForEach(LinkWaveSurfaceStyle.allCases) { style in
                        Text(style.title).tag(style.rawValue)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
            }

            NavigationLink {
                ThemeSettingsView(settings: settings)
            } label: {
                HStack(spacing: 10) {
                    Label("Theme & Colors", systemImage: "paintpalette")
                    Spacer(minLength: 6)
                    HStack(spacing: -5) {
                        ForEach(Array(themeSummaryDots.enumerated()), id: \.offset) { _, color in
                            Circle()
                                .fill(color)
                                .frame(width: 15, height: 15)
                                .overlay(Circle().strokeBorder(Color.primary.opacity(0.18), lineWidth: 1))
                        }
                    }
                    Text(activeThemeName)
                        .font(.caption)
                        .foregroundStyle(palette.textSecondary.color)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
            }

            NavigationLink {
                AppIconSettingsView(settings: settings)
            } label: {
                HStack(spacing: 10) {
                    LinkWaveAppIconPreview(
                        choice: settings.appIconChoice,
                        logoColor: settings.logoColor.color(for: colorScheme)
                    )
                    .frame(width: 28, height: 28)
                    .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .clipped()

                    Text("App Icon")
                        .foregroundStyle(.primary)
                    Spacer(minLength: 6)
                    Text("\(settings.appIconChoice.title) · \(settings.logoColor.title)")
                        .font(.caption)
                        .foregroundStyle(palette.textSecondary.color)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                }
            }
        }
    }

    private var palette: ThemePalette {
        settings.themePalette(for: colorScheme)
    }

    private var surfaceStyle: LinkWaveSurfaceStyle {
        LinkWaveSurfaceStyle(rawValue: surfaceStyleRawValue) ?? .liquidGlass
    }

    private var networkAndToolsSection: some View {
        Section("Network & Tools") {
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
            NavigationLink {
                RouterTelemetrySettingsView(viewModel: viewModel)
            } label: {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Router Telemetry")
                        Text(telemetrySummary)
                            .font(.caption)
                            .foregroundStyle(palette.textSecondary.color)
                    }
                } icon: {
                    Image(systemName: "waveform.path.ecg")
                }
            }
        }
    }

    private var preferencesSection: some View {
        Section {
            Menu {
                ForEach(HapticLevel.allCases) { option in
                    Button {
                        settings.hapticLevel = option
                        Haptics.impact()
                    } label: {
                        if settings.hapticLevel == option {
                            Label(option.title, systemImage: "checkmark")
                        } else {
                            Text(option.title)
                        }
                    }
                }
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: settings.hapticLevel.symbolName)
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(palette.accent.color)
                        .frame(width: 24)
                    Text("Haptics")
                        .foregroundStyle(palette.textPrimary.color)
                    Spacer(minLength: 8)
                    Text(settings.hapticLevel.title)
                        .foregroundStyle(palette.textSecondary.color)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(palette.textTertiary.color)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
        } header: {
            Text("Preferences")
        } footer: {
            Text("Syncs on launch, when the app returns, and when a tab is more than 10 seconds out of date.")
            .linkWaveText(.secondary)
        }
    }

    private var systemAndAboutSection: some View {
        Section("System & About") {
            if settings.isConfigured {
                Button(role: .destructive) {
                    showRebootAlert = true
                } label: {
                    Label("Restart Fibre Router", systemImage: "power")
                }
                .disabled(!viewModel.isConnected || viewModel.isLoggedOut)
            }

            NavigationLink {
                AboutSettingsView(viewModel: viewModel, settings: settings)
            } label: {
                HStack {
                    Label("About", systemImage: "info.circle")
                    Spacer(minLength: 8)
                    Text("\(versionAndBuild) · \(shortRouterModel)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(palette.textSecondary.color)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                }
            }
        }
    }

    private var activeThemeName: String {
        settings.activePreset(for: colorScheme)?.title ?? "Custom"
    }

    private var themeSummaryDots: [Color] {
        settings.activePreset(for: colorScheme)?.previewDots(for: colorScheme)
            ?? [palette.bgPrimary.color, palette.bgSecondary.color, palette.accent.color]
    }

    private var telemetrySummary: String {
        var parts: [String] = []
        if !viewModel.wan.connectionType.isEmpty { parts.append(viewModel.wan.connectionType) }
        if viewModel.wan.uptimeSeconds > 0 { parts.append(InternetCard.uptime(viewModel.wan.uptimeSeconds)) }
        if let cpu = viewModel.health.cpuPercent { parts.append("\(cpu)% CPU") }
        return parts.isEmpty ? "Status and hardware readings" : parts.joined(separator: " · ")
    }

    private var versionAndBuild: String {
        let info = Bundle.main.infoDictionary
        return "\(info?["CFBundleShortVersionString"] as? String ?? "?") (\(info?["CFBundleVersion"] as? String ?? "?"))"
    }

    private var shortRouterModel: String {
        if !viewModel.health.model.isEmpty { return viewModel.health.model }
        if let model = settings.activeProfile?.detectedModel, !model.isEmpty { return model }
        return "ONT"
    }
}

private struct RouterTelemetrySettingsView: View {
    @ObservedObject var viewModel: MonitorViewModel
    @ObservedObject private var settings: SettingsStore
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage("linkwave.surfaceStyle") private var surfaceStyleRawValue = LinkWaveSurfaceStyle.liquidGlass.rawValue

    init(viewModel: MonitorViewModel) {
        self.viewModel = viewModel
        self.settings = viewModel.settings
    }

    private var palette: ThemePalette { settings.themePalette(for: colorScheme) }
    private var surfaceStyle: LinkWaveSurfaceStyle {
        LinkWaveSurfaceStyle(rawValue: surfaceStyleRawValue) ?? .liquidGlass
    }

    var body: some View {
        Form {
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
                        .linkWaveText(.secondary)
                }
            }
        }
        .environment(\.linkWaveThemePalette, palette)
        .environment(\.linkWaveSurfaceStyle, surfaceStyle)
        .linkWaveThemedListSurface()
        .linkWaveText(.primary)
        .liquidGlassScrollEdges()
        .navigationTitle("Router Telemetry")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)
    }
}

private struct AboutSettingsView: View {
    @ObservedObject var viewModel: MonitorViewModel
    @ObservedObject var settings: SettingsStore
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage("linkwave.surfaceStyle") private var surfaceStyleRawValue = LinkWaveSurfaceStyle.liquidGlass.rawValue

    private var palette: ThemePalette { settings.themePalette(for: colorScheme) }
    private var surfaceStyle: LinkWaveSurfaceStyle {
        LinkWaveSurfaceStyle(rawValue: surfaceStyleRawValue) ?? .liquidGlass
    }

    var body: some View {
        Form {
            Section("About") {
                LabeledContent("Version", value: versionAndBuild)
                    .font(.subheadline.monospacedDigit())
                LabeledContent("Router", value: routerDescription)
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
        .environment(\.linkWaveThemePalette, palette)
        .environment(\.linkWaveSurfaceStyle, surfaceStyle)
        .linkWaveThemedListSurface()
        .linkWaveText(.primary)
        .liquidGlassScrollEdges()
        .navigationTitle("About")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)
    }

    private var versionAndBuild: String {
        let info = Bundle.main.infoDictionary
        return "\(info?["CFBundleShortVersionString"] as? String ?? "?") (\(info?["CFBundleVersion"] as? String ?? "?"))"
    }

    private var routerDescription: String {
        if !viewModel.health.model.isEmpty { return "Huawei OptiXstar \(viewModel.health.model)" }
        if let model = settings.activeProfile?.detectedModel, !model.isEmpty {
            return "Huawei OptiXstar \(model)"
        }
        return "Huawei OptiXstar ONT"
    }
}

private struct AppIconSettingsView: View {
    @ObservedObject var settings: SettingsStore
    @ObservedObject private var appIconManager = AppIconManager.shared
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage("linkwave.surfaceStyle") private var surfaceStyleRawValue = LinkWaveSurfaceStyle.liquidGlass.rawValue

    private var palette: ThemePalette { settings.themePalette(for: colorScheme) }
    private var surfaceStyle: LinkWaveSurfaceStyle {
        LinkWaveSurfaceStyle(rawValue: surfaceStyleRawValue) ?? .liquidGlass
    }

    var body: some View {
        Form {
            Section("Logo Color") {
                Picker("Logo Color", selection: Binding(
                    get: { settings.logoColor },
                    set: { settings.setLogoColor($0) }
                )) {
                    ForEach(AppLogoColorChoice.allCases) { choice in
                        HStack(spacing: 8) {
                            Circle()
                                .fill(choice.color(for: colorScheme))
                                .frame(width: 12, height: 12)
                            Text(choice.title)
                        }
                        .tag(choice)
                    }
                }
                .pickerStyle(.menu)
            }

            Section("App Icon") {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 3), spacing: 10) {
                    ForEach(AppIconChoice.allCases) { choice in
                        AppIconPickerTile(
                            choice: choice,
                            isSelected: appIconManager.activeIconName == choice.alternateIconName(logoColor: settings.logoColor),
                            logoColor: settings.logoColor.color(for: colorScheme)
                        ) {
                            settings.appIconChoice = choice
                            appIconManager.apply(choice, logoColor: settings.logoColor)
                        }
                        .disabled(!appIconManager.supportsAlternateIcons && choice != .classic)
                    }
                }

                Text("Logo Color applies to the LinkWave icon designs. Classic keeps its original artwork.")
                    .font(.caption)
                    .linkWaveText(.secondary)

                if !appIconManager.supportsAlternateIcons {
                    Text("Alternate app icons aren't supported on this device.")
                        .font(.caption)
                        .linkWaveText(.secondary)
                }
                if let error = appIconManager.errorMessage {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .accessibilityLabel("App icon error: \(error)")
                }
            }
        }
        .environment(\.linkWaveThemePalette, palette)
        .environment(\.linkWaveSurfaceStyle, surfaceStyle)
        .linkWaveThemedListSurface()
        .linkWaveText(.primary)
        .liquidGlassScrollEdges()
        .navigationTitle("App Icon")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)
    }
}

private struct DiagnosticsScreen: View {
    @ObservedObject var viewModel: MonitorViewModel

    var body: some View {
        ScrollView {
            DiagnosticsCard(viewModel: viewModel)
                .padding()
        }
        .background { LiquidGlassBackground(isSheet: true) }
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
                        .linkWaveText(.secondary)
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
                            .linkWaveText(.secondary)
                            .frame(maxWidth: .infinity)
                            .multilineTextAlignment(.center)
                            .linkWaveGlassCard()
                    }
                }
            }
            .padding()
        }
        .background { LiquidGlassBackground(isSheet: true) }
        .liquidGlassScrollEdges()
        .refreshable { await viewModel.refreshAll(forceReauthIfNeeded: true) }
        .navigationTitle("Home Network")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)
    }
}

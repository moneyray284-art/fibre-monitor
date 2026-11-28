import CoreImage.CIFilterBuiltins
import SwiftUI
import UIKit

public struct WifiTabView: View {
    @ObservedObject var viewModel: MonitorViewModel
    @Environment(\.linkWaveThemePalette) private var palette
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var pendingRadio: (radio: WifiRadio, enable: Bool)?
    @State private var activeSheet: WifiSheetRoute?

    public init(viewModel: MonitorViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    if !viewModel.settings.isConfigured {
                        WifiEmptyCard(message: "Add a router in Settings to manage Wi-Fi networks.")
                    } else {
                        if viewModel.wifi.radios.isEmpty && viewModel.wifi.networks.isEmpty {
                            WifiEmptyCard(
                                message: wifiEmptyMessage,
                                isLoading: viewModel.isRefreshing && !viewModel.isLoggedOut,
                                actionTitle: viewModel.isLoggedOut ? "Reconnect" : nil,
                                action: viewModel.isLoggedOut ? { viewModel.reconnectSession() } : nil
                            )
                        } else {
                            radiosCard
                            LazyVGrid(columns: bandColumns, alignment: .leading, spacing: 12) {
                                ForEach(WifiFrequencyBand.allCases) { band in
                                    bandCard(for: band)
                                }
                            }
                        }

                        if let status = viewModel.wifiMutationStatus {
                            HStack(spacing: 9) {
                                if status.hasPrefix("Applying") {
                                    ProgressView().controlSize(.small)
                                } else {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(palette.textAccent)
                                }
                                Text(status)
                                    .font(.caption)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .linkWaveGlassCard(padding: 12)
                        }

                    }
                }
                .padding(.horizontal)
                .padding(.top, 8)
                .padding(.bottom, 24)
            }
            .background { LiquidGlassBackground() }
            .liquidGlassScrollEdges()
            .alwaysScrollBounce()
            .refreshable {
                await viewModel.refreshAll(forceReauthIfNeeded: true)
            }
            .navigationTitle("Wi-Fi")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                StandaloneTopBarTrailingItem(
                    content: AnyView(RouterRefreshToolbarButton(viewModel: viewModel, isEnabled: viewModel.settings.isConfigured))
                )
            }
        }
        .alert(
            pendingRadio.map { "Turn \(MonitorViewModel.bandName($0.radio.band)) Wi-Fi \($0.enable ? "on" : "off")?" } ?? "",
            isPresented: Binding(get: { pendingRadio != nil }, set: { if !$0 { pendingRadio = nil } })
        ) {
            Button("Cancel", role: .cancel) { pendingRadio = nil }
            Button(pendingRadio?.enable == false ? "Turn Off" : "Turn On", role: pendingRadio?.enable == false ? .destructive : nil) {
                if let p = pendingRadio {
                    Task { await viewModel.setRadio(p.radio, enabled: p.enable) }
                }
                pendingRadio = nil
            }
        } message: {
            if let p = pendingRadio, !p.enable {
                if viewModel.isPhoneOnWifi {
                    Text("This iPhone is currently on Wi-Fi. Turning off \(MonitorViewModel.bandName(p.radio.band)) will disconnect this app immediately if you're on this band. Devices on this band will disconnect and move to another band if they can.")
                } else {
                    Text("Devices on \(MonitorViewModel.bandName(p.radio.band)) will disconnect and move to another band if they can.")
                }
            } else {
                Text("The radio takes a few seconds to start.")
            }
        }
        .sheet(item: $activeSheet) { sheet in
            switch sheet {
            case .qr(let network):
                WifiQrSheet(viewModel: viewModel, network: network)
                    .toolbar(.hidden, for: .tabBar)
            case .edit(let network, let initialSsid):
                WifiEditSheet(viewModel: viewModel, network: network, initialSsid: initialSsid)
                    .toolbar(.hidden, for: .tabBar)
            }
        }
        .task(id: viewModel.isConnected && viewModel.selectedTab == .wifi) {
            if viewModel.isConnected && viewModel.selectedTab == .wifi {
                await viewModel.refreshWifiManagementState()
            }
        }
    }

    private static func isSecondary(_ index: Int) -> Bool {
        WifiFrequencyBand.allCases.contains { $0.secondaryIndices.contains(index) }
    }

    private var radiosCard: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: "antenna.radiowaves.left.and.right")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(palette.textAccent)
                    .frame(width: 38, height: 38)
                    .background(palette.textAccent.opacity(0.12), in: RoundedRectangle(cornerRadius: 11, style: .continuous))

                VStack(alignment: .leading, spacing: 3) {
                    Text("Wi-Fi Networks")
                        .font(.headline.weight(.bold))
                    Text("\(activeRadioCount)/2 radios active · \(broadcastingSSIDCount)/\(viewModel.wifi.networks.count) SSIDs broadcasting")
                        .font(.caption2.monospacedDigit())
                        .linkWaveText(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                }
                Spacer(minLength: 3)
                if viewModel.isWifiSaving { ProgressView().controlSize(.small) }
            }
            .padding(14)
            .background {
                ZStack {
                    LinearGradient(
                        colors: [palette.textAccent.opacity(0.09), palette.textAccent.opacity(0.025), .clear],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                    RadialGradient(
                        colors: [palette.textAccent.opacity(0.16), .clear],
                        center: .topTrailing,
                        startRadius: 0,
                        endRadius: 135
                    )
                }
                .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            }

            GeometryReader { geometry in
                let twoPointFourCount = onlineNetworkCount(in: .twoPointFour)
                let fiveCount = onlineNetworkCount(in: .five)
                let total = twoPointFourCount + fiveCount
                let availableWidth = max(0, geometry.size.width - 2)
                let twoPointFourFraction = total == 0 ? 0.5 : CGFloat(twoPointFourCount) / CGFloat(total)
                let fiveFraction = total == 0 ? 0.5 : CGFloat(fiveCount) / CGFloat(total)
                HStack(spacing: 2) {
                    Capsule()
                        .fill(Color.green.opacity(twoPointFourCount > 0 ? 0.9 : 0.2))
                        .frame(width: availableWidth * twoPointFourFraction)
                    Capsule()
                        .fill(palette.textAccent.opacity(fiveCount > 0 ? 0.9 : 0.2))
                        .frame(width: availableWidth * fiveFraction)
                }
            }
            .frame(height: 4)
            .padding(.horizontal, 14)

            LinkWaveHairlineDivider()
                .padding(.horizontal, 14)

            HStack(spacing: 0) {
                bandSummary(WifiFrequencyBand.twoPointFour)
                Rectangle()
                    .fill(palette.textSecondary.color.opacity(0.25))
                    .frame(width: 0.5, height: 36)
                bandSummary(WifiFrequencyBand.five)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
        }
        .linkWaveGlassCard(padding: 0)
    }

    private var bandColumns: [GridItem] {
        horizontalSizeClass == .regular
            ? [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]
            : [GridItem(.flexible())]
    }

    private var activeRadioCount: Int {
        viewModel.wifi.radios.filter(\.enabled).count
    }

    private var broadcastingSSIDCount: Int {
        viewModel.wifi.networks.filter { network in
            network.enabled && (radio(for: band(for: network))?.enabled ?? true)
        }.count
    }

    private func bandSummary(_ band: WifiFrequencyBand) -> some View {
        let radio = radio(for: band)
        let liveCount = onlineNetworkCount(in: band)
        let bandTint = band == .twoPointFour ? Color.green : palette.textAccent
        return HStack(spacing: 8) {
            Circle()
                .fill(bandTint.opacity((radio?.enabled ?? false) && liveCount > 0 ? 1 : 0.35))
                .frame(width: 6, height: 6)
            VStack(alignment: .leading, spacing: 3) {
                Text(band.title)
                    .font(.caption.weight(.semibold))
                Text((radio?.enabled ?? false) && liveCount > 0 ? "\(liveCount) Live" : "Off")
                    .font(.caption2.weight(.medium).monospacedDigit())
                    .foregroundStyle((radio?.enabled ?? false) && liveCount > 0 ? bandTint : palette.textTertiary.color)
            }
            Spacer(minLength: 2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.trailing, 12)
    }

    private func onlineNetworkCount(in band: WifiFrequencyBand) -> Int {
        guard radio(for: band)?.enabled == true else { return 0 }
        return bandNetworks(band).filter(\.enabled).count
    }

    private func bandCard(for band: WifiFrequencyBand) -> some View {
        let radio = radio(for: band)
        let networks = bandNetworks(band)
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 9) {
                Image(systemName: radio?.enabled == true ? "wifi" : "wifi.slash")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(radio?.enabled == true ? palette.textAccent : palette.textTertiary.color)
                    .frame(width: 34, height: 34)
                    .background(
                        (radio?.enabled == true ? palette.textAccent : palette.textTertiary.color).opacity(0.12),
                        in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                    )
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 5) {
                        Text(band.title)
                            .font(.subheadline.weight(.bold))
                        Text("· \(networks.count) SSIDs")
                            .font(.caption2.monospacedDigit())
                            .linkWaveText(.secondary)
                    }
                    Text(radio?.enabled == true ? "Wireless radio is active" : "Radio disabled — networks paused")
                        .font(.caption2)
                        .linkWaveText(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                }
                Spacer(minLength: 3)
                if let radio {
                    Toggle(
                        "\(band.title) Radio",
                        isOn: Binding(get: { radio.enabled }, set: { pendingRadio = (radio, $0) })
                    )
                    .labelsHidden()
                    .accessibilityLabel("Toggle \(band.title) Wi-Fi radio")
                    .disabled(viewModel.isWifiSaving || !viewModel.isConnected)
                }
            }
            .padding(.bottom, 10)

            if networks.isEmpty {
                Text("No SSIDs reported for this band.")
                    .font(.caption)
                    .linkWaveText(.secondary)
                    .padding(.vertical, 8)
            } else {
                ForEach(networks) { network in
                    WifiNetworkRow(
                        network: network,
                        isEditDisabled: viewModel.isWifiSaving || !viewModel.isConnected,
                        radioIsEnabled: radio?.enabled ?? true,
                        canDisable: Self.isSecondary(network.ssidIndex),
                        canDelete: Self.isSecondary(network.ssidIndex),
                        openEdit: { initialSsid in activeSheet = .edit(network, initialSsid: initialSsid) },
                        openQr: { activeSheet = .qr(network) },
                        setEnabled: { enabled in Task { await viewModel.setWifiNetwork(network, enabled: enabled) } },
                        delete: { Task { await viewModel.deleteWifiNetwork(network) } }
                    )
                    if network.id != networks.last?.id {
                        LinkWaveHairlineDivider(leading: 2)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .linkWaveGlassCard()
    }

    private func bandNetworks(_ band: WifiFrequencyBand) -> [WifiNetwork] {
        viewModel.wifi.networks
            .filter { self.band(for: $0) == band }
            .sorted { $0.ssidIndex < $1.ssidIndex }
    }

    private func band(for network: WifiNetwork) -> WifiFrequencyBand {
        WifiFrequencyBand(rawValue: network.band) ?? (network.ssidIndex <= 4 ? .twoPointFour : .five)
    }

    private func radio(for band: WifiFrequencyBand) -> WifiRadio? {
        viewModel.wifi.radios.first { $0.band == band.rawValue }
    }

    private var wifiEmptyMessage: String {
        if viewModel.isLoggedOut { return "Session is logged out. Tap Reconnect to manage Wi-Fi." }
        if viewModel.isConnected { return "Reading Wi-Fi configuration…" }
        if let err = viewModel.errorMessage { return err }
        return viewModel.isRefreshing ? "Loading Wi-Fi configuration…" : "Waiting for the router… Pull down to refresh."
    }
}

private enum WifiSheetRoute: Identifiable {
    case qr(WifiNetwork)
    case edit(WifiNetwork, initialSsid: String?)

    var id: String {
        switch self {
        case .qr(let network): return "qr-\(network.id)"
        case .edit(let network, _): return "edit-\(network.id)"
        }
    }
}

private struct WifiNetworkRow: View {
    let network: WifiNetwork
    let isEditDisabled: Bool
    let radioIsEnabled: Bool
    let canDisable: Bool
    let canDelete: Bool
    let openEdit: (String?) -> Void
    let openQr: () -> Void
    let setEnabled: (Bool) -> Void
    let delete: () -> Void

    @State private var optimisticEnabled: Bool?
    @State private var showDeleteConfirmation = false
    @State private var isEditingName = false
    @State private var editedName = ""
    @FocusState private var nameFieldFocused: Bool
    @Environment(\.linkWaveThemePalette) private var palette

    private var enabledBinding: Binding<Bool> {
        Binding(
            get: { optimisticEnabled ?? network.enabled },
            set: { newValue in
                optimisticEnabled = newValue
                setEnabled(newValue)
            }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 4) {
                    if isEditingName {
                        HStack(spacing: 6) {
                            TextField("Network name", text: $editedName)
                                .font(.subheadline.weight(.semibold))
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .focused($nameFieldFocused)
                                .onChange(of: editedName) { value in
                                    if value.count > 32 { editedName = String(value.prefix(32)) }
                                }
                            Button {
                                openEdit(editedName.trimmingCharacters(in: .whitespacesAndNewlines))
                                isEditingName = false
                                nameFieldFocused = false
                            } label: {
                                Image(systemName: "checkmark")
                                    .font(.caption.weight(.bold))
                                    .foregroundStyle(palette.textAccent)
                            }
                            .buttonStyle(.plain)
                            .disabled(isEditDisabled || editedName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            .accessibilityLabel("Save network name")
                            Button {
                                editedName = network.name
                                isEditingName = false
                                nameFieldFocused = false
                            } label: {
                                Image(systemName: "xmark")
                                    .font(.caption.weight(.bold))
                                    .linkWaveText(.secondary)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Cancel network name edit")
                        }
                    } else {
                        Text(network.name.isEmpty ? "SSID \(network.ssidIndex)" : network.name)
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)
                    }
                    HStack(spacing: 5) {
                        Circle()
                            .fill(isActive ? Color.green : palette.textTertiary.color)
                            .frame(width: 6, height: 6)
                        Text(statusText)
                            .foregroundStyle(isActive ? Color.green : palette.textTertiary.color)
                        Text("· SSID \(network.ssidIndex) · \(network.ssidIndex == Self.primaryIndex(for: network) ? "Primary" : "Secondary") network")
                            .foregroundStyle(palette.textSecondary.color)
                    }
                    .font(.caption2.monospacedDigit())
                }

                Spacer(minLength: 6)
            }

            HStack(spacing: 11) {
                if canDisable {
                    Button {
                        enabledBinding.wrappedValue.toggle()
                    } label: {
                        Label(enabledBinding.wrappedValue ? "Enabled" : "Disabled",
                              systemImage: enabledBinding.wrappedValue ? "checkmark.circle.fill" : "circle")
                            .font(.caption2.weight(.semibold).monospacedDigit())
                            .foregroundStyle(enabledBinding.wrappedValue ? Color.green : palette.textSecondary.color)
                    }
                    .buttonStyle(.plain)
                    .disabled(isEditDisabled)
                }
                if !isEditingName {
                    Button {
                        editedName = network.name
                        isEditingName = true
                        nameFieldFocused = true
                    } label: {
                        Label("Edit", systemImage: "pencil")
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(palette.textAccent)
                    }
                    .buttonStyle(.plain)
                    .disabled(isEditDisabled)

                    Button { openEdit(nil) } label: {
                        Image(systemName: "key.fill")
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(palette.textAccent)
                    }
                    .buttonStyle(.plain)
                    .disabled(isEditDisabled)
                    .accessibilityLabel("Edit Wi-Fi password")

                    Button(action: openQr) {
                        Label("QR", systemImage: "qrcode")
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(palette.textAccent)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Show Wi-Fi QR code")

                    if canDelete {
                        Button(role: .destructive) {
                            showDeleteConfirmation = true
                        } label: {
                            Label("Delete", systemImage: "trash")
                                .font(.caption2.weight(.medium))
                                .foregroundStyle(.red)
                        }
                        .buttonStyle(.plain)
                        .disabled(isEditDisabled)
                    }
                }
            }
        }
        .padding(.vertical, 10)
        .onChange(of: network.enabled) { _ in optimisticEnabled = nil }
        .onChange(of: network.name) { value in
            if !isEditingName { editedName = value }
        }
        .alert("Delete extra Wi-Fi network?", isPresented: $showDeleteConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive, action: delete)
        } message: {
            Text("\(network.name) will be removed from the \(MonitorViewModel.bandName(network.band)) network list.")
        }
    }

    private static func primaryIndex(for network: WifiNetwork) -> Int {
        WifiFrequencyBand(rawValue: network.band)?.wlanIndices.first ?? (network.ssidIndex <= 4 ? 1 : 5)
    }

    private var isActive: Bool {
        radioIsEnabled && network.enabled
    }

    private var statusText: String {
        guard radioIsEnabled else { return "Paused" }
        return network.enabled ? "Active" : "Off"
    }
}

/// Fetches the Wi-Fi passphrase on demand from `WlanBasic.asp`, renders an offline QR code,
/// and discards the passphrase immediately on dismiss or app background.
private struct WifiQrSheet: View {
    @ObservedObject var viewModel: MonitorViewModel
    let network: WifiNetwork

    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.linkWaveThemePalette) private var palette
    @Environment(\.colorScheme) private var colorScheme

    @State private var config: WifiSsidConfig?
    @State private var isLoading = false
    @State private var errorText: String?
    @State private var showPassword = false
    @State private var copiedPassword = false
    @State private var copiedNetworkName = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    if isLoading {
                        ProgressView("Reading security settings from router…")
                            .padding(.vertical, 36)
                    } else if let errorText {
                        VStack(spacing: 12) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.largeTitle)
                                .foregroundColor(.orange)
                            Text(errorText)
                                .font(.subheadline)
                                .linkWaveText(.secondary)
                                .multilineTextAlignment(.center)
                            Button("Retry") {
                                Task { await loadConfig() }
                            }
                            .liquidGlassActionButton()
                        }
                        .frame(maxWidth: .infinity)
                        .linkWaveGlassCard()
                    } else if let config {
                        content(for: config)
                    }
                }
                .padding()
            }
            .background { LiquidGlassBackground(isSheet: true) }
            .navigationTitle("Wi-Fi Network")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(.hidden, for: .tabBar)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDragIndicator(.visible)
        .task { await loadConfig() }
        .onDisappear {
            config = nil
            showPassword = false
        }
        .onChange(of: scenePhase) { phase in
            if phase == .background {
                config = nil
                showPassword = false
                dismiss()
            }
        }
    }

    @ViewBuilder
    private func content(for cfg: WifiSsidConfig) -> some View {
        VStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 5) {
                Text("SHARE WI-FI")
                    .font(.caption2.weight(.bold))
                    .tracking(1.1)
                    .foregroundStyle(palette.textAccent)
                Text(cfg.ssid.isEmpty ? network.name : cfg.ssid)
                    .font(.title3.weight(.bold))
                    .lineLimit(2)
                if cfg.isHidden {
                    HStack {
                        Label("Hidden network", systemImage: "eye.slash")
                            .font(.caption)
                            .linkWaveText(.secondary)
                        Spacer()
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if let payload = cfg.qrPayload, let uiImage = QrImageGenerator.generate(from: payload) {
                Image(uiImage: uiImage)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: 220, maxHeight: 220)
                    .padding(14)
                    .background(Color.white, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .accessibilityLabel("Wi-Fi join QR code for \(cfg.ssid)")
                    .frame(maxWidth: .infinity)
                    .padding(14)
                    .background(
                        colorScheme == .dark ? Color.white.opacity(0.96) : Color.white,
                        in: RoundedRectangle(cornerRadius: 20, style: .continuous)
                    )
                    .overlay {
                        RoundedRectangle(cornerRadius: 20, style: .continuous)
                            .stroke(Color.black.opacity(0.08), lineWidth: 0.8)
                    }

                Text("SSID \(network.ssidIndex) · \(MonitorViewModel.bandName(network.band)) · \(cfg.authMode.displayName)")
                    .font(.caption.monospacedDigit())
                    .linkWaveText(.secondary)

                Button {
                    UIPasteboard.general.string = cfg.ssid
                    Haptics.impact(.light)
                    copiedNetworkName = true
                    Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 1_500_000_000)
                        copiedNetworkName = false
                    }
                } label: {
                    Label(copiedNetworkName ? "Network Name Copied" : "Copy Network Name",
                          systemImage: copiedNetworkName ? "checkmark.circle.fill" : "doc.on.doc")
                        .foregroundStyle(copiedNetworkName ? Color.green : palette.textAccent)
                        .frame(maxWidth: .infinity)
                }
                .liquidGlassActionButton(tint: palette.textAccent)

                let shareImage = Image(uiImage: uiImage)
                ShareLink(
                    item: shareImage,
                    preview: SharePreview("Join Wi-Fi: \(cfg.ssid)", image: shareImage)
                ) {
                    Label("Share QR Code", systemImage: "square.and.arrow.up")
                        .frame(maxWidth: .infinity)
                }
                .liquidGlassSmallButton()
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "qrcode")
                        .font(.largeTitle)
                        .linkWaveText(.secondary)
                    Text(qrUnavailableReason(for: cfg))
                        .font(.subheadline)
                        .linkWaveText(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .linkWaveGlassCard()
            }

            if cfg.authMode != .open && !cfg.psk.isEmpty && !cfg.isPasswordMasked {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Passphrase")
                        .font(.caption.weight(.semibold))
                        .linkWaveText(.secondary)

                    HStack(spacing: 10) {
                        Text(showPassword ? cfg.psk : String(repeating: "•", count: max(8, min(cfg.psk.count, 16))))
                            .font(.body.monospaced())
                            .textSelection(.enabled)
                        Spacer()
                        Button {
                            showPassword.toggle()
                        } label: {
                            Image(systemName: showPassword ? "eye.slash" : "eye")
                        }
                        .accessibilityLabel(showPassword ? "Hide password" : "Reveal password")

                        Button {
                            UIPasteboard.general.string = cfg.psk
                            Haptics.impact(.light)
                            copiedPassword = true
                        } label: {
                            Label(copiedPassword ? "Copied" : "Copy", systemImage: copiedPassword ? "checkmark" : "doc.on.doc")
                                .font(.caption.weight(.semibold))
                        }
                        .liquidGlassSmallButton()
                    }
                    .padding(.vertical, 8)

                    Text("Fetched live from the router and never saved on this iPhone.")
                        .font(.caption2)
                        .linkWaveText(.secondary)
                }
                .linkWaveGlassCard()
            }
        }
    }

    private func qrUnavailableReason(for cfg: WifiSsidConfig) -> String {
        if cfg.isPasswordMasked {
            return "This router masks Wi-Fi passphrases in its web page, so a join QR code cannot be generated automatically."
        }
        return "QR codes are available for Open and WPA/WPA2/WPA3-PSK networks."
    }

    private func loadConfig() async {
        isLoading = true
        errorText = nil
        do {
            config = try await viewModel.fetchWifiSsidConfig(for: network)
        } catch {
            errorText = MonitorViewModel.describe(error, host: viewModel.settings.host)
        }
        isLoading = false
    }
}

/// Ephemeral editor for WPA2-PSK SSID & passphrase (`#704`).
/// Refuses edits when security mode is unsupported or required `WlanBasic.asp` fields are missing/masked,
/// requires typed SSID confirmation before submit, and wipes sensitive state on dismiss/background.
private struct WifiEditSheet: View {
    @ObservedObject var viewModel: MonitorViewModel
    let network: WifiNetwork
    let initialSsid: String?

    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase

    @State private var config: WifiSsidConfig?
    @State private var isLoading = false
    @State private var loadError: String?
    @State private var ssidInput = ""
    @State private var passwordInput = ""
    @State private var showPassword = false
    @State private var showConfirmSheet = false
    @State private var isSaving = false
    @State private var saveErrorText: String?

    private var hasChanges: Bool {
        guard let config else { return false }
        return ssidInput != config.ssid || passwordInput != config.psk
    }

    private var validationError: String? {
        do {
            try HuaweiOntClient.validateWifiCredentials(ssid: ssidInput, password: passwordInput)
            return nil
        } catch {
            return (error as? LocalizedError)?.errorDescription ?? "Invalid Wi-Fi settings."
        }
    }

    private var canSubmit: Bool {
        guard let config else { return false }
        return config.authMode.isEditableWpa2Or3Psk
            && config.missingEditFields.isEmpty
            && hasChanges
            && validationError == nil
            && !isSaving
    }

    var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    VStack {
                        Spacer()
                        ProgressView("Reading Wi-Fi configuration…")
                        Spacer()
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background { LiquidGlassBackground(isSheet: true) }
                } else if let loadError {
                    ScrollView {
                        VStack(spacing: 12) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.largeTitle)
                                .foregroundColor(.orange)
                            Text(loadError)
                                .font(.subheadline)
                                .linkWaveText(.secondary)
                                .multilineTextAlignment(.center)
                            Button("Retry") {
                                Task { await loadConfig() }
                            }
                            .liquidGlassActionButton()
                        }
                        .frame(maxWidth: .infinity)
                        .linkWaveGlassCard()
                        .padding()
                    }
                    .background { LiquidGlassBackground(isSheet: true) }
                } else if let config {
                    if !config.authMode.isEditableWpa2Or3Psk {
                        refusalView(
                            title: "Unsupported Security Mode",
                            message: "This network uses \(config.authMode.displayName). Change it in the router's web page."
                        )
                    } else if !config.missingEditFields.isEmpty {
                        refusalView(
                            title: "Cannot Edit Safely",
                            message: "Required router settings were missing or masked (\(config.missingEditFields.joined(separator: ", "))), so changing credentials is disabled."
                        )
                    } else {
                        editForm(for: config)
                    }
                }
            }
            .navigationTitle("Edit Wi-Fi")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(.hidden, for: .tabBar)
            .interactiveDismissDisabled(isSaving)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .disabled(isSaving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    if config != nil && config?.authMode.isEditableWpa2Or3Psk == true && config?.missingEditFields.isEmpty == true {
                        Button("Save") {
                            saveErrorText = nil
                            showConfirmSheet = true
                        }
                        .disabled(!canSubmit)
                    }
                }
            }
        }
        .task { await loadConfig() }
        .onDisappear { wipeSensitiveState() }
        .onChange(of: scenePhase) { phase in
            if phase == .background {
                wipeSensitiveState()
                dismiss()
            }
        }
        .sheet(isPresented: $showConfirmSheet) {
            WifiEditConfirmSheet(
                newSsid: ssidInput,
                band: network.band,
                isPhoneOnWifi: viewModel.isPhoneOnWifi,
                isSaving: isSaving,
                errorText: saveErrorText
            ) {
                await commitSave()
            }
        }
    }

    @ViewBuilder
    private func editForm(for cfg: WifiSsidConfig) -> some View {
        Form {
            Section {
                TextField("Network name (SSID)", text: $ssidInput)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            } header: {
                Text("Network Name (SSID)")
            } footer: {
                Text("\(ssidInput.utf8.count)/32 UTF-8 bytes")
                    .foregroundColor(ssidInput.utf8.count > 32 ? .red : .secondary)
            }

            Section {
                HStack(spacing: 8) {
                    if showPassword {
                        TextField("Wi-Fi password", text: $passwordInput)
                            .font(.body.monospaced())
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    } else {
                        SecureField("Wi-Fi password", text: $passwordInput)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }
                    Button {
                        showPassword.toggle()
                    } label: {
                        Image(systemName: showPassword ? "eye.slash" : "eye")
                            .linkWaveText(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(showPassword ? "Hide password" : "Reveal password")
                }
            } header: {
                Text("Passphrase")
            } footer: {
                Text("8 to 63 printable ASCII characters (\(passwordInput.count)/63). Fetched live and never saved on this iPhone.")
            }

            if let validationError {
                Section {
                    Label(validationError, systemImage: "exclamationmark.circle.fill")
                        .font(.subheadline)
                        .foregroundColor(.red)
                }
            }

            Section("Network Details") {
                LabeledContent("Band", value: MonitorViewModel.bandName(network.band))
                LabeledContent("Security", value: cfg.authMode.displayName)
                LabeledContent("Hidden", value: cfg.isHidden ? "Yes" : "No")
            }
        }
        .linkWaveThemedListSurface()
    }

    private func refusalView(title: String, message: String) -> some View {
        ScrollView {
            VStack(spacing: 12) {
                Image(systemName: "lock.shield")
                    .font(.largeTitle)
                    .foregroundColor(.orange)
                Text(title)
                    .font(.headline)
                Text(message)
                    .font(.subheadline)
                    .linkWaveText(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .linkWaveGlassCard()
            .padding()
        }
        .background { LiquidGlassBackground(isSheet: true) }
    }

    private func loadConfig() async {
        isLoading = true
        loadError = nil
        do {
            let loaded = try await viewModel.fetchWifiSsidConfig(for: network)
            config = loaded
            ssidInput = initialSsid ?? loaded.ssid
            passwordInput = loaded.psk
        } catch {
            loadError = MonitorViewModel.describe(error, host: viewModel.settings.host)
        }
        isLoading = false
    }

    private func commitSave() async {
        guard let cfg = config else { return }
        isSaving = true
        saveErrorText = nil
        do {
            _ = try await viewModel.updateWifiCredentials(
                config: cfg,
                newSsid: ssidInput,
                newPassword: passwordInput
            )
            isSaving = false
            showConfirmSheet = false
            wipeSensitiveState()
            dismiss()
        } catch {
            isSaving = false
            saveErrorText = MonitorViewModel.describe(error, host: viewModel.settings.host)
        }
    }

    private func wipeSensitiveState() {
        config = nil
        passwordInput = ""
        showPassword = false
        showConfirmSheet = false
        saveErrorText = nil
    }
}

private struct WifiEditConfirmSheet: View {
    let newSsid: String
    let band: String
    let isPhoneOnWifi: Bool
    let isSaving: Bool
    let errorText: String?
    let onConfirm: () async -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var typedSsid = ""

    private var matchesSsid: Bool {
        typedSsid == newSsid
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("All Devices Will Disconnect", systemImage: "wifi.exclamationmark")
                            .font(.headline)
                            .foregroundColor(.orange)
                        Text(
                            isPhoneOnWifi
                                ? "When the router applies these settings, all devices on \(MonitorViewModel.bandName(band)) — including this iPhone — will disconnect immediately. You will need to rejoin \"\(newSsid)\" in Settings → Wi-Fi with the new password."
                                : "When the router applies these settings, every device on \(MonitorViewModel.bandName(band)) will disconnect and must rejoin \"\(newSsid)\" with the new password."
                        )
                        .font(.subheadline)
                        .linkWaveText(.secondary)
                    }
                    .padding(.vertical, 4)
                }

                Section {
                    TextField("Type \(newSsid)", text: $typedSsid)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text("Type the new SSID to confirm")
                } footer: {
                    Text("Enter \"\(newSsid)\" exactly to apply the change.")
                }

                if let errorText {
                    Section {
                        Label(errorText, systemImage: "exclamationmark.triangle.fill")
                            .font(.subheadline)
                            .foregroundColor(.red)
                    }
                }
            }
            .linkWaveThemedListSurface()
            .navigationTitle("Confirm Wi-Fi Change")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(.hidden, for: .tabBar)
            .interactiveDismissDisabled(isSaving)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .disabled(isSaving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isSaving {
                        ProgressView()
                    } else {
                        Button("Apply") {
                            Task { await onConfirm() }
                        }
                        .disabled(!matchesSsid)
                    }
                }
            }
        }
    }
}

private enum QrImageGenerator {
    static func generate(from payload: String) -> UIImage? {
        let context = CIContext()
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(payload.utf8)
        filter.correctionLevel = "M"
        guard let outputImage = filter.outputImage else { return nil }
        let scaled = outputImage.transformed(by: CGAffineTransform(scaleX: 10, y: 10))
        guard let cgImage = context.createCGImage(scaled, from: scaled.extent) else { return nil }
        return UIImage(cgImage: cgImage)
    }
}

private struct WifiEmptyCard: View {
    let message: String
    var isLoading: Bool = false
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: 10) {
            if isLoading {
                ProgressView()
            } else {
                Image(systemName: "wifi")
                    .font(.system(size: 32))
                    .linkWaveText(.secondary)
                    .accessibilityHidden(true)
            }
            Text(message)
                .font(.subheadline)
                .linkWaveText(.secondary)
                .multilineTextAlignment(.center)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .liquidGlassSmallButton()
                    .padding(.top, 2)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .linkWaveGlassCard()
    }
}

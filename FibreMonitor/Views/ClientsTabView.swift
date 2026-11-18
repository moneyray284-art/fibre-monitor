import SwiftUI

private enum ClientDeviceIcon {
    private enum Kind {
        case phone, tablet, laptop, desktop, appleTV, tv, gaming, smartHome, printer
    }

    // A small offline OUI hint set for device families that are reasonably distinctive.
    // OUI identifies the registered manufacturer, not the exact product model, so ambiguous
    // vendors are deliberately left to the hostname and DHCP vendor text.
    private static let ouiHints: [String: Kind] = [
        "240AC4": .smartHome, // Espressif
        "000E58": .smartHome, // Sonos
        "5CAAFD": .smartHome, // Sonos
        "000D4B": .tv,        // Roku
        "000048": .printer,   // Seiko Epson
        "008077": .printer    // Brother
    ]

    static func symbol(for device: OntDevice, isThisPhone: Bool) -> String {
        switch classify(device, isThisPhone: isThisPhone) {
        case .some(.phone): return "iphone"
        case .some(.tablet): return "ipad"
        case .some(.laptop): return "laptopcomputer"
        case .some(.desktop): return "desktopcomputer"
        case .some(.appleTV): return "appletv"
        case .some(.tv): return "tv"
        case .some(.gaming): return "gamecontroller"
        case .some(.smartHome): return "lightbulb"
        case .some(.printer): return "printer"
        case nil: return device.port.isWifi ? "wifi" : (device.port.isLan ? "cable.connector" : "network")
        }
    }

    private static func classify(_ device: OntDevice, isThisPhone: Bool) -> Kind? {
        if isThisPhone { return .phone }

        let text = [device.hostName, device.routerAlias, device.dhcpVendor, device.displayName]
            .joined(separator: " ")
            .lowercased()
        let tokens = Set(text.split { !$0.isLetter && !$0.isNumber }.map(String.init))
        func has(_ values: [String]) -> Bool {
            values.contains { value in
                let normalized = value.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
                if normalized.count == 1 { return tokens.contains(normalized[0]) || text.contains(value.lowercased()) }
                return text.contains(value.lowercased())
            }
        }

        if has(["ipad", "tab", "tablet", "kindle"]) { return .tablet }
        if has(["playstation", "ps4", "ps5", "xbox", "nintendo", "switch"]) { return .gaming }
        if has(["apple-tv", "appletv"]) { return .appleTV }
        if has(["tv", "roku", "firetv", "fire tv", "chromecast", "bravia", "webos", "tizen", "nvidia-shield", "nvidia shield"]) {
            return .tv
        }
        if has(["printer", "epson", "canon", "brother", "laserjet"]) { return .printer }
        if has(["macbook", "laptop", "thinkpad"]) { return .laptop }
        if has(["imac", "mac-mini", "mac mini", "desktop", "windows", "dell", "hp", "hewlett packard", "lenovo", "asus", "pc"]) {
            return .desktop
        }
        if has(["iphone", "galaxy", "pixel", "android", "redmi", "tecno", "infinix", "oneplus", "phone"]) {
            return .phone
        }
        if has(["esp", "esp32", "tuya", "sonoff", "alexa", "echo", "homepod", "camera", "cam", "plug"]) {
            return .smartHome
        }

        let oui = device.mac.uppercased().filter(\.isHexDigit).prefix(6)
        return ouiHints[String(oui)]
    }
}

private enum ClientSignal {
    static func bars(for device: OntDevice) -> Int {
        guard device.isOnline else { return 0 }
        if device.port.isLan { return 4 }
        guard device.port.isWifi, let rssi = device.rssiDbm else { return 3 }
        if rssi >= -55 { return 4 }
        if rssi >= -65 { return 3 }
        if rssi >= -79 { return 2 }
        return 1
    }

    static func color(for device: OntDevice, accent: Color, neutral: Color) -> Color {
        guard device.isOnline else { return neutral }
        guard device.port.isWifi, let rssi = device.rssiDbm else { return accent }
        if rssi >= -65 { return .green }
        if rssi >= -79 { return .orange }
        return Color(red: 0.88, green: 0.24, blue: 0.35)
    }

    static func quality(for device: OntDevice) -> String? {
        guard device.isOnline, device.port.isWifi, let rssi = device.rssiDbm else { return nil }
        if rssi >= -65 { return "Strong" }
        if rssi >= -79 { return "Fair" }
        return "Weak"
    }

    static func detail(for device: OntDevice) -> String? {
        if let rssi = device.rssiDbm {
            return "\(Int(rssi.rounded())) dBm"
        }
        let label = device.port.compactLabel
        return label.isEmpty || label == "—" ? nil : label
    }
}

private struct ClientSignalBars: View {
    let level: Int
    let color: Color
    let mutedColor: Color

    private let heights: [CGFloat] = [4, 7, 10, 13]

    var body: some View {
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(0..<4, id: \.self) { index in
                Capsule()
                    .fill(index < level ? color : mutedColor.opacity(0.42))
                    .frame(width: 3, height: heights[index])
            }
        }
        .frame(height: 13)
        .accessibilityLabel(level == 0 ? "No connection signal" : "Signal, \(level) of 4 bars")
    }
}

public struct ClientsTabView: View {
    @ObservedObject var viewModel: MonitorViewModel
    @ObservedObject private var discoveredNameStore: DiscoveredDeviceNameStore
    @Environment(\.linkWaveThemePalette) private var palette
    @State private var searchText = ""
    @State private var selectedDevice: OntDevice?
    @State private var selectedBlockedDevice: BlockedRouterDevice?
    @State private var localWiFiIPv4: String?
    @State private var isOnlineExpanded = true
    @State private var isOfflineExpanded = false
    @State private var pendingBlockConflictDevice: OntDevice?
    @State private var showBlockConflictAlert = false

    public init(viewModel: MonitorViewModel) {
        self.viewModel = viewModel
        _discoveredNameStore = ObservedObject(wrappedValue: .shared)
    }

    private var selectedFilter: ClientsFilter { viewModel.clientsFilter }

    public var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    if viewModel.settings.isConfigured {
                        HStack {
                            Text("\(filteredOnline.count) online · \(filteredOffline.count) offline · \(viewModel.blockedDevices.count) blocked")
                                .font(.caption.weight(.medium))
                                .linkWaveText(.secondary)
                                .monospacedDigit()
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 4)
                        clientFilterTabs
                    }

                    if !viewModel.settings.isConfigured {
                        ClientsEmptyCard(
                            icon: "wifi.router",
                            title: "No Router Configured",
                            message: "Add a router in Settings to see connected clients."
                        )
                    } else if selectedFilter == .blocked {
                        if filteredBlockedDevices.isEmpty {
                            ClientsEmptyCard(
                                icon: "hand.raised",
                                title: "No blocked devices",
                                message: "Devices you block from Wi-Fi will appear here."
                            )
                        } else {
                            VStack(spacing: 10) {
                                CardHeader(icon: "hand.raised.fill", title: "Blocked") {
                                    Pill(text: "\(filteredBlockedDevices.count)", color: .red)
                                }
                                ForEach(filteredBlockedDevices) { device in
                                    blockedButton(for: device)
                                }
                            }
                            .linkWaveGlassCard()
                        }
                    } else if visibleOnline.isEmpty && visibleOffline.isEmpty {
                        ClientsEmptyCard(
                            icon: searchText.isEmpty
                                ? (viewModel.isLoggedOut ? "rectangle.portrait.and.arrow.right" : "laptopcomputer.and.iphone")
                                : "magnifyingglass",
                            title: clientsEmptyTitle,
                            message: clientsEmptyMessage,
                            isLoading: searchText.isEmpty && viewModel.isRefreshing && !viewModel.isLoggedOut,
                            actionTitle: searchText.isEmpty && viewModel.isLoggedOut ? "Reconnect" : nil,
                            action: viewModel.isLoggedOut ? { viewModel.reconnectSession() } : nil
                        )
                    } else {
                        if !visibleOnline.isEmpty {
                            ClientDeviceSectionCard(
                                icon: "wifi",
                                title: "Online",
                                count: visibleOnline.count,
                                tint: .green,
                                isExpanded: isOnlineExpanded,
                                action: {
                                    isOnlineExpanded.toggle()
                                },
                                content: AnyView(clientRows(visibleOnline))
                            )
                        }

                        if !visibleOffline.isEmpty {
                            ClientDeviceSectionCard(
                                icon: "moon.zzz.fill",
                                title: "Offline",
                                count: visibleOffline.count,
                                tint: .secondary,
                                isExpanded: isOfflineExpanded,
                                action: {
                                    isOfflineExpanded.toggle()
                                },
                                content: AnyView(clientRows(visibleOffline))
                            )
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
                LocalDeviceNameDiscovery.shared.scan(
                    devices: viewModel.devices,
                    gatewayHost: viewModel.settings.activeProfile?.host,
                    force: true
                )
            }
            .searchable(text: $searchText, prompt: "Search name, IP, MAC, or vendor")
            .navigationTitle("Clients")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                StandaloneTopBarTrailingItem(
                    content: AnyView(RouterRefreshToolbarButton(viewModel: viewModel, isEnabled: viewModel.settings.isConfigured))
                )
            }
        }
        .onAppear {
            refreshLocalWiFiAddress()
            startLocalNameDiscoveryIfVisible()
        }
        .onChange(of: viewModel.devices) { devices in
            guard viewModel.selectedTab == .clients else { return }
            LocalDeviceNameDiscovery.shared.scan(
                devices: devices,
                gatewayHost: viewModel.settings.activeProfile?.host
            )
        }
        .onChange(of: viewModel.isConnected) { _ in refreshLocalWiFiAddress() }
        .onChange(of: viewModel.selectedTab) { tab in
            if tab == .clients {
                refreshLocalWiFiAddress()
                startLocalNameDiscoveryIfVisible()
            }
        }
        .sheet(item: $selectedDevice) { device in
            ClientDetailSheet(
                viewModel: viewModel,
                device: currentSnapshot(of: device),
                isThisPhone: isThisPhone(device)
            )
        }
        .sheet(item: $selectedBlockedDevice) { device in
            BlockedClientDetailSheet(
                device: device,
                displayName: displayName(for: device),
                onUnblock: { Task { await viewModel.unblockWifiDevice(device) } }
            )
        }
        .alert("Existing Access-Control Entries", isPresented: $showBlockConflictAlert) {
            Button("Clear & Block Device", role: .destructive) {
                guard let device = pendingBlockConflictDevice else { return }
                pendingBlockConflictDevice = nil
                Task { await viewModel.blockWifiDevice(device, clearConflictingEntries: true) }
            }
            Button("Cancel", role: .cancel) { pendingBlockConflictDevice = nil }
        } message: {
            Text("This clears the router's existing WLAN and LAN MAC access-control entries, enables blacklist mode, and blocks the selected device.")
        }
    }

    private func currentSnapshot(of device: OntDevice) -> OntDevice {
        viewModel.devices.first(where: { $0.id == device.id }) ?? device
    }

    private func startLocalNameDiscoveryIfVisible() {
        guard viewModel.selectedTab == .clients else { return }
        LocalDeviceNameDiscovery.shared.scan(
            devices: viewModel.devices,
            gatewayHost: viewModel.settings.activeProfile?.host
        )
    }

    private func requestBlock(_ device: OntDevice) {
        Task { @MainActor in
            if await viewModel.blockWifiDevice(device) {
                pendingBlockConflictDevice = device
                showBlockConflictAlert = true
            }
        }
    }

    private func clientButton(for device: OntDevice) -> some View {
        let thisPhone = isThisPhone(device)
        return Button {
            selectedDevice = device
        } label: {
            ClientRow(
                device: device,
                displayName: resolvedName(for: device),
                isThisPhone: thisPhone
            )
        }
        .buttonStyle(.plain)
        .contextMenu {
            if !thisPhone && device.port.isWifi {
                Button(role: .destructive) {
                    requestBlock(device)
                } label: {
                    Label("Block Device", systemImage: "hand.raised.fill")
                }
            }
        }
    }

    private func blockedButton(for device: BlockedRouterDevice) -> some View {
        BlockedClientRow(
            device: device,
            displayName: displayName(for: device),
            onSelect: { selectedBlockedDevice = device },
            onUnblock: { Task { await viewModel.unblockWifiDevice(device) } }
        )
    }

    @ViewBuilder
    private func clientRows(_ devices: [OntDevice]) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(devices.enumerated()), id: \.offset) { entry in
                clientButton(for: entry.element)
                if entry.offset < devices.count - 1 {
                    Divider()
                        .padding(.leading, 54)
                        .padding(.trailing, 12)
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 8)
    }

    private func displayName(for blocked: BlockedRouterDevice) -> String {
        if let device = viewModel.devices.first(where: { $0.mac.caseInsensitiveCompare(blocked.mac) == .orderedSame }) {
            return resolvedName(for: device)
        }
        return blocked.name.isEmpty ? blocked.mac : blocked.name
    }

    private func resolvedName(for device: OntDevice) -> String {
        DeviceNameResolver.name(
            for: device,
            userAlias: viewModel.settings.alias(for: device.mac),
            discoveredName: discoveredNameStore.name(for: device.mac)
        )
    }

    private var filteredOnline: [OntDevice] {
        let devices = filter(unblockedDeviceRecords.filter(\.isOnline))
        return devices.sorted { isThisPhone($0) && !isThisPhone($1) }
    }

    private var filteredWeakClients: [OntDevice] {
        filter(unblockedDeviceRecords.filter { $0.isOnline && ($0.rssiDbm ?? .infinity) <= -75 })
            .sorted {
                let left = $0.rssiDbm ?? .infinity
                let right = $1.rssiDbm ?? .infinity
                if left != right { return left < right }
                return resolvedName(for: $0).localizedCaseInsensitiveCompare(resolvedName(for: $1)) == .orderedAscending
            }
    }

    private var clientFilterTabs: some View {
        HStack(spacing: 3) {
            ForEach(ClientsFilter.allCases, id: \.self) { filter in
                Button {
                    selectFilter(filter)
                } label: {
                    Text("\(filter.menuTitle) \(count(for: filter))")
                        .font(.caption2.weight(.semibold))
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.78)
                        .foregroundStyle(selectedFilter == filter ? palette.textAccent : palette.textSecondary.color)
                        .frame(maxWidth: .infinity, minHeight: 34)
                        .background {
                            if selectedFilter == filter {
                                Capsule().fill(palette.textAccent.opacity(0.13))
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selectedFilter == filter ? .isSelected : [])
            }
        }
        .padding(3)
        .liquidGlassCapsule()
    }

    private func count(for filter: ClientsFilter) -> Int {
        switch filter {
        case .all: allCount
        case .online: filteredOnline.count
        case .weak: filteredWeakClients.count
        case .offline: filteredOffline.count
        case .blocked: filteredBlockedDevices.count
        }
    }

    private var filteredOffline: [OntDevice] {
        filter(unblockedDeviceRecords.filter { !$0.isOnline })
    }

    private var unblockedDeviceRecords: [OntDevice] {
        let blockedMacs = Set(viewModel.blockedDevices.map { $0.mac.lowercased() })
        return viewModel.devices.filter { !blockedMacs.contains($0.mac.lowercased()) }
    }

    private var filteredBlockedDevices: [BlockedRouterDevice] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return viewModel.blockedDevices }
        return viewModel.blockedDevices.filter {
            $0.mac.lowercased().contains(query)
                || $0.name.lowercased().contains(query)
                || $0.ssidName.lowercased().contains(query)
        }
    }

    private var visibleOnline: [OntDevice] {
        switch selectedFilter {
        case .all, .online: filteredOnline
        case .weak: filteredWeakClients
        case .offline, .blocked: []
        }
    }

    private var visibleOffline: [OntDevice] {
        selectedFilter == .all || selectedFilter == .offline ? filteredOffline : []
    }

    private var allCount: Int { filteredOnline.count + filteredOffline.count }

    private var selectedCount: Int {
        switch selectedFilter {
        case .all: allCount
        case .online: filteredOnline.count
        case .weak: filteredWeakClients.count
        case .offline: filteredOffline.count
        case .blocked: filteredBlockedDevices.count
        }
    }

    private func selectFilter(_ filter: ClientsFilter) {
        withAnimation(.spring(response: 0.34, dampingFraction: 0.82)) {
            viewModel.clientsFilter = filter
            switch filter {
            case .all:
                isOnlineExpanded = true
                isOfflineExpanded = false
            case .online:
                isOnlineExpanded = true
                isOfflineExpanded = false
            case .weak:
                isOnlineExpanded = true
                isOfflineExpanded = false
            case .offline:
                isOfflineExpanded = true
                isOnlineExpanded = false
            case .blocked:
                break
            }
        }
    }

    private var filterMenu: some View {
        Menu {
            Button {
                selectFilter(.all)
            } label: {
                HStack {
                    Image(systemName: "square.grid.2x2")
                    Text("All (\(allCount))")
                    Spacer()
                    if selectedFilter == .all {
                        Image(systemName: "checkmark")
                    }
                }
            }

            Button {
                selectFilter(.online)
            } label: {
                HStack {
                    Circle().fill(.green).frame(width: 8, height: 8)
                    Text("Online (\(filteredOnline.count))")
                    Spacer()
                    if selectedFilter == .online {
                        Image(systemName: "checkmark")
                    }
                }
            }

            Button {
                selectFilter(.weak)
            } label: {
                HStack {
                    Image(systemName: "wifi.exclamationmark")
                    Text("Weak (\(filteredWeakClients.count))")
                    Spacer()
                    if selectedFilter == .weak {
                        Image(systemName: "checkmark")
                    }
                }
            }

            Button {
                selectFilter(.offline)
            } label: {
                HStack {
                    Circle().fill(.secondary).frame(width: 8, height: 8)
                    Text("Offline (\(filteredOffline.count))")
                    Spacer()
                    if selectedFilter == .offline {
                        Image(systemName: "checkmark")
                    }
                }
            }

            Button {
                selectFilter(.blocked)
            } label: {
                HStack {
                    Image(systemName: "hand.raised.fill")
                    Text("Blocked (\(viewModel.blockedDevices.count))")
                    Spacer()
                    if selectedFilter == .blocked {
                        Image(systemName: "checkmark")
                    }
                }
            }
        } label: {
            HStack(spacing: 6) {
                Text("\(selectedFilter.menuTitle) (\(selectedCount))")
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.caption2.weight(.bold))
            }
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 10)
            .frame(height: 38)
            .contentShape(Capsule())
            .liquidGlassToolbarCapsule()
        }
        .accessibilityLabel("Filter devices")
        .accessibilityValue("\(selectedFilter.menuTitle), \(selectedCount) devices")
    }

    private var clientsEmptyTitle: String {
        if !searchText.isEmpty { return "No Matching Clients" }
        if selectedFilter == .blocked { return "No blocked devices" }
        if selectedFilter == .online { return "No online devices" }
        if selectedFilter == .weak { return "No Weak-Signal Clients" }
        if selectedFilter == .offline { return "No offline devices" }
        if viewModel.isLoggedOut { return "Logged Out of Router" }
        if viewModel.isConnected { return "No Clients Reported" }
        return viewModel.isRefreshing ? "Loading Clients…" : "Waiting for Router…"
    }

    private var clientsEmptyMessage: String {
        if !searchText.isEmpty { return "Try searching by name, IP address, MAC, or vendor." }
        if selectedFilter == .blocked { return "Devices you block from Wi-Fi will appear here." }
        if selectedFilter == .online { return "The router currently reports no online devices." }
        if selectedFilter == .weak { return "All online devices have strong Wi-Fi signal above -75 dBm." }
        if selectedFilter == .offline { return "All reported devices are currently online." }
        if viewModel.isLoggedOut { return "Tap Reconnect to resume reading the device list." }
        if let err = viewModel.errorMessage { return err }
        return "Pull down to refresh once the router responds."
    }

    private func refreshLocalWiFiAddress() {
        localWiFiIPv4 = LocalWiFiAddress.currentIPv4Address(interface: "en0")
    }

    private func isThisPhone(_ device: OntDevice) -> Bool {
        guard let localWiFiIPv4 = localWiFiIPv4.flatMap(LocalWiFiAddress.normalizedIPv4),
              let clientIPv4 = LocalWiFiAddress.normalizedIPv4(device.ip) else {
            return false
        }
        return localWiFiIPv4 == clientIPv4
    }

    private func filter(_ items: [OntDevice]) -> [OntDevice] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return items }
        return items.filter { d in
            let local = resolvedName(for: d).lowercased()
            return local.contains(query)
                || d.hostName.lowercased().contains(query)
                || d.routerAlias.lowercased().contains(query)
                || d.dhcpVendor.lowercased().contains(query)
                || d.ip.lowercased().contains(query)
                || d.mac.lowercased().contains(query)
                || d.port.label.lowercased().contains(query)
                || (isThisPhone(d) && "this phone".contains(query))
        }
    }
}

private struct ClientDeviceSectionCard: View {
    let icon: String
    let title: String
    let count: Int
    let tint: Color
    let isExpanded: Bool
    let action: () -> Void
    let content: AnyView

    init(
        icon: String,
        title: String,
        count: Int,
        tint: Color,
        isExpanded: Bool,
        action: @escaping () -> Void,
        content: AnyView
    ) {
        self.icon = icon
        self.title = title
        self.count = count
        self.tint = tint
        self.isExpanded = isExpanded
        self.action = action
        self.content = content
    }

    var body: some View {
        VStack(spacing: 0) {
            Button(action: action) {
                HStack(spacing: 10) {
                    Image(systemName: icon)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(tint)
                        .frame(width: 36, height: 36)
                        .background(tint.opacity(0.14), in: Circle())
                        .accessibilityHidden(true)
                    Text(title)
                        .font(.subheadline.weight(.bold))
                        .linkWaveText(.primary)
                    Spacer()
                    Pill(text: "\(count)", color: tint)
                    Image(systemName: "chevron.down")
                        .font(.caption.weight(.semibold))
                        .linkWaveText(.secondary)
                        .rotationEffect(.degrees(isExpanded ? 0 : -90))
                        .frame(width: 18, height: 24)
                        .accessibilityHidden(true)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(title), \(count) devices")
            .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
            .accessibilityHint("Double-tap to \(isExpanded ? "collapse" : "expand") this section")

            if isExpanded {
                content
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .linkWaveGlassCard(padding: 0)
        .animation(.spring(response: 0.34, dampingFraction: 0.82), value: isExpanded)
    }
}

private struct BlockedClientRow: View {
    let device: BlockedRouterDevice
    let displayName: String
    let onSelect: () -> Void
    let onUnblock: () -> Void
    @Environment(\.linkWaveThemePalette) private var palette

    var body: some View {
        HStack(spacing: 10) {
            Button(action: onSelect) {
                HStack(spacing: 10) {
                    Image(systemName: "hand.raised.fill")
                        .foregroundStyle(.red)
                        .frame(width: 34, height: 34)
                        .background(Color.red.opacity(0.12), in: Circle())
                    VStack(alignment: .leading, spacing: 3) {
                        Text(displayName.isEmpty ? device.mac : displayName)
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)
                        Text("\(device.mac) · \(device.ssidName)")
                            .font(.caption2.monospaced())
                            .linkWaveText(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 8)
                }
            }
            .buttonStyle(.plain)
            Button("Unblock", action: onUnblock)
                .font(.caption.weight(.semibold))
                .buttonStyle(.bordered)
                .tint(palette.textAccent)
        }
        .padding(10)
        .liquidGlassPill()
    }
}

private struct BlockedClientDetailSheet: View {
    let device: BlockedRouterDevice
    let displayName: String
    let onUnblock: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    LabeledContent("Name", value: displayName.isEmpty ? device.mac : displayName)
                    LabeledContent("MAC Address", value: device.mac)
                    LabeledContent("Wi-Fi Network", value: device.ssidName)
                }

                Section {
                    Button(role: .destructive) {
                        onUnblock()
                        dismiss()
                    } label: {
                        Label("Unblock Device", systemImage: "hand.raised.slash")
                    }
                } footer: {
                    Text("This restores the device's access to the selected Wi-Fi network.")
                }
            }
            .linkWaveThemedListSurface()
            .navigationTitle(displayName.isEmpty ? "Blocked Device" : displayName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(.hidden, for: .tabBar)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

private struct ClientRow: View {
    let device: OntDevice
    let displayName: String
    var isThisPhone = false
    @Environment(\.linkWaveThemePalette) private var palette

    private var signalColor: Color {
        ClientSignal.color(for: device, accent: palette.textAccent, neutral: palette.textSecondary.color)
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: ClientDeviceIcon.symbol(for: device, isThisPhone: isThisPhone))
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(device.isOnline ? palette.textAccent : palette.textSecondary.color)
                .frame(width: 38, height: 38)
                .background(
                    (device.isOnline ? palette.textAccent : palette.textSecondary.color)
                        .opacity(device.isOnline ? 0.14 : 0.1),
                    in: Circle()
                )
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(isThisPhone && isGenericHost ? "This Phone" : displayName)
                        .font(.subheadline.weight(.semibold))
                        .linkWaveText(.primary)
                        .lineLimit(1)
                    if isThisPhone {
                        Text("This Device")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(palette.textAccent)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(palette.textAccent.opacity(0.12), in: Capsule())
                    }
                }
                HStack(spacing: 4) {
                    Text(device.ip.isEmpty ? device.mac : device.ip)
                        .lineLimit(1)
                    if device.isOnline, !device.connectedText.isEmpty {
                        Text("·")
                        Text(device.connectedText)
                            .lineLimit(1)
                    }
                }
                .font(.caption.monospaced())
                .linkWaveText(.secondary)
                if let rateSummary = rateText {
                    Text(rateSummary)
                        .font(.caption2.monospacedDigit())
                        .linkWaveText(.secondary)
                }
            }

            Spacer(minLength: 8)

            if device.isOnline {
                VStack(alignment: .trailing, spacing: 5) {
                    HStack(spacing: 5) {
                        ClientSignalBars(
                            level: ClientSignal.bars(for: device),
                            color: signalColor,
                            mutedColor: palette.textTertiary.color
                        )
                        if let rssi = device.rssiDbm, device.port.isWifi {
                            Text("\(Int(rssi.rounded())) dBm")
                                .font(.caption2.monospacedDigit())
                                .linkWaveText(.secondary)
                            if let quality = ClientSignal.quality(for: device) {
                                Text("· \(quality)")
                                    .font(.caption2.weight(.medium))
                                    .foregroundStyle(signalColor)
                            }
                        }
                    }
                    if let bandLabel {
                        Pill(text: bandLabel, color: palette.textAccent)
                    }
                }
            } else {
                Text(offlineCaption)
                    .font(.caption2)
                    .linkWaveText(.secondary)
                    .multilineTextAlignment(.trailing)
                    .lineLimit(2)
            }

            Image(systemName: "chevron.right")
                .font(.caption2.weight(.semibold))
                .foregroundColor(palette.textTertiary.color.opacity(0.8))
                .accessibilityHidden(true)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 10)
        .accessibilityElement(children: .combine)
        .accessibilityHint("Double-tap to inspect device details")
    }

    private var isGenericHost: Bool {
        guard isThisPhone else { return false }
        let normalized = displayName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return ["iphone", "unknown", "unknown device", "unknown_device", "private wi-fi device", "--", ""].contains(normalized)
    }

    private var bandLabel: String? {
        switch device.port {
        case .wifi5, .wifi24: return device.port.label
        case .lan: return "LAN"
        case .other: return nil
        }
    }

    private var offlineCaption: String {
        if device.port.isWifi { return "Offline · \(device.port.label)" }
        if device.port.isLan { return "Offline · LAN" }
        return "Offline"
    }

    private var rateText: String? {
        guard device.hasTrafficRates else { return nil }
        var parts: [String] = []
        if let down = device.trafficRecvRate, down > 0 {
            parts.append("↓ \(TrafficRateFormatter.string(bytesPerSecond: down))")
        }
        if let up = device.trafficSendRate, up > 0 {
            parts.append("↑ \(TrafficRateFormatter.string(bytesPerSecond: up))")
        }
        return parts.isEmpty ? nil : parts.joined(separator: "  ")
    }
}
private struct ClientDetailSheet: View {
    @ObservedObject var viewModel: MonitorViewModel
    @ObservedObject private var discoveredNameStore: DiscoveredDeviceNameStore
    let device: OntDevice
    let isThisPhone: Bool
    @Environment(\.dismiss) private var dismiss

    @State private var showRouterRename = false
    @State private var showLocalRename = false
    @State private var localAliasInput = ""
    @State private var confirmRemove = false
    @State private var showBlockConflictConfirmation = false

    init(viewModel: MonitorViewModel, device: OntDevice, isThisPhone: Bool) {
        self.viewModel = viewModel
        self.device = device
        self.isThisPhone = isThisPhone
        _discoveredNameStore = ObservedObject(wrappedValue: .shared)
    }

    private var currentDevice: OntDevice {
        viewModel.devices.first(where: { $0.mac == device.mac }) ?? device
    }

    private var canRenameOnRouter: Bool {
        currentDevice.domain.hasPrefix("InternetGatewayDevice.LANDevice.1.X_HW_UserDev.")
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    LabeledContent("Name", value: viewModel.name(for: currentDevice))
                    LabeledContent("Status", value: currentDevice.isOnline ? "Online (\(currentDevice.connectedText))" : "Offline")
                    LabeledContent("Connection", value: currentDevice.port.label)
                    if !currentDevice.ip.isEmpty {
                        LabeledContent("IP Address", value: currentDevice.ip)
                    }
                    LabeledContent("MAC Address", value: currentDevice.mac)
                    if DeviceNameResolver.isLocallyAdministeredMAC(currentDevice.mac) {
                        LabeledContent("MAC Type", value: "Randomized MAC")
                    }
                }

                if currentDevice.hasTrafficRates {
                    Section("Live Traffic") {
                        if let down = currentDevice.trafficRecvRate {
                            LabeledContent("Download Rate", value: TrafficRateFormatter.string(bytesPerSecond: down))
                        }
                        if let up = currentDevice.trafficSendRate {
                            LabeledContent("Upload Rate", value: TrafficRateFormatter.string(bytesPerSecond: up))
                        }
                    }
                }

                if currentDevice.port.isWifi && !isThisPhone {
                    Section {
                        Button(role: .destructive) {
                            Task { await blockCurrentDevice() }
                        } label: {
                            Label("Block Device", systemImage: "hand.raised.fill")
                        }
                    } header: {
                        Text("Wi-Fi Access")
                    } footer: {
                        Text("This device will be added to the router's Wi-Fi blacklist and disconnected.")
                    }
                }

                Section("Reported Details") {
                    if !currentDevice.routerAlias.isEmpty && currentDevice.routerAlias != "--" {
                        LabeledContent("Router Name", value: currentDevice.routerAlias)
                    }
                    if !currentDevice.hostName.isEmpty && currentDevice.hostName != "--" {
                        LabeledContent("Hostname", value: currentDevice.hostName)
                    }
                    if !currentDevice.dhcpVendor.isEmpty && currentDevice.dhcpVendor != "--" {
                        LabeledContent("DHCP Vendor", value: currentDevice.dhcpVendor)
                    }
                    if let lease = currentDevice.leaseSecondsRemaining, lease > 0 {
                        LabeledContent("Lease Remaining", value: InternetCard.uptime(lease))
                    }
                }

                Section {
                    Button {
                        showRouterRename = true
                    } label: {
                        Label("Rename on Router", systemImage: "pencil")
                    }
                    .disabled(!canRenameOnRouter || !viewModel.isConnected)

                    Button {
                        localAliasInput = viewModel.settings.alias(for: currentDevice.mac) ?? ""
                        showLocalRename = true
                    } label: {
                        Label("Rename on This iPhone Only", systemImage: "iphone")
                    }

                    if !currentDevice.isOnline {
                        Button(role: .destructive) {
                            confirmRemove = true
                        } label: {
                            Label("Remove from Router List", systemImage: "trash")
                        }
                    }
                } footer: {
                    if !canRenameOnRouter {
                        Text("This device record cannot be renamed on the router; use Rename on This iPhone Only.")
                    } else if !viewModel.isConnected {
                        Text("Reconnect to the router to save a name on the router.")
                    } else {
                        Text("Rename on Router updates the alias stored on the ONT; Rename on This iPhone Only keeps a private label on this device.")
                    }
                }
            }
            .linkWaveThemedListSurface()
            .navigationTitle(viewModel.name(for: currentDevice))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(.hidden, for: .tabBar)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .sheet(isPresented: $showRouterRename) {
            ClientRouterRenameSheet(viewModel: viewModel, device: currentDevice)
        }
        .alert("Rename on This iPhone Only", isPresented: $showLocalRename) {
            TextField("Device name", text: $localAliasInput)
            Button("Cancel", role: .cancel) {}
            Button("Save") {
                viewModel.settings.setAlias(localAliasInput, for: currentDevice.mac)
                Haptics.notify(.success)
            }
        } message: {
            Text("Saved locally on this iPhone only. Leave empty to use the router's name.")
        }
        .confirmationDialog(
            "Remove \(viewModel.name(for: currentDevice))?",
            isPresented: $confirmRemove,
            titleVisibility: .visible
        ) {
            Button("Remove from List", role: .destructive) {
                Task {
                    await viewModel.removeDevice(currentDevice)
                    dismiss()
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This only clears the offline device from the router's list. If it connects again it will reappear.")
        }
        .alert("Existing Access-Control Entries", isPresented: $showBlockConflictConfirmation) {
            Button("Clear & Block Device", role: .destructive) {
                Task {
                    await viewModel.blockWifiDevice(currentDevice, clearConflictingEntries: true)
                    if viewModel.actionMessage?.hasPrefix("Blocked ") == true { dismiss() }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This clears the router's existing WLAN and LAN MAC access-control entries, enables blacklist mode, and blocks the selected device.")
        }
    }

    private func blockCurrentDevice() async {
        let hasConflict = await viewModel.blockWifiDevice(currentDevice)
        if hasConflict {
            showBlockConflictConfirmation = true
        } else if viewModel.actionMessage?.hasPrefix("Blocked ") == true {
            dismiss()
        }
    }
}

private struct ClientRouterRenameSheet: View {
    @ObservedObject var viewModel: MonitorViewModel
    let device: OntDevice
    @Environment(\.dismiss) private var dismiss

    @State private var aliasInput = ""
    @State private var isSaving = false
    @State private var errorText: String?

    private var trimmedInput: String {
        aliasInput.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var validationError: String? {
        do {
            _ = try HuaweiOntClient.validateDeviceAlias(aliasInput)
            return nil
        } catch {
            return (error as? LocalizedError)?.errorDescription ?? "Invalid device name."
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Device name on router", text: $aliasInput)
                        .textInputAutocapitalization(.words)
                        .autocorrectionDisabled()
                } header: {
                    Text("Router Alias")
                } footer: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("\(trimmedInput.utf8.count)/64 UTF-8 bytes")
                            .foregroundColor(trimmedInput.utf8.count > 64 ? .red : .secondary)
                        if let validationError, !aliasInput.isEmpty {
                            Text(validationError)
                                .foregroundColor(.red)
                        } else {
                            Text("Updates UserDevAlias on the router and clears any iPhone-only nickname.")
                        }
                    }
                }

                if let errorText {
                    Section {
                        Label(errorText, systemImage: "exclamationmark.triangle.fill")
                            .foregroundColor(.red)
                            .font(.subheadline)
                    }
                }
            }
            .linkWaveThemedListSurface()
            .navigationTitle("Rename on Router")
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
                        Button("Save") {
                            Task { await submit() }
                        }
                        .disabled(validationError != nil)
                    }
                }
            }
        }
        .onAppear {
            if aliasInput.isEmpty {
                let seed = device.routerAlias.isEmpty ? device.displayName : device.routerAlias
                aliasInput = seed == "Unknown device" ? "" : seed
            }
        }
    }

    private func submit() async {
        isSaving = true
        errorText = nil
        do {
            try await viewModel.renameDeviceOnRouter(device, alias: aliasInput)
            dismiss()
        } catch {
            errorText = MonitorViewModel.describe(error, host: viewModel.settings.host)
        }
        isSaving = false
    }
}

private struct ClientsEmptyCard: View {
    let icon: String
    let title: String
    let message: String
    var isLoading: Bool = false
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: 10) {
            if isLoading {
                ProgressView()
            } else {
                Image(systemName: icon)
                    .font(.system(size: 32))
                    .linkWaveText(.secondary)
                    .accessibilityHidden(true)
            }
            Text(title)
                .font(.headline)
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

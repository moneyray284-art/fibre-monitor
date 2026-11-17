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
        if rssi >= -66 { return 3 }
        if rssi >= -74 { return 2 }
        return 1
    }

    static func color(for device: OntDevice) -> Color {
        guard device.isOnline else { return .secondary }
        guard device.port.isWifi, let rssi = device.rssiDbm else { return .green }
        if rssi >= -66 { return .green }
        if rssi >= -74 { return .orange }
        return .red
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

    private let heights: [CGFloat] = [4, 7, 10, 13]

    var body: some View {
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(0..<4, id: \.self) { index in
                Capsule()
                    .fill(index < level ? color : Color.secondary.opacity(0.22))
                    .frame(width: 3, height: heights[index])
            }
        }
        .frame(height: 13)
        .accessibilityLabel(level == 0 ? "No connection signal" : "Signal, \(level) of 4 bars")
    }
}

private enum ClientDeviceFilter: String, CaseIterable {
    case all
    case online
    case offline
    case blocked

    var menuTitle: String {
        switch self {
        case .all: "All"
        case .online: "Online"
        case .offline: "Offline"
        case .blocked: "Blocked"
        }
    }
}

public struct ClientsTabView: View {
    @ObservedObject var viewModel: MonitorViewModel
    @State private var searchText = ""
    @State private var selectedDevice: OntDevice?
    @State private var selectedFilter: ClientDeviceFilter = .online
    @State private var localWiFiIPv4: String?
    @State private var isOnlineExpanded = true
    @State private var isOfflineExpanded = false
    @State private var actionDevice: OntDevice?
    @State private var actionBlockedDevice: BlockedRouterDevice?
    @State private var showDeviceActions = false
    @State private var pendingBlockConflictDevice: OntDevice?
    @State private var showBlockConflictAlert = false

    public init(viewModel: MonitorViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        NavigationStack {
            List {
                if !viewModel.settings.isConfigured {
                    ClientsEmptyCard(
                        icon: "wifi.router",
                        title: "No Router Configured",
                        message: "Add a router in Settings to see connected clients."
                    )
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                } else if selectedFilter == .blocked && filteredBlockedDevices.isEmpty {
                    ClientsEmptyCard(
                        icon: "hand.raised",
                        title: "No blocked devices",
                        message: "Devices you block from Wi-Fi will appear here."
                    )
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                } else if selectedFilter != .blocked && visibleOnline.isEmpty && visibleOffline.isEmpty {
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
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                } else if selectedFilter == .blocked {
                    Section {
                        ForEach(filteredBlockedDevices) { device in
                            blockedButton(for: device)
                        }
                    } header: {
                        CardHeader(icon: "hand.raised.fill", title: "Blocked") {
                            Pill(text: "\(filteredBlockedDevices.count)", color: .red)
                        }
                        .textCase(nil)
                        .font(.subheadline)
                    }
                } else {
                    if !visibleOnline.isEmpty {
                        Section {
                            if isOnlineExpanded {
                                ForEach(visibleOnline) { device in
                                    clientButton(for: device)
                                }
                            }
                        } header: {
                            CollapsibleClientSectionHeader(
                                icon: "bolt.horizontal.circle.fill",
                                title: "Online",
                                count: visibleOnline.count,
                                tint: .green,
                                isExpanded: isOnlineExpanded
                            ) {
                                withAnimation(.spring(response: 0.34, dampingFraction: 0.82)) {
                                    isOnlineExpanded.toggle()
                                }
                            }
                            .textCase(nil)
                        }
                    }

                    if !visibleOffline.isEmpty {
                        Section {
                            if isOfflineExpanded {
                                ForEach(visibleOffline) { device in
                                    clientButton(for: device)
                                }
                            }
                        } header: {
                            CollapsibleClientSectionHeader(
                                icon: "moon.zzz",
                                title: "Offline",
                                count: visibleOffline.count,
                                tint: .secondary,
                                isExpanded: isOfflineExpanded
                            ) {
                                withAnimation(.spring(response: 0.34, dampingFraction: 0.82)) {
                                    isOfflineExpanded.toggle()
                                }
                            }
                            .textCase(nil)
                        }
                    }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background { LiquidGlassBackground() }
            .liquidGlassScrollEdges()
            .alwaysScrollBounce()
            .refreshable { await viewModel.refreshAll() }
            .searchable(text: $searchText, prompt: "Search name, IP, MAC, or vendor")
            .navigationTitle("Clients")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    filterMenu
                }
                ToolbarItem(placement: .topBarTrailing) {
                    RouterRefreshToolbarButton(viewModel: viewModel, isEnabled: viewModel.settings.isConfigured)
                }
            }
        }
        .onAppear(perform: refreshLocalWiFiAddress)
        .onChange(of: viewModel.isConnected) { _ in refreshLocalWiFiAddress() }
        .onChange(of: viewModel.selectedTab) { tab in
            if tab == .clients { refreshLocalWiFiAddress() }
        }
        .sheet(item: $selectedDevice) { device in
            ClientDetailSheet(viewModel: viewModel, device: currentSnapshot(of: device))
        }
        .confirmationDialog(
            deviceActionTitle,
            isPresented: $showDeviceActions,
            titleVisibility: .visible
        ) {
            if let device = actionDevice {
                Button("View Details") {
                    selectedDevice = device
                    clearActionTarget()
                }
                if device.port.isWifi && !isThisPhone(device) {
                    Button("Block Device", role: .destructive) {
                        requestBlock(device)
                        clearActionTarget()
                    }
                }
            }
            if let device = actionBlockedDevice {
                Button("Unblock Device") {
                    Task { await viewModel.unblockWifiDevice(device) }
                    clearActionTarget()
                }
            }
            Button("Cancel", role: .cancel) { clearActionTarget() }
        } message: {
            if let device = actionDevice {
                Text("Choose an action for \(viewModel.name(for: device)).")
            } else if let device = actionBlockedDevice {
                Text("Restore Wi-Fi access for \(device.name.isEmpty ? device.mac : device.name).")
            }
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
            actionDevice = device
            actionBlockedDevice = nil
            showDeviceActions = true
        } label: {
            ClientRow(
                device: device,
                displayName: viewModel.name(for: device),
                isThisPhone: thisPhone
            )
        }
        .buttonStyle(.plain)
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            if !thisPhone && device.port.isWifi {
                Button(role: .destructive) {
                    actionDevice = device
                    actionBlockedDevice = nil
                    showDeviceActions = true
                } label: {
                    Label("Block", systemImage: "hand.raised.fill")
                }
            }
        }
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
        .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
    }

    private func blockedButton(for device: BlockedRouterDevice) -> some View {
        BlockedClientRow(
            device: device,
            displayName: displayName(for: device),
            onSelect: {
                actionBlockedDevice = device
                actionDevice = nil
                showDeviceActions = true
            },
            onUnblock: { Task { await viewModel.unblockWifiDevice(device) } }
        )
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) {
                Task { await viewModel.unblockWifiDevice(device) }
            } label: {
                Label("Unblock", systemImage: "hand.raised.slash")
            }
        }
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
        .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
    }

    private var deviceActionTitle: String {
        if let device = actionDevice { return viewModel.name(for: device) }
        if let device = actionBlockedDevice { return device.name.isEmpty ? device.mac : device.name }
        return "Device Actions"
    }

    private func clearActionTarget() {
        actionDevice = nil
        actionBlockedDevice = nil
    }

    private func displayName(for blocked: BlockedRouterDevice) -> String {
        if let device = viewModel.devices.first(where: { $0.mac.caseInsensitiveCompare(blocked.mac) == .orderedSame }) {
            return viewModel.name(for: device)
        }
        return blocked.name.isEmpty ? blocked.mac : blocked.name
    }

    private var filteredOnline: [OntDevice] {
        let devices = filter(unblockedDeviceRecords.filter(\.isOnline))
        return devices.sorted { isThisPhone($0) && !isThisPhone($1) }
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
        selectedFilter == .offline || selectedFilter == .blocked ? [] : filteredOnline
    }

    private var visibleOffline: [OntDevice] {
        selectedFilter == .online || selectedFilter == .blocked ? [] : filteredOffline
    }

    private var allCount: Int { filteredOnline.count + filteredOffline.count }

    private var selectedCount: Int {
        switch selectedFilter {
        case .all: allCount
        case .online: filteredOnline.count
        case .offline: filteredOffline.count
        case .blocked: filteredBlockedDevices.count
        }
    }

    private func selectFilter(_ filter: ClientDeviceFilter) {
        withAnimation(.spring(response: 0.34, dampingFraction: 0.82)) {
            selectedFilter = filter
            switch filter {
            case .all:
                isOnlineExpanded = true
                isOfflineExpanded = false
            case .online:
                isOnlineExpanded = true
            case .offline:
                isOfflineExpanded = true
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
            .liquidGlassCapsule()
        }
        .accessibilityLabel("Filter devices")
        .accessibilityValue("\(selectedFilter.menuTitle), \(selectedCount) devices")
    }

    private var clientsEmptyTitle: String {
        if !searchText.isEmpty { return "No Matching Clients" }
        if selectedFilter == .blocked { return "No blocked devices" }
        if selectedFilter == .online { return "No online devices" }
        if selectedFilter == .offline { return "No offline devices" }
        if viewModel.isLoggedOut { return "Logged Out of Router" }
        if viewModel.isConnected { return "No Clients Reported" }
        return viewModel.isRefreshing ? "Loading Clients…" : "Waiting for Router…"
    }

    private var clientsEmptyMessage: String {
        if !searchText.isEmpty { return "Try searching by name, IP address, MAC, or vendor." }
        if selectedFilter == .blocked { return "Devices you block from Wi-Fi will appear here." }
        if selectedFilter == .online { return "The router currently reports no online devices." }
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
            let local = viewModel.name(for: d).lowercased()
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

private struct CollapsibleClientSectionHeader: View {
    let icon: String
    let title: String
    let count: Int
    let tint: Color
    let isExpanded: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .foregroundStyle(Color.accentColor)
                    .accessibilityHidden(true)
                Text(title)
                    .font(.subheadline.weight(.bold))
                Spacer()
                Pill(text: "\(count)", color: tint)
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 16)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.bar)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowInsets(EdgeInsets())
        .accessibilityLabel("\(title), \(count) devices")
        .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
        .accessibilityHint("Double-tap to \(isExpanded ? "collapse" : "expand") this section")
    }
}

private struct BlockedClientRow: View {
    let device: BlockedRouterDevice
    let displayName: String
    let onSelect: () -> Void
    let onUnblock: () -> Void

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
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 8)
                }
            }
            .buttonStyle(.plain)
            Button("Unblock", action: onUnblock)
                .font(.caption.weight(.semibold))
                .buttonStyle(.bordered)
                .tint(.accentColor)
        }
        .padding(10)
        .liquidGlassPill()
    }
}

private struct ClientRow: View {
    let device: OntDevice
    let displayName: String
    var isThisPhone = false

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: ClientDeviceIcon.symbol(for: device, isThisPhone: isThisPhone))
                .font(.subheadline.weight(.semibold))
                .foregroundColor(device.isOnline ? .accentColor : .secondary)
                .frame(width: 34, height: 34)
                .background((device.isOnline ? Color.accentColor : Color.secondary).opacity(device.isOnline ? 0.14 : 0.1), in: Circle())
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(isGenericHost ? "This Phone" : displayName)
                        .font(.subheadline.weight(.semibold))
                        .foregroundColor(.primary)
                        .lineLimit(1)
                    if isThisPhone && !isGenericHost {
                        Text("This Phone")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(Color.accentColor)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(Color.accentColor.opacity(0.12), in: Capsule())
                    }
                }
                if isThisPhone && isGenericHost {
                    Text("Reported as \(reportedName)")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
                Text(device.ip.isEmpty ? device.mac : device.ip)
                    .font(.caption.monospaced())
                    .foregroundColor(.secondary)
                if let rateSummary = rateText {
                    Text(rateSummary)
                        .font(.caption2.monospacedDigit())
                        .foregroundColor(.secondary)
                }
            }

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 4) {
                HStack(spacing: 6) {
                    ClientSignalBars(level: ClientSignal.bars(for: device), color: ClientSignal.color(for: device))
                    Text(device.isOnline ? device.connectedText : "Offline")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                if let signalDetail = ClientSignal.detail(for: device) {
                    Text(signalDetail)
                        .font(.caption2.monospacedDigit())
                        .foregroundColor(.secondary)
                }
                Pill(text: device.port.label, color: badgeColor)
            }

            Image(systemName: "chevron.right")
                .font(.caption2.weight(.semibold))
                .foregroundColor(.secondary.opacity(0.6))
                .accessibilityHidden(true)
        }
        .padding(10)
        .liquidGlassPill()
        .accessibilityElement(children: .combine)
        .accessibilityHint("Double-tap to inspect device details")
    }

    private var isGenericHost: Bool {
        guard isThisPhone else { return false }
        let normalized = displayName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return ["iphone", "unknown", "unknown device", "unknown_device", "--", ""].contains(normalized)
    }

    private var reportedName: String {
        let hostname = device.hostName.trimmingCharacters(in: .whitespacesAndNewlines)
        return hostname.isEmpty || hostname == "--" ? displayName : hostname
    }

    private var badgeColor: Color {
        switch device.port {
        case .wifi5: return .purple
        case .wifi24: return .blue
        case .lan: return .teal
        case .other: return .secondary
        }
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
    let device: OntDevice
    @Environment(\.dismiss) private var dismiss

    @State private var showRouterRename = false
    @State private var showLocalRename = false
    @State private var localAliasInput = ""
    @State private var confirmRemove = false

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
                    .foregroundColor(.secondary)
                    .accessibilityHidden(true)
            }
            Text(title)
                .font(.headline)
            Text(message)
                .font(.subheadline)
                .foregroundColor(.secondary)
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

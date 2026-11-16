import Foundation
import Network
import SwiftUI
import UIKit

public enum AppTab: Hashable, Sendable {
    case home, usage, clients, wifi
}

@MainActor
public final class MonitorViewModel: ObservableObject {
    @Published public var selectedTab: AppTab = .home
    @Published public private(set) var isLoggedOut = false
    @Published public private(set) var traffic = TrafficState()
    @Published public private(set) var wan = WanInfo()
    @Published public private(set) var optical = OpticalInfo()
    @Published public private(set) var devices: [OntDevice] = []
    @Published public private(set) var blockedDevices: [BlockedRouterDevice] = []
    @Published public private(set) var health = RouterHealth()
    @Published public private(set) var wifi = WifiState()
    @Published public private(set) var lan = LanInfo()
    @Published public private(set) var isWifiSaving = false

    public enum DiagnosticMode: String, CaseIterable { case ping = "Ping", traceroute = "Traceroute" }
    @Published public var diagnosticMode: DiagnosticMode = .ping
    @Published public var diagnosticHost = "8.8.8.8"
    @Published public var pingCount = 4
    @Published public private(set) var diagnosticOutput = DiagnosticOutput()
    @Published public private(set) var isDiagnosing = false
    private var diagnosticTask: Task<Void, Never>?
    @Published public private(set) var isConnected = false
    @Published public private(set) var isRefreshing = false
    @Published public private(set) var lastUpdate: Date?
    @Published public private(set) var routerResponseTimeMs: Int?
    @Published public var errorMessage: String?
    @Published public private(set) var isConnectionFailure = false
    @Published public var actionMessage: String?
    @Published public var awaitingRouterSelection: Bool
    @Published public private(set) var isPhoneOnWifi = true

    public let settings: SettingsStore
    private var client: any RouterProvider
    private let transport: OntTransport
    private let pathMonitor = NWPathMonitor()
    private var reachabilityFailureCount = 0
    private var reachabilityFailureStartedAt: Date?
    private var refreshRequestedAfterCurrent = false
    private let reachabilityFailureThreshold = 3
    private var lastCoreSync: Date = .distantPast
    private let coreSyncInterval: TimeInterval = 10
    // Health, Wi-Fi and LAN come from full web pages (50-130 KB), so sync them rarely.
    private var lastPageSync: Date = .distantPast
    private let pageSyncInterval: TimeInterval = 30
    private var lastLanSync: Date = .distantPast
    private let lanSyncInterval: TimeInterval = 300

    public init(settings: SettingsStore = .shared, transport: OntTransport = URLSessionOntTransport()) {
        self.settings = settings
        self.transport = transport
        self.client = RouterProviderFactory.make(profile: settings.activeProfile, credentials: settings.credentials, transport: transport)
        self.awaitingRouterSelection = settings.profiles.count >= 2
        pathMonitor.pathUpdateHandler = { [weak self] path in
            let onWifi = path.usesInterfaceType(.wifi)
            Task { @MainActor [weak self] in
                self?.isPhoneOnWifi = onWifi
            }
        }
        pathMonitor.start(queue: DispatchQueue(label: "dev.mattdev0.fibremonitor.netpath", qos: .utility))
    }

    deinit {
        pathMonitor.cancel()
    }

    public var onlineDevices: [OntDevice] { devices.filter(\.isOnline) }

    public var displayModelName: String {
        if settings.activeProfile?.resolvedRouterType == .generic { return "Generic router" }
        if !health.model.isEmpty { return health.model }
        if let detected = settings.activeProfile?.detectedModel, !detected.isEmpty { return detected }
        return "OptiXstar ONT"
    }

    public var shouldSuggestFallbackHost: Bool {
        isConnectionFailure && settings.activeProfile != nil && !settings.host.isEmpty && settings.host != "192.168.100.1"
    }

    public func name(for device: OntDevice) -> String {
        settings.alias(for: device.mac) ?? device.displayName
    }

    // MARK: Event-driven Sync & Router Switching

    public func refreshIfStale(maxAge: TimeInterval = 10, force: Bool = false) async {
        guard !awaitingRouterSelection, settings.isConfigured, !isLoggedOut else { return }
        if !force, let lastUpdate, Date().timeIntervalSince(lastUpdate) <= maxAge { return }
        await refreshAll()
    }

    /// Closes the router session when the app backgrounds so its web UI stays usable for others.
    public func endForegroundSession() {
        resetReachabilityFailures()
        Task { await client.logout() }
    }

    /// Explicit user-triggered logout from Settings. Pauses automatic sync until Reconnect is tapped.
    public func logoutSession() async {
        diagnosticTask?.cancel()
        diagnosticTask = nil
        isLoggedOut = true
        isConnected = false
        isRefreshing = false
        resetReachabilityFailures()
        await client.logout()
        Haptics.impact(.light)
        actionMessage = "Logged out of router."
    }

    public func reconnectSession() {
        isLoggedOut = false
        errorMessage = nil
        Task { await refreshAll() }
    }

    /// Switches to a different router profile: logs out of the old session, resets cookies & view state, and syncs the new one.
    public func switchRouter(to profile: RouterProfile) async {
        diagnosticTask?.cancel()
        diagnosticTask = nil
        clearViewState()
        isLoggedOut = false
        awaitingRouterSelection = false

        await client.logout()
        settings.selectProfile(profile.id)
        client = RouterProviderFactory.make(profile: settings.activeProfile, credentials: settings.credentials, transport: transport)
        await client.switchCredentials(settings.credentials)
        await syncRouter()
    }

    public func selectRouterAndStart(_ profile: RouterProfile) {
        Task {
            await switchRouter(to: profile)
        }
    }

    public func settingsChanged() {
        diagnosticTask?.cancel()
        diagnosticTask = nil
        clearViewState()
        isLoggedOut = false
        awaitingRouterSelection = false
        Task {
            await client.logout()
            client = RouterProviderFactory.make(profile: settings.activeProfile, credentials: settings.credentials, transport: transport)
            await client.switchCredentials(settings.credentials)
            if settings.isConfigured {
                await syncRouter()
            }
        }
    }

    public func useFallbackHost(_ fallbackHost: String = "192.168.100.1") async {
        guard var profile = settings.activeProfile else { return }
        profile.host = fallbackHost
        settings.updateProfile(profile)
        isLoggedOut = false
        errorMessage = nil
        isConnectionFailure = false
        client = RouterProviderFactory.make(profile: settings.activeProfile, credentials: settings.credentials, transport: transport)
        await client.switchCredentials(settings.credentials)
        await syncRouter()
    }

    public func refreshAll() async {
        guard !isRefreshing else { return }
        isLoggedOut = false
        lastCoreSync = .distantPast
        lastPageSync = .distantPast
        lastLanSync = .distantPast
        resetReachabilityFailures()
        await syncRouter()
    }

    private func refreshAfterMutation() async {
        lastCoreSync = .distantPast
        lastPageSync = .distantPast
        lastLanSync = .distantPast
        guard !isRefreshing else {
            refreshRequestedAfterCurrent = true
            return
        }
        await syncRouter()
    }

    private func clearViewState() {
        traffic = TrafficState()
        blockedDevices = []
        wan = WanInfo()
        optical = OpticalInfo()
        devices = []
        health = RouterHealth()
        wifi = WifiState()
        lan = LanInfo()
        diagnosticOutput = DiagnosticOutput()
        isDiagnosing = false
        isConnected = false
        isRefreshing = false
        lastUpdate = nil
        routerResponseTimeMs = nil
        errorMessage = nil
        isConnectionFailure = false
        actionMessage = nil
        lastCoreSync = .distantPast
        lastPageSync = .distantPast
        lastLanSync = .distantPast
        resetReachabilityFailures()
    }

    public func syncRouter() async {
        guard !isRefreshing else { return }
        guard settings.activeProfile != nil else {
            isConnected = false
            isConnectionFailure = false
            errorMessage = "Add a router in Settings to get started."
            return
        }
        guard settings.isConfigured else {
            isConnected = false
            isConnectionFailure = false
            errorMessage = OntError.notConfigured.errorDescription
            return
        }
        if await client.loginIsBlocked() {
            isConnected = false
            isConnectionFailure = false
            errorMessage = OntError.loginRejected.errorDescription
            return
        }
        isRefreshing = true
        defer {
            isRefreshing = false
            if refreshRequestedAfterCurrent {
                refreshRequestedAfterCurrent = false
                Task { await self.refreshAll() }
            }
        }
        do {
            let requestStartedAt = ProcessInfo.processInfo.systemUptime
            traffic = try await client.pollTraffic(now: Date())
            routerResponseTimeMs = max(0, Int((ProcessInfo.processInfo.systemUptime - requestStartedAt) * 1_000))
            if let profileId = settings.activeProfile?.id,
               let downloaded = traffic.cumulativeDownloadBytes,
               let uploaded = traffic.cumulativeUploadBytes {
                settings.recordTrafficCounters(download: downloaded, upload: uploaded, for: profileId)
            }
            if let activeId = settings.activeProfile?.id, let identity = await client.routerIdentity() {
                settings.recordDetection(for: activeId, model: identity.model, cfgMode: identity.cfgMode)
            }
            if Date().timeIntervalSince(lastCoreSync) >= coreSyncInterval {
                lastCoreSync = Date()
                if let w = try? await client.fetchWan() { wan = w }
                if let o = try? await client.fetchOptical() { optical = o }
                if Date().timeIntervalSince(lastPageSync) >= pageSyncInterval {
                    lastPageSync = Date()
                    // Wi-Fi first: it tells the device list which SSID is on which band.
                    if let w = try? await client.fetchWifi() { wifi = w }
                    if let h = try? await client.fetchHealth() { health = h }
                }
                if let d = try? await client.fetchDevices() { devices = d }
                if let blocked = try? await client.fetchWlanMacBlacklist() {
                    blockedDevices = blocked.activeBlockedDevices
                }
                if Date().timeIntervalSince(lastLanSync) >= lanSyncInterval {
                    lastLanSync = Date()
                    if let l = try? await client.fetchLan() { lan = l }
                }
            }
            isConnected = true
            isConnectionFailure = false
            errorMessage = nil
            let syncDate = Date()
            if let profileId = settings.activeProfile?.id {
                settings.recordSuccessfulSync(for: profileId, at: syncDate)
                settings.recordConnectionObservation(isReachable: true, for: profileId, at: syncDate)
            }
            resetReachabilityFailures()
            lastUpdate = syncDate
            WidgetSnapshotStore.save(
                rxPowerDbm: optical.rxPowerDbm,
                summary: settings.dataUsageSummary,
                onlineClientCount: onlineDevices.count,
                pppoeUptimeSeconds: wan.connectionType.lowercased().contains("pppoe") ? wan.uptimeSeconds : nil,
                at: syncDate
            )
        } catch {
            if error is CancellationError || Self.isCancellationError(error) { return }
            isConnected = false
            isConnectionFailure = Self.isReachabilityError(error)
            errorMessage = Self.describe(error, host: settings.host)
            if isConnectionFailure, isPhoneOnWifi, let profileId = settings.activeProfile?.id {
                let failureDate = Date()
                if reachabilityFailureCount == 0 {
                    reachabilityFailureStartedAt = failureDate
                }
                reachabilityFailureCount += 1
                if reachabilityFailureCount >= reachabilityFailureThreshold {
                    settings.recordConnectionObservation(
                        isReachable: false,
                        for: profileId,
                        at: failureDate,
                        interruptionStartedAt: reachabilityFailureStartedAt
                    )
                }
            } else {
                resetReachabilityFailures()
            }
        }
    }

    private func resetReachabilityFailures() {
        reachabilityFailureCount = 0
        reachabilityFailureStartedAt = nil
    }

    public func fetchWifiSsidConfig(for network: WifiNetwork) async throws -> WifiSsidConfig {
        let configs = try await client.fetchWlanBasic(bandHint: network.band, ssidIndex: network.ssidIndex)
        guard let match = configs.first(where: { $0.ssidIndex == network.ssidIndex }) else {
            throw OntError.badResponse("Wi-Fi network configuration")
        }
        return match
    }

    public func setRadio(_ radio: WifiRadio, enabled: Bool) async {
        guard !isWifiSaving else { return }
        isWifiSaving = true
        defer { isWifiSaving = false }
        do {
            wifi = try await client.setRadio(radio.index, enabled: enabled)
            Haptics.notify(.success)
            actionMessage = "\(Self.bandName(radio.band)) Wi-Fi turned \(enabled ? "on" : "off"), confirmed by the router."
            await refreshAfterMutation()
        } catch {
            Haptics.notify(.error)
            actionMessage = Self.describe(error, host: settings.host)
            if let w = try? await client.fetchWifi() { wifi = w }
        }
    }

    /// Saves a new SSID/passphrase for a WPA2-PSK SSID via `#704`.
    public func updateWifiCredentials(
        config: WifiSsidConfig,
        newSsid: String,
        newPassword: String
    ) async throws -> WifiUpdateResult {
        guard !isWifiSaving else { throw OntError.badResponse("Wi-Fi update already in progress") }
        isWifiSaving = true
        defer { isWifiSaving = false }
        do {
            let result = try await client.updateWifiCredentials(
                config: config,
                newSsid: newSsid,
                newPassword: newPassword
            )
            lastPageSync = Date()
            if result.connectionDropped {
                isConnected = false
                isConnectionFailure = true
                Haptics.notify(.warning)
                actionMessage = "Wi-Fi settings were sent. Rejoin \"\(newSsid)\" on this iPhone to reconnect."
                errorMessage = "Disconnected while saving Wi-Fi settings. Rejoin \"\(newSsid)\" on Wi-Fi to continue monitoring."
            } else {
                if let updatedWifi = result.wifi { wifi = updatedWifi }
                Haptics.notify(.success)
                actionMessage = "Wi-Fi updated to \"\(newSsid)\". Devices may take a few seconds to reconnect."
                await refreshAfterMutation()
            }
            return result
        } catch {
            Haptics.notify(.error)
            throw error
        }
    }

    // MARK: Diagnostics

    public func startDiagnostic() {
        guard !isDiagnosing else { return }
        let mode = diagnosticMode, host = diagnosticHost, count = pingCount
        isDiagnosing = true
        diagnosticOutput = DiagnosticOutput(text: "Starting \(mode.rawValue.lowercased()) to \(host)…\n")
        diagnosticTask = Task { [weak self] in
            guard let self else { return }
            defer { self.isDiagnosing = false }
            do {
                if mode == .ping {
                    try await self.client.startPing(host: host, count: count)
                } else {
                    try await self.client.startTrace(host: host)
                }
                // Ping takes about a second per reply; traceroute up to 30 hops can take a couple of minutes.
                let deadline = Date().addingTimeInterval(mode == .ping ? Double(count) * 11 + 10 : 180)
                while !Task.isCancelled && Date() < deadline {
                    try await Task.sleep(nanoseconds: 2_000_000_000)
                    let out = mode == .ping ? try await self.client.pingOutput() : try await self.client.traceOutput()
                    if !out.text.isEmpty || out.isFinished { self.diagnosticOutput = out }
                    if out.isFinished { return }
                }
                if !Task.isCancelled {
                    self.diagnosticOutput.status = "Stopped waiting for the router"
                }
            } catch is CancellationError {
            } catch {
                self.diagnosticOutput = DiagnosticOutput(text: Self.describe(error, host: self.settings.host), status: "Error")
            }
        }
    }

    /// Stops following the output; the router finishes the test on its own.
    public func stopDiagnostic() {
        diagnosticTask?.cancel()
        diagnosticTask = nil
        isDiagnosing = false
        if diagnosticOutput.status == nil { diagnosticOutput.status = "Stopped" }
    }

    // MARK: Devices

    public func renameDeviceOnRouter(_ device: OntDevice, alias: String) async throws {
        do {
            let trimmed = try HuaweiOntClient.validateDeviceAlias(alias)
            devices = try await client.renameDevice(device, alias: trimmed)
            // Clear any phone-only alias override so the new router name displays immediately.
            settings.setAlias("", for: device.mac)
            Haptics.notify(.success)
            actionMessage = "Renamed device on router to \(trimmed)."
            await refreshAfterMutation()
        } catch {
            Haptics.notify(.error)
            throw error
        }
    }

    public func removeDevice(_ device: OntDevice) async {
        do {
            devices = try await client.deleteDevice(device)
            Haptics.notify(.success)
            actionMessage = "Removed \(name(for: device)) from the device list."
            await refreshAfterMutation()
        } catch {
            Haptics.notify(.error)
            actionMessage = Self.describe(error, host: settings.host)
        }
    }

    public func blockWifiDevice(_ device: OntDevice) async {
        let ssidIndex: Int
        switch device.port {
        case .wifi24(let index), .wifi5(let index): ssidIndex = index
        case .lan, .other:
            actionMessage = "Only a Wi-Fi client can be blocked from the WLAN blacklist."
            return
        }
        guard ssidIndex > 0 else {
            actionMessage = "The router did not report this device's Wi-Fi network, so it cannot be blocked safely."
            return
        }
        do {
            let state = try await client.blockWifiDevice(
                device,
                name: name(for: device),
                ssidName: "SSID-\(ssidIndex)"
            )
            blockedDevices = state.activeBlockedDevices
            devices = (try? await client.fetchDevices()) ?? devices
            Haptics.notify(.success)
            actionMessage = "Blocked \(name(for: device)) from Wi-Fi."
            await refreshAfterMutation()
        } catch {
            Haptics.notify(.error)
            actionMessage = Self.describe(error, host: settings.host)
        }
    }

    public func unblockWifiDevice(_ device: BlockedRouterDevice) async {
        do {
            let state = try await client.unblockWifiDevice(device)
            blockedDevices = state.activeBlockedDevices
            Haptics.notify(.success)
            actionMessage = "Unblocked \(device.name.isEmpty ? device.mac : device.name)."
            await refreshAfterMutation()
        } catch {
            Haptics.notify(.error)
            actionMessage = Self.describe(error, host: settings.host)
        }
    }

    static func bandName(_ band: String) -> String {
        band.replacingOccurrences(of: "GHz", with: " GHz")
    }

    public func reboot() async {
        do {
            try await client.reboot()
            Haptics.notify(.warning)
            actionMessage = "Restart sent. The router will be back in about 2 minutes."
        } catch {
            Haptics.notify(.error)
            actionMessage = "Restart failed: \(Self.describe(error, host: settings.host))"
        }
    }

    static func isReachabilityError(_ error: Error) -> Bool {
        guard let url = error as? URLError else { return false }
        switch url.code {
        case .timedOut, .cannotConnectToHost, .cannotFindHost, .networkConnectionLost, .notConnectedToInternet:
            return true
        default:
            return false
        }
    }

    static func isCancellationError(_ error: Error) -> Bool {
        if let url = error as? URLError, url.code == .cancelled { return true }
        let nsError = error as NSError
        return nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled
    }

    static func describe(_ error: Error, host: String = "") -> String {
        if let ont = error as? OntError { return ont.errorDescription ?? "\(ont)" }
        if isReachabilityError(error) {
            if !host.isEmpty && host != "192.168.100.1" {
                return "Can't reach the router at \(host). Make sure this iPhone is on its Wi-Fi, or try 192.168.100.1."
            }
            return "Can't reach the router. Make sure this iPhone is on its Wi-Fi."
        }
        return error.localizedDescription
    }
}

@MainActor
public enum Haptics {
    public static func notify(_ type: UINotificationFeedbackGenerator.FeedbackType) {
        let generator = UINotificationFeedbackGenerator()
        generator.prepare()
        generator.notificationOccurred(type)
    }

    public static func impact(_ style: UIImpactFeedbackGenerator.FeedbackStyle = .light) {
        let generator = UIImpactFeedbackGenerator(style: style)
        generator.prepare()
        generator.impactOccurred()
    }
}

import Foundation
import Combine
import SwiftUI
import UIKit

public enum RouterConnectionState: Equatable, Sendable {
    case offline
    case connecting
    case connected
    case temporarilyLocked
    case invalidCredentials
}

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
    @Published public private(set) var cachedOnlineDeviceCount = 0
    @Published public private(set) var cachedOfflineDeviceCount = 0
    @Published public private(set) var hasLoadedDeviceList = false
    @Published public private(set) var blockedDevices: [BlockedRouterDevice] = []
    @Published public private(set) var health = RouterHealth()
    @Published public private(set) var wifi = WifiState()
    @Published public private(set) var lan = LanInfo()
    @Published public private(set) var isWifiSaving = false
    @Published public private(set) var wifiMutationStatus: String?

    public enum DiagnosticMode: String, CaseIterable { case ping = "Ping", traceroute = "Traceroute" }
    @Published public var diagnosticMode: DiagnosticMode = .ping
    @Published public var diagnosticHost = "8.8.8.8"
    @Published public var pingCount = 4
    @Published public private(set) var diagnosticOutput = DiagnosticOutput()
    @Published public private(set) var isDiagnosing = false
    private var diagnosticTask: Task<Void, Never>?
    @Published public private(set) var isConnected = false
    @Published public private(set) var isAuthenticated = false
    @Published public private(set) var connectionState: RouterConnectionState = .offline
    @Published public private(set) var isRefreshing = false
    @Published public private(set) var isSpeedTestRunning = false
    @Published public private(set) var isLiveTrafficActive = false
    @Published public private(set) var isForegroundSessionReady = false
    @Published public private(set) var isRouterLoginPaused = false
    @Published public private(set) var lastUpdate: Date?
    @Published public private(set) var routerResponseTimeMs: Int?
    @Published public var errorMessage: String?
    @Published public private(set) var isConnectionFailure = false
    @Published public var actionMessage: String?
    @Published public var awaitingRouterSelection: Bool
    @Published public private(set) var isConnectedToWiFi = false
    @Published public private(set) var hasInternetPath = false

    public var isPhoneOnWifi: Bool { isConnectedToWiFi }
    public var canRunSpeedTest: Bool { isConnectedToWiFi && hasInternetPath }

    public let settings: SettingsStore
    private var client: any RouterProvider
    private let transport: OntTransport
    private let networkMonitor: NetworkMonitor
    private let requiresWiFiPath: Bool
    private var reachabilityFailureCount = 0
    private var reachabilityFailureStartedAt: Date?
    private var refreshRequestedAfterCurrent = false
    private var routerRecoveryTask: Task<Void, Never>?
    private var settingsChangeTask: Task<Void, Never>?
    private var settingsReconnectTask: Task<Void, Never>?
    private var networkReconnectTask: Task<Void, Never>?
    private var fullRefreshTask: Task<Void, Never>?
    private var fullRefreshID: UUID?
    private var routerConfigurationReadyForSync = true
    private var didAttemptInitialRouterSync = false
    private var isLiveTrafficPollInProgress = false
    private var isLiveTrafficPausedForRefresh = false
    private var isRetryingTransientRouterError = false
    private var lastRouterSyncError: Error?
    private var settingsCancellables = Set<AnyCancellable>()
    private var wifiMutationStatusTask: Task<Void, Never>?
    private var wifiMutationRefreshTask: Task<Void, Never>?
    private var lastObservedRouterConfiguration: RouterConfigurationFingerprint
    private var routerConfigurationGeneration = 0
    private var didAttemptAutomaticRouterRecovery = false
    private var isWiFiRecoveryPending = false
    private let reachabilityFailureThreshold = 3
    private var lastCoreSync: Date = .distantPast
    private var lastTrafficSampleAt: Date = .distantPast
    private let coreSyncInterval: TimeInterval = 10
    // Health, Wi-Fi and LAN come from full web pages (50-130 KB), so sync them rarely.
    private var lastPageSync: Date = .distantPast
    private let pageSyncInterval: TimeInterval = 30
    private var lastLanSync: Date = .distantPast
    private let lanSyncInterval: TimeInterval = 300

    private var routerRequestsAllowed: Bool {
        !requiresWiFiPath || networkMonitor.routerRequestsAllowed
    }

    private struct RouterConfigurationFingerprint: Equatable {
        let profileID: UUID?
        let credentials: HuaweiOntClient.Credentials
        let credentialsRevision: UInt64
    }

    private enum TransientRouterRetryPolicy: Equatable {
        case none
        case coldLaunch
        case wifiReconnect

        var delays: [UInt64] {
            switch self {
            case .none: []
            case .coldLaunch: [600_000_000, 1_500_000_000]
            case .wifiReconnect: [1_200_000_000]
            }
        }
    }

    public init(settings: SettingsStore = .shared, transport: OntTransport = URLSessionOntTransport()) {
        let networkMonitor = NetworkMonitor.shared
        self.networkMonitor = networkMonitor
        self.settings = settings
        self.transport = transport
        self.requiresWiFiPath = transport.requiresWiFiForRouterRequests
        self.client = RouterProviderFactory.make(profile: settings.activeProfile, credentials: settings.credentials, transport: transport)
        self.isConnectedToWiFi = !transport.requiresWiFiForRouterRequests || networkMonitor.isConnectedToWiFi
        self.hasInternetPath = !transport.requiresWiFiForRouterRequests || networkMonitor.hasInternetPath
        self.awaitingRouterSelection = settings.profiles.count >= 2
        self.lastObservedRouterConfiguration = RouterConfigurationFingerprint(
            profileID: settings.activeProfile?.id,
            credentials: settings.credentials,
            credentialsRevision: settings.routerCredentialsRevision
        )
        self.connectionState = settings.isConfigured ? .connecting : .offline
        hydrateCachedRouterData()
        settings.refreshUsageSummaryForCurrentLocalDay()
        settings.$activeProfileId
            .dropFirst()
            .sink { [weak self] _ in self?.scheduleSettingsConfigurationCheck() }
            .store(in: &settingsCancellables)
        settings.$profiles
            .dropFirst()
            .sink { [weak self] _ in self?.scheduleSettingsConfigurationCheck() }
            .store(in: &settingsCancellables)
        settings.$routerCredentialsRevision
            .dropFirst()
            .sink { [weak self] _ in self?.scheduleSettingsConfigurationCheck() }
            .store(in: &settingsCancellables)
        if transport.requiresWiFiForRouterRequests {
            networkMonitor.$pathState
                .removeDuplicates()
                .sink { [weak self] state in
                    Task { @MainActor [weak self] in self?.handleNetworkPathChange(state) }
                }
                .store(in: &settingsCancellables)
        }
    }

    private func handleNetworkPathChange(_ state: NetworkPathState) {
        let wasConnectedToWiFi = isConnectedToWiFi
        let internetPathChanged = hasInternetPath != state.hasInternetPath
        guard wasConnectedToWiFi != state.isConnectedToWiFi || internetPathChanged else { return }

        isConnectedToWiFi = state.isConnectedToWiFi
        hasInternetPath = state.hasInternetPath

        guard wasConnectedToWiFi != state.isConnectedToWiFi else { return }
        if !state.isConnectedToWiFi {
            networkReconnectTask?.cancel()
            networkReconnectTask = nil
            isWiFiRecoveryPending = false
            isForegroundSessionReady = false
            isConnected = false
            isAuthenticated = false
            connectionState = .offline
            isConnectionFailure = false
            traffic.downloadMbps = 0
            traffic.uploadMbps = 0
            lastTrafficSampleAt = .distantPast
            resetReachabilityFailures()
            cancelRouterRecovery()
            fullRefreshTask?.cancel()
            let provider = client
            Task { await provider.suspendForNetworkLoss() }
            return
        }

        guard settings.isConfigured, !isLoggedOut else { return }
        isWiFiRecoveryPending = true
        isConnected = false
        isAuthenticated = false
        isConnectionFailure = false
        connectionState = .connecting
        errorMessage = nil
        if fullRefreshTask != nil { refreshRequestedAfterCurrent = true }
        if UIApplication.shared.applicationState == .active {
            scheduleNetworkReconnect()
        }
    }

    private func scheduleNetworkReconnect() {
        networkReconnectTask?.cancel()
        networkReconnectTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: 600_000_000)
            } catch {
                return
            }
            guard let self,
                  !Task.isCancelled else { return }
            self.networkReconnectTask = nil
            guard
                  self.routerRequestsAllowed,
                  self.settings.isConfigured,
                  !self.isLoggedOut,
                  UIApplication.shared.applicationState == .active else { return }
            await self.refreshAll(forceReauthIfNeeded: true)
        }
    }

    public var onlineDevices: [OntDevice] { devices.filter(\.isOnline) }

    public var homeOnlineDeviceCount: Int {
        hasLoadedDeviceList ? onlineDevices.count : cachedOnlineDeviceCount
    }

    public var homeOfflineDeviceCount: Int {
        hasLoadedDeviceList ? max(0, devices.count - onlineDevices.count) : cachedOfflineDeviceCount
    }

    public var displayModelName: String {
        if settings.activeProfile?.resolvedRouterType == .generic { return "Generic router" }
        if !health.model.isEmpty { return health.model }
        if let detected = settings.activeProfile?.detectedModel, !detected.isEmpty { return detected }
        return "OptiXstar ONT"
    }

    private func hydrateCachedRouterData() {
        var cachedHealth = RouterHealth()
        cachedHealth.model = settings.activeProfile?.detectedModel ?? ""
        health = cachedHealth
        optical = OpticalInfo()
        cachedOnlineDeviceCount = 0
        cachedOfflineDeviceCount = 0
        hasLoadedDeviceList = false

        guard let snapshot = WidgetSnapshotStore.load(), Self.snapshot(snapshot, matches: settings) else { return }
        optical.rxPowerDbm = snapshot.rxPowerDbm
        health.model = snapshot.routerModel ?? cachedHealth.model
        cachedOnlineDeviceCount = snapshot.onlineClientCount
        cachedOfflineDeviceCount = snapshot.offlineClientCount ?? 0
        if Calendar.current.isDate(snapshot.updatedAt, inSameDayAs: Date()),
           let profileID = settings.activeProfile?.id {
            settings.restoreTodayUsageFromSharedSnapshot(
                downloadBytes: snapshot.todayDownloadBytes,
                uploadBytes: snapshot.todayUploadBytes,
                for: profileID
            )
        }
    }

    private static func snapshot(_ snapshot: LinkWaveWidgetSnapshot, matches settings: SettingsStore) -> Bool {
        guard let profile = settings.activeProfile else { return false }
        if let cachedProfileID = snapshot.routerProfileID {
            return cachedProfileID == profile.id.uuidString
        }
        return snapshot.routerHost?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            == profile.host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    public var shouldSuggestFallbackHost: Bool {
        isConnectionFailure && settings.activeProfile != nil && !settings.host.isEmpty && settings.host != "192.168.100.1"
    }

    public func name(for device: OntDevice) -> String {
        settings.alias(for: device.mac) ?? device.displayName
    }

    private var currentRouterConfiguration: RouterConfigurationFingerprint {
        RouterConfigurationFingerprint(
            profileID: settings.activeProfile?.id,
            credentials: settings.credentials,
            credentialsRevision: settings.routerCredentialsRevision
        )
    }

    private func scheduleSettingsConfigurationCheck() {
        settingsChangeTask?.cancel()
        settingsChangeTask = Task { @MainActor [weak self] in
            await Task.yield()
            guard let self, !Task.isCancelled else { return }
            self.settingsChangeTask = nil
            self.reconnectIfSettingsChanged()
        }
    }

    /// Reconnects automatically when the active profile or its Keychain credentials change.
    public func reconnectIfSettingsChanged() {
        reconnectToSavedConfiguration(force: false)
    }

    // MARK: Event-driven Sync & Router Switching

    public func refreshIfStale(maxAge: TimeInterval = 10, force: Bool = false) async {
        guard settings.isConfigured, !isLoggedOut else { return }
        let mustReconnect = !isAuthenticated || !isConnected || connectionState == .offline
        if !force, !mustReconnect, isForegroundSessionReady,
           let lastUpdate, Date().timeIntervalSince(lastUpdate) <= maxAge { return }
        await refreshAll(forceReauthIfNeeded: true)
    }

    /// Lets iOS Wi-Fi reconnect before the single foreground session check.
    public func prepareForegroundSession() async {
        isForegroundSessionReady = false
        guard settings.isConfigured, !isLoggedOut else { return }
        guard routerRequestsAllowed else { return }
        let settleDelay: UInt64 = isWiFiRecoveryPending ? 600_000_000 : 350_000_000
        do {
            try await Task.sleep(nanoseconds: settleDelay)
        } catch {
            return
        }
        guard !Task.isCancelled else { return }
        while isRefreshing && !Task.isCancelled {
            do {
                try await Task.sleep(nanoseconds: 50_000_000)
            } catch {
                return
            }
        }
        guard !Task.isCancelled else { return }
        if !isForegroundSessionReady { await refreshAll(forceReauthIfNeeded: true) }
    }

    /// Pauses foreground polling and its lockout timer as soon as the app backgrounds.
    public func pauseForegroundSession() {
        isForegroundSessionReady = false
        cancelRouterRecovery()
    }

    /// Closes the router session when the app backgrounds so its web UI stays usable for others.
    public func endForegroundSession() async {
        isForegroundSessionReady = false
        cancelRouterRecovery()
        WidgetSnapshotStore.updateUsage(summary: settings.dataUsageSummary, at: Date())
        resetReachabilityFailures()
        await client.logout()
    }

    /// Samples only the WAN counters while the app is active. This deliberately does
    /// not touch `isRefreshing`, so the manual refresh control stays idle during live ticks.
    public func runLiveTrafficFeed() async {
        guard !isLiveTrafficActive,
              isForegroundSessionReady,
              !isRouterLoginPaused,
              routerRequestsAllowed else { return }
        isLiveTrafficActive = true
        defer { isLiveTrafficActive = false }

        var nextTick = ProcessInfo.processInfo.systemUptime
        while !Task.isCancelled, isForegroundSessionReady, !isRouterLoginPaused {
            nextTick += 1
            if !isSpeedTestRunning && !isLiveTrafficPausedForRefresh {
                await pollLiveTraffic()
            }
            if Task.isCancelled { break }
            let remaining = max(0, nextTick - ProcessInfo.processInfo.systemUptime)
            if remaining > 0 {
                try? await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000))
            }
        }
    }

    public func setSpeedTestRunning(_ running: Bool) {
        isSpeedTestRunning = running
    }

    private func pollLiveTraffic() async {
        guard !awaitingRouterSelection,
              settings.isConfigured,
              !isLoggedOut,
              routerRequestsAllowed,
              isForegroundSessionReady,
              !isRouterLoginPaused,
              !isRefreshing,
              !isLiveTrafficPausedForRefresh,
              !isLiveTrafficPollInProgress,
              !isSpeedTestRunning,
              let profileId = settings.activeProfile?.id else { return }

        isLiveTrafficPollInProgress = true
        defer { isLiveTrafficPollInProgress = false }
        let generation = routerConfigurationGeneration
        let provider = client
        let sampledAt = Date()
        do {
            let sample = try await provider.pollTraffic(now: sampledAt)
            guard routerRequestsAllowed,
                  settings.activeProfile?.id == profileId,
                  routerConfigurationGeneration == generation else { return }
            acceptTraffic(sample, sampledAt: sampledAt, profileId: profileId)
            isConnected = true
            isAuthenticated = true
            connectionState = .connected
        } catch {
            guard !Self.isCancellationError(error),
                  settings.activeProfile?.id == profileId,
                  routerConfigurationGeneration == generation else { return }
            guard routerRequestsAllowed else { return }
            if let failure = await provider.routerAuthFailure() {
                handleRouterAuthFailure(failure)
            }
            // Other transient polling errors stay quiet; an explicit sync owns those banners.
        }
    }

    private func acceptTraffic(_ sample: TrafficState, sampledAt: Date, profileId: UUID?) {
        guard sampledAt >= lastTrafficSampleAt else { return }
        lastTrafficSampleAt = sampledAt
        traffic = sample
        if let profileId,
           let downloaded = sample.cumulativeDownloadBytes,
           let uploaded = sample.cumulativeUploadBytes {
            settings.recordTrafficCounters(download: downloaded, upload: uploaded, for: profileId)
        }
    }

    /// Explicit user-triggered logout from Settings. Pauses automatic sync until Reconnect is tapped.
    public func logoutSession() async {
        diagnosticTask?.cancel()
        diagnosticTask = nil
        isForegroundSessionReady = false
        cancelRouterRecovery()
        isLoggedOut = true
        isConnected = false
        isAuthenticated = false
        connectionState = .offline
        isRefreshing = false
        resetReachabilityFailures()
        await client.logout()
        Haptics.impact(.light)
        actionMessage = "Logged out of router."
    }

    public func reconnectSession() {
        isLoggedOut = false
        connectionState = .connecting
        errorMessage = nil
        Task { await refreshAll(forceReauthIfNeeded: true) }
    }

    /// Switches to a different router profile: logs out of the old session, resets cookies & view state, and syncs the new one.
    public func switchRouter(to profile: RouterProfile) async {
        diagnosticTask?.cancel()
        diagnosticTask = nil
        routerConfigurationReadyForSync = false
        routerConfigurationGeneration &+= 1
        cancelRouterRecovery()
        isRouterLoginPaused = false
        didAttemptAutomaticRouterRecovery = false
        clearViewState()
        connectionState = .connecting
        isLoggedOut = false
        awaitingRouterSelection = false

        await client.logout()
        settings.selectProfile(profile.id)
        lastObservedRouterConfiguration = currentRouterConfiguration
        hydrateCachedRouterData()
        client = RouterProviderFactory.make(profile: settings.activeProfile, credentials: settings.credentials, transport: transport)
        await client.switchCredentials(settings.credentials)
        routerConfigurationReadyForSync = true
        await syncRouter()
    }

    public func selectRouterAndStart(_ profile: RouterProfile) {
        if settings.activeProfile?.id == profile.id {
            lastObservedRouterConfiguration = currentRouterConfiguration
        }
        Task {
            await switchRouter(to: profile)
        }
    }

    public func settingsChanged() {
        reconnectToSavedConfiguration(force: true)
    }

    /// Revalidates the router session whenever the Settings destination closes, even if the
    /// user did not change a profile during that visit. This also clears any cached lockout.
    public func settingsDidDismiss() {
        if settingsReconnectTask != nil { return }
        if connectionState == .connected,
           let lastUpdate,
           Date().timeIntervalSince(lastUpdate) < 3 {
            return
        }
        reconnectToSavedConfiguration(force: true)
    }

    private func reconnectToSavedConfiguration(force: Bool) {
        let configuration = currentRouterConfiguration
        guard force || configuration != lastObservedRouterConfiguration else { return }
        let profileChanged = configuration.profileID != lastObservedRouterConfiguration.profileID
        lastObservedRouterConfiguration = configuration

        diagnosticTask?.cancel()
        diagnosticTask = nil
        routerConfigurationGeneration &+= 1
        cancelRouterRecovery()
        isRouterLoginPaused = false
        didAttemptAutomaticRouterRecovery = false
        if profileChanged {
            clearViewState()
            hydrateCachedRouterData()
        }
        routerConfigurationReadyForSync = false
        isLoggedOut = false
        awaitingRouterSelection = false

        isConnected = false
        isAuthenticated = false
        isConnectionFailure = false
        isForegroundSessionReady = false
        isRefreshing = false
        connectionState = settings.isConfigured ? .connecting : .offline
        errorMessage = settings.isConfigured ? nil : OntError.notConfigured.errorDescription
        lastCoreSync = .distantPast
        lastTrafficSampleAt = .distantPast
        lastPageSync = .distantPast
        lastLanSync = .distantPast
        resetReachabilityFailures()

        guard settingsReconnectTask == nil else { return }
        settingsReconnectTask = Task { @MainActor [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                let generation = self.routerConfigurationGeneration
                let oldClient = self.client
                await oldClient.logout()
                guard !Task.isCancelled else { break }
                guard generation == self.routerConfigurationGeneration else { continue }

                guard self.settings.isConfigured, self.settings.activeProfile != nil else {
                    self.routerConfigurationReadyForSync = true
                    self.connectionState = .offline
                    self.isConnected = false
                    self.isAuthenticated = false
                    self.errorMessage = OntError.notConfigured.errorDescription
                    break
                }

                self.client = RouterProviderFactory.make(
                    profile: self.settings.activeProfile,
                    credentials: self.settings.credentials,
                    transport: self.transport
                )
                self.lastObservedRouterConfiguration = self.currentRouterConfiguration
                self.routerConfigurationReadyForSync = true
                await self.awaitFullRefreshCompletion()
                guard generation == self.routerConfigurationGeneration else { continue }
                if !self.isAuthenticated || !self.isConnected {
                    await self.refreshAll(forceReauthIfNeeded: true)
                }
                break
            }
            self.settingsReconnectTask = nil
        }
    }

    public func useFallbackHost(_ fallbackHost: String = "192.168.100.1") async {
        guard var profile = settings.activeProfile else { return }
        routerConfigurationGeneration &+= 1
        cancelRouterRecovery()
        isRouterLoginPaused = false
        didAttemptAutomaticRouterRecovery = false
        profile.host = fallbackHost
        settings.updateProfile(profile)
        lastObservedRouterConfiguration = currentRouterConfiguration
        isLoggedOut = false
        isConnected = false
        isAuthenticated = false
        connectionState = .connecting
        isForegroundSessionReady = false
        isRefreshing = false
        errorMessage = nil
        isConnectionFailure = false
        routerConfigurationReadyForSync = false
        client = RouterProviderFactory.make(profile: settings.activeProfile, credentials: settings.credentials, transport: transport)
        await client.switchCredentials(settings.credentials)
        routerConfigurationReadyForSync = true
        await syncRouter()
    }

    public func refreshAll(forceReauthIfNeeded: Bool = true) async {
        guard routerRequestsAllowed else {
            isConnected = false
            isAuthenticated = false
            isForegroundSessionReady = false
            connectionState = .offline
            isConnectionFailure = false
            traffic.downloadMbps = 0
            traffic.uploadMbps = 0
            lastTrafficSampleAt = .distantPast
            return
        }

        if let fullRefreshTask {
            await fullRefreshTask.value
            if refreshRequestedAfterCurrent {
                refreshRequestedAfterCurrent = false
                await refreshAll(forceReauthIfNeeded: true)
            }
            return
        }

        let runID = UUID()
        fullRefreshID = runID
        let shouldRetryColdLaunch = forceReauthIfNeeded && settings.isConfigured && !didAttemptInitialRouterSync
        let retryPolicy: TransientRouterRetryPolicy = forceReauthIfNeeded && isWiFiRecoveryPending
            ? .wifiReconnect
            : (shouldRetryColdLaunch ? .coldLaunch : .none)
        if retryPolicy == .wifiReconnect { isWiFiRecoveryPending = false }
        if settings.isConfigured { didAttemptInitialRouterSync = true }
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.performFullRefresh(
                forceReauthIfNeeded: forceReauthIfNeeded,
                retryPolicy: retryPolicy,
                runID: runID
            )
        }
        fullRefreshTask = task
        await task.value
        guard fullRefreshID == runID else { return }
        fullRefreshTask = nil
        fullRefreshID = nil
        if refreshRequestedAfterCurrent {
            refreshRequestedAfterCurrent = false
            await refreshAll(forceReauthIfNeeded: true)
        }
    }

    private func performFullRefresh(
        forceReauthIfNeeded: Bool,
        retryPolicy: TransientRouterRetryPolicy,
        runID: UUID
    ) async {
        guard fullRefreshID == runID else { return }
        guard routerRequestsAllowed else { return }
        isLoggedOut = false
        lastCoreSync = .distantPast
        lastTrafficSampleAt = .distantPast
        lastPageSync = .distantPast
        lastLanSync = .distantPast
        resetReachabilityFailures()

        if forceReauthIfNeeded,
           (!isAuthenticated || !isConnected || connectionState == .offline),
           !isRouterLoginPaused {
            errorMessage = nil
            isConnectionFailure = false
            connectionState = settings.isConfigured ? .connecting : .offline
        }

        isLiveTrafficPausedForRefresh = true
        isRefreshing = true
        isRetryingTransientRouterError = retryPolicy != .none
        defer {
            isRetryingTransientRouterError = false
            if fullRefreshID == runID {
                isRefreshing = false
                isLiveTrafficPausedForRefresh = false
            }
        }

        while isLiveTrafficPollInProgress, !Task.isCancelled {
            do {
                try await Task.sleep(nanoseconds: 20_000_000)
            } catch {
                return
            }
        }
        guard !Task.isCancelled, fullRefreshID == runID else { return }

        while !routerConfigurationReadyForSync, !Task.isCancelled {
            do {
                try await Task.sleep(nanoseconds: 20_000_000)
            } catch {
                return
            }
        }
        guard !Task.isCancelled, fullRefreshID == runID else { return }

        let retryDelays = retryPolicy.delays
        var retryIndex = 0
        while true {
            lastRouterSyncError = nil
            await syncRouterCore(allowDuringSettingsReconnect: settingsReconnectTask != nil)
            guard fullRefreshID == runID else { return }
            guard let syncError = lastRouterSyncError else { break }
            guard routerRequestsAllowed else { return }
            let isRetryable: Bool
            switch retryPolicy {
            case .none:
                isRetryable = false
            case .coldLaunch:
                isRetryable = Self.isColdLaunchRetryableSocketError(syncError)
            case .wifiReconnect:
                isRetryable = Self.isWiFiRecoveryRetryableSocketError(syncError)
            }
            guard isRetryable, retryIndex < retryDelays.count else {
                if Self.isColdLaunchRetryableSocketError(syncError) {
                    isConnected = false
                    isAuthenticated = false
                    connectionState = .offline
                    isConnectionFailure = true
                    errorMessage = Self.describe(syncError, host: settings.host)
                    recordReachabilityFailureIfNeeded()
                }
                break
            }

            connectionState = .connecting
            isConnected = false
            isAuthenticated = false
            isConnectionFailure = false
            errorMessage = nil
            do {
                try await Task.sleep(nanoseconds: retryDelays[retryIndex])
            } catch {
                return
            }
            retryIndex += 1
        }
    }

    private func awaitFullRefreshCompletion() async {
        while let activeRefresh = fullRefreshTask {
            await activeRefresh.value
            await Task.yield()
        }
    }

    private func refreshAfterMutation() async {
        lastCoreSync = .distantPast
        lastTrafficSampleAt = .distantPast
        lastPageSync = .distantPast
        lastLanSync = .distantPast
        guard !isRefreshing else {
            refreshRequestedAfterCurrent = true
            return
        }
        await refreshAll(forceReauthIfNeeded: true)
    }

    private func clearViewState() {
        traffic = TrafficState()
        lastTrafficSampleAt = .distantPast
        blockedDevices = []
        wan = WanInfo()
        optical = OpticalInfo()
        devices = []
        cachedOnlineDeviceCount = 0
        cachedOfflineDeviceCount = 0
        hasLoadedDeviceList = false
        health = RouterHealth()
        wifi = WifiState()
        lan = LanInfo()
        diagnosticOutput = DiagnosticOutput()
        isDiagnosing = false
        isConnected = false
        isAuthenticated = false
        connectionState = .offline
        isForegroundSessionReady = false
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
        await refreshAll(forceReauthIfNeeded: true)
    }

    private func syncRouterCore(allowDuringSettingsReconnect: Bool) async {
        guard routerRequestsAllowed else { return }
        guard allowDuringSettingsReconnect || settingsReconnectTask == nil else { return }
        let syncGeneration = routerConfigurationGeneration
        let provider = client
        let profileID = settings.activeProfile?.id
        guard settings.activeProfile != nil else {
            isConnected = false
            isAuthenticated = false
            connectionState = .offline
            isConnectionFailure = false
            errorMessage = "Add a router in Settings to get started."
            return
        }
        guard settings.isConfigured else {
            isConnected = false
            isAuthenticated = false
            connectionState = .offline
            isConnectionFailure = false
            errorMessage = OntError.notConfigured.errorDescription
            return
        }
        if let authFailure = await provider.routerAuthFailure() {
            guard syncGeneration == routerConfigurationGeneration else { return }
            handleRouterAuthFailure(authFailure)
            return
        }
        guard syncGeneration == routerConfigurationGeneration else { return }
        if !isConnected { connectionState = .connecting }
        do {
            let requestStartedAt = ProcessInfo.processInfo.systemUptime
            let sampledAt = Date()
            let trafficSample = try await provider.pollTraffic(now: sampledAt)
            guard routerRequestsAllowed,
                  syncGeneration == routerConfigurationGeneration else { return }
            acceptTraffic(trafficSample, sampledAt: sampledAt, profileId: profileID)
            routerResponseTimeMs = max(0, Int((ProcessInfo.processInfo.systemUptime - requestStartedAt) * 1_000))
            // A valid WAN response proves the serialized coordinator established a session.
            // Publish this now so every tab updates and the foreground feed starts while
            // the less-frequent detail requests continue below.
            isConnected = true
            isAuthenticated = true
            connectionState = .connected
            isConnectionFailure = false
            isRouterLoginPaused = false
            isForegroundSessionReady = true
            if let activeId = profileID, let identity = await provider.routerIdentity() {
                guard syncGeneration == routerConfigurationGeneration else { return }
                settings.recordDetection(for: activeId, model: identity.model, cfgMode: identity.cfgMode)
            }
            if Date().timeIntervalSince(lastCoreSync) >= coreSyncInterval {
                lastCoreSync = Date()
                let shouldSyncPages = Date().timeIntervalSince(lastPageSync) >= pageSyncInterval
                if shouldSyncPages { lastPageSync = Date() }
                let shouldSyncLan = Date().timeIntervalSince(lastLanSync) >= lanSyncInterval
                if shouldSyncLan { lastLanSync = Date() }

                // These router reads do not depend on each other. Run them together so
                // one slow diagnostics or device page does not hold up every tab.
                async let wanRead: WanInfo? = try? await provider.fetchWan()
                async let opticalRead: OpticalInfo? = try? await provider.fetchOptical()
                async let wifiRead: WifiState? = shouldSyncPages ? try? await provider.fetchWifi() : nil
                async let healthRead: RouterHealth? = shouldSyncPages ? try? await provider.fetchHealth() : nil
                let (freshWifi, freshHealth) = await (wifiRead, healthRead)
                guard syncGeneration == routerConfigurationGeneration else { return }
                if let freshWifi { wifi = freshWifi }
                if let freshHealth { health = freshHealth }

                // Fetch Wi-Fi before clients so the router client can map each device
                // to its correct SSID band. The remaining reads are independent.
                async let devicesRead: [OntDevice]? = try? await provider.fetchDevices()
                async let blockedRead: WlanMacBlacklistState? = try? await provider.fetchWlanMacBlacklist()
                async let lanRead: LanInfo? = shouldSyncLan ? try? await provider.fetchLan() : nil
                let (freshWan, freshOptical, freshDevices, freshBlocked, freshLan) =
                    await (wanRead, opticalRead, devicesRead, blockedRead, lanRead)
                guard syncGeneration == routerConfigurationGeneration else { return }
                if let freshWan { wan = freshWan }
                if let freshOptical { optical = freshOptical }
                if let freshDevices {
                    devices = freshDevices
                    hasLoadedDeviceList = true
                    cachedOnlineDeviceCount = freshDevices.filter(\.isOnline).count
                    cachedOfflineDeviceCount = max(0, freshDevices.count - cachedOnlineDeviceCount)
                }
                if let freshBlocked { blockedDevices = freshBlocked.activeBlockedDevices }
                if let freshLan { lan = freshLan }
            }
            guard routerRequestsAllowed,
                  syncGeneration == routerConfigurationGeneration else { return }
            if let authFailure = await provider.routerAuthFailure() {
                guard syncGeneration == routerConfigurationGeneration else { return }
                handleRouterAuthFailure(authFailure)
                return
            }
            isConnected = true
            isAuthenticated = true
            connectionState = .connected
            isConnectionFailure = false
            isRouterLoginPaused = false
            isForegroundSessionReady = true
            didAttemptAutomaticRouterRecovery = false
            cancelRouterRecovery()
            errorMessage = nil
            let syncDate = Date()
            if let profileId = profileID {
                settings.recordSuccessfulSync(for: profileId, at: syncDate)
                settings.recordConnectionObservation(isReachable: true, for: profileId, at: syncDate)
            }
            resetReachabilityFailures()
            lastUpdate = syncDate
            WidgetSnapshotStore.save(
                rxPowerDbm: optical.rxPowerDbm,
                routerHost: settings.activeProfile?.host,
                routerProfileID: profileID?.uuidString,
                routerModel: health.model.isEmpty ? settings.activeProfile?.detectedModel : health.model,
                summary: settings.dataUsageSummary,
                onlineClientCount: hasLoadedDeviceList ? cachedOnlineDeviceCount : nil,
                offlineClientCount: hasLoadedDeviceList ? cachedOfflineDeviceCount : nil,
                pppoeUptimeSeconds: wan.connectionType.lowercased().contains("pppoe") ? wan.uptimeSeconds : nil,
                at: syncDate
            )
        } catch {
            guard syncGeneration == routerConfigurationGeneration else { return }
            if error is CancellationError || Self.isCancellationError(error) { return }
            guard routerRequestsAllowed else { return }
            if let authFailure = await provider.routerAuthFailure() {
                guard syncGeneration == routerConfigurationGeneration else { return }
                handleRouterAuthFailure(authFailure)
                return
            }
            lastRouterSyncError = error
            isConnected = false
            isAuthenticated = false
            isConnectionFailure = Self.isReachabilityError(error)
            if isRetryingTransientRouterError && Self.isColdLaunchRetryableSocketError(error) {
                connectionState = .connecting
                errorMessage = nil
            } else {
                connectionState = .offline
                errorMessage = Self.describe(error, host: settings.host)
                recordReachabilityFailureIfNeeded()
            }
        }
    }

    private func resetReachabilityFailures() {
        reachabilityFailureCount = 0
        reachabilityFailureStartedAt = nil
    }

    private func recordReachabilityFailureIfNeeded() {
        guard isConnectionFailure, isPhoneOnWifi,
              let profileId = settings.activeProfile?.id else {
            resetReachabilityFailures()
            return
        }

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
    }

    private func handleRouterAuthFailure(_ failure: RouterAuthFailure) {
        isConnected = false
        isAuthenticated = false
        isConnectionFailure = false
        isForegroundSessionReady = false
        isRouterLoginPaused = true
        resetReachabilityFailures()

        switch failure {
        case .invalidCredentials:
            connectionState = .invalidCredentials
            cancelRouterRecovery()
            errorMessage = OntError.loginRejected.errorDescription
        case .temporarilyLocked(let retryAt):
            connectionState = .temporarilyLocked
            if didAttemptAutomaticRouterRecovery {
                errorMessage = "Router login is still temporarily locked. Save the router credentials in Settings to retry."
                cancelRouterRecovery()
            } else {
                errorMessage = OntError.loginTemporarilyLocked.errorDescription
                scheduleRouterRecovery(at: retryAt)
            }
        }
    }

    private func scheduleRouterRecovery(at retryAt: Date) {
        guard routerRecoveryTask == nil, !didAttemptAutomaticRouterRecovery else { return }
        let delay = max(0, retryAt.timeIntervalSinceNow) + 0.25
        routerRecoveryTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            } catch {
                return
            }
            guard let self, !Task.isCancelled else { return }
            self.routerRecoveryTask = nil
            self.didAttemptAutomaticRouterRecovery = true
            await self.refreshAll(forceReauthIfNeeded: true)
        }
    }

    private func cancelRouterRecovery() {
        routerRecoveryTask?.cancel()
        routerRecoveryTask = nil
    }

    public func fetchWifiSsidConfig(for network: WifiNetwork) async throws -> WifiSsidConfig {
        let configs = try await client.fetchWlanBasic(bandHint: network.band, ssidIndex: network.ssidIndex)
        guard let match = configs.first(where: { $0.ssidIndex == network.ssidIndex }) else {
            throw OntError.badResponse("Wi-Fi network configuration")
        }
        return match
    }

    @discardableResult
    public func refreshWifiManagementState() async -> Bool {
        // If a tab switch also started the app-wide refresh, let its main sync finish
        // before doing the optional disabled-SSID enrichment reads.
        await awaitFullRefreshCompletion()
        guard isConnected, routerRequestsAllowed, !isWifiSaving else { return false }
        do {
            wifi = try await client.fetchManagedWifiState()
            return true
        } catch {
            return false
        }
    }

    public func setWifiNetwork(_ network: WifiNetwork, enabled: Bool) async {
        guard !isWifiSaving, Self.isSecondaryWifiNetwork(network.ssidIndex) else { return }
        isWifiSaving = true
        beginWifiMutationStatus()
        defer { isWifiSaving = false }
        do {
            let result = try await client.setWifiNetworkEnabled(ssidIndex: network.ssidIndex, enabled: enabled)
            await completeWifiMutation(result)
            Haptics.notify(.success)
        } catch {
            wifiMutationStatus = Self.describe(error, host: settings.host)
            scheduleWifiMutationStatusClear()
            actionMessage = wifiMutationStatus
            Haptics.notify(.error)
        }
    }

    public func deleteWifiNetwork(_ network: WifiNetwork) async {
        guard !isWifiSaving, Self.isSecondaryWifiNetwork(network.ssidIndex) else { return }
        isWifiSaving = true
        beginWifiMutationStatus()
        defer { isWifiSaving = false }
        do {
            let result = try await client.deleteWifiNetwork(ssidIndex: network.ssidIndex)
            await completeWifiMutation(result)
            Haptics.notify(.success)
        } catch {
            wifiMutationStatus = Self.describe(error, host: settings.host)
            scheduleWifiMutationStatusClear()
            actionMessage = wifiMutationStatus
            Haptics.notify(.error)
        }
    }

    private func beginWifiMutationStatus() {
        wifiMutationStatusTask?.cancel()
        wifiMutationRefreshTask?.cancel()
        wifiMutationStatusTask = nil
        wifiMutationRefreshTask = nil
        wifiMutationStatus = "Applying Wi-Fi settings — router radio restarting…"
    }

    private func completeWifiMutation(_ result: WifiUpdateResult) async {
        if let updatedWifi = result.wifi { wifi = updatedWifi }
        lastPageSync = .distantPast
        if result.connectionDropped {
            wifiMutationStatus = "Applying Wi-Fi settings — router radio restarting…"
            wifiMutationRefreshTask = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                guard let self, !Task.isCancelled else { return }
                // The first read can succeed while the radio is still returning its
                // pre-change state. Always read again after the normal 5–10 second
                // WLAN restart window so newly added/changed SSIDs become visible.
                _ = await self.refreshWifiManagementState()
                try? await Task.sleep(nanoseconds: 6_000_000_000)
                guard !Task.isCancelled else { return }
                _ = await self.refreshWifiManagementState()
            }
        } else {
            wifiMutationStatus = "Wi-Fi settings applied."
            await refreshAfterMutation()
        }
        scheduleWifiMutationStatusClear()
    }

    private func scheduleWifiMutationStatusClear() {
        wifiMutationStatusTask?.cancel()
        wifiMutationStatusTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 12_000_000_000)
            guard let self, !Task.isCancelled else { return }
            self.wifiMutationStatus = nil
            self.wifiMutationStatusTask = nil
        }
    }

    private static func isSecondaryWifiNetwork(_ index: Int) -> Bool {
        WifiFrequencyBand.allCases.contains { $0.secondaryIndices.contains(index) }
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

    @discardableResult
    public func blockWifiDevice(_ device: OntDevice, clearConflictingEntries: Bool = false) async -> Bool {
        let ssidIndex: Int
        switch device.port {
        case .wifi24(let index), .wifi5(let index): ssidIndex = index
        case .lan, .other:
            actionMessage = "Only a Wi-Fi client can be blocked from the WLAN blacklist."
            return false
        }
        guard ssidIndex > 0 else {
            actionMessage = "The router did not report this device's Wi-Fi network, so it cannot be blocked safely."
            return false
        }
        do {
            let state = try await client.blockWifiDevice(
                device,
                name: name(for: device),
                ssidName: "SSID-\(ssidIndex)",
                clearConflictingEntries: clearConflictingEntries
            )
            blockedDevices = state.activeBlockedDevices
            devices = (try? await client.fetchDevices()) ?? devices
            Haptics.notify(.success)
            actionMessage = "Blocked \(name(for: device)) from Wi-Fi."
            await refreshAfterMutation()
            return false
        } catch {
            if let ontError = error as? OntError,
               ontError == .macFilterPolicyConflict,
               !clearConflictingEntries {
                return true
            }
            Haptics.notify(.error)
            actionMessage = Self.describe(error, host: settings.host)
            return false
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

    private static func isColdLaunchRetryableSocketError(_ error: Error) -> Bool {
        let retryableCodes: Set<Int> = [
            NSURLErrorNotConnectedToInternet,
            NSURLErrorCannotConnectToHost,
            NSURLErrorTimedOut,
        ]
        var candidate: NSError? = error as NSError
        while let current = candidate {
            if current.domain == NSURLErrorDomain, retryableCodes.contains(current.code) {
                return true
            }
            candidate = current.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        return false
    }

    private static func isWiFiRecoveryRetryableSocketError(_ error: Error) -> Bool {
        let retryableCodes: Set<Int> = [NSURLErrorNotConnectedToInternet, NSURLErrorCannotConnectToHost]
        var candidate: NSError? = error as NSError
        while let current = candidate {
            if current.domain == NSURLErrorDomain, retryableCodes.contains(current.code) {
                return true
            }
            candidate = current.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        return false
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

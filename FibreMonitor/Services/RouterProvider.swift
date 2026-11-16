import Foundation

/// Common networking surface used by the monitor. The protocol keeps router-specific
/// implementations replaceable without changing the screens or usage history.
public protocol RouterProvider: Sendable {
    var routerType: RouterType { get }
    func loginIsBlocked() async -> Bool
    func routerIdentity() async -> HuaweiOntClient.RouterIdentity?

    func switchCredentials(_ credentials: HuaweiOntClient.Credentials) async
    func login() async throws
    func logout() async
    func pollTraffic(now: Date) async throws -> TrafficState
    func fetchWan() async throws -> WanInfo
    func fetchOptical() async throws -> OpticalInfo
    func fetchDevices() async throws -> [OntDevice]
    func fetchHealth() async throws -> RouterHealth
    func fetchWifi() async throws -> WifiState
    func fetchWlanBasic(bandHint: String?, ssidIndex: Int?) async throws -> [WifiSsidConfig]
    func setRadio(_ index: Int, enabled: Bool) async throws -> WifiState
    func updateWifiCredentials(config: WifiSsidConfig, newSsid: String, newPassword: String) async throws -> WifiUpdateResult
    func fetchLan() async throws -> LanInfo
    func startPing(host: String, count: Int) async throws
    func pingOutput() async throws -> DiagnosticOutput
    func startTrace(host: String) async throws
    func traceOutput() async throws -> DiagnosticOutput
    func deleteDevice(_ device: OntDevice) async throws -> [OntDevice]
    func renameDevice(_ device: OntDevice, alias: String) async throws -> [OntDevice]
    func reboot() async throws
    func fetchWlanMacBlacklist() async throws -> WlanMacBlacklistState
    func blockWifiDevice(_ device: OntDevice, name: String, ssidName: String) async throws -> WlanMacBlacklistState
    func unblockWifiDevice(_ device: BlockedRouterDevice) async throws -> WlanMacBlacklistState
}

public extension HuaweiOntClient {
    nonisolated var routerType: RouterType { .huaweiONT }
    func loginIsBlocked() async -> Bool { isLoginBlocked }
    func routerIdentity() async -> RouterIdentity? { detectedIdentity }
}

extension HuaweiOntClient: RouterProvider {}

/// Keeps the Huawei implementation available under the provider-oriented name used by
/// profile selection while retaining its existing, thoroughly captured ONT client.
public typealias HuaweiONTProvider = HuaweiOntClient

public struct GenericRouterProvider: RouterProvider {
    public let routerType: RouterType = .generic

    public init() {}

    private func unsupported<T>() throws -> T {
        throw GenericRouterProviderError()
    }

    public func loginIsBlocked() async -> Bool { false }
    public func routerIdentity() async -> HuaweiOntClient.RouterIdentity? { nil }
    public func switchCredentials(_ credentials: HuaweiOntClient.Credentials) async {}
    public func login() async throws { throw GenericRouterProviderError() }
    public func logout() async {}
    public func pollTraffic(now: Date) async throws -> TrafficState { try unsupported() }
    public func fetchWan() async throws -> WanInfo { try unsupported() }
    public func fetchOptical() async throws -> OpticalInfo { try unsupported() }
    public func fetchDevices() async throws -> [OntDevice] { try unsupported() }
    public func fetchHealth() async throws -> RouterHealth { try unsupported() }
    public func fetchWifi() async throws -> WifiState { try unsupported() }
    public func fetchWlanBasic(bandHint: String?, ssidIndex: Int?) async throws -> [WifiSsidConfig] { try unsupported() }
    public func setRadio(_ index: Int, enabled: Bool) async throws -> WifiState { try unsupported() }
    public func updateWifiCredentials(config: WifiSsidConfig, newSsid: String, newPassword: String) async throws -> WifiUpdateResult { try unsupported() }
    public func fetchLan() async throws -> LanInfo { try unsupported() }
    public func startPing(host: String, count: Int) async throws { throw GenericRouterProviderError() }
    public func pingOutput() async throws -> DiagnosticOutput { try unsupported() }
    public func startTrace(host: String) async throws { throw GenericRouterProviderError() }
    public func traceOutput() async throws -> DiagnosticOutput { try unsupported() }
    public func deleteDevice(_ device: OntDevice) async throws -> [OntDevice] { try unsupported() }
    public func renameDevice(_ device: OntDevice, alias: String) async throws -> [OntDevice] { try unsupported() }
    public func reboot() async throws { throw GenericRouterProviderError() }
    public func fetchWlanMacBlacklist() async throws -> WlanMacBlacklistState { try unsupported() }
    public func blockWifiDevice(_ device: OntDevice, name: String, ssidName: String) async throws -> WlanMacBlacklistState { try unsupported() }
    public func unblockWifiDevice(_ device: BlockedRouterDevice) async throws -> WlanMacBlacklistState { try unsupported() }
}

private struct GenericRouterProviderError: LocalizedError {
    var errorDescription: String? {
        "This router type does not have a compatible LinkWave network adapter yet. Select Huawei ONT for Huawei OptiXstar routers."
    }
}

public enum RouterProviderFactory {
    public static func make(
        profile: RouterProfile?,
        credentials: HuaweiOntClient.Credentials,
        transport: OntTransport = URLSessionOntTransport()
    ) -> any RouterProvider {
        switch profile?.resolvedRouterType ?? .huaweiONT {
        case .huaweiONT:
            HuaweiONTProvider(credentials: credentials, transport: transport)
        case .generic:
            GenericRouterProvider()
        }
    }
}

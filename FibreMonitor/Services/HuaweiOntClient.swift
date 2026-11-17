import Foundation

/// Talks to a Huawei OptiXstar ONT (tested against the HG8145X6-10 web UI).
///
/// Huawei ONT adapter. Authentication and its cookie-backed session are coordinated by
/// `RouterAuthCoordinator` so overlapping router requests share one login attempt.
public actor HuaweiOntClient {
    public struct Credentials: Equatable, Sendable {
        public var host: String
        public var username: String
        public var password: String
        public init(host: String, username: String, password: String) {
            self.host = host; self.username = username; self.password = password
        }
    }

    public struct RouterIdentity: Equatable, Sendable {
        public var model: String?
        public var cfgMode: String?

        public init(model: String? = nil, cfgMode: String? = nil) {
            self.model = model
            self.cfgMode = cfgMode
        }
    }

    private let transport: OntTransport
    private let authCoordinator: RouterAuthCoordinator
    private var credentials: Credentials
    private var loggedIn = false
    public private(set) var detectedIdentity: RouterIdentity?

    private var lastCounters: (rx: UInt64, tx: UInt64, time: Date)?
    private var traffic = TrafficState()
    private let maxHistory = 60

    public init(credentials: Credentials, transport: OntTransport = URLSessionOntTransport()) {
        self.credentials = credentials
        self.transport = transport
        self.authCoordinator = RouterAuthCoordinator(credentials: credentials, transport: transport)
    }

    public func update(credentials new: Credentials) async {
        guard new != credentials else { return }
        credentials = new
        loggedIn = false
        await authCoordinator.updateCredentials(new)
        await transport.resetSession(host: new.host)
        lastCounters = nil
        traffic = TrafficState()
        wanDomain = nil
        ssidBands = [:]
        detectedIdentity = nil
    }

    /// Logs out of any active session, resets transport cookies, and switches to new router credentials.
    public func switchCredentials(_ new: Credentials) async {
        await logout()
        credentials = new
        loggedIn = false
        await authCoordinator.updateCredentials(new)
        lastCounters = nil
        traffic = TrafficState()
        wanDomain = nil
        ssidBands = [:]
        detectedIdentity = nil
        await transport.resetSession(host: new.host)
    }

    public func loginFailure() async -> RouterAuthFailure? {
        await authCoordinator.currentFailure()
    }

    // MARK: Session

    public func login() async throws {
        guard !credentials.password.isEmpty, !credentials.host.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw OntError.notConfigured
        }
        guard Self.isValidHost(credentials.host) else { throw OntError.invalidHost }
        do {
            detectedIdentity = try await authCoordinator.authenticate()
            loggedIn = true
        } catch {
            loggedIn = false
            throw error
        }
    }

    public func logout() async {
        let wasLoggedIn = loggedIn
        let currentHost = credentials.host
        await authCoordinator.beginSessionClose()
        loggedIn = false
        lastCounters = nil
        wanDomain = nil
        ssidBands = [:]
        detectedIdentity = nil
        if wasLoggedIn, let token = try? await freshToken() {
            _ = try? await transport.send(.init(.post, "/logout.cgi?RequestFile=html/logout.html",
                                                form: [("x.X_HW_Token", token)], ajax: false),
                                          host: currentHost)
        }
        await transport.resetSession(host: currentHost)
        await authCoordinator.finishSessionClose()
    }

    /// Stops login work and cancels transport requests without sending a logout over cellular.
    public func suspendForNetworkLoss() async {
        loggedIn = false
        lastCounters = nil
        traffic.downloadMbps = 0
        traffic.uploadMbps = 0
        await authCoordinator.suspendForNetworkLoss()
        await transport.cancelPendingRequests()
    }

    /// Sends a data request, logging in first if needed and once more if the session expired.
    /// Full HTML pages are checked for `expect` (text the real page always contains), because
    /// an expired session answers with the login page instead.
    private func fetch(_ request: OntRequest, expect: String? = nil) async throws -> String {
        func valid(_ text: String) -> Bool {
            if let expect { return text.contains(expect) }
            return HuaweiJs.looksLikeData(text)
        }
        let response = try await sendAuthenticated(request)
        if valid(response) { return response }
        let generation = await authCoordinator.currentGeneration()
        await invalidateSession(ifGeneration: generation)
        let retry = try await sendAuthenticated(request)
        guard valid(retry) else { throw OntError.sessionExpired }
        return retry
    }

    /// Retries one request after Huawei drops its sid cookie or returns a login redirect.
    /// URLSession reports HTTP 401/403/500 as `badServerResponse` (-1011) here.
    private func sendAuthenticated(_ request: OntRequest) async throws -> String {
        try await login()
        let generation = await authCoordinator.currentGeneration()
        var firstResponse: String?
        do {
            firstResponse = try await transport.send(request, host: credentials.host)
        } catch {
            guard Self.isExpiredSessionError(error) else { throw error }
        }

        if let firstResponse, !Self.looksLikeLoginPage(firstResponse) {
            return firstResponse
        }

        await invalidateSession(ifGeneration: generation)
        try await login()
        let retryGeneration = await authCoordinator.currentGeneration()
        do {
            let retryRequest = try await refreshedWlanTokenIfNeeded(in: request)
            let response = try await transport.send(retryRequest, host: credentials.host)
            guard !Self.looksLikeLoginPage(response) else {
                await invalidateSession(ifGeneration: retryGeneration)
                throw OntError.sessionExpired
            }
            return response
        } catch {
            if Self.isExpiredSessionError(error) {
                await invalidateSession(ifGeneration: retryGeneration)
            }
            throw error
        }
    }

    private func refreshedWlanTokenIfNeeded(in request: OntRequest) async throws -> OntRequest {
        guard request.path.contains("/html/amp/wlanbasic/set.cgi"),
              request.path.contains("RequestFile=html/amp/wlanbasic/WlanBasic.asp"),
              request.form.contains(where: { $0.0 == "x.X_HW_Token" }) else { return request }
        let page = try await fetchWlanBasicPage()
        let token = try Self.wlanPageToken(in: page)
        var refreshed = request
        refreshed.form = refreshed.form.map { key, value in
            key == "x.X_HW_Token" ? (key, token) : (key, value)
        }
        return refreshed
    }

    private static func isExpiredSessionError(_ error: Error) -> Bool {
        if let ontError = error as? OntError, case .sessionExpired = ontError { return true }
        guard let urlError = error as? URLError else { return false }
        return urlError.code == .badServerResponse || urlError.code == .userAuthenticationRequired
    }

    private func freshToken() async throws -> String {
        let t = HuaweiJs.clean(try await transport.send(.init(.post, "/html/ssmp/common/GetRandToken.asp"), host: credentials.host))
        guard !t.isEmpty, !t.contains("<") else { throw OntError.sessionExpired }
        return t
    }

    private static func cacheBuster() -> String { String(Int(Date().timeIntervalSince1970 * 1000)) }

    // MARK: Traffic

    /// Polls the WAN byte counters and returns speeds from the change since the last poll.
    public func pollTraffic(now: Date = Date()) async throws -> TrafficState {
        let text = try await fetch(.init(.get, "/html/bbsp/common/get_wan_list_pppwanstat.asp?_=\(Self.cacheBuster())"))
        var stats = HuaweiJs.records(of: "WaninfoStats", in: text, fallbackParams: Self.statsParams)
        if stats.isEmpty {
            // IPoE (DHCP/static) WANs report through the IP variant.
            let ip = try await fetch(.init(.get, "/html/bbsp/common/get_wan_list_ipwanstat.asp?_=\(Self.cacheBuster())"))
            stats = HuaweiJs.records(of: "WaninfoStats", in: ip, fallbackParams: Self.statsParams)
        }
        guard let first = stats.first, let counters = Self.counters(from: first) else {
            throw OntError.badResponse("traffic counters")
        }
        apply(counters: counters, at: now)
        return traffic
    }

    static let statsParams = ["domain", "BytesSent", "BytesReceived", "PacketsSent", "PacketsReceived",
                              "UnicastSent", "UnicastReceived", "MulticastSent", "MulticastReceived",
                              "BroadcastSent", "BroadcastReceived", "BytesSentHigh", "BytesSentLow",
                              "BytesReceivedHigh", "BytesReceivedLow"]

    /// Uses the 64-bit high/low pair when the firmware provides it, else the plain counter.
    static func counters(from r: [String: String]) -> (rx: UInt64, tx: UInt64)? {
        func value(_ plain: String, _ high: String, _ low: String) -> UInt64? {
            if let h = UInt64(r[high] ?? ""), let l = UInt64(r[low] ?? "") { return (h << 32) | l }
            return UInt64(r[plain] ?? "")
        }
        guard let rx = value("BytesReceived", "BytesReceivedHigh", "BytesReceivedLow"),
              let tx = value("BytesSent", "BytesSentHigh", "BytesSentLow") else { return nil }
        return (rx, tx)
    }

    /// Byte delta between polls, allowing for 32-bit counter wrap. Returns nil when the
    /// counter went backwards for another reason (e.g. the PPPoE session reconnected).
    static func delta(previous: UInt64, current: UInt64) -> UInt64? {
        if current >= previous { return current - previous }
        if previous <= UInt64(UInt32.max) && previous > UInt64(UInt32.max) / 2 {
            return (UInt64(UInt32.max) + 1 - previous) + current
        }
        return nil
    }

    private func apply(counters: (rx: UInt64, tx: UInt64), at now: Date) {
        traffic.cumulativeDownloadBytes = counters.rx
        traffic.cumulativeUploadBytes = counters.tx
        defer { lastCounters = (counters.rx, counters.tx, now) }
        guard let last = lastCounters else { return }
        let seconds = now.timeIntervalSince(last.time)
        guard seconds >= 0.3,
              let dRx = Self.delta(previous: last.rx, current: counters.rx),
              let dTx = Self.delta(previous: last.tx, current: counters.tx) else { return }
        let down = Double(dRx) * 8 / seconds / 1_000_000
        let up = Double(dTx) * 8 / seconds / 1_000_000
        // Anything above 10 Gbps is a counter glitch, not traffic.
        guard down < 10_000, up < 10_000 else { return }
        traffic.downloadMbps = down
        traffic.uploadMbps = up
        traffic.peakDownloadMbps = max(traffic.peakDownloadMbps, down)
        traffic.peakUploadMbps = max(traffic.peakUploadMbps, up)
        traffic.history.append(ThroughputSample(downloadMbps: down, uploadMbps: up, time: now))
        if traffic.history.count > maxHistory { traffic.history.removeFirst(traffic.history.count - maxHistory) }
    }

    // MARK: WAN

    public func fetchWan() async throws -> WanInfo {
        let token = try await freshTokenLoggingIn()
        let text = try await fetch(.init(.post, "/html/bbsp/common/getwanlist.asp", form: [("x.X_HW_Token", token)]))
        let wan = Self.parseWan(text)
        if !wan.domain.isEmpty { wanDomain = wan.domain }
        return wan
    }

    /// Internet WAN used as the source interface for ping and traceroute.
    private var wanDomain: String?

    // MARK: Diagnostics (router-side ping / traceroute)

    private static let diagnosePage = "RequestFile=html/bbsp/maintenance/diagnosecommon.asp"

    public static func isValidHost(_ host: String) -> Bool {
        let h = host.trimmingCharacters(in: .whitespaces)
        guard !h.isEmpty, h.count <= 253 else { return false }
        guard !h.hasPrefix("."), !h.hasPrefix("-"), !h.contains("..") else { return false }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-:")
        return h.unicodeScalars.allSatisfy { allowed.contains($0) }
    }

    private func diagnosticInterface() async throws -> String {
        if let d = wanDomain { return d }
        let wan = try await fetchWan()
        guard !wan.domain.isEmpty else { throw OntError.badResponse("internet connection") }
        return wan.domain
    }

    /// Starts a ping from the router, like the Diagnostics page. Read progress with `pingOutput()`.
    public func startPing(host: String, count: Int = 4) async throws {
        let h = host.trimmingCharacters(in: .whitespaces)
        guard Self.isValidHost(h) else { throw OntError.invalidHost }
        let interface = try await diagnosticInterface()
        let token = try await freshTokenLoggingIn()
        _ = try await sendAuthenticated(.init(.post,
            "/html/bbsp/maintenance/complex.cgi?x=InternetGatewayDevice.IPPingDiagnostics&RUNSTATE_FLAG=Ping&\(Self.diagnosePage)",
            form: [("x.Host", h), ("x.DiagnosticsState", "Requested"), ("x.NumberOfRepetitions", String(min(max(count, 1), 50))),
                   ("x.DSCP", "0"), ("x.DataBlockSize", "56"), ("x.Timeout", "10000"), ("x.Interface", interface),
                   ("RUNSTATE_FLAG.value", "START"), ("x.X_HW_Token", token)],
            ajax: false))
    }

    public func pingOutput() async throws -> DiagnosticOutput {
        DiagnosticOutput.parse(try await fetch(.init(.post, "/html/bbsp/maintenance/GetPingResult.asp")))
    }

    /// Starts a traceroute from the router. Read progress with `traceOutput()`.
    public func startTrace(host: String) async throws {
        let h = host.trimmingCharacters(in: .whitespaces)
        guard Self.isValidHost(h) else { throw OntError.invalidHost }
        let interface = try await diagnosticInterface()
        let token = try await freshTokenLoggingIn()
        _ = try await sendAuthenticated(.init(.post,
            "/html/bbsp/maintenance/complex.cgi?x=InternetGatewayDevice.TraceRouteDiagnostics&RUNSTATE_FLAG=Traceroute&\(Self.diagnosePage)",
            form: [("x.Interface", interface), ("x.X_HW_ProtocolType", "0"), ("x.DiagnosticsState", "Requested"),
                   ("x.Host", h), ("x.DataBlockSize", "38"), ("RUNSTATE_FLAG.value", "START"), ("x.X_HW_Token", token)],
            ajax: false))
    }

    public func traceOutput() async throws -> DiagnosticOutput {
        DiagnosticOutput.parse(try await fetch(.init(.post, "/html/bbsp/maintenance/GetRouteResult.asp")))
    }

    static func parseWan(_ text: String) -> WanInfo {
        let ppp = HuaweiJs.records(of: "WanPPP", in: text, fallbackParams: wanPppParams)
        let ip = HuaweiJs.records(of: "WanIP", in: text, fallbackParams: wanIpParams)
        let all = ppp.map { ($0, "PPPoE") } + ip.map { ($0, "IPoE") }
        // Prefer the connected internet WAN over TR-069/VoIP-only ones.
        let ranked = all.sorted { a, b in score(a.0) > score(b.0) }
        guard let best = ranked.first else { return WanInfo() }
        let (r, type) = best
        var wan = WanInfo()
        wan.domain = r["domain"] ?? ""
        wan.name = r["Name"] ?? ""
        wan.connectionStatus = r["ConnectionStatus"] ?? r["Status"] ?? ""
        wan.connectionType = type
        wan.ipAddress = r["IPAddress"] ?? ""
        wan.gateway = r["Gateway"] ?? ""
        wan.dnsServers = (r["dnsstr"] ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        wan.vlanId = r["VlanId"] ?? ""
        wan.uptimeSeconds = Int(r["Uptime"] ?? "") ?? 0
        wan.lastError = r["LastConnErr"] ?? ""
        return wan
    }

    private static func score(_ r: [String: String]) -> Int {
        var s = 0
        if (r["ConnectionStatus"] ?? r["Status"]) == "Connected" { s += 4 }
        if (r["ServiceList"] ?? "").uppercased().contains("INTERNET") { s += 2 }
        if !(r["IPAddress"] ?? "").isEmpty { s += 1 }
        return s
    }

    static let wanPppParams = ["domain", "X_HW_VXLAN_Enable", "X_HW_OperateDisable", "ConnectionTrigger", "MACAddress", "Status",
                               "LastConnErr", "RemoteWanInfo", "Name", "Enable", "EnableLanDhcp", "DstIPForwardingList",
                               "ConnectionStatus", "Mode", "IPAddress", "Gateway", "NATEnable", "X_HW_NatType", "dnsstr",
                               "Username", "Password", "DialMode", "ConnectionControl", "VlanId", "MultiVlanID", "Pri8021",
                               "LcpEchoReqCheck", "ServiceList", "ExServiceList", "Tr069Flag", "IdleDisconnectTime", "MacId",
                               "IPv4Enable", "IPv6Enable", "IPv6MultiCastVlan", "PriPolicy", "DefaultPri", "MaxMRUSize",
                               "PPPoEACName", "X_HW_IdleDetectMode", "Uptime", "DNSOverrideAllowed", "X_HW_LowerLayers",
                               "PPPoESessionID", "X_HW_IGMPEnable", "StaticRouteInfo", "X_HW_DscpToPbitTbl", "Hurl", "Motm",
                               "X_HW_BridgeEnable", "X_HW_NPTv6Enable", "X_HW_SpeedLimit_UP", "X_HW_SpeedLimit_DOWN",
                               "X_HW_PingResponseEnable", "X_HW_PingResponseWhiteList", "IPForwardModeEnabled", "X_HW_UpPortId"]

    static let wanIpParams = ["domain", "X_HW_VXLAN_Enable", "X_HW_OperateDisable", "ConnectionTrigger", "MACAddress", "Status",
                              "LastConnErr", "RemoteWanInfo", "Name", "Enable", "EnableLanDhcp", "DstIPForwardingList",
                              "ConnectionStatus", "Mode", "IPMode", "IPAddress", "SubnetMask", "Gateway", "NATEnable",
                              "X_HW_NatType", "dnsstr", "VlanId", "MultiVlanID", "Pri8021", "VenderClassID", "ClientID",
                              "ServiceList", "ExServiceList", "Tr069Flag", "MacId", "IPv4Enable", "IPv6Enable",
                              "IPv6MultiCastVlan", "PriPolicy", "DefaultPri", "MaxMTUSize", "DHCPLeaseTime", "NTPServer",
                              "TimeZoneInfo", "SIPServer", "StaticRouteInfo", "VendorInfo", "DHCPLeaseTimeRemaining", "Uptime",
                              "DNSOverrideAllowed", "X_HW_LowerLayers", "X_HW_IPoEName", "X_HW_IPoEPassword", "X_HW_IGMPEnable",
                              "X_HW_DscpToPbitTbl", "IPv4IPAddressSecond", "IPv4SubnetMaskSecond", "IPv4IPAddressThird",
                              "IPv4SubnetMaskThird", "X_HW_NPTv6Enable", "X_HW_SpeedLimit_UP", "X_HW_SpeedLimit_DOWN",
                              "X_HW_LteProfile", "X_HW_PingResponseEnable", "X_HW_PingResponseWhiteList", "IPForwardModeEnabled",
                              "X_HW_UpPortId"]

    // MARK: Optical

    public func fetchOptical() async throws -> OpticalInfo {
        let token = try await freshTokenLoggingIn()
        let text = try await fetch(.init(.post, "/html/amp/common/getSmartDiagnoseResult.asp", form: [("x.X_HW_Token", token)]))
        var info = Self.parseSmartDiagnose(text)
        // TX power and temperature, when the firmware exposes them. Optional.
        if let optic = try? await sendAuthenticated(.init(.post, "/html/ssmp/common/getOpticTxRx.asp")),
           HuaweiJs.looksLikeData(optic) {
            Self.mergeOpticTxRx(optic, into: &info)
        }
        return info
    }

    static func parseSmartDiagnose(_ text: String) -> OpticalInfo {
        var info = OpticalInfo()
        info.rxPowerDbm = parseDbm(HuaweiJs.stringVar("opticInfo", in: text))
        info.ponMode = HuaweiJs.stringVar("ontPonMode", in: text) ?? ""
        if info.ponMode.lowercased() == "epon" {
            info.registrationState = HuaweiJs.stringVar("eponStatus", in: text) ?? ""
        } else {
            info.registrationState = HuaweiJs.stringVar("gponStatus", in: text) ?? ""
        }
        return info
    }

    static func mergeOpticTxRx(_ text: String, into info: inout OpticalInfo) {
        let defs = HuaweiJs.definitions(in: text)
        for (name, params) in defs where params.contains("RxPower") || params.contains("TxPower") {
            guard let r = HuaweiJs.records(of: name, in: text).first else { continue }
            if let rx = parseDbm(r["RxPower"]) { info.rxPowerDbm = rx }
            if let tx = parseDbm(r["TxPower"]) { info.txPowerDbm = tx }
            if let t = Double(r["Temperature"] ?? "") { info.temperatureC = t }
            return
        }
    }

    static func parseDbm(_ raw: String?) -> Double? {
        guard let raw = raw?.trimmingCharacters(in: .whitespaces), !raw.isEmpty, raw != "--" else { return nil }
        return Double(raw)
    }

    // MARK: Devices

    public func fetchDevices() async throws -> [OntDevice] {
        let text = try await fetch(.init(.post, "/html/bbsp/common/GetLanUserDevInfo.asp"))
        var devices = Self.parseDevices(text, ssidBands: ssidBands)
        // Optional DHCP lease enrichment; older firmwares or sessions without it still succeed.
        if let dhcp = try? await sendAuthenticated(.init(.post, "/html/bbsp/common/GetLanUserDhcpInfo.asp")),
           HuaweiJs.looksLikeData(dhcp) {
            devices = Self.enrichDevices(devices, withDhcpInfo: dhcp)
        }
        return devices
    }

    /// SSID index -> "2.4GHz"/"5GHz" from the router's Wi-Fi list; learned by `fetchWifi()`.
    private var ssidBands: [Int: String] = [:]

    /// Removes an offline device from the router's list, like the device page's Delete button
    /// (which the router only offers for offline devices). Returns the refreshed list.
    public func deleteDevice(_ device: OntDevice) async throws -> [OntDevice] {
        guard !device.isOnline else { throw OntError.deviceOnline }
        guard device.domain.hasPrefix("InternetGatewayDevice.LANDevice.1.X_HW_UserDev.") else {
            throw OntError.badResponse("device record")
        }
        let token = try await freshTokenLoggingIn()
        _ = try await sendAuthenticated(.init(.post,
            "/html/bbsp/userdevinfo/del.cgi?x=InternetGatewayDevice.LANDevice.1.X_HW_UserDev"
                + "&RequestFile=html/bbsp/userdevinfo/userdevinfosmart.asp",
            form: [(device.domain, ""), ("x.X_HW_Token", token)]))
        let after = try await fetchDevices()
        guard !after.contains(where: { $0.mac == device.mac }) else { throw OntError.notConfirmed }
        return after
    }

    public static func validateDeviceAlias(_ alias: String) throws -> String {
        let trimmed = alias.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.utf8.count <= 64 else {
            throw OntError.invalidDeviceAlias
        }
        let allPrintable = trimmed.unicodeScalars.allSatisfy { $0.value >= 0x20 && $0.value != 0x7F }
        guard allPrintable else { throw OntError.invalidDeviceAlias }
        return trimmed
    }

    /// Renames a device on the router (`#198`), then re-fetches the device list.
    public func renameDevice(_ device: OntDevice, alias: String) async throws -> [OntDevice] {
        guard device.domain.hasPrefix("InternetGatewayDevice.LANDevice.1.X_HW_UserDev.") else {
            throw OntError.badResponse("device record")
        }
        let cleanAlias = try Self.validateDeviceAlias(alias)
        let token = try await freshTokenLoggingIn()
        let deviceType = device.userSpecifiedDeviceType.isEmpty ? "0" : device.userSpecifiedDeviceType
        _ = try await sendAuthenticated(.init(.post,
            "/html/bbsp/userdevinfo/set.cgi?x=\(device.domain)&RequestFile=html/bbsp/userdevinfo/userdetdevinfo.asp",
            form: [
                ("x.UserDevAlias", cleanAlias),
                ("x.UserSpecifiedDeviceType", deviceType),
                ("x.X_HW_Token", token)
            ],
            ajax: false))
        return try await fetchDevices()
    }

    // MARK: WLAN access control

    private static let wlanMacFilterPage = "/html/bbsp/wlanmacfilter/wlanmacfilter.asp"
    private static let wlanMacFilterObject = "InternetGatewayDevice.X_HW_Security.WLANMacFilter"
    private static let lanMacFilterPage = "/html/bbsp/macfilter/macfilter.asp"
    private static let lanMacFilterObject = "InternetGatewayDevice.X_HW_Security.MacFilter"

    public func fetchWlanMacBlacklist() async throws -> WlanMacBlacklistState {
        let page = try await fetch(.init(.get, Self.wlanMacFilterPage, ajax: false), expect: "MacFilterSrc")
        return Self.parseWlanMacBlacklist(page)
    }

    static func parseWlanMacBlacklist(_ page: String) -> WlanMacBlacklistState {
        let rows = HuaweiJs.instances(of: "stMacFilter", in: page)
        let devices = rows.compactMap { row -> BlockedRouterDevice? in
            guard let domain = row.first else { return nil }
            let values = Array(row.dropFirst())
            let mac = values.map(normalizedFilterMac).first(where: { !$0.isEmpty }) ?? ""
            let ssidName = values.first(where: { $0.localizedCaseInsensitiveContains("ssid") }) ?? ""
            let name = values.first(where: {
                !$0.localizedCaseInsensitiveContains("ssid") && normalizedFilterMac($0).isEmpty
            }) ?? ""
            guard domain.hasPrefix(Self.wlanMacFilterObject + "."),
                  let index = Int(domain.dropFirst(Self.wlanMacFilterObject.count + 1)), index > 0,
                  !mac.isEmpty else { return nil }
            return BlockedRouterDevice(
                domain: domain,
                mac: mac,
                ssidName: ssidName,
                name: name
            )
        }
        return WlanMacBlacklistState(
            isEnabled: HuaweiJs.stringVar("enableFilter", in: page) == "1",
            policy: HuaweiJs.stringVar("Mode", in: page) ?? "",
            devices: devices
        )
    }

    private static func normalizedFilterMac(_ value: String) -> String {
        let mac = HuaweiJs.clean(value).replacingOccurrences(of: "-", with: ":").lowercased()
        let octets = mac.split(separator: ":")
        guard octets.count == 6,
              octets.allSatisfy({ $0.count == 2 && $0.allSatisfy(\.isHexDigit) }),
              let first = UInt8(octets[0], radix: 16), first & 1 == 0,
              mac != "00:00:00:00:00:00" else { return "" }
        return mac
    }

    public func blockWifiDevice(
        _ device: OntDevice,
        name: String,
        ssidName: String,
        clearConflictingEntries: Bool = false
    ) async throws -> WlanMacBlacklistState {
        let isWifi: Bool
        switch device.port {
        case .wifi24, .wifi5: isWifi = true
        case .lan, .other: isWifi = false
        }
        guard isWifi, ssidName.hasPrefix("SSID-"),
              let index = Int(ssidName.dropFirst("SSID-".count)), (1...8).contains(index) else {
            throw OntError.badResponse("Wi-Fi association")
        }
        let mac = Self.normalizedFilterMac(device.mac)
        guard !mac.isEmpty else { throw OntError.badResponse("device MAC address") }

        var state = try await fetchWlanMacBlacklist()
        if state.policy != "0" || !state.isEnabled {
            // Changing an existing whitelist would invert the meaning of every current entry.
            // The UI must confirm before this explicit replacement path clears both lists.
            let wlanPage = try await fetch(.init(.get, Self.wlanMacFilterPage, ajax: false), expect: "MacFilterSrc")
            let wiredPage = try await fetch(.init(.get, Self.lanMacFilterPage, ajax: false), expect: "MacFilter")
            let wlanRows = HuaweiJs.instances(of: "stMacFilter", in: wlanPage)
            let wiredRows = HuaweiJs.instances(of: "stMacFilter", in: wiredPage)
            let hasEntries = !wlanRows.isEmpty || !wiredRows.isEmpty
            if hasEntries && !clearConflictingEntries { throw OntError.macFilterPolicyConflict }
            if clearConflictingEntries {
                try await clearMacFilterEntries(wlanRows: wlanRows, wiredRows: wiredRows)
                state = try await fetchWlanMacBlacklist()
                let verifiedWired = try await fetch(.init(.get, Self.lanMacFilterPage, ajax: false), expect: "MacFilter")
                guard state.devices.isEmpty,
                      HuaweiJs.instances(of: "stMacFilter", in: verifiedWired).isEmpty else {
                    throw OntError.notConfirmed
                }
            } else if !state.devices.isEmpty {
                throw OntError.macFilterPolicyConflict
            }

            let token = try await freshTokenLoggingIn()
            _ = try await sendAuthenticated(.init(.post,
                "/html/bbsp/wlanmacfilter/set.cgi?x=InternetGatewayDevice.X_HW_Security&RequestFile=html/bbsp/wlanmacfilter/wlanmacfilter.asp",
                form: [
                    ("x.MacFilterPolicy", "0"),
                    ("x.MacFilterRight", "1"),
                    ("x.X_HW_Token", token)
                ], ajax: false))
            state = try await fetchWlanMacBlacklist()
            guard state.policy == "0", state.isEnabled, state.devices.isEmpty else {
                throw OntError.notConfirmed
            }
        }

        if state.activeBlockedDevices.contains(where: { $0.mac == mac }) { return state }
        let token = try await freshTokenLoggingIn()
        let path = "/html/bbsp/wlanmacfilter/add.cgi?x=\(Self.wlanMacFilterObject)&RequestFile=html/bbsp/wlanmacfilter/wlanmacfilter.asp"
        _ = try await sendAuthenticated(.init(.post, path, form: [
            ("x.SourceMACAddress", mac),
            ("x.SSIDName", ssidName),
            ("x.DeviceName", name),
            ("x.Enable", "1"),
            ("x.X_HW_Token", token)
        ], ajax: false))

        state = try await fetchWlanMacBlacklist()
        guard state.activeBlockedDevices.contains(where: { $0.mac == mac }) else {
            throw OntError.notConfirmed
        }
        return state
    }

    private func clearMacFilterEntries(wlanRows: [[String]], wiredRows: [[String]]) async throws {
        let wlanDomains = wlanRows.compactMap(\.first).filter { Self.isMacFilterRecord($0, in: Self.wlanMacFilterObject) }
        let wiredDomains = wiredRows.compactMap(\.first).filter { Self.isMacFilterRecord($0, in: Self.lanMacFilterObject) }

        for domain in wlanDomains {
            let token = try await freshTokenLoggingIn()
            let path = "/html/bbsp/wlanmacfilter/del.cgi?x=\(Self.wlanMacFilterObject)&RequestFile=html/bbsp/wlanmacfilter/wlanmacfilter.asp"
            _ = try await sendAuthenticated(.init(.post, path, form: [
                (domain, ""), ("x.X_HW_Token", token)
            ], ajax: false))
        }
        for domain in wiredDomains {
            let token = try await freshTokenLoggingIn()
            let path = "/html/bbsp/macfilter/del.cgi?x=\(Self.lanMacFilterObject)&RequestFile=html/bbsp/macfilter/macfilter.asp"
            _ = try await sendAuthenticated(.init(.post, path, form: [
                (domain, ""), ("x.X_HW_Token", token)
            ], ajax: false))
        }
    }

    private static func isMacFilterRecord(_ domain: String, in object: String) -> Bool {
        let prefix = object + "."
        guard domain.hasPrefix(prefix) else { return false }
        return Int(domain.dropFirst(prefix.count)) != nil
    }

    public func unblockWifiDevice(_ device: BlockedRouterDevice) async throws -> WlanMacBlacklistState {
        let prefix = Self.wlanMacFilterObject + "."
        guard device.domain.hasPrefix(prefix),
              let index = Int(device.domain.dropFirst(prefix.count)), index > 0 else {
            throw OntError.badResponse("blacklist record")
        }
        let token = try await freshTokenLoggingIn()
        let path = "/html/bbsp/wlanmacfilter/del.cgi?x=\(Self.wlanMacFilterObject)&RequestFile=html/bbsp/wlanmacfilter/wlanmacfilter.asp"
        _ = try await sendAuthenticated(.init(.post, path, form: [
            (device.domain, ""),
            ("x.X_HW_Token", token)
        ], ajax: false))
        let state = try await fetchWlanMacBlacklist()
        guard !state.devices.contains(where: { $0.mac == device.mac }) else { throw OntError.notConfirmed }
        return state
    }

    // MARK: Router health

    private static func looksLikeLoginPage(_ text: String) -> Bool {
        let lower = text.lowercased()
        return lower.contains("login.cgi") || lower.contains("login.html")
            || lower.contains("txt_username") || lower.contains("txt_password")
            || lower.contains("loginform")
    }

    public func fetchHealth() async throws -> RouterHealth {
        try await login()
        let req = OntRequest(.get, "/html/ssmp/deviceinfo/deviceinfo.asp", ajax: false)
        let response = try await sendAuthenticated(req)
        guard response.contains("cpuUsed") || response.contains("stDeviceInfo") else {
            throw OntError.badResponse("deviceinfo")
        }
        return Self.parseHealth(response)
    }

    static func parseHealth(_ text: String) -> RouterHealth {
        var h = RouterHealth()
        h.cpuPercent = Int((HuaweiJs.stringVar("cpuUsed", in: text) ?? "").replacingOccurrences(of: "%", with: ""))
        h.memoryPercent = Int((HuaweiJs.stringVar("memUsed", in: text) ?? "").replacingOccurrences(of: "%", with: ""))
        h.uptimeSeconds = Int(HuaweiJs.stringVar("dev_uptime", in: text) ?? "")
        if let info = HuaweiJs.records(of: "stDeviceInfo", in: text).first {
            h.model = info["ModelName"] ?? ""
            h.firmware = info["SoftwareVersion"] ?? ""
            h.hardware = info["HardwareVersion"] ?? ""
        }
        return h
    }

    // MARK: Wi-Fi

    public func fetchWifi() async throws -> WifiState {
        let text = try await fetch(.init(.get, "/html/amp/common/wlan_list.asp", ajax: false), expect: "stRadio")
        let state = Self.parseWifi(text)
        ssidBands = Dictionary(state.networks.map { ($0.ssidIndex, $0.band) }, uniquingKeysWith: { a, _ in a })
        return state
    }

    /// Combines the router's Wi-Fi list with configured WLAN slots, including disabled SSIDs.
    /// Passphrases from WlanBasic.asp are discarded before returning to the UI.
    public func fetchManagedWifiState() async throws -> WifiState {
        var state = try await fetchWifi()
        let configs = try await fetchWlanBasic()
        for config in configs where (1...8).contains(config.ssidIndex) && !config.ssid.isEmpty {
            let band = WifiFrequencyBand.label(for: config.ssidIndex, fallback: "")
            let network = WifiNetwork(
                ssidIndex: config.ssidIndex,
                name: config.ssid,
                band: band,
                enabled: config.isEnabled
            )
            if let index = state.networks.firstIndex(where: { $0.ssidIndex == config.ssidIndex }) {
                state.networks[index] = network
            } else {
                state.networks.append(network)
            }
        }
        state.networks.sort { $0.ssidIndex < $1.ssidIndex }
        ssidBands = Dictionary(state.networks.map { ($0.ssidIndex, $0.band) }, uniquingKeysWith: { a, _ in a })
        return state
    }

    static func parseWifi(_ text: String) -> WifiState {
        var state = WifiState()
        var seen = Set<Int>()
        for r in HuaweiJs.records(of: "stRadio", in: text, fallbackParams: ["domain", "OperatingFrequencyBand", "Enable"]) {
            guard let index = Int((r["domain"] ?? "").split(separator: ".").last ?? ""), seen.insert(index).inserted else { continue }
            state.radios.append(WifiRadio(index: index, band: r["OperatingFrequencyBand"] ?? "", enabled: r["Enable"] == "1"))
        }
        let params = ["domain", "name", "ssid", "X_HW_ServiceEnable", "enable", "RFBand", "X_HW_RFBand", "bindenable"]
        var networksByIndex: [Int: WifiNetwork] = [:]
        for r in HuaweiJs.records(of: "stWlanInfo", in: text, fallbackParams: params) {
            // Skip the page's own template record ('domain', 'SSID'+tid, ...).
            guard let index = Int((r["domain"] ?? "").split(separator: ".").last ?? ""), index > 0 else { continue }
            let enabled = r["enable"] == "1" && r["X_HW_ServiceEnable"] != "0"
            let fallbackBand = r["X_HW_RFBand"] ?? r["RFBand"] ?? ""
            let candidate = WifiNetwork(
                ssidIndex: index,
                name: r["ssid"] ?? "",
                band: WifiFrequencyBand.label(for: index, fallback: fallbackBand),
                enabled: enabled
            )
            if let existing = networksByIndex[index] {
                if existing.name.isEmpty && !candidate.name.isEmpty {
                    networksByIndex[index] = candidate
                } else if !existing.enabled && candidate.enabled {
                    networksByIndex[index] = WifiNetwork(
                        ssidIndex: index,
                        name: existing.name,
                        band: WifiFrequencyBand.label(for: index, fallback: fallbackBand),
                        enabled: true
                    )
                }
            } else {
                networksByIndex[index] = candidate
            }
        }
        state.networks = networksByIndex.values.sorted { $0.ssidIndex < $1.ssidIndex }
        state.radios.sort { $0.index < $1.index }
        state.networks.sort { $0.ssidIndex < $1.ssidIndex }
        return state
    }

    /// Fetches ephemeral SSID security & Wi-Fi configuration from `WlanBasic.asp`.
    /// Callers must discard returned passphrases when dismissed or backgrounded.
    public func fetchWlanBasic(bandHint: String? = nil, ssidIndex: Int? = nil) async throws -> [WifiSsidConfig] {
        let text = try await fetchWlanBasicPage()
        var pages = [text]
        if let ssidIndex {
            let configs = Self.parseWlanBasic(text)
            if !configs.contains(where: { $0.ssidIndex == ssidIndex }) {
                let suffix = (bandHint?.hasPrefix("5") == true) ? "?5G" : "?2G"
                let alt = try await fetch(.init(.get, "/html/amp/wlanbasic/WlanBasic.asp\(suffix)", ajax: false), expect: "stWlan")
                pages.append(alt)
            }
        } else {
            for suffix in ["?2G", "?5G"] {
                if let page = try? await fetch(.init(.get, "/html/amp/wlanbasic/WlanBasic.asp\(suffix)", ajax: false), expect: "stWlan") {
                    pages.append(page)
                }
            }
        }
        return Self.mergeWlanBasicConfigs(pages.map(Self.parseWlanBasic))
    }

    private static func mergeWlanBasicConfigs(_ pages: [[WifiSsidConfig]]) -> [WifiSsidConfig] {
        var byIndex: [Int: WifiSsidConfig] = [:]
        for page in pages {
            for incoming in page {
                guard let existing = byIndex[incoming.ssidIndex] else {
                    byIndex[incoming.ssidIndex] = incoming
                    continue
                }
                if existing.ssid.isEmpty && !incoming.ssid.isEmpty {
                    byIndex[incoming.ssidIndex] = incoming
                }
            }
        }
        return byIndex.values.sorted { $0.ssidIndex < $1.ssidIndex }
    }

    private func fetchWlanBasicPage(suffix: String = "") async throws -> String {
        try await fetch(.init(.get, "/html/amp/wlanbasic/WlanBasic.asp\(suffix)", ajax: false), expect: "stWlan")
    }

    /// Huawei's WLAN form carries the page-scoped token in its hidden `hwonttoken` input.
    private static func wlanPageToken(in page: String) throws -> String {
        let inputRegex = try NSRegularExpression(pattern: "(?is)<input\\b[^>]*>")
        let fullRange = NSRange(page.startIndex..<page.endIndex, in: page)
        let tokenNames: Set<String> = ["hwonttoken", "onttoken", "x.x_hw_token", "x_hw_token"]

        func attribute(_ name: String, in tag: String) -> String? {
            let escapedName = NSRegularExpression.escapedPattern(for: name)
            guard let regex = try? NSRegularExpression(
                pattern: "(?is)\\b\(escapedName)\\s*=\\s*(?:\"([^\"]*)\"|'([^']*)')"
            ), let match = regex.firstMatch(in: tag, range: NSRange(tag.startIndex..<tag.endIndex, in: tag)) else {
                return nil
            }
            for group in 1...2 {
                if let range = Range(match.range(at: group), in: tag) { return String(tag[range]) }
            }
            return nil
        }

        for match in inputRegex.matches(in: page, range: fullRange) {
            guard let range = Range(match.range, in: page) else { continue }
            let tag = String(page[range])
            let names = [attribute("id", in: tag), attribute("name", in: tag)]
                .compactMap { $0?.lowercased() }
            guard names.contains(where: tokenNames.contains),
                  let value = attribute("value", in: tag), !value.isEmpty else { continue }
            return HuaweiJs.clean(value)
        }

        if let regex = try? NSRegularExpression(
            pattern: "(?is)(?:onttoken|x\\.x_hw_token|x_hw_token)\\s*[:=]\\s*['\"]([^'\"]+)['\"]"
        ), let match = regex.firstMatch(in: page, range: fullRange),
           let range = Range(match.range(at: 1), in: page) {
            return HuaweiJs.clean(String(page[range]))
        }
        throw OntError.badResponse("WLAN page token")
    }

    private static let wlanConfigurationRoot = "InternetGatewayDevice.LANDevice.1.WLANConfiguration"
    private static let wlanBasicRequestFile = "html/amp/wlanbasic/WlanBasic.asp"

    private func checkedWifiWrite(_ request: OntRequest, token: String) async throws -> String {
        var authorizedRequest = request
        if !authorizedRequest.form.contains(where: { $0.0 == "x.X_HW_Token" }) {
            authorizedRequest.form.append(("x.X_HW_Token", token))
        }
        let response = try await sendAuthenticated(authorizedRequest)
        try Self.ensureWifiWriteAllowed(response)
        return response
    }

    private static func ensureWifiWriteAllowed(_ response: String) throws {
        let lower = response.lowercased()
        if lower.contains("err_no_right") || lower.contains("no right") {
            throw OntError.wifiModificationNotAllowed
        }
        if lower.contains("errinfo") {
            let message = Self.wifiErrorInfo(in: response)
            throw OntError.wifiWriteRejected(message.isEmpty ? "Router rejected the Wi-Fi change." : message)
        }
    }

    private static func isTransientWifiWriteError(_ error: Error) -> Bool {
        guard let url = error as? URLError else { return false }
        return [.networkConnectionLost, .timedOut, .cannotConnectToHost, .notConnectedToInternet].contains(url.code)
    }

    private static func isSecondaryIndex(_ index: Int) -> Bool {
        WifiFrequencyBand.allCases.contains { $0.secondaryIndices.contains(index) }
    }

    private static func band(for index: Int) -> WifiFrequencyBand? {
        guard (1...8).contains(index) else { return nil }
        return index <= 4 ? .twoPointFour : .five
    }

    private static func wifiSetRequest(index: Int, fields: [(String, String)], token: String) -> OntRequest {
        let domain = "\(wlanConfigurationRoot).\(index)"
        return OntRequest(
            .post,
            "/html/amp/wlanbasic/set.cgi?x=\(domain)&y=\(domain).PreSharedKey.1&RequestFile=\(wlanBasicRequestFile)",
            form: fields + [("x.X_HW_Token", token)],
            ajax: false,
            timeoutInterval: 2.0
        )
    }

    private static func wifiErrorInfo(in response: String) -> String {
        guard let regex = try? NSRegularExpression(
            pattern: "(?is)errinfo\\s*[:=]\\s*['\"]?([^'\";<>\\r\\n]+)"
        ), let match = regex.firstMatch(in: response, range: NSRange(response.startIndex..<response.endIndex, in: response)),
           let range = Range(match.range(at: 1), in: response) else { return "" }
        return HuaweiJs.clean(String(response[range])).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func parseWlanBasic(_ text: String) -> [WifiSsidConfig] {
        let wlanParams = [
            "domain", "name", "enable", "ssid", "wlHide", "DeviceNum", "wmmEnable",
            "BeaconType", "BasicEncryptionModes", "BasicAuthenticationMode",
            "KeyIndex", "EncryptionLevel",
            "WPAEncryptionModes", "WPAAuthenticationMode",
            "IEEE11iEncryptionModes", "IEEE11iAuthenticationMode",
            "X_HW_WPAand11iEncryptionModes", "X_HW_WPAand11iAuthenticationMode",
            "WPARekey", "RadiusServer", "RadiusPort", "RadiusKey",
            "X_HW_ServiceEnable", "LowerLayers",
            "X_HW_WAPIEncryptionModes", "X_HW_WAPIAuthenticationMode",
            "X_HW_WAPIServer", "X_HW_WAPIPort", "X_HW_WPSConfigurated",
            "UAPSDEnable", "IsolationEnable"
        ]
        let wifiParams = ["domain", "name", "enable", "ssid", "mode", "channel", "power", "Country", "AutoChannelEnable", "channelWidth"]
        let pskParams = ["domain", "psk", "kpp"]
        let wpsParams = ["domain", "X_HW_ConfigMethod", "DevicePassword", "X_HW_PinGenerator", "Enable"]

        let kppUsed = HuaweiJs.stringVar("kppUsedFlag", in: text) == "1"
        let passwordMask = HuaweiJs.stringVar("wifiPasswordMask", in: text) == "1"

        func wlanIndex(from domain: String) -> Int? {
            if let r = domain.range(of: "WLANConfiguration.") {
                let tail = domain[r.upperBound...]
                let digits = tail.prefix { $0.isNumber }
                return Int(digits)
            }
            return Int(domain.split(separator: ".").last ?? "")
        }

        var modesByIndex: [Int: String] = [:]
        for r in HuaweiJs.records(of: "stWlanWifi", in: text, fallbackParams: wifiParams) {
            guard let idx = wlanIndex(from: r["domain"] ?? ""), let mode = r["mode"], !mode.isEmpty else { continue }
            modesByIndex[idx] = mode
        }

        var pskByIndex: [Int: String] = [:]
        for r in HuaweiJs.records(of: "stPreSharedKey", in: text, fallbackParams: pskParams) {
            guard let idx = wlanIndex(from: r["domain"] ?? "") else { continue }
            let primary = r["psk"] ?? r["value"] ?? ""
            let kpp = r["kpp"] ?? ""
            pskByIndex[idx] = (kppUsed && !kpp.isEmpty) ? kpp : primary
        }

        var wpsByIndex: [Int: [String: String]] = [:]
        for r in HuaweiJs.records(of: "stWpsPin", in: text, fallbackParams: wpsParams) {
            guard let idx = wlanIndex(from: r["domain"] ?? "") else { continue }
            wpsByIndex[idx] = r
        }

        var result: [WifiSsidConfig] = []
        var seen = Set<Int>()
        for r in HuaweiJs.records(of: "stWlan", in: text, fallbackParams: wlanParams) {
            let domain = r["domain"] ?? ""
            guard let idx = wlanIndex(from: domain), seen.insert(idx).inserted else { continue }
            let psk = pskByIndex[idx] ?? ""
            let masked = passwordMask && psk == "********"
            let wps = wpsByIndex[idx]
            result.append(WifiSsidConfig(
                ssidIndex: idx,
                domain: domain,
                interfaceName: r["name"] ?? "",
                enable: r["enable"] ?? "",
                ssid: r["ssid"] ?? "",
                wlHide: r["wlHide"] ?? "",
                deviceNum: r["DeviceNum"] ?? "",
                wmmEnable: r["wmmEnable"] ?? "",
                beaconType: r["BeaconType"] ?? "",
                basicAuthenticationMode: r["BasicAuthenticationMode"] ?? "",
                basicEncryptionModes: r["BasicEncryptionModes"] ?? "",
                keyIndex: r["KeyIndex"] ?? "",
                encryptionLevel: r["EncryptionLevel"] ?? "",
                wpaEncryptionModes: r["WPAEncryptionModes"] ?? "",
                wpaAuthenticationMode: r["WPAAuthenticationMode"] ?? "",
                ieee11iEncryptionModes: r["IEEE11iEncryptionModes"] ?? "",
                ieee11iAuthenticationMode: r["IEEE11iAuthenticationMode"] ?? "",
                mixEncryptionModes: r["X_HW_WPAand11iEncryptionModes"] ?? "",
                mixAuthenticationMode: r["X_HW_WPAand11iAuthenticationMode"] ?? "",
                wpaRekey: r["WPARekey"] ?? "",
                serviceEnable: r["X_HW_ServiceEnable"] ?? "1",
                lowerLayers: r["LowerLayers"] ?? "",
                standard: modesByIndex[idx] ?? "",
                psk: psk,
                isPasswordMasked: masked,
                wpsEnable: wps?["Enable"] ?? "",
                wpsConfigMethod: wps?["X_HW_ConfigMethod"] ?? "",
                wpsPinGenerator: wps?["X_HW_PinGenerator"] ?? "",
                wpsDevicePassword: wps?["DevicePassword"] ?? "",
                hasWlanWifiRecord: modesByIndex[idx] != nil,
                hasPskRecord: pskByIndex[idx] != nil,
                hasWpsRecord: wps != nil
            ))
        }
        result.sort { $0.ssidIndex < $1.ssidIndex }
        return result
    }

    public func addWifiNetwork(
        band: WifiFrequencyBand,
        ssid: String,
        password: String,
        isVisible: Bool
    ) async throws -> WifiUpdateResult {
        try Self.validateWifiCredentials(ssid: ssid, password: password)
        let initialConfigs = try await fetchWlanBasic()
        guard !initialConfigs.contains(where: {
            Self.band(for: $0.ssidIndex) == band && $0.ssid.caseInsensitiveCompare(ssid) == .orderedSame
        }) else {
            throw OntError.badResponse("Wi-Fi network name already exists on this band")
        }

        let pageSuffix = band == .twoPointFour ? "?2G" : "?5G"
        let latestPage = try await fetchWlanBasicPage(suffix: pageSuffix)
        let latestConfigs = Self.parseWlanBasic(latestPage)
        let allConfigs = Self.mergeWlanBasicConfigs([initialConfigs, latestConfigs])
        let occupied = Set(allConfigs.filter {
            band.wlanIndices.contains($0.ssidIndex) && !$0.ssid.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }.map(\.ssidIndex))
        guard let targetIndex = band.secondaryIndices.first(where: { !occupied.contains($0) }) else {
            throw OntError.wifiSlotLimitReached
        }
        let token = try Self.wlanPageToken(in: latestPage)
        let write = Self.wifiSetRequest(index: targetIndex, fields: [
            ("x.Enable", "1"),
            ("x.SSID", ssid),
            ("x.SSIDAdvertisementEnabled", isVisible ? "1" : "0"),
            ("x.BeaconType", "11i"),
            ("x.BasicAuthenticationMode", "None"),
            ("x.BasicEncryptionModes", "None"),
            ("x.WPAEncryptionModes", "AESEncryption"),
            ("x.WPAAuthenticationMode", "PSKAuthentication"),
            ("x.IEEE11iEncryptionModes", "AESEncryption"),
            ("x.IEEE11iAuthenticationMode", "PSKAuthentication"),
            ("x.X_HW_WPAand11iEncryptionModes", "AESEncryption"),
            ("x.X_HW_WPAand11iAuthenticationMode", "PSKAuthentication"),
            ("y.PreSharedKey", password)
        ], token: token)
        do {
            _ = try await checkedWifiWrite(write, token: token)
        } catch let error as URLError where Self.isTransientWifiWriteError(error) {
            return WifiUpdateResult(wifi: nil, connectionDropped: true)
        }
        return WifiUpdateResult(wifi: nil, connectionDropped: true)
    }

    public func setWifiNetworkEnabled(ssidIndex: Int, enabled: Bool) async throws -> WifiUpdateResult {
        guard Self.isSecondaryIndex(ssidIndex) else { throw OntError.badResponse("primary Wi-Fi network is protected") }
        let configs = try await fetchWlanBasic()
        guard let config = configs.first(where: { $0.ssidIndex == ssidIndex }), !config.ssid.isEmpty else {
            throw OntError.badResponse("Wi-Fi network")
        }
        let bandSuffix = ssidIndex <= 4 ? "?2G" : "?5G"
        let page = try await fetchWlanBasicPage(suffix: bandSuffix)
        let token = try Self.wlanPageToken(in: page)
        let request = Self.wifiSetRequest(index: ssidIndex, fields: [
            ("x.Enable", enabled ? "1" : "0")
        ], token: token)
        do {
            _ = try await checkedWifiWrite(request, token: token)
        } catch let error as URLError where Self.isTransientWifiWriteError(error) {
            return WifiUpdateResult(wifi: nil, connectionDropped: true)
        }
        return WifiUpdateResult(wifi: nil, connectionDropped: true)
    }

    public func deleteWifiNetwork(ssidIndex: Int) async throws -> WifiUpdateResult {
        guard Self.isSecondaryIndex(ssidIndex) else { throw OntError.badResponse("primary Wi-Fi network is protected") }
        let configs = try await fetchWlanBasic()
        guard configs.contains(where: { $0.ssidIndex == ssidIndex && !$0.ssid.isEmpty }) else {
            throw OntError.badResponse("Wi-Fi network")
        }
        let bandSuffix = ssidIndex <= 4 ? "?2G" : "?5G"
        let page = try await fetchWlanBasicPage(suffix: bandSuffix)
        let token = try Self.wlanPageToken(in: page)
        let request = Self.wifiSetRequest(index: ssidIndex, fields: [
            ("x.Enable", "0"),
            ("x.SSID", ""),
            ("x.SSIDAdvertisementEnabled", "0")
        ], token: token)
        do {
            _ = try await checkedWifiWrite(request, token: token)
        } catch let error as URLError where Self.isTransientWifiWriteError(error) {
            return WifiUpdateResult(wifi: nil, connectionDropped: true)
        }
        return WifiUpdateResult(wifi: nil, connectionDropped: true)
    }

    /// Turns a whole radio (2.4 GHz = 1, 5 GHz = 2) on or off, like the Wi-Fi page's switch.
    /// Refuses to switch off the last radio that is on, which would cut every Wi-Fi device off.
    public func setRadio(_ index: Int, enabled: Bool) async throws -> WifiState {
        let before = try await fetchWifi()
        guard let radio = before.radios.first(where: { $0.index == index }) else { throw OntError.badResponse("Wi-Fi radio") }
        if radio.enabled == enabled { return before }
        if !enabled && !before.radios.contains(where: { $0.index != index && $0.enabled }) {
            throw OntError.lastRadio
        }
        let page = try await fetchWlanBasicPage()
        let token = try Self.wlanPageToken(in: page)
        let flag = enabled ? "1" : "0"
        let request = OntRequest(.post,
            "/html/amp/wlanbasic/set.cgi?x=InternetGatewayDevice.X_HW_DEBUG.AMP.SetWifiCoverEnable"
                + "&y=InternetGatewayDevice.LANDevice.1.WiFi.Radio.\(index)&RequestFile=html/amp/wlanbasic/WlanBasic.asp",
            form: [("x.Enable", flag), ("x.RadioInst", String(index)), ("y.Enable", flag), ("x.X_HW_Token", token)],
            ajax: false,
            timeoutInterval: 2.0
        )
        do {
            _ = try await sendAuthenticated(request)
        } catch let error as URLError where Self.isTransientWifiWriteError(error) {
            // A successful radio change can interrupt its own response. Continue to read back.
        }
        // The radio restarts; read back until it reports the new state.
        for _ in 0..<6 {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            if let now = try? await fetchWifi(), now.radios.first(where: { $0.index == index })?.enabled == enabled {
                return now
            }
        }
        throw OntError.notConfirmed
    }

    public static func validateWifiCredentials(ssid: String, password: String) throws {
        let hasText = !ssid.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let ssidBytes = ssid.utf8.count
        let ssidPrintable = ssid.unicodeScalars.allSatisfy { $0.value >= 0x20 && $0.value != 0x7F }
        guard hasText, ssidBytes >= 1, ssidBytes <= 32, ssidPrintable else {
            throw OntError.invalidWifiSsid
        }
        let pwdAscii = password.unicodeScalars.allSatisfy { $0.value >= 0x20 && $0.value <= 0x7E }
        guard password.count >= 8, password.count <= 63, pwdAscii else {
            throw OntError.invalidWifiPassword
        }
    }

    /// Builds the exact `#704` POST request from parsed `WlanBasic.asp` configuration, preserving field order
    /// and setting the 4 user-controlled fields (`y.SSID`, `w.SSID`, `k.PreSharedKey`, `w.Key`).
    static func wifiEditRequest(
        config: WifiSsidConfig,
        newSsid: String,
        newPassword: String,
        token: String
    ) throws -> OntRequest {
        guard config.authMode.isEditableWpa2Or3Psk else {
            throw OntError.unsupportedWifiSecurity(config.authMode.displayName)
        }
        let missing = config.missingEditFields
        guard missing.isEmpty else {
            throw OntError.incompleteWifiConfig(missing)
        }
        try validateWifiCredentials(ssid: newSsid, password: newPassword)

        let domain = config.domain
        let ssidInst = String(config.ssidIndex)
        let encryptionMode = config.ieee11iEncryptionModes
        let ieeeAuth = config.ieee11iAuthenticationMode

        let path = "/html/amp/wlanbasic/set.cgi"
            + "?c1=InternetGatewayDevice.X_HW_DEBUG.WLANConfigAction"
            + "&w=InternetGatewayDevice.X_HW_DEBUG.AMP.WifiCoverSetWlanBasic"
            + "&y=\(domain)"
            + "&z=\(domain).WPS"
            + "&k=\(domain).PreSharedKey.1"
            + "&c2=InternetGatewayDevice.X_HW_DEBUG.WLANConfigAction"
            + "&RequestFile=html/amp/wlanbasic/WlanBasic.asp"

        let form: [(String, String)] = [
            ("y.Enable", config.enable),
            ("y.SSIDAdvertisementEnabled", config.wlHide),
            ("y.SSID", newSsid),
            ("y.X_HW_AssociateNum", config.deviceNum),
            ("y.BeaconType", config.beaconType),
            ("y.IEEE11iAuthenticationMode", ieeeAuth),
            ("y.IEEE11iEncryptionModes", encryptionMode),
            ("k.PreSharedKey", newPassword),
            ("y.X_HW_GroupRekey", config.wpaRekey),
            ("z.Enable", config.wpsEnable),
            ("z.X_HW_ConfigMethod", config.wpsConfigMethod),
            ("z.X_HW_PinGenerator", config.wpsPinGenerator),
            ("z.DevicePassword", config.wpsDevicePassword),
            ("w.SsidInst", ssidInst),
            ("w.SSID", newSsid),
            ("w.Enable", config.enable),
            ("w.Standard", config.standard),
            ("w.BasicAuthenticationMode", config.basicAuthenticationMode),
            ("w.BasicEncryptionModes", config.basicEncryptionModes),
            ("w.WPAAuthenticationMode", config.wpaAuthenticationMode),
            ("w.WPAEncryptionModes", config.wpaEncryptionModes),
            ("w.IEEE11iAuthenticationMode", ieeeAuth),
            ("w.IEEE11iEncryptionModes", encryptionMode),
            ("w.MixAuthenticationMode", config.mixAuthenticationMode),
            ("w.MixEncryptionModes", config.mixEncryptionModes),
            ("w.SSIDAdvertisementEnabled", config.wlHide),
            ("w.WMMEnable", config.wmmEnable),
            ("w.MaxAssociateNum", config.deviceNum),
            ("w.BeaconType", config.beaconType),
            ("w.WEPEncryptionLevel", config.encryptionLevel),
            ("w.WEPKeyIndex", config.keyIndex),
            ("w.Key", newPassword),
            ("c1.ActionType", "0"),
            ("c2.ActionType", "1"),
            ("c2.SSIDList", ssidInst),
            ("x.X_HW_Token", token)
        ]
        return OntRequest(.post, path, form: form, ajax: false, timeoutInterval: 2.0)
    }

    /// Saves an SSID name and passphrase (`#704`) and re-reads `wlan_list.asp`, handling expected Wi-Fi drops gracefully.
    public func updateWifiCredentials(
        config: WifiSsidConfig,
        newSsid: String,
        newPassword: String
    ) async throws -> WifiUpdateResult {
        _ = try Self.wifiEditRequest(config: config, newSsid: newSsid, newPassword: newPassword, token: "validate")
        let page = try await fetchWlanBasicPage()
        let token = try Self.wlanPageToken(in: page)
        let request = try Self.wifiEditRequest(config: config, newSsid: newSsid, newPassword: newPassword, token: token)
        do {
            _ = try await sendAuthenticated(request)
        } catch let url as URLError where [.networkConnectionLost, .timedOut, .cannotConnectToHost, .notConnectedToInternet].contains(url.code) {
            return WifiUpdateResult(wifi: nil, connectionDropped: true)
        }
        do {
            let refreshed = try await fetchWifi()
            return WifiUpdateResult(wifi: refreshed, connectionDropped: false)
        } catch {
            return WifiUpdateResult(wifi: nil, connectionDropped: true)
        }
    }

    // MARK: LAN

    public func fetchLan() async throws -> LanInfo {
        let text = try await fetch(.init(.get, "/html/bbsp/dhcpservercfg/dhcp2.asp", ajax: false), expect: "dhcpmainst")
        return Self.parseLan(text)
    }

    static func parseLan(_ text: String) -> LanInfo {
        var lan = LanInfo()
        let interfaces = HuaweiJs.records(of: "stipaddr", in: text)
        if let ip = interfaces.first(where: { ($0["domain"] ?? "").contains("IPInterface.1") }) ?? interfaces.first {
            lan.routerIp = ip["ipaddr"] ?? ""
            lan.subnetMask = ip["subnetmask"] ?? ""
        }
        if let ip2 = interfaces.first(where: {
            ($0["domain"] ?? "").contains("IPInterface.2") && $0["enable"] != "0" && !($0["ipaddr"] ?? "").isEmpty
        }) {
            lan.secondaryIp = ip2["ipaddr"] ?? ""
        }
        if let d = HuaweiJs.records(of: "dhcpmainst", in: text).first(where: { ($0["startip"] ?? "").contains(".") }) {
            lan.dhcpEnabled = d["enable"] == "1"
            lan.poolStart = d["startip"] ?? ""
            lan.poolEnd = d["endip"] ?? ""
            lan.leaseSeconds = Int(d["leasetime"] ?? "") ?? 0
            let dns = (d["MainDNS"].flatMap { $0.isEmpty ? nil : $0 } ?? d["DNSServers"] ?? "")
            lan.dnsServers = dns.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        }
        return lan
    }

    static let userDeviceParams = ["Domain", "IpAddr", "MacAddr", "Port", "IpType", "DevType", "DevStatus", "PortType",
                                   "Time", "HostName", "IPv4Enabled", "IPv6Enabled", "DeviceType", "UserDevAlias",
                                   "UserSpecifiedDeviceType", "LeaseTimeRemaining", "TrafficSendRate", "TrafficRecvRate"]

    static let userDeviceNewParams = ["Domain", "IpAddr", "MacAddr", "Port", "IpType", "DevType", "DevStatus", "PortType",
                                      "Time", "HostName", "IPv4Enabled", "IPv6Enabled", "DeviceType", "UserDevAlias",
                                      "UserSpecifiedDeviceType", "LeaseTimeRemaining", "RealMacAddr"]

    static let dhcpInfoParams = ["domain", "name", "ip", "mac", "remaintime", "devtype", "interfacetype",
                                 "AddressSource", "ConnectedTime"]

    private static func cleanPlaceholder(_ raw: String?) -> String {
        let trimmed = (raw ?? "").trimmingCharacters(in: .whitespaces)
        return trimmed == "--" ? "" : trimmed
    }

    private static func parseNonZeroRate(_ raw: String?) -> Int? {
        guard let raw = raw?.trimmingCharacters(in: .whitespaces),
              let value = Int(raw), value > 0 else { return nil }
        return value
    }

    private static func normalizedMac(_ raw: String?) -> String {
        (raw ?? "").lowercased().filter { "0123456789abcdef".contains($0) }
    }

    /// Reads RSSI fields from any router record that also identifies a client MAC. Huawei firmware
    /// varies the associated-station record name, so inspect constructor field names instead of
    /// depending on one endpoint-specific class name.
    private static func wifiSignalByMac(in text: String) -> [String: Double] {
        var result: [String: Double] = [:]
        let definitions = HuaweiJs.definitions(in: text)
        for (recordName, fields) in definitions {
            let macField = fields.first { field in
                let key = field.lowercased().filter(\.isLetter)
                return key.contains("mac") && (key.contains("addr") || key == "mac")
            }
            let signalFields = fields.filter { field in
                let key = field.lowercased().filter(\.isLetter)
                return key.contains("rssi") || key.contains("signal")
            }
            guard let macField, !signalFields.isEmpty else { continue }

            for record in HuaweiJs.records(of: recordName, in: text) {
                guard let mac = record[macField], !normalizedMac(mac).isEmpty,
                      let rssi = parseRssiDbm(in: record, keys: signalFields) else { continue }
                result[normalizedMac(mac)] = rssi
            }
        }
        return result
    }

    private static func parseRssiDbm(in record: [String: String], keys: [String]? = nil) -> Double? {
        let candidates = keys ?? record.keys.filter { key in
            let normalized = key.lowercased().filter(\.isLetter)
            return normalized.contains("rssi") || normalized.contains("signal")
        }
        for key in candidates {
            guard let raw = record[key]?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { continue }
            let pattern = #"-?\d+(?:\.\d+)?"#
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(in: raw, range: NSRange(raw.startIndex..., in: raw)),
                  let range = Range(match.range, in: raw),
                  let value = Double(raw[range]),
                  value <= 0, value >= -120 else { continue }
            return value
        }
        return nil
    }

    /// All known devices, online first, de-duplicated by MAC (the page lists some twice).
    /// Supports both 18-arg `USERDevice` (checked first so traffic rates are kept) and 17-arg `USERDeviceNew`.
    /// `ssidBands` maps SSID index to band from the Wi-Fi list; without it bands are guessed.
    static func parseDevices(_ text: String, ssidBands: [Int: String] = [:]) -> [OntDevice] {
        var seen = Set<String>()
        var devices: [OntDevice] = []
        let signalByMac = wifiSignalByMac(in: text)
        let candidates = HuaweiJs.records(of: "USERDevice", in: text, fallbackParams: userDeviceParams)
            + HuaweiJs.records(of: "USERDeviceNew", in: text, fallbackParams: userDeviceNewParams)

        for r in candidates {
            let primaryMac = cleanPlaceholder(r["MacAddr"]).lowercased()
            let fallbackMac = cleanPlaceholder(r["RealMacAddr"]).lowercased()
            let mac = primaryMac.isEmpty ? fallbackMac : primaryMac
            guard !mac.isEmpty, seen.insert(mac).inserted else { continue }

            let rawType = cleanPlaceholder(r["UserSpecifiedDeviceType"])
            let lease = Int(r["LeaseTimeRemaining"] ?? "").flatMap { $0 > 0 ? $0 : nil }
            let rawPort = cleanPlaceholder(r["Port"])
            let interfaceType = [r["PortType"], r["InterfaceType"], r["interfacetype"]]
                .compactMap { $0 }
                .map { cleanPlaceholder($0) }
                .first(where: { !$0.isEmpty }) ?? ""

            devices.append(OntDevice(
                domain: r["Domain"] ?? "",
                mac: mac,
                ip: cleanPlaceholder(r["IpAddr"]),
                hostName: cleanPlaceholder(r["HostName"]),
                routerAlias: cleanPlaceholder(r["UserDevAlias"]),
                dhcpVendor: cleanPlaceholder(r["DevType"]),
                port: ConnectionPort(raw: rawPort, ssidBands: ssidBands, fallbackRaw: interfaceType),
                isOnline: (r["DevStatus"] ?? "").lowercased() == "online",
                connectedTime: r["Time"] ?? "",
                userSpecifiedDeviceType: rawType.isEmpty ? "0" : rawType,
                trafficSendRate: parseNonZeroRate(r["TrafficSendRate"]),
                trafficRecvRate: parseNonZeroRate(r["TrafficRecvRate"]),
                leaseSecondsRemaining: lease,
                rssiDbm: parseRssiDbm(in: r) ?? signalByMac[normalizedMac(mac)]
            ))
        }
        return devices.sorted { a, b in
            if a.isOnline != b.isOnline { return a.isOnline }
            return a.ip.localizedStandardCompare(b.ip) == .orderedAscending
        }
    }

    /// Enriches parsed devices with hostname, DHCP vendor class, IP, or lease remaining from `GetLanUserDhcpInfo.asp`.
    static func enrichDevices(_ devices: [OntDevice], withDhcpInfo text: String) -> [OntDevice] {
        var byMac: [String: [String: String]] = [:]
        for r in HuaweiJs.records(of: "DHCPInfo", in: text, fallbackParams: dhcpInfoParams) {
            let mac = cleanPlaceholder(r["mac"]).lowercased()
            guard !mac.isEmpty, byMac[mac] == nil else { continue }
            byMac[mac] = r
        }
        guard !byMac.isEmpty else { return devices }
        return devices.map { device in
            guard let lease = byMac[device.mac] else { return device }
            var copy = device
            if copy.hostName.isEmpty { copy.hostName = cleanPlaceholder(lease["name"]) }
            if copy.dhcpVendor.isEmpty { copy.dhcpVendor = cleanPlaceholder(lease["devtype"]) }
            if copy.ip.isEmpty { copy.ip = cleanPlaceholder(lease["ip"]) }
            if copy.leaseSecondsRemaining == nil,
               let rem = Int(lease["remaintime"] ?? ""), rem > 0 {
                copy.leaseSecondsRemaining = rem
            }
            return copy
        }
    }

    // MARK: Actions

    public func reboot() async throws {
        let token = try await freshTokenLoggingIn()
        // Same request the web UI's "Restart" button submits from the main page.
        _ = try await sendAuthenticated(.init(.post,
            "/CustomApp/set.cgi?x=InternetGatewayDevice.X_HW_DEBUG.SMP.DM.ResetBoard&RequestFile=../CustomApp/mainpage.asp",
            form: [("x.X_HW_Token", token)], ajax: false))
        await invalidateSession()
        lastCounters = nil
    }

    private func freshTokenLoggingIn() async throws -> String {
        let request = OntRequest(.post, "/html/ssmp/common/GetRandToken.asp")
        for attempt in 0..<2 {
            let token = HuaweiJs.clean(try await sendAuthenticated(request))
            if !token.isEmpty && !token.contains("<") { return token }
            if attempt == 1 { throw OntError.sessionExpired }
            let generation = await authCoordinator.currentGeneration()
            await invalidateSession(ifGeneration: generation)
        }
        throw OntError.sessionExpired
    }

    private func invalidateSession() async {
        loggedIn = false
        await authCoordinator.invalidateSession()
    }

    private func invalidateSession(ifGeneration generation: UInt64) async {
        if await authCoordinator.invalidateSession(ifGeneration: generation) {
            loggedIn = false
        }
    }
}

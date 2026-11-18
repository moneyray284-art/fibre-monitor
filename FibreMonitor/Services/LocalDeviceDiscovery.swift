import Combine
import Foundation
import Network

/// Keeps friendly names learned from local Bonjour/SSDP advertisements across router refreshes.
@MainActor
public final class DiscoveredDeviceNameStore: ObservableObject {
    public static let shared = DiscoveredDeviceNameStore()

    @Published private var namesByNormalizedMAC: [String: String]

    private let defaults = UserDefaults.standard
    private let storageKey = "linkwave.discovered_device_names.v1"

    private init() {
        namesByNormalizedMAC = UserDefaults.standard.dictionary(forKey: storageKey) as? [String: String] ?? [:]
    }

    public func name(for mac: String) -> String? {
        guard let key = Self.normalizedMAC(mac) else { return nil }
        let name = namesByNormalizedMAC[key]
        return DeviceNameResolver.isUsefulName(name ?? "") ? name : nil
    }

    fileprivate func remember(_ name: String, for mac: String) {
        guard let key = Self.normalizedMAC(mac) else { return }
        let cleaned = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard DeviceNameResolver.isUsefulName(cleaned) else { return }
        guard namesByNormalizedMAC[key] != cleaned else { return }
        namesByNormalizedMAC[key] = cleaned
        defaults.set(namesByNormalizedMAC, forKey: storageKey)
    }

    fileprivate nonisolated static func normalizedMAC(_ mac: String) -> String? {
        let hex = mac.lowercased().filter(\.isHexDigit)
        return hex.count == 12 ? hex : nil
    }
}

/// A short, rate-limited discovery pass. Bonjour resolution uses system DNS-SD; SSDP probes
/// currently-online client IPs by unicast so this works without a multicast entitlement.
@MainActor
public final class LocalDeviceNameDiscovery {
    public static let shared = LocalDeviceNameDiscovery()

    private static let bonjourTypes = [
        "_companion-link._tcp",
        "_airplay._tcp",
        "_hap._tcp",
        "_googlecast._tcp",
        "_smb._tcp",
        "_ipp._tcp",
        "_http._tcp"
    ]

    private let queue = DispatchQueue(label: "com.linkwave.device-discovery", qos: .utility)
    private var browsers: [NWBrowser] = []
    private var connections: [NWConnection] = []
    private var scanTimeout: Task<Void, Never>?
    private var scanID: UUID?
    private var onlineMACByIP: [String: String] = [:]
    private var seenBonjourEndpoints = Set<String>()
    private var lastScanAt = Date.distantPast
    private var lastAddressSignature = ""
    private var isScanning = false

    private init() {}

    public func scan(devices: [OntDevice], gatewayHost: String?, force: Bool = false) {
        guard NetworkMonitor.shared.isConnectedToWiFi, !isScanning else { return }

        let online = devices.filter { $0.isOnline && Self.isIPv4($0.ip) }
        guard !online.isEmpty else { return }

        let now = Date()
        let signature = online.map { "\($0.mac.lowercased())@\($0.ip)" }.sorted().joined(separator: "|")
        guard force || signature != lastAddressSignature || now.timeIntervalSince(lastScanAt) >= 30 else { return }
        guard force || now.timeIntervalSince(lastScanAt) >= 8 else { return }

        lastScanAt = now
        lastAddressSignature = signature
        onlineMACByIP = Dictionary(online.map { (Self.normalizedIP($0.ip), $0.mac) }, uniquingKeysWith: { first, _ in first })
        seenBonjourEndpoints.removeAll(keepingCapacity: true)
        let generation = UUID()
        scanID = generation
        isScanning = true

        for type in Self.bonjourTypes {
            beginBonjourBrowse(type: type, generation: generation)
        }

        // SSDP replies are unicast to the requesting socket. Probe only known online client
        // addresses, never the whole LAN, and keep this pass bounded to the same short window.
        var ssdpTargets = Array(onlineMACByIP.keys.prefix(24))
        if let gatewayHost, Self.isIPv4(gatewayHost) {
            ssdpTargets.append(Self.normalizedIP(gatewayHost))
        }
        for ip in Set(ssdpTargets) {
            beginSSDPProbe(ip: ip, generation: generation)
        }

        scanTimeout = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_600_000_000)
            guard !Task.isCancelled else { return }
            self?.finishScan(generation: generation)
        }
    }

    private func beginBonjourBrowse(type: String, generation: UUID) {
        let browser = NWBrowser(for: .bonjour(type: type, domain: nil), using: .tcp)
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            let endpoints: [(NWEndpoint, String)] = results.compactMap { result in
                guard case let .service(name, _, _, _) = result.endpoint else { return nil }
                return (result.endpoint, name)
            }
            Task { @MainActor [weak self] in
                self?.resolveBonjour(endpoints, generation: generation)
            }
        }
        browser.start(queue: queue)
        browsers.append(browser)
    }

    private func resolveBonjour(_ endpoints: [(NWEndpoint, String)], generation: UUID) {
        guard scanID == generation else { return }
        for (endpoint, name) in endpoints {
            let key = endpoint.debugDescription
            guard seenBonjourEndpoints.insert(key).inserted else { continue }

            let connection = NWConnection(to: endpoint, using: .tcp)
            connection.stateUpdateHandler = { [weak self, weak connection] state in
                guard case .ready = state, let connection else { return }
                guard let remoteEndpoint = connection.currentPath?.remoteEndpoint,
                      case let .hostPort(host, _) = remoteEndpoint,
                      case let .ipv4(address) = host else {
                    connection.cancel()
                    return
                }
                let ip = address.debugDescription
                Task { @MainActor [weak self] in
                    self?.remember(name, at: ip, generation: generation)
                }
                connection.cancel()
            }
            connection.start(queue: queue)
            connections.append(connection)
        }
    }

    private func beginSSDPProbe(ip: String, generation: UUID) {
        guard let port = NWEndpoint.Port(rawValue: 1900) else { return }
        let endpoint = NWEndpoint.hostPort(host: .name(ip, nil), port: port)
        let connection = NWConnection(to: endpoint, using: .udp)
        let request = Data(
            "M-SEARCH * HTTP/1.1\r\nHOST: 239.255.255.250:1900\r\nMAN: \"ssdp:discover\"\r\nMX: 1\r\nST: ssdp:all\r\n\r\n".utf8
        )

        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard case .ready = state, let connection else { return }
            connection.send(
                content: request,
                contentContext: .defaultMessage,
                isComplete: true,
                completion: .contentProcessed { _ in }
            )
            Task { @MainActor [weak self, weak connection] in
                guard let connection else { return }
                self?.receiveSSDP(on: connection, targetIP: ip, generation: generation)
            }
        }
        connection.start(queue: queue)
        connections.append(connection)
    }

    private func receiveSSDP(on connection: NWConnection, targetIP: String, generation: UUID) {
        connection.receiveMessage { [weak self, weak connection] data, _, _, error in
            guard let data, !data.isEmpty else { return }
            Task { @MainActor [weak self] in
                await self?.handleSSDP(data, targetIP: targetIP, generation: generation)
            }
            guard error == nil, let connection, connection.state == .ready else { return }
            Task { @MainActor [weak self, weak connection] in
                guard let connection else { return }
                self?.receiveSSDP(on: connection, targetIP: targetIP, generation: generation)
            }
        }
    }

    private func handleSSDP(_ data: Data, targetIP: String, generation: UUID) async {
        guard scanID == generation else { return }
        let response = String(decoding: data, as: UTF8.self)
        guard let location = Self.header("LOCATION", in: response),
              let url = URL(string: location),
              url.scheme?.hasPrefix("http") == true else { return }

        let friendlyName = await Self.fetchFriendlyName(from: url)
        guard scanID == generation, let friendlyName else { return }
        let locationIP = url.host.map(Self.normalizedIP) ?? ""
        let matchIP = onlineMACByIP[targetIP] != nil ? targetIP : locationIP
        remember(friendlyName, at: matchIP, generation: generation)
    }

    private func remember(_ name: String, at ip: String, generation: UUID) {
        guard scanID == generation,
              let mac = onlineMACByIP[Self.normalizedIP(ip)] else { return }
        DiscoveredDeviceNameStore.shared.remember(name, for: mac)
    }

    private func finishScan(generation: UUID) {
        guard scanID == generation else { return }
        scanTimeout?.cancel()
        scanTimeout = nil
        scanID = nil
        isScanning = false
        browsers.forEach { $0.cancel() }
        connections.forEach { $0.cancel() }
        browsers.removeAll()
        connections.removeAll()
        onlineMACByIP.removeAll()
        seenBonjourEndpoints.removeAll()
    }

    private static func header(_ name: String, in response: String) -> String? {
        for line in response.components(separatedBy: .newlines) {
            guard let separator = line.firstIndex(of: ":"),
                  line[..<separator].trimmingCharacters(in: .whitespaces).caseInsensitiveCompare(name) == .orderedSame else {
                continue
            }
            let value = line[line.index(after: separator)...].trimmingCharacters(in: .whitespacesAndNewlines)
            return value.isEmpty ? nil : value
        }
        return nil
    }

    private static func fetchFriendlyName(from url: URL) async -> String? {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 1.2
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  data.count <= 128_000 else { return nil }
            let delegate = SSDPFriendlyNameParser()
            let parser = XMLParser(data: data)
            parser.delegate = delegate
            guard parser.parse() else { return nil }
            let name = delegate.name.trimmingCharacters(in: .whitespacesAndNewlines)
            return DeviceNameResolver.isUsefulName(name) ? name : nil
        } catch {
            return nil
        }
    }

    private static func normalizedIP(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
    }

    private static func isIPv4(_ value: String) -> Bool {
        let parts = normalizedIP(value).split(separator: ".")
        return parts.count == 4 && parts.allSatisfy { part in
            guard let octet = Int(part) else { return false }
            return (0...255).contains(octet)
        }
    }
}

private final class SSDPFriendlyNameParser: NSObject, XMLParserDelegate {
    private(set) var name = ""
    private var isReadingFriendlyName = false

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        isReadingFriendlyName = elementName.caseInsensitiveCompare("friendlyName") == .orderedSame
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if isReadingFriendlyName { name += string }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        if elementName.caseInsensitiveCompare("friendlyName") == .orderedSame { isReadingFriendlyName = false }
    }
}

public enum DeviceNameResolver {
    private static let ouiVendors: [String: String] = [
        "000393": "Apple", "000A27": "Apple", "000A95": "Apple", "0010FA": "Apple",
        "001451": "Apple", "0016CB": "Apple", "0017F2": "Apple", "001B63": "Apple",
        "001E52": "Apple", "0021E9": "Apple", "002312": "Apple", "002500": "Apple",
        "3C0754": "Apple", "600308": "Apple", "705681": "Apple", "A483E7": "Apple", "F01898": "Apple",
        "001247": "Samsung", "001599": "Samsung", "0017C9": "Samsung", "001D25": "Samsung",
        "001FCC": "Samsung", "002339": "Samsung", "002454": "Samsung", "002637": "Samsung",
        "5001BB": "Samsung", "5C0A5B": "Samsung", "781FDB": "Samsung", "B43A28": "Samsung",
        "3C5AB4": "Google", "3C286D": "Google", "F4F5D8": "Google",
        "001A11": "Google", "DAA119": "Google", "FCA667": "Google",
        "000D4B": "Roku", "240AC4": "Espressif", "000E58": "Sonos", "5CAAFD": "Sonos",
        "000048": "Epson", "008077": "Brother", "00000C": "Cisco", "001B2F": "Cisco"
    ]

    public static func name(for device: OntDevice, userAlias: String?, discoveredName: String?) -> String {
        for candidate in [userAlias, device.routerAlias, device.hostName, discoveredName] {
            if let candidate, isUsefulName(candidate) { return candidate.trimmingCharacters(in: .whitespacesAndNewlines) }
        }

        if let vendor = vendorFromReportedClass(device.dhcpVendor) { return "\(vendor) device" }
        if let vendor = ouiVendor(for: device.mac) { return "\(vendor) device" }
        if isLocallyAdministeredMAC(device.mac) { return "Private Wi-Fi Device" }
        if let vendor = genericVendorLabel(device.dhcpVendor) { return vendor }
        return "Unknown device"
    }

    public static func isLocallyAdministeredMAC(_ mac: String) -> Bool {
        guard let normalized = DiscoveredDeviceNameStore.normalizedMAC(mac),
              let firstByte = UInt8(normalized.prefix(2), radix: 16) else { return false }
        return (firstByte & 0x02) != 0
    }

    public static func isUsefulName(_ raw: String) -> Bool {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = name.lowercased().replacingOccurrences(of: "_", with: " ")
        let compact = normalized.filter { $0.isLetter || $0.isNumber }
        return !compact.isEmpty
            && !["unknown", "unknowndevice", "unknownhost", "device", "na", "none", "null", "undefined", "0"].contains(compact)
            && !normalized.hasPrefix("reported as unknown")
    }

    private static func ouiVendor(for mac: String) -> String? {
        guard !isLocallyAdministeredMAC(mac),
              let normalized = DiscoveredDeviceNameStore.normalizedMAC(mac) else { return nil }
        return ouiVendors[String(normalized.prefix(6))]
    }

    private static func vendorFromReportedClass(_ raw: String) -> String? {
        let value = raw.lowercased()
        let vendors: [(String, [String])] = [
            ("Apple", ["apple", "iphone", "ipad"]),
            ("Samsung", ["samsung"]),
            ("Google", ["google", "pixel", "chromecast"]),
            ("Huawei", ["huawei", "honor"]),
            ("Xiaomi", ["xiaomi", "redmi"]),
            ("Sony", ["sony", "playstation"]),
            ("LG", ["lg electronics", "webos"]),
            ("Microsoft", ["microsoft", "msft", "xbox"]),
            ("Amazon", ["amazon", "fire tv", "kindle"]),
            ("Android", ["android"]),
            ("Roku", ["roku"]),
            ("Epson", ["epson"]),
            ("Canon", ["canon"]),
            ("Brother", ["brother"])
        ]
        return vendors.first { _, needles in needles.contains(where: { value.contains($0) }) }?.0
    }

    private static func genericVendorLabel(_ raw: String) -> String? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isUsefulName(value), value.count <= 40,
              !value.contains("-dhcp-"),
              !value.allSatisfy(\.isNumber) else { return nil }
        return value
    }
}

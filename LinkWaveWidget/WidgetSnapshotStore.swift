import Foundation
import Security

struct WidgetRouterConfiguration: Hashable {
    var routerName: String
    var gatewayURL: String
    var username: String

    var host: String? {
        let raw = gatewayURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = raw.contains("://") ? raw : "http://\(raw)"
        guard let components = URLComponents(string: normalized),
              components.scheme?.lowercased() == "http",
              let host = components.host, !host.isEmpty else { return nil }
        return host
    }

    var profileKey: String {
        let identity = "\((host ?? gatewayURL).lowercased())|\(username.lowercased())"
        return Data(identity.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

struct LinkWaveWidgetSnapshot: Codable {
    var routerName: String
    var model: String
    var todayDownloadBytes: UInt64
    var todayUploadBytes: UInt64
    var monthDownloadBytes: UInt64
    var monthUploadBytes: UInt64
    var onlineClientCount: Int
    var rxPowerDbm: Double?
    var lastSyncAt: Date?

    static func empty(routerName: String) -> LinkWaveWidgetSnapshot {
        LinkWaveWidgetSnapshot(
            routerName: routerName,
            model: "HG8145X6-10",
            todayDownloadBytes: 0,
            todayUploadBytes: 0,
            monthDownloadBytes: 0,
            monthUploadBytes: 0,
            onlineClientCount: 0,
            rxPowerDbm: nil,
            lastSyncAt: nil
        )
    }
}

struct WidgetUsageLedger: Codable {
    var dayKey: String
    var monthKey: String
    var previousDownloadCounter: UInt64
    var previousUploadCounter: UInt64
    var todayDownloadBytes: UInt64 = 0
    var todayUploadBytes: UInt64 = 0
    var monthDownloadBytes: UInt64 = 0
    var monthUploadBytes: UInt64 = 0

    mutating func record(download: UInt64, upload: UInt64, at date: Date) {
        let newDay = Self.dayKey(for: date)
        let newMonth = Self.monthKey(for: date)
        let crossedPeriod = newDay != dayKey || newMonth != monthKey
        if newDay != dayKey {
            dayKey = newDay
            todayDownloadBytes = 0
            todayUploadBytes = 0
        }
        if newMonth != monthKey {
            monthKey = newMonth
            monthDownloadBytes = 0
            monthUploadBytes = 0
        }

        if crossedPeriod {
            // There is no safe way to split a missed multi-day interval using a single WAN
            // counter sample, so establish a clean baseline instead of charging old traffic
            // to the newly started day/month.
            previousDownloadCounter = download
            previousUploadCounter = upload
            return
        }

        if download >= previousDownloadCounter {
            let delta = download - previousDownloadCounter
            todayDownloadBytes = Self.add(todayDownloadBytes, delta)
            monthDownloadBytes = Self.add(monthDownloadBytes, delta)
        }
        if upload >= previousUploadCounter {
            let delta = upload - previousUploadCounter
            todayUploadBytes = Self.add(todayUploadBytes, delta)
            monthUploadBytes = Self.add(monthUploadBytes, delta)
        }
        // If a WAN counter resets, establish a new baseline without erasing totals.
        previousDownloadCounter = download
        previousUploadCounter = upload
    }

    mutating func rollForward(to date: Date) {
        let newDay = Self.dayKey(for: date)
        let newMonth = Self.monthKey(for: date)
        if newDay != dayKey {
            dayKey = newDay
            todayDownloadBytes = 0
            todayUploadBytes = 0
        }
        if newMonth != monthKey {
            monthKey = newMonth
            monthDownloadBytes = 0
            monthUploadBytes = 0
        }
    }

    static func initial(download: UInt64, upload: UInt64, at date: Date) -> WidgetUsageLedger {
        WidgetUsageLedger(
            dayKey: dayKey(for: date),
            monthKey: monthKey(for: date),
            previousDownloadCounter: download,
            previousUploadCounter: upload
        )
    }

    private static func dayKey(for date: Date) -> String { formatted(date, format: "yyyy-MM-dd") }
    private static func monthKey(for date: Date) -> String { formatted(date, format: "yyyy-MM") }
    private static func formatted(_ date: Date, format: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = .autoupdatingCurrent
        formatter.dateFormat = format
        return formatter.string(from: date)
    }
    private static func add(_ lhs: UInt64, _ rhs: UInt64) -> UInt64 {
        let (sum, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? UInt64.max : sum
    }
}

enum WidgetLocalStore {
    private static let defaults = UserDefaults.standard
    private static let snapshotPrefix = "linkwave.widget.snapshot.v1."
    private static let ledgerPrefix = "linkwave.widget.usage-ledger.v1."
    private static let cooldownPrefix = "linkwave.widget.last-fetch.v1."
    private static let routerNamePrefix = "linkwave.widget.router-name.v1."
    private static let gatewayPrefix = "linkwave.widget.gateway.v1."
    private static let usernamePrefix = "linkwave.widget.username.v1."

    static func snapshot(for configuration: WidgetRouterConfiguration) -> LinkWaveWidgetSnapshot? {
        guard let data = defaults.data(forKey: snapshotPrefix + configuration.profileKey) else { return nil }
        guard var snapshot = try? JSONDecoder().decode(LinkWaveWidgetSnapshot.self, from: data) else { return nil }
        snapshot.routerName = configuration.routerName
        return snapshot
    }

    static func saveConfiguration(_ configuration: WidgetRouterConfiguration) {
        let key = configuration.profileKey
        defaults.set(configuration.routerName, forKey: routerNamePrefix + key)
        defaults.set(configuration.gatewayURL, forKey: gatewayPrefix + key)
        defaults.set(configuration.username, forKey: usernamePrefix + key)
    }

    static func save(_ snapshot: LinkWaveWidgetSnapshot, for configuration: WidgetRouterConfiguration) {
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        defaults.set(data, forKey: snapshotPrefix + configuration.profileKey)
    }

    static func ledger(for configuration: WidgetRouterConfiguration) -> WidgetUsageLedger? {
        guard let data = defaults.data(forKey: ledgerPrefix + configuration.profileKey) else { return nil }
        return try? JSONDecoder().decode(WidgetUsageLedger.self, from: data)
    }

    static func save(_ ledger: WidgetUsageLedger, for configuration: WidgetRouterConfiguration) {
        guard let data = try? JSONEncoder().encode(ledger) else { return }
        defaults.set(data, forKey: ledgerPrefix + configuration.profileKey)
    }

    static func lastFetchAt(for configuration: WidgetRouterConfiguration) -> Date? {
        defaults.object(forKey: cooldownPrefix + configuration.profileKey) as? Date
    }

    static func markFetchStarted(for configuration: WidgetRouterConfiguration, at date: Date) {
        defaults.set(date, forKey: cooldownPrefix + configuration.profileKey)
    }
}

enum WidgetCredentialStore {
    private static let service = "dev.mattdev0.fibremonitor.widget.credentials"

    static func password(for configuration: WidgetRouterConfiguration) -> String? {
        guard let host = configuration.host else { return nil }
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account(host: host, username: configuration.username),
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        query[kSecUseDataProtectionKeychain as String] = true
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func save(password: String, for configuration: WidgetRouterConfiguration) {
        guard !password.isEmpty, let host = configuration.host else { return }
        let account = account(host: host, username: configuration.username)
        let key: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(key as CFDictionary)
        var item = key
        item[kSecValueData as String] = Data(password.utf8)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        item[kSecUseDataProtectionKeychain as String] = true
        SecItemAdd(item as CFDictionary, nil)
    }

    private static func account(host: String, username: String) -> String {
        "\(host.lowercased())|\(username.lowercased())"
    }
}

actor WidgetRefreshService {
    static let shared = WidgetRefreshService()

    func refresh(for configuration: WidgetRouterConfiguration) async -> LinkWaveWidgetSnapshot? {
        let now = Date()
        if let lastFetch = WidgetLocalStore.lastFetchAt(for: configuration),
           now.timeIntervalSince(lastFetch) < 15 {
            return WidgetLocalStore.snapshot(for: configuration)
        }
        WidgetLocalStore.markFetchStarted(for: configuration, at: now)

        guard let host = configuration.host,
              let password = WidgetCredentialStore.password(for: configuration),
              !password.isEmpty else {
            return WidgetLocalStore.snapshot(for: configuration)
        }

        let client = HuaweiOntClient(
            credentials: .init(host: host, username: configuration.username, password: password),
            transport: URLSessionOntTransport()
        )

        do {
            try await client.login()
            let traffic = try await client.pollTraffic(now: now)
            let devices = try await client.fetchDevices()
            let optical = try await client.fetchOptical()
            let identity = await client.detectedIdentity
            let reportedModel = identity?.model?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            await client.logout()

            var ledger = WidgetLocalStore.ledger(for: configuration)
            if let download = traffic.cumulativeDownloadBytes,
               let upload = traffic.cumulativeUploadBytes {
                if var existing = ledger {
                    existing.record(download: download, upload: upload, at: now)
                    ledger = existing
                } else {
                    ledger = .initial(download: download, upload: upload, at: now)
                }
            } else if var existing = ledger {
                existing.rollForward(to: now)
                ledger = existing
            }
            if let ledger { WidgetLocalStore.save(ledger, for: configuration) }

            let previous = WidgetLocalStore.snapshot(for: configuration)
            let snapshot = LinkWaveWidgetSnapshot(
                routerName: configuration.routerName,
                model: reportedModel.isEmpty ? "HG8145X6-10" : reportedModel,
                todayDownloadBytes: ledger?.todayDownloadBytes ?? previous?.todayDownloadBytes ?? 0,
                todayUploadBytes: ledger?.todayUploadBytes ?? previous?.todayUploadBytes ?? 0,
                monthDownloadBytes: ledger?.monthDownloadBytes ?? previous?.monthDownloadBytes ?? 0,
                monthUploadBytes: ledger?.monthUploadBytes ?? previous?.monthUploadBytes ?? 0,
                onlineClientCount: devices.filter(\.isOnline).count,
                rxPowerDbm: optical.rxPowerDbm,
                lastSyncAt: now
            )
            WidgetLocalStore.save(snapshot, for: configuration)
            return snapshot
        } catch {
            await client.logout()
            return WidgetLocalStore.snapshot(for: configuration)
        }
    }
}

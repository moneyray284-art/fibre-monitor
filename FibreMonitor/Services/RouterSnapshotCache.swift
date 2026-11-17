import Foundation

public struct RouterSnapshot: Codable, Sendable {
    public var routerProfileID: String?
    public var routerHost: String?
    public var routerModel: String?
    public var rxPowerDbm: Double?
    public var todayDownloadBytes: UInt64
    public var todayUploadBytes: UInt64
    public var todayTotalBytes: UInt64
    public var onlineClientCount: Int
    public var offlineClientCount: Int?
    public var pppoeUptimeSeconds: Int?
    public var updatedAt: Date

    public init(
        routerProfileID: String? = nil,
        routerHost: String? = nil,
        routerModel: String? = nil,
        rxPowerDbm: Double? = nil,
        todayDownloadBytes: UInt64 = 0,
        todayUploadBytes: UInt64 = 0,
        todayTotalBytes: UInt64 = 0,
        onlineClientCount: Int = 0,
        offlineClientCount: Int? = nil,
        pppoeUptimeSeconds: Int? = nil,
        updatedAt: Date = Date()
    ) {
        self.routerProfileID = routerProfileID
        self.routerHost = routerHost
        self.routerModel = routerModel
        self.rxPowerDbm = rxPowerDbm
        self.todayDownloadBytes = todayDownloadBytes
        self.todayUploadBytes = todayUploadBytes
        self.todayTotalBytes = todayTotalBytes
        self.onlineClientCount = onlineClientCount
        self.offlineClientCount = offlineClientCount
        self.pppoeUptimeSeconds = pppoeUptimeSeconds
        self.updatedAt = updatedAt
    }
}

/// Keeps the last router readings available to LinkWave itself between launches.
@MainActor
public enum RouterSnapshotCache {
    public static let appGroupID = "group.dev.mattdev0.fibremonitor"

    private static let snapshotKey = "linkwave.router.snapshot.v1"
    private static let legacyWidgetSnapshotKey = "linkwave.widget.snapshot.v1"
    private static let legacySnapshotFileName = "LinkWaveWidgetSnapshot.json"

    public static func save(
        rxPowerDbm: Double?,
        routerHost: String?,
        routerProfileID: String? = nil,
        routerModel: String? = nil,
        summary: DataUsageSummary,
        onlineClientCount: Int? = nil,
        offlineClientCount: Int? = nil,
        pppoeUptimeSeconds: Int?,
        at date: Date
    ) {
        let total = summary.todayDownloadBytes.addingReportingOverflow(summary.todayUploadBytes)
        let previous = read()
        let previousMatchesProfile: Bool
        if let routerProfileID, let previousProfileID = previous?.routerProfileID {
            previousMatchesProfile = previousProfileID == routerProfileID
        } else {
            previousMatchesProfile = previous?.routerHost?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                == routerHost?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }
        persist(RouterSnapshot(
            routerProfileID: routerProfileID,
            routerHost: routerHost,
            routerModel: routerModel ?? (previousMatchesProfile ? previous?.routerModel : nil),
            rxPowerDbm: rxPowerDbm,
            todayDownloadBytes: summary.todayDownloadBytes,
            todayUploadBytes: summary.todayUploadBytes,
            todayTotalBytes: total.overflow ? UInt64.max : total.partialValue,
            onlineClientCount: onlineClientCount ?? (previousMatchesProfile ? previous?.onlineClientCount : nil) ?? 0,
            offlineClientCount: offlineClientCount ?? (previousMatchesProfile ? previous?.offlineClientCount : nil),
            pppoeUptimeSeconds: pppoeUptimeSeconds,
            updatedAt: date
        ))
    }

    /// Background refresh has fresh usage counters only, so retain other cached router details.
    public static func updateUsage(summary: DataUsageSummary, at date: Date) {
        var snapshot = read() ?? RouterSnapshot(updatedAt: .distantPast)
        let total = summary.todayDownloadBytes.addingReportingOverflow(summary.todayUploadBytes)
        snapshot.todayDownloadBytes = summary.todayDownloadBytes
        snapshot.todayUploadBytes = summary.todayUploadBytes
        snapshot.todayTotalBytes = total.overflow ? UInt64.max : total.partialValue
        snapshot.updatedAt = date
        persist(snapshot)
    }

    public static func load() -> RouterSnapshot? { read() }

    private static func read() -> RouterSnapshot? {
        let shared = UserDefaults(suiteName: appGroupID)
        for store in [shared, UserDefaults.standard] {
            guard let data = store?.data(forKey: snapshotKey),
                  let snapshot = try? JSONDecoder().decode(RouterSnapshot.self, from: data) else { continue }
            return snapshot
        }
        if let data = shared?.data(forKey: legacyWidgetSnapshotKey),
           let snapshot = try? JSONDecoder().decode(RouterSnapshot.self, from: data) {
            persist(snapshot)
            return snapshot
        }
        if let data = snapshotFileURL.flatMap({ try? Data(contentsOf: $0) }),
           let snapshot = try? JSONDecoder().decode(RouterSnapshot.self, from: data) {
            persist(snapshot)
            return snapshot
        }
        if let data = UserDefaults.standard.data(forKey: snapshotKey),
           let snapshot = try? JSONDecoder().decode(RouterSnapshot.self, from: data) {
            persist(snapshot)
            return snapshot
        }
        return nil
    }

    private static func persist(_ snapshot: RouterSnapshot) {
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        UserDefaults.standard.set(data, forKey: snapshotKey)
        UserDefaults(suiteName: appGroupID)?.set(data, forKey: snapshotKey)
        if let snapshotFileURL {
            try? data.write(to: snapshotFileURL, options: .atomic)
        }
    }

    private static var snapshotFileURL: URL? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroupID)?
            .appendingPathComponent(legacySnapshotFileName, isDirectory: false)
    }
}

import Foundation
import WidgetKit

public struct LinkWaveWidgetSnapshot: Codable, Sendable {
    public var routerHost: String?
    public var rxPowerDbm: Double?
    public var todayDownloadBytes: UInt64
    public var todayUploadBytes: UInt64
    public var todayTotalBytes: UInt64
    public var onlineClientCount: Int
    public var pppoeUptimeSeconds: Int?
    public var updatedAt: Date
    public var routerReachableAt: Date?

    public init(
        rxPowerDbm: Double? = nil,
        routerHost: String? = nil,
        todayDownloadBytes: UInt64 = 0,
        todayUploadBytes: UInt64 = 0,
        todayTotalBytes: UInt64 = 0,
        onlineClientCount: Int = 0,
        pppoeUptimeSeconds: Int? = nil,
        updatedAt: Date = Date(),
        routerReachableAt: Date? = nil
    ) {
        self.routerHost = routerHost
        self.rxPowerDbm = rxPowerDbm
        self.todayDownloadBytes = todayDownloadBytes
        self.todayUploadBytes = todayUploadBytes
        self.todayTotalBytes = todayTotalBytes
        self.onlineClientCount = onlineClientCount
        self.pppoeUptimeSeconds = pppoeUptimeSeconds
        self.updatedAt = updatedAt
        self.routerReachableAt = routerReachableAt
    }
}

@MainActor
public enum WidgetSnapshotStore {
    public static let appGroupID = "group.dev.mattdev0.fibremonitor"
    private static let snapshotKey = "linkwave.widget.snapshot.v1"
    private static let snapshotFileName = "LinkWaveWidgetSnapshot.json"

    public static func save(
        rxPowerDbm: Double?,
        routerHost: String?,
        summary: DataUsageSummary,
        onlineClientCount: Int,
        pppoeUptimeSeconds: Int?,
        at date: Date
    ) {
        let total = summary.todayDownloadBytes.addingReportingOverflow(summary.todayUploadBytes)
        let snapshot = LinkWaveWidgetSnapshot(
            rxPowerDbm: rxPowerDbm,
            routerHost: routerHost,
            todayDownloadBytes: summary.todayDownloadBytes,
            todayUploadBytes: summary.todayUploadBytes,
            todayTotalBytes: total.overflow ? UInt64.max : total.partialValue,
            onlineClientCount: onlineClientCount,
            pppoeUptimeSeconds: pppoeUptimeSeconds,
            updatedAt: date
        )
        persist(snapshot)
    }

    /// Background refresh only has fresh usage counters, so preserve router details from the last foreground sync.
    public static func updateUsage(summary: DataUsageSummary, at date: Date) {
        let previous = read() ?? LinkWaveWidgetSnapshot()
        let total = summary.todayDownloadBytes.addingReportingOverflow(summary.todayUploadBytes)
        var updated = previous
        updated.todayDownloadBytes = summary.todayDownloadBytes
        updated.todayUploadBytes = summary.todayUploadBytes
        updated.todayTotalBytes = total.overflow ? UInt64.max : total.partialValue
        updated.updatedAt = date
        persist(updated)
    }

    private static func read() -> LinkWaveWidgetSnapshot? {
        let defaultsData = UserDefaults(suiteName: appGroupID)?.data(forKey: snapshotKey)
        let fileData = snapshotURL.flatMap { try? Data(contentsOf: $0) }
        guard let data = defaultsData ?? fileData else { return nil }
        return try? JSONDecoder().decode(LinkWaveWidgetSnapshot.self, from: data)
    }

    private static func persist(_ snapshot: LinkWaveWidgetSnapshot) {
        if let data = try? JSONEncoder().encode(snapshot) {
            UserDefaults(suiteName: appGroupID)?.set(data, forKey: snapshotKey)
            if let url = snapshotURL {
                try? data.write(to: url, options: .atomic)
            }
        }
        WidgetCenter.shared.reloadAllTimelines()
    }

    private static var snapshotURL: URL? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroupID)?
            .appendingPathComponent(snapshotFileName, isDirectory: false)
    }
}

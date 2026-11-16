import Foundation
import WidgetKit

public struct LinkWaveWidgetSnapshot: Codable, Sendable {
    public var rxPowerDbm: Double?
    public var todayDownloadBytes: UInt64
    public var todayUploadBytes: UInt64
    public var todayTotalBytes: UInt64
    public var onlineClientCount: Int
    public var pppoeUptimeSeconds: Int?
    public var updatedAt: Date

    public init(
        rxPowerDbm: Double? = nil,
        todayDownloadBytes: UInt64 = 0,
        todayUploadBytes: UInt64 = 0,
        todayTotalBytes: UInt64 = 0,
        onlineClientCount: Int = 0,
        pppoeUptimeSeconds: Int? = nil,
        updatedAt: Date = Date()
    ) {
        self.rxPowerDbm = rxPowerDbm
        self.todayDownloadBytes = todayDownloadBytes
        self.todayUploadBytes = todayUploadBytes
        self.todayTotalBytes = todayTotalBytes
        self.onlineClientCount = onlineClientCount
        self.pppoeUptimeSeconds = pppoeUptimeSeconds
        self.updatedAt = updatedAt
    }
}

@MainActor
public enum WidgetSnapshotStore {
    public static let appGroupID = "group.dev.mattdev0.fibremonitor"
    private static let snapshotKey = "linkwave.widget.snapshot.v1"

    public static func save(
        rxPowerDbm: Double?,
        summary: DataUsageSummary,
        onlineClientCount: Int,
        pppoeUptimeSeconds: Int?,
        at date: Date
    ) {
        let total = summary.todayDownloadBytes.addingReportingOverflow(summary.todayUploadBytes)
        let snapshot = LinkWaveWidgetSnapshot(
            rxPowerDbm: rxPowerDbm,
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
        guard let data = UserDefaults(suiteName: appGroupID)?.data(forKey: snapshotKey) else { return nil }
        return try? JSONDecoder().decode(LinkWaveWidgetSnapshot.self, from: data)
    }

    private static func persist(_ snapshot: LinkWaveWidgetSnapshot) {
        guard let defaults = UserDefaults(suiteName: appGroupID),
              let data = try? JSONEncoder().encode(snapshot) else { return }
        defaults.set(data, forKey: snapshotKey)
        WidgetCenter.shared.reloadAllTimelines()
    }
}

import Darwin
import Foundation

public struct PersonalUsageSnapshot: Equatable, Sendable {
    public var todayDownloadBytes: UInt64
    public var todayUploadBytes: UInt64
    public var monthDownloadBytes: UInt64
    public var monthUploadBytes: UInt64
    public var totalDownloadBytes: UInt64
    public var totalUploadBytes: UInt64

    public init(
        todayDownloadBytes: UInt64 = 0,
        todayUploadBytes: UInt64 = 0,
        monthDownloadBytes: UInt64 = 0,
        monthUploadBytes: UInt64 = 0,
        totalDownloadBytes: UInt64 = 0,
        totalUploadBytes: UInt64 = 0
    ) {
        self.todayDownloadBytes = todayDownloadBytes
        self.todayUploadBytes = todayUploadBytes
        self.monthDownloadBytes = monthDownloadBytes
        self.monthUploadBytes = monthUploadBytes
        self.totalDownloadBytes = totalDownloadBytes
        self.totalUploadBytes = totalUploadBytes
    }

    public static let empty = PersonalUsageSnapshot()
}

/// Estimates this iPhone's Wi-Fi traffic while LinkWave has a verified connection
/// to the selected router. Raw interface counters are private to this device.
@MainActor
public final class PersonalUsageTracker {
    private struct InterfaceCounters {
        let downloaded: UInt64
        let uploaded: UInt64
    }

    private struct ProfileState: Codable {
        var lastInboundCounter: UInt64?
        var lastOutboundCounter: UInt64?
        var todayKey: String
        var monthKey: String
        var todayDownloadBytes: UInt64 = 0
        var todayUploadBytes: UInt64 = 0
        var monthDownloadBytes: UInt64 = 0
        var monthUploadBytes: UInt64 = 0
        var totalDownloadBytes: UInt64 = 0
        var totalUploadBytes: UInt64 = 0

        init(todayKey: String, monthKey: String) {
            self.lastInboundCounter = nil
            self.lastOutboundCounter = nil
            self.todayKey = todayKey
            self.monthKey = monthKey
        }
    }

    private static let storageKey = "linkwave.personal_usage.v1"
    private let defaults: UserDefaults
    private var profiles: [String: ProfileState]

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.storageKey),
           let saved = try? JSONDecoder().decode([String: ProfileState].self, from: data) {
            self.profiles = saved
        } else {
            self.profiles = [:]
        }
    }

    public func snapshot(for profileID: UUID?, at date: Date = Date()) -> PersonalUsageSnapshot {
        guard let profileID else { return .empty }
        var state = rolledOverState(for: profileID, at: date)
        profiles[profileID.uuidString] = state
        persist()
        return makeSnapshot(from: state)
    }

    /// Samples en0 only when both Wi-Fi and the selected router session are confirmed.
    /// An unlinked interval clears the raw baseline so traffic on other networks is excluded.
    @discardableResult
    public func sample(
        profileID: UUID?,
        isConnectedToWiFi: Bool,
        isLinkedToProfile: Bool,
        at date: Date = Date()
    ) -> PersonalUsageSnapshot {
        guard let profileID else { return .empty }
        var state = rolledOverState(for: profileID, at: date)
        let profileKey = profileID.uuidString

        guard isConnectedToWiFi, isLinkedToProfile,
              let counters = Self.interfaceCounters(interface: "en0") else {
            state.lastInboundCounter = nil
            state.lastOutboundCounter = nil
            profiles[profileKey] = state
            persist()
            return makeSnapshot(from: state)
        }

        if let previousInbound = state.lastInboundCounter,
           let previousOutbound = state.lastOutboundCounter {
            let countersDidNotReset = counters.downloaded >= previousInbound
                && counters.uploaded >= previousOutbound
            if countersDidNotReset {
                let delta = counters.downloaded - previousInbound
                state.todayDownloadBytes = Self.adding(delta, to: state.todayDownloadBytes)
                state.monthDownloadBytes = Self.adding(delta, to: state.monthDownloadBytes)
                state.totalDownloadBytes = Self.adding(delta, to: state.totalDownloadBytes)
                let uploadDelta = counters.uploaded - previousOutbound
                state.todayUploadBytes = Self.adding(uploadDelta, to: state.todayUploadBytes)
                state.monthUploadBytes = Self.adding(uploadDelta, to: state.monthUploadBytes)
                state.totalUploadBytes = Self.adding(uploadDelta, to: state.totalUploadBytes)
            }
        }

        // A counter decrease (for example after a reboot) only establishes a new baseline.
        state.lastInboundCounter = counters.downloaded
        state.lastOutboundCounter = counters.uploaded
        profiles[profileKey] = state
        persist()
        return makeSnapshot(from: state)
    }

    /// Ends a verified router interval without changing accumulated totals.
    public func pause(profileID: UUID?) {
        guard let profileID else { return }
        let key = profileID.uuidString
        guard var state = profiles[key] else { return }
        state.lastInboundCounter = nil
        state.lastOutboundCounter = nil
        profiles[key] = state
        persist()
    }

    public func deleteProfile(_ profileID: UUID) {
        profiles.removeValue(forKey: profileID.uuidString)
        persist()
    }

    private func rolledOverState(for profileID: UUID, at date: Date) -> ProfileState {
        let todayKey = Self.dayKey(for: date)
        let monthKey = String(todayKey.prefix(7))
        guard var state = profiles[profileID.uuidString] else {
            return ProfileState(todayKey: todayKey, monthKey: monthKey)
        }
        if state.todayKey != todayKey {
            state.todayKey = todayKey
            state.todayDownloadBytes = 0
            state.todayUploadBytes = 0
        }
        if state.monthKey != monthKey {
            state.monthKey = monthKey
            state.monthDownloadBytes = 0
            state.monthUploadBytes = 0
        }
        return state
    }

    private func makeSnapshot(from state: ProfileState) -> PersonalUsageSnapshot {
        PersonalUsageSnapshot(
            todayDownloadBytes: state.todayDownloadBytes,
            todayUploadBytes: state.todayUploadBytes,
            monthDownloadBytes: state.monthDownloadBytes,
            monthUploadBytes: state.monthUploadBytes,
            totalDownloadBytes: state.totalDownloadBytes,
            totalUploadBytes: state.totalUploadBytes
        )
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(profiles) else { return }
        defaults.set(data, forKey: Self.storageKey)
    }

    private static func interfaceCounters(interface targetInterface: String) -> InterfaceCounters? {
        var firstInterface: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&firstInterface) == 0, let firstInterface else { return nil }
        defer { freeifaddrs(firstInterface) }

        var current: UnsafeMutablePointer<ifaddrs>? = firstInterface
        while let entry = current {
            let value = entry.pointee
            if String(cString: value.ifa_name) == targetInterface,
               let address = value.ifa_addr,
               address.pointee.sa_family == UInt8(AF_LINK),
               let rawData = value.ifa_data {
                let data = rawData.assumingMemoryBound(to: if_data.self).pointee
                return InterfaceCounters(
                    downloaded: UInt64(data.ifi_ibytes),
                    uploaded: UInt64(data.ifi_obytes)
                )
            }
            current = value.ifa_next
        }
        return nil
    }

    private static func adding(_ value: UInt64, to total: UInt64) -> UInt64 {
        let (sum, overflow) = total.addingReportingOverflow(value)
        return overflow ? UInt64.max : sum
    }

    private static func dayKey(for date: Date) -> String {
        let parts = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }
}

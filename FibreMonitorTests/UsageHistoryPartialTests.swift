import XCTest
@testable import FibreMonitor

final class UsageHistoryPartialTests: XCTestCase {
    private struct LegacyDay: Codable {
        var downloadBytes: UInt64
        var uploadBytes: UInt64
    }

    private struct LegacyProfileUsage: Codable {
        var lastDownloadCounter: UInt64?
        var lastUploadCounter: UInt64?
        var totalDownloadBytes: UInt64
        var totalUploadBytes: UInt64
        var days: [String: LegacyDay]
        var chartStartDayKey: String?
        var lastCounterSampleAt: Date?
        var lastSuccessfulSyncAt: Date?
        var observedDayKeys: [String]?
        var incompleteDayKeys: [String]?
        var lastConnectionObservationAt: Date?
        var connectionInterruptions: [ConnectionInterruption]?
    }

    @MainActor
    func testNormalOvernightSyncDoesNotMarkFinishedDayPartialAndTodayDoes() {
        let (defaults, suite, settings, profile) = makeStore()
        defer { defaults.removePersistentDomain(forName: suite) }

        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let firstDay = calendar.date(byAdding: .day, value: -2, to: today)!
        let yesterday = calendar.date(byAdding: .day, value: -1, to: today)!
        let firstMorning = calendar.date(bySettingHour: 8, minute: 0, second: 0, of: firstDay)!
        let firstEvening = calendar.date(bySettingHour: 16, minute: 0, second: 0, of: firstDay)!
        let yesterdayMorning = calendar.date(bySettingHour: 8, minute: 0, second: 0, of: yesterday)!
        let todaySample = Date().addingTimeInterval(-2)

        settings.recordTrafficCounters(download: 1_000, upload: 2_000, for: profile.id, at: firstMorning)
        settings.recordTrafficCounters(download: 1_500, upload: 2_500, for: profile.id, at: firstEvening)
        settings.recordTrafficCounters(download: 2_000, upload: 3_000, for: profile.id, at: yesterdayMorning)
        settings.recordTrafficCounters(download: 2_500, upload: 3_500, for: profile.id, at: todaySample)

        let history = settings.dataUsageSummary.historicalDailyHistory
        XCTAssertTrue(history.first(where: { calendar.isDate($0.date, inSameDayAs: firstDay) })?.isPartial == true)
        XCTAssertFalse(history.first(where: { calendar.isDate($0.date, inSameDayAs: yesterday) })?.isPartial ?? true)
        XCTAssertTrue(history.first(where: { calendar.isDate($0.date, inSameDayAs: today) })?.isPartial == true)
    }

    @MainActor
    func testLongGapAndCounterResetMarkAffectedDaysPartial() {
        let (defaults, suite, settings, profile) = makeStore()
        defer { defaults.removePersistentDomain(forName: suite) }

        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let firstDay = calendar.date(byAdding: .day, value: -5, to: today)!
        let firstSample = calendar.date(bySettingHour: 8, minute: 0, second: 0, of: firstDay)!
        let afterLongGap = firstSample.addingTimeInterval(40 * 60 * 60)
        settings.recordTrafficCounters(download: 10_000_000_000, upload: 20_000_000_000, for: profile.id, at: firstSample)
        settings.recordTrafficCounters(download: 10_100_000_000, upload: 20_100_000_000, for: profile.id, at: afterLongGap)

        let longGapDay = Calendar.current.startOfDay(for: afterLongGap)
        XCTAssertTrue(settings.dataUsageSummary.historicalDailyHistory.first(where: {
            calendar.isDate($0.date, inSameDayAs: longGapDay)
        })?.isPartial == true)

        let followingDay = calendar.date(byAdding: .day, value: 1, to: longGapDay)!
        let resetSample = calendar.date(bySettingHour: 8, minute: 0, second: 0, of: followingDay)!
        settings.recordTrafficCounters(download: 10_200_000_000, upload: 20_200_000_000, for: profile.id, at: resetSample)
        let resetDay = calendar.date(byAdding: .day, value: 1, to: followingDay)!
        let resetTime = calendar.date(bySettingHour: 9, minute: 0, second: 0, of: resetDay)!
        settings.recordTrafficCounters(download: 5_000, upload: 6_000, for: profile.id, at: resetTime)

        XCTAssertTrue(settings.dataUsageSummary.historicalDailyHistory.first(where: {
            calendar.isDate($0.date, inSameDayAs: resetDay)
        })?.isPartial == true)
    }

    @MainActor
    func testLegacyOvernightMarkersAreClearedExceptForFirstTrackingDay() throws {
        let (defaults, suite, settings, profile) = makeStore()
        defer { defaults.removePersistentDomain(forName: suite) }

        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let dates = (-4 ... -2).compactMap { calendar.date(byAdding: .day, value: $0, to: today) }
        let keys = dates.map(dayKey)
        let days = Dictionary(uniqueKeysWithValues: keys.map { ($0, LegacyDay(downloadBytes: 1_000, uploadBytes: 500)) })
        let legacyUsage = LegacyProfileUsage(
            lastDownloadCounter: 10_000,
            lastUploadCounter: 20_000,
            totalDownloadBytes: 3_000,
            totalUploadBytes: 1_500,
            days: days,
            chartStartDayKey: keys[0],
            lastCounterSampleAt: dates.last,
            lastSuccessfulSyncAt: dates.last,
            observedDayKeys: keys,
            incompleteDayKeys: keys,
            lastConnectionObservationAt: nil,
            connectionInterruptions: nil
        )
        defaults.set(try JSONEncoder().encode([profile.id.uuidString: legacyUsage]), forKey: "data_usage_v1")

        let upgraded = SettingsStore(defaults: defaults, passwordStore: InMemoryPasswordStore([profile.id.uuidString: "test-password"]))
        let history = upgraded.dataUsageSummary.historicalDailyHistory
        XCTAssertTrue(history.first(where: { calendar.isDate($0.date, inSameDayAs: dates[0]) })?.isPartial == true)
        XCTAssertFalse(history.first(where: { calendar.isDate($0.date, inSameDayAs: dates[1]) })?.isPartial ?? true)
        XCTAssertFalse(history.first(where: { calendar.isDate($0.date, inSameDayAs: dates[2]) })?.isPartial ?? true)
    }

    @MainActor
    private func makeStore() -> (UserDefaults, String, SettingsStore, RouterProfile) {
        let suite = "dev.mattdev0.fibremonitor.usage-tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let settings = SettingsStore(defaults: defaults, passwordStore: InMemoryPasswordStore())
        let profile = settings.addProfile(RouterProfile.mtnTemplate(), password: "test-password")
        return (defaults, suite, settings, profile)
    }

    private func dayKey(_ date: Date) -> String {
        let parts = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }
}

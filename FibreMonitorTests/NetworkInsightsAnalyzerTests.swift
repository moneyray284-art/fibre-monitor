import XCTest
@testable import FibreMonitor

final class NetworkInsightsAnalyzerTests: XCTestCase {
    func testOpticalDiagnosisDistinguishesOptimalAndCriticalRX() {
        let healthy = diagnose(rx: -15.97)
        XCTAssertEqual(healthy.severity, .optimal)
        XCTAssertEqual(healthy.checks.first?.status, .optimal)

        let critical = diagnose(rx: -27.84)
        XCTAssertEqual(critical.severity, .critical)
        XCTAssertEqual(critical.checks.first?.status, .critical)
        XCTAssertTrue(critical.inlineHint.contains("-27.8 dBm"))
    }

    func testWiFiCrowdingUsesLiveSSIDNamesAndEnabledBandState() {
        let devices = [
            makeDevice(mac: "00:00:00:00:00:01", name: "Phone 1", port: .wifi24(ssidIndex: 1)),
            makeDevice(mac: "00:00:00:00:00:02", name: "Phone 2", port: .wifi24(ssidIndex: 2)),
            makeDevice(mac: "00:00:00:00:00:03", name: "TV", port: .wifi24(ssidIndex: 3)),
            makeDevice(mac: "00:00:00:00:00:04", name: "Laptop", port: .wifi5(ssidIndex: 5))
        ]
        let wifi = WifiState(
            radios: [
                WifiRadio(index: 1, band: "2.4GHz", enabled: true),
                WifiRadio(index: 2, band: "5GHz", enabled: true)
            ],
            networks: [
                WifiNetwork(ssidIndex: 1, name: "Family-2G", band: "2.4GHz", enabled: true),
                WifiNetwork(ssidIndex: 5, name: "Family-5G", band: "5GHz", enabled: true)
            ]
        )

        let result = NetworkInsightsAnalyzer.diagnose(
            snapshot: RouterSnapshot(rxPowerDbm: -15.97),
            devices: devices,
            blockedDevices: [],
            wifi: wifi,
            speedTest: nil
        )

        let bandCheck = try! XCTUnwrap(result.checks.first { $0.title == "Wi-Fi Band Balance" })
        XCTAssertTrue(result.hasWiFiBandConcern)
        XCTAssertEqual(bandCheck.status, .warning)
        XCTAssertTrue(bandCheck.detail.contains("‘Family-2G’"))
        XCTAssertTrue(bandCheck.detail.contains("‘Family-5G’"))
    }

    func testWeakClientsExcludeOfflineAndBlockedDevicesAndSortWeakestFirst() {
        let weak = makeDevice(mac: "00:00:00:00:00:11", name: "Weak", port: .wifi24(ssidIndex: 1), rssi: -75)
        let weakest = makeDevice(mac: "00:00:00:00:00:12", name: "Weakest", port: .wifi5(ssidIndex: 5), rssi: -88)
        let blocked = makeDevice(mac: "00:00:00:00:00:13", name: "Blocked", port: .wifi24(ssidIndex: 1), rssi: -96)
        let offline = makeDevice(mac: "00:00:00:00:00:14", name: "Offline", port: .wifi24(ssidIndex: 1), rssi: -99, online: false)

        let result = NetworkInsightsAnalyzer.diagnose(
            snapshot: RouterSnapshot(rxPowerDbm: -15),
            devices: [weak, weakest, blocked, offline],
            blockedDevices: [BlockedRouterDevice(domain: "blocked", mac: blocked.mac, ssidName: "SSID 1")],
            wifi: WifiState(),
            speedTest: nil
        )

        XCTAssertEqual(result.weakClients.map(\.name), ["Weakest", "Weak"])
        XCTAssertEqual(result.weakClients.map(\.rssiDbm), [-88, -75])
        XCTAssertTrue(result.actions.contains(.inspectWeakClients))
    }

    func testUsageForecastProjectionAndSpikeDetection() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = date(2026, 6, 6, calendar: calendar)
        let history = [
            point(2026, 6, 1, gb: 4, calendar: calendar),
            point(2026, 6, 2, gb: 4, calendar: calendar),
            point(2026, 6, 3, gb: 4, calendar: calendar),
            point(2026, 6, 4, gb: 4, calendar: calendar),
            point(2026, 6, 5, gb: 6, calendar: calendar)
        ]

        let forecast = NetworkInsightsAnalyzer.forecast(
            history: history,
            selectedMonth: now,
            todayDownloadBytes: 1_000_000_000,
            todayUploadBytes: 1_000_000_000,
            now: now,
            calendar: calendar
        )

        XCTAssertEqual(forecast.completedDayCount, 5)
        XCTAssertEqual(forecast.activeReadingDayCount, 6)
        XCTAssertEqual(forecast.dailyAverageGb ?? 0, 4, accuracy: 0.001)
        XCTAssertEqual(forecast.remainingDays, 24)
        XCTAssertEqual(forecast.projectedMonthGb ?? 0, 120, accuracy: 0.001)
        XCTAssertEqual(forecast.spikeDays.count, 1)
        XCTAssertEqual(forecast.spikeDays.first?.totalGb ?? 0, 6, accuracy: 0.001)
        XCTAssertEqual(forecast.spikeDays.first?.multiplier ?? 0, 1.5, accuracy: 0.001)
        XCTAssertEqual(forecast.peakDay?.date, history[4].date)
    }

    func testUsageForecastGracefullyHidesProjectionBelowThreeCompletedDays() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = date(2026, 6, 3, calendar: calendar)
        let history = [
            point(2026, 6, 1, gb: 4, calendar: calendar),
            point(2026, 6, 2, gb: 6, calendar: calendar)
        ]

        let forecast = NetworkInsightsAnalyzer.forecast(
            history: history,
            selectedMonth: now,
            todayDownloadBytes: 0,
            todayUploadBytes: 0,
            now: now,
            calendar: calendar
        )

        XCTAssertEqual(forecast.completedDayCount, 2)
        XCTAssertEqual(forecast.dailyAverageGb ?? 0, 5, accuracy: 0.001)
        XCTAssertNil(forecast.projectedMonthGb)
        XCTAssertFalse(forecast.hasEnoughData)
        XCTAssertEqual(forecast.paceNote, "Need 3 completed days to compare your recent pace.")
    }

    private func diagnose(rx: Double) -> ConnectionDiagnosis {
        NetworkInsightsAnalyzer.diagnose(
            snapshot: RouterSnapshot(rxPowerDbm: rx),
            devices: [],
            blockedDevices: [],
            wifi: WifiState(),
            speedTest: nil
        )
    }

    private func makeDevice(
        mac: String,
        name: String,
        port: ConnectionPort,
        rssi: Double? = nil,
        online: Bool = true
    ) -> OntDevice {
        OntDevice(
            mac: mac,
            ip: "192.168.100.10",
            hostName: name,
            routerAlias: "",
            dhcpVendor: "",
            port: port,
            isOnline: online,
            connectedTime: "0:10",
            rssiDbm: rssi
        )
    }

    private func date(_ year: Int, _ month: Int, _ day: Int, calendar: Calendar) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: 12))!
    }

    private func point(_ year: Int, _ month: Int, _ day: Int, gb: Double, calendar: Calendar) -> DailyUsagePoint {
        let bytes = UInt64(gb * 1_000_000_000)
        return DailyUsagePoint(
            date: date(year, month, day, calendar: calendar),
            label: "\(day)",
            downloadBytes: bytes,
            uploadBytes: 0,
            isPartial: false
        )
    }
}

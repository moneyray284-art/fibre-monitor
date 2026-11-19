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

        XCTAssertEqual(diagnose(rx: -26).severity, .optimal)
        XCTAssertEqual(diagnose(rx: -27).severity, .critical)
        XCTAssertEqual(diagnose(rx: -7).severity, .critical)
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
                WifiNetwork(ssidIndex: 1, name: "Home Sweet WiFi", band: "2.4GHz", enabled: true),
                WifiNetwork(ssidIndex: 2, name: "Speed Matters", band: "2.4GHz", enabled: true),
                WifiNetwork(ssidIndex: 5, name: "Meta", band: "5GHz", enabled: true)
            ]
        )

        let result = NetworkInsightsAnalyzer.diagnose(
            snapshot: RouterSnapshot(rxPowerDbm: -15.97),
            devices: devices,
            blockedDevices: [],
            wifi: wifi,
            speedTest: healthySpeedTest()
        )

        let bandCheck = try! XCTUnwrap(result.checks.first { $0.title == "Wi-Fi Band Balance" })
        XCTAssertTrue(result.hasWiFiBandConcern)
        XCTAssertEqual(bandCheck.status, .warning)
        XCTAssertTrue(bandCheck.detail.contains("‘Home Sweet WiFi’"))
        XCTAssertTrue(bandCheck.detail.contains("‘Meta’"))
        XCTAssertTrue(bandCheck.detail.contains("‘Speed Matters’"))
        XCTAssertEqual(bandCheck.action, .reviewWiFiBands)
        XCTAssertEqual(result.checks.first { $0.title == "Latency & Speed" }?.action, .runSpeedTest)
        XCTAssertNil(result.checks.first { $0.title == "Optical Fibre Line" }?.action)
    }

    func testClientRSSIAloneDoesNotCreateDiagnosisAlertOrCheck() {
        let lowSignal = makeDevice(mac: "00:00:00:00:00:11", name: "Private Wi-Fi Device", port: .wifi24(ssidIndex: 1), rssi: -96)
        let result = NetworkInsightsAnalyzer.diagnose(
            snapshot: RouterSnapshot(rxPowerDbm: -15),
            devices: [lowSignal],
            blockedDevices: [],
            wifi: WifiState(
                radios: [
                    WifiRadio(index: 1, band: "2.4GHz", enabled: true),
                    WifiRadio(index: 2, band: "5GHz", enabled: true)
                ],
                networks: [
                    WifiNetwork(ssidIndex: 1, name: "Home Sweet WiFi", band: "2.4GHz", enabled: true),
                    WifiNetwork(ssidIndex: 5, name: "Meta", band: "5GHz", enabled: true)
                ]
            ),
            speedTest: healthySpeedTest()
        )

        XCTAssertEqual(result.checks.count, 3)
        XCTAssertEqual(result.severity, .optimal)
        XCTAssertFalse(result.hasWiFiBandConcern)
        XCTAssertFalse(result.summary.localizedCaseInsensitiveContains("weak"))
    }

    func testMissingRouterReadingsRemainPendingInsteadOfAttention() {
        let result = NetworkInsightsAnalyzer.diagnose(
            snapshot: RouterSnapshot(),
            devices: [],
            blockedDevices: [],
            wifi: WifiState(),
            speedTest: healthySpeedTest()
        )

        XCTAssertEqual(result.severity, .pending)
        XCTAssertEqual(result.checks.count, 3)
    }

    func testCrowdingRequiresAtLeastFourOnlineClientsAnd75PercentOn24GHz() {
        let devices = (1...3).map { index in
            makeDevice(
                mac: String(format: "00:00:00:00:01:%02x", index),
                name: "Phone \(index)",
                port: .wifi24(ssidIndex: index)
            )
        }
        let result = NetworkInsightsAnalyzer.diagnose(
            snapshot: RouterSnapshot(rxPowerDbm: -15),
            devices: devices,
            blockedDevices: [],
            wifi: WifiState(
                radios: [
                    WifiRadio(index: 1, band: "2.4GHz", enabled: true),
                    WifiRadio(index: 2, band: "5GHz", enabled: true)
                ],
                networks: [WifiNetwork(ssidIndex: 5, name: "Meta", band: "5GHz", enabled: true)]
            ),
            speedTest: healthySpeedTest()
        )

        XCTAssertFalse(result.hasWiFiBandConcern)
        XCTAssertEqual(result.severity, .optimal)
    }

    func testDegradedSpeedTestRaisesLatencyAndSpeedCheck() {
        let result = NetworkInsightsAnalyzer.diagnose(
            snapshot: RouterSnapshot(rxPowerDbm: -15),
            devices: [],
            blockedDevices: [],
            wifi: WifiState(
                radios: [WifiRadio(index: 2, band: "5GHz", enabled: true)],
                networks: [WifiNetwork(ssidIndex: 5, name: "Meta", band: "5GHz", enabled: true)]
            ),
            speedTest: SpeedTestResult(pingMs: 120, jitterMs: 35, downloadMbps: 9, uploadMbps: 4)
        )

        let speedCheck = result.checks.first { $0.title == "Latency & Speed" }
        XCTAssertEqual(speedCheck?.status, .warning)
        XCTAssertTrue(speedCheck?.detail.contains("high ping") == true)
        XCTAssertEqual(result.severity, .warning)
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
            point(2026, 6, 5, gb: 7, calendar: calendar)
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
        XCTAssertEqual(forecast.dailyAverageGb ?? 0, 4.6, accuracy: 0.001)
        XCTAssertEqual(forecast.remainingDays, 24)
        XCTAssertEqual(forecast.projectedMonthGb ?? 0, 135.4, accuracy: 0.001)
        XCTAssertEqual(forecast.spikeDays.count, 1)
        XCTAssertEqual(forecast.spikeDays.first?.totalGb ?? 0, 7, accuracy: 0.001)
        XCTAssertEqual(forecast.spikeDays.first?.multiplier ?? 0, 7 / 4.6, accuracy: 0.001)
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
            wifi: healthyWifiState(),
            speedTest: healthySpeedTest()
        )
    }

    private func healthyWifiState() -> WifiState {
        WifiState(
            radios: [
                WifiRadio(index: 1, band: "2.4GHz", enabled: true),
                WifiRadio(index: 2, band: "5GHz", enabled: true)
            ],
            networks: [
                WifiNetwork(ssidIndex: 1, name: "Home Sweet WiFi", band: "2.4GHz", enabled: true),
                WifiNetwork(ssidIndex: 5, name: "Meta", band: "5GHz", enabled: true)
            ]
        )
    }

    private func healthySpeedTest() -> SpeedTestResult {
        SpeedTestResult(pingMs: 24, jitterMs: 4, downloadMbps: 100, uploadMbps: 20)
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

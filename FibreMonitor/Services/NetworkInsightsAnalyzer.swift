import Foundation

#if canImport(FoundationModels)
import FoundationModels
#endif

enum InsightSeverity: String, Equatable, Sendable {
    case optimal
    case warning
    case critical

    var label: String {
        switch self {
        case .optimal: "Optimal"
        case .warning: "Needs Attention"
        case .critical: "Action Needed"
        }
    }
}

enum InsightCheckStatus: Equatable, Sendable {
    case optimal
    case warning
    case critical
    case pending
}

struct ConnectionDiagnosisCheck: Equatable, Identifiable, Sendable {
    var id: String { title }
    let title: String
    let status: InsightCheckStatus
    let detail: String
    let symbol: String
}

enum ConnectionDiagnosisAction: String, CaseIterable, Equatable, Sendable, Identifiable {
    case inspectWeakClients
    case reviewWiFiBands
    case runSpeedTest

    var id: String { rawValue }

    var title: String {
        switch self {
        case .inspectWeakClients: "Inspect Weak Clients"
        case .reviewWiFiBands: "Review Wi-Fi Bands"
        case .runSpeedTest: "Run Speed Test"
        }
    }

    var symbol: String {
        switch self {
        case .inspectWeakClients: "wifi.exclamationmark"
        case .reviewWiFiBands: "wifi"
        case .runSpeedTest: "speedometer"
        }
    }
}

struct WeakClientSignal: Equatable, Sendable, Identifiable {
    var id: String { mac.lowercased() }
    let mac: String
    let name: String
    let rssiDbm: Double
}

struct ConnectionDiagnosis: Sendable {
    let severity: InsightSeverity
    let verdictTitle: String
    let inlineHint: String
    let summary: String
    let checks: [ConnectionDiagnosisCheck]
    let actions: [ConnectionDiagnosisAction]
    let weakClients: [WeakClientSignal]
    let hasWiFiBandConcern: Bool
}

struct UsageForecastDay: Equatable, Sendable, Identifiable {
    var id: Date { date }
    let date: Date
    let totalGb: Double
    let multiplier: Double
}

struct UsageForecast: Sendable {
    let activeReadingDayCount: Int
    let completedDayCount: Int
    let remainingDays: Int
    let dailyAverageGb: Double?
    let projectedMonthGb: Double?
    let peakDay: UsageForecastDay?
    let spikeDays: [UsageForecastDay]
    let hasEnoughData: Bool
    let paceNote: String
}

enum NetworkInsightsAnalyzer {
    static func diagnose(
        snapshot: RouterSnapshot,
        devices: [OntDevice],
        deviceNames: [String: String] = [:],
        blockedDevices: [BlockedRouterDevice],
        wifi: WifiState,
        speedTest: SpeedTestResult?
    ) -> ConnectionDiagnosis {
        let blockedMACs = Set(blockedDevices.map { normalizedMAC($0.mac) })
        let onlineDevices = devices.filter { $0.isOnline && !blockedMACs.contains(normalizedMAC($0.mac)) }

        let opticalStatus: InsightCheckStatus
        let opticalDetail: String
        let opticalHint: String?
        if let rx = snapshot.rxPowerDbm {
            if (-24.0...(-8.0)).contains(rx) {
                opticalStatus = .optimal
                opticalDetail = String(format: "Optical RX is healthy at %.2f dBm.", rx)
                opticalHint = nil
            } else if rx < -24.0 && rx > -27.0 {
                opticalStatus = .warning
                opticalDetail = String(format: "Optical RX is marginal at %.2f dBm; monitor the fibre connection.", rx)
                opticalHint = String(format: "Optical RX is marginal at %.1f dBm", rx)
            } else if rx <= -27.0 || rx >= -7.0 {
                opticalStatus = .critical
                opticalDetail = String(format: "Optical RX is weak at %.2f dBm; inspect the fibre path and connectors.", rx)
                opticalHint = String(format: "Optical RX is weak at %.1f dBm", rx)
            } else {
                // The unspecified -8...-7 dBm edge is treated as marginal rather than healthy.
                opticalStatus = .warning
                opticalDetail = String(format: "Optical RX is outside the preferred range at %.2f dBm.", rx)
                opticalHint = String(format: "Optical RX needs a closer look at %.1f dBm", rx)
            }
        } else {
            opticalStatus = .pending
            opticalDetail = "Optical RX reading is not available yet."
            opticalHint = nil
        }

        let active24Names = activeSSIDNames(in: wifi, band: .twoPointFour)
        let active5Names = activeSSIDNames(in: wifi, band: .five)
        let fiveGEnabled = bandEnabled(in: wifi, band: .five)
        let wifi24Clients = onlineDevices.filter { wifiBand(for: $0.port) == .twoPointFour }
        let crowdThresholdReached: Bool
        if onlineDevices.count >= 4 {
            crowdThresholdReached = Double(wifi24Clients.count) / Double(onlineDevices.count) >= 0.75
                || (onlineDevices.count >= 3 && Double(wifi24Clients.count) / Double(onlineDevices.count) >= 0.60)
        } else if onlineDevices.count >= 3 {
            crowdThresholdReached = Double(wifi24Clients.count) / Double(onlineDevices.count) >= 0.60
        } else {
            crowdThresholdReached = false
        }
        let isFiveGOff = fiveGEnabled == false
        let hasWiFiBandConcern = isFiveGOff || crowdThresholdReached

        let wifiStatus: InsightCheckStatus
        let wifiDetail: String
        let wifiHint: String?
        if isFiveGOff {
            wifiStatus = .warning
            let source = active24Names.isEmpty ? "the active 2.4 GHz network" : quoted(active24Names)
            let target = active5Names.isEmpty ? "an enabled 5 GHz network" : quoted(active5Names)
            wifiDetail = "5 GHz is off. Turn it on, then move capable devices from \(source) to \(target)."
            wifiHint = "5 GHz is off"
        } else if crowdThresholdReached {
            wifiStatus = .warning
            let source = active24Names.isEmpty ? "the active 2.4 GHz network" : quoted(active24Names)
            let target = active5Names.isEmpty ? "the active 5 GHz network" : quoted(active5Names)
            wifiDetail = "\(wifi24Clients.count) of \(onlineDevices.count) online devices use 2.4 GHz. Move capable devices from \(source) to \(target)."
            wifiHint = "Many devices are using 2.4 GHz"
        } else if fiveGEnabled == nil && wifi.radios.isEmpty && wifi.networks.isEmpty {
            wifiStatus = .pending
            wifiDetail = "Wi-Fi radio and SSID information is not available yet."
            wifiHint = nil
        } else {
            wifiStatus = .optimal
            let names = [active24Names, active5Names].flatMap { $0 }
            wifiDetail = names.isEmpty
                ? "The reported Wi-Fi bands are enabled and no 2.4 GHz crowding threshold was reached."
                : "Active router networks: \(quoted(names)). No 2.4 GHz crowding threshold was reached."
            wifiHint = nil
        }

        let weakClients = onlineDevices.compactMap { device -> WeakClientSignal? in
            guard let rssi = device.rssiDbm, rssi <= -75 else { return nil }
            return WeakClientSignal(
                mac: device.mac,
                name: deviceNames[normalizedMAC(device.mac)] ?? device.displayName,
                rssiDbm: rssi
            )
        }
        .sorted { lhs, rhs in
            if lhs.rssiDbm != rhs.rssiDbm { return lhs.rssiDbm < rhs.rssiDbm }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }

        let weakStatus: InsightCheckStatus = weakClients.isEmpty ? (onlineDevices.isEmpty ? .pending : .optimal) : .warning
        let weakDetail: String
        if weakClients.isEmpty {
            weakDetail = onlineDevices.isEmpty
                ? "No online client signal readings are available yet."
                : "No online non-blocked clients are reporting signal at or below -75 dBm."
        } else {
            let affected = weakClients.prefix(2).map {
                "\($0.name) (\(Int($0.rssiDbm.rounded())) dBm)"
            }.joined(separator: ", ")
            let additional = weakClients.count > 2 ? " and \(weakClients.count - 2) more" : ""
            weakDetail = "Weak Wi-Fi signal: \(affected)\(additional)."
        }

        let speedStatus: InsightCheckStatus
        let speedDetail: String
        if let speedTest {
            speedStatus = .optimal
            speedDetail = String(
                format: "Latest test: %.0f ms ping, %.0f ms jitter, %.1f Mbps down and %.1f Mbps up.",
                speedTest.pingMs,
                speedTest.jitterMs,
                speedTest.downloadMbps,
                speedTest.uploadMbps
            )
        } else {
            speedStatus = .pending
            speedDetail = "Not tested yet · Pending"
        }

        let checks = [
            ConnectionDiagnosisCheck(title: "Optical Fibre Line", status: opticalStatus, detail: opticalDetail, symbol: "waveform.path.ecg"),
            ConnectionDiagnosisCheck(title: "Wi-Fi Band Balance", status: wifiStatus, detail: wifiDetail, symbol: "wifi"),
            ConnectionDiagnosisCheck(title: "Weak Client Signals", status: weakStatus, detail: weakDetail, symbol: "wifi.exclamationmark"),
            ConnectionDiagnosisCheck(title: "Latency & Speed", status: speedStatus, detail: speedDetail, symbol: "speedometer")
        ]

        let severity: InsightSeverity
        if opticalStatus == .critical {
            severity = .critical
        } else if opticalStatus == .warning || hasWiFiBandConcern || !weakClients.isEmpty || opticalStatus == .pending {
            severity = .warning
        } else {
            severity = .optimal
        }

        let verdictTitle: String
        switch severity {
        case .optimal: verdictTitle = "Your connection looks healthy"
        case .warning: verdictTitle = "Your connection needs attention"
        case .critical: verdictTitle = "Action needed on your fibre line"
        }

        let inlineHint: String
        if let opticalHint, opticalStatus == .critical || opticalStatus == .warning {
            inlineHint = opticalHint
        } else if isFiveGOff {
            inlineHint = "5 GHz is off"
        } else if let wifiHint {
            inlineHint = wifiHint
        } else if let weakest = weakClients.first {
            inlineHint = "\(weakest.name) has weak signal at \(Int(weakest.rssiDbm.rounded())) dBm"
        } else if opticalStatus == .pending {
            inlineHint = "Waiting for fibre reading"
        } else {
            inlineHint = "Fibre and Wi-Fi readings look healthy"
        }

        var summaryParts = [opticalDetail]
        if wifiStatus == .warning { summaryParts.append(wifiDetail) }
        if !weakClients.isEmpty { summaryParts.append(weakDetail) }
        if speedTest == nil { summaryParts.append(speedDetail) }

        var actions: [ConnectionDiagnosisAction] = []
        if !weakClients.isEmpty { actions.append(.inspectWeakClients) }
        if hasWiFiBandConcern { actions.append(.reviewWiFiBands) }
        if speedTest == nil { actions.append(.runSpeedTest) }

        return ConnectionDiagnosis(
            severity: severity,
            verdictTitle: verdictTitle,
            inlineHint: inlineHint,
            summary: summaryParts.joined(separator: " "),
            checks: checks,
            actions: actions,
            weakClients: weakClients,
            hasWiFiBandConcern: hasWiFiBandConcern
        )
    }

    static func forecast(
        history: [DailyUsagePoint],
        selectedMonth: Date,
        todayDownloadBytes: UInt64,
        todayUploadBytes: UInt64,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> UsageForecast {
        let monthStart = calendar.dateInterval(of: .month, for: selectedMonth)?.start ?? calendar.startOfDay(for: selectedMonth)
        let today = calendar.startOfDay(for: now)
        let currentMonthStart = calendar.dateInterval(of: .month, for: now)?.start ?? today
        let historyByDay = Dictionary(history.map { (calendar.startOfDay(for: $0.date), $0) }, uniquingKeysWith: { _, latest in latest })
        let days = makeMonthPoints(
            monthStart: monthStart,
            historyByDay: historyByDay,
            todayDownloadBytes: todayDownloadBytes,
            todayUploadBytes: todayUploadBytes,
            today: today,
            calendar: calendar
        )

        let activeDays = days.filter { $0.totalBytes != nil }
        let completed = activeDays.filter {
            calendar.startOfDay(for: $0.date) < today && !$0.isPartial
        }
        let completedGB = completed.compactMap { totalGB($0.totalBytes) }
        let average = completedGB.count >= 2 ? completedGB.reduce(0, +) / Double(completedGB.count) : nil

        let remainingDays: Int
        if calendar.isDate(monthStart, equalTo: currentMonthStart, toGranularity: .month),
           let range = calendar.range(of: .day, in: .month, for: monthStart) {
            let todayDay = calendar.component(.day, from: today)
            remainingDays = max(0, range.count - todayDay)
        } else {
            remainingDays = 0
        }

        let monthToDateGB = activeDays.compactMap { totalGB($0.totalBytes) }.reduce(0, +)
        let projected = completed.count >= 3 ? monthToDateGB + (average ?? 0) * Double(remainingDays) : nil

        let peak = activeDays.compactMap { point -> UsageForecastDay? in
            guard let gb = totalGB(point.totalBytes) else { return nil }
            return UsageForecastDay(date: point.date, totalGb: gb, multiplier: 0)
        }.max { $0.totalGb < $1.totalGb }

        let spikes: [UsageForecastDay]
        if let average, average > 0 {
            spikes = activeDays.compactMap { point -> UsageForecastDay? in
                guard let gb = totalGB(point.totalBytes), gb >= 5.0 else { return nil }
                let multiplier = gb / average
                guard multiplier >= 1.45 else { return nil }
                return UsageForecastDay(date: point.date, totalGb: gb, multiplier: multiplier)
            }
            .sorted {
                if $0.multiplier != $1.multiplier { return $0.multiplier > $1.multiplier }
                return $0.date > $1.date
            }
        } else {
            spikes = []
        }

        let hasEnoughData = completed.count >= 3
        let paceNote = paceDescription(completed: completed, averageGB: average, hasEnoughData: hasEnoughData, calendar: calendar)

        return UsageForecast(
            activeReadingDayCount: activeDays.count,
            completedDayCount: completed.count,
            remainingDays: remainingDays,
            dailyAverageGb: average,
            projectedMonthGb: projected,
            peakDay: peak,
            spikeDays: spikes,
            hasEnoughData: hasEnoughData,
            paceNote: paceNote
        )
    }

    private static func makeMonthPoints(
        monthStart: Date,
        historyByDay: [Date: DailyUsagePoint],
        todayDownloadBytes: UInt64,
        todayUploadBytes: UInt64,
        today: Date,
        calendar: Calendar
    ) -> [DailyUsagePoint] {
        guard let range = calendar.range(of: .day, in: .month, for: monthStart) else { return [] }
        return range.compactMap { dayNumber in
            guard let date = calendar.date(byAdding: .day, value: dayNumber - 1, to: monthStart) else { return nil }
            let key = calendar.startOfDay(for: date)
            if key == today, todayDownloadBytes > 0 || todayUploadBytes > 0 {
                return DailyUsagePoint(
                    date: key,
                    label: String(dayNumber),
                    downloadBytes: todayDownloadBytes,
                    uploadBytes: todayUploadBytes,
                    isPartial: true
                )
            }
            return historyByDay[key]
        }
    }

    private static func totalGB(_ totalBytes: UInt64?) -> Double? {
        guard let totalBytes else { return nil }
        return Double(totalBytes) / 1_000_000_000
    }

    private static func paceDescription(
        completed: [DailyUsagePoint],
        averageGB: Double?,
        hasEnoughData: Bool,
        calendar: Calendar
    ) -> String {
        guard hasEnoughData, let averageGB, averageGB > 0 else {
            return "Need 3 completed days to compare your recent pace."
        }
        let latestThree = completed.sorted { $0.date < $1.date }.suffix(3)
        let recentGB = latestThree.compactMap { totalGB($0.totalBytes) }
        guard recentGB.count == 3 else { return "Need 3 completed days to compare your recent pace." }
        let recentAverage = recentGB.reduce(0, +) / 3
        let difference = recentAverage / averageGB - 1
        if difference >= 0.15 {
            return String(format: "Your last 3 completed days are running %.0f%% above your average pace.", difference * 100)
        }
        if difference <= -0.15 {
            return String(format: "Your last 3 completed days are running %.0f%% below your average pace.", abs(difference) * 100)
        }
        return "Your recent pace is in line with your average."
    }

    private static func normalizedMAC(_ mac: String) -> String {
        mac.lowercased().filter(\.isHexDigit)
    }

    private static func quoted(_ names: [String]) -> String {
        names.map { "‘\($0)’" }.joined(separator: ", ")
    }

    private static func activeSSIDNames(in wifi: WifiState, band: WifiFrequencyBand) -> [String] {
        Array(Set(wifi.networks.compactMap { network -> String? in
            guard network.enabled,
                  resolvedBand(index: network.ssidIndex, fallback: network.band) == band else { return nil }
            let name = network.name.trimmingCharacters(in: .whitespacesAndNewlines)
            return name.isEmpty ? nil : name
        })).sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    private static func bandEnabled(in wifi: WifiState, band: WifiFrequencyBand) -> Bool? {
        let matchingRadios = wifi.radios.filter { radio in
            let resolved: WifiFrequencyBand?
            if radio.index == 1 { resolved = .twoPointFour }
            else if radio.index == 2 { resolved = .five }
            else { resolved = WifiFrequencyBand(rawValue: radio.band) }
            return resolved == band
        }
        if let radio = matchingRadios.first { return radio.enabled }

        let networks = wifi.networks.filter { resolvedBand(index: $0.ssidIndex, fallback: $0.band) == band }
        guard !networks.isEmpty else { return nil }
        return networks.contains(where: \.enabled)
    }

    private static func resolvedBand(index: Int, fallback: String) -> WifiFrequencyBand? {
        WifiFrequencyBand(rawValue: WifiFrequencyBand.label(for: index, fallback: fallback))
    }

    private static func wifiBand(for port: ConnectionPort) -> WifiFrequencyBand? {
        switch port {
        case .wifi24(_): .twoPointFour
        case .wifi5(_): .five
        case .lan(_), .other(_): nil
        }
    }
}

enum ConnectionDiagnosisNarrative {
    static func polish(_ diagnosis: ConnectionDiagnosis) async -> String? {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            return await polishWithFoundationModels(diagnosis)
        }
        #endif
        return nil
    }

    #if canImport(FoundationModels)
    @available(iOS 26.0, *)
    private static func polishWithFoundationModels(_ diagnosis: ConnectionDiagnosis) async -> String? {
        guard SystemLanguageModel.default.availability == .available else { return nil }
        let session = LanguageModelSession(instructions: """
        Rewrite the supplied router diagnosis as one concise, calm plain-English summary. Use only the supplied facts, names, and numbers. Do not add, change, round, or infer metrics. Do not change severity or recommendations. Return one sentence only.
        """)
        let facts = "Severity: \(diagnosis.severity.label). Summary: \(diagnosis.summary)"

        return await withTaskGroup(of: String?.self) { group in
            group.addTask {
                do {
                    let response = try await session.respond(to: facts)
                    let candidate = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !candidate.isEmpty,
                          candidate.count <= 280,
                          !candidate.contains("\n"),
                          numericTokens(in: candidate) == numericTokens(in: facts) else { return nil }
                    return candidate
                } catch {
                    return nil
                }
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                return nil
            }
            let firstResult = await group.next() ?? nil
            group.cancelAll()
            return firstResult
        }
    }

    @available(iOS 26.0, *)
    private static func numericTokens(in text: String) -> [String] {
        guard let expression = try? NSRegularExpression(pattern: #"(?<![A-Za-z])[-+]?\d+(?:\.\d+)?"#) else { return [] }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return expression.matches(in: text, range: range).compactMap { match in
            guard let range = Range(match.range, in: text) else { return nil }
            return String(text[range])
        }
    }
    #endif
}

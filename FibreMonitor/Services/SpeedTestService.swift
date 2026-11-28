import Foundation

struct SpeedTestResult: Equatable, Sendable {
    let pingMs: Double
    let jitterMs: Double
    let downloadMbps: Double
    let uploadMbps: Double

    var downMbps: Double { downloadMbps }
    var upMbps: Double { uploadMbps }
}
public struct SpeedTestRecord: Codable, Identifiable, Equatable {
    public let id: UUID
    public let timestamp: Date
    public let pingMs: Double
    public let jitterMs: Double
    public let downMbps: Double
    public let upMbps: Double

    public init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        pingMs: Double,
        jitterMs: Double,
        downMbps: Double,
        upMbps: Double
    ) {
        self.id = id
        self.timestamp = timestamp
        self.pingMs = pingMs
        self.jitterMs = jitterMs
        self.downMbps = downMbps
        self.upMbps = upMbps
    }

    private enum CodingKeys: String, CodingKey {
        case id, timestamp, pingMs, jitterMs, downMbps, upMbps
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? values.decode(UUID.self, forKey: .id)) ?? UUID()
        timestamp = (try? values.decode(Date.self, forKey: .timestamp)) ?? .distantPast
        pingMs = (try? values.decode(Double.self, forKey: .pingMs)) ?? 0
        jitterMs = (try? values.decode(Double.self, forKey: .jitterMs)) ?? 0
        downMbps = (try? values.decode(Double.self, forKey: .downMbps)) ?? 0
        upMbps = (try? values.decode(Double.self, forKey: .upMbps)) ?? 0
    }

    var result: SpeedTestResult {
        SpeedTestResult(pingMs: pingMs, jitterMs: jitterMs, downloadMbps: downMbps, uploadMbps: upMbps)
    }
}

enum SpeedTestPhase: String, Equatable, Sendable {
    case idle = "Ready"
    case ping = "Checking latency"
    case download = "Measuring download"
    case upload = "Measuring upload"
}

struct SpeedTestProgress: Equatable, Sendable {
    typealias Phase = SpeedTestPhase

    var phase: SpeedTestPhase
    var liveDownKbps: Double
    var liveUpKbps: Double
    var pingMs: Double?
    var jitterMs: Double?
    var testDownMbps: Double?
    var testUpMbps: Double?
    var fraction: Double
    var detail: String
    var elapsed: TimeInterval?

    var currentMbps: Double? {
        switch phase {
        case .download: liveDownKbps / 1_000
        case .upload: liveUpKbps / 1_000
        case .idle, .ping: nil
        }
    }

    init(
        phase: SpeedTestPhase,
        fraction: Double = 0,
        detail: String = "",
        currentMbps: Double? = nil,
        pingMs: Double? = nil,
        jitterMs: Double? = nil,
        elapsed: TimeInterval? = nil,
        liveDownKbps: Double = 0,
        liveUpKbps: Double = 0,
        testDownMbps: Double? = nil,
        testUpMbps: Double? = nil
    ) {
        self.phase = phase
        self.fraction = fraction
        self.detail = detail
        self.pingMs = pingMs
        self.jitterMs = jitterMs
        self.elapsed = elapsed
        self.liveDownKbps = phase == .download ? (currentMbps ?? 0) * 1_000 : liveDownKbps
        self.liveUpKbps = phase == .upload ? (currentMbps ?? 0) * 1_000 : liveUpKbps
        self.testDownMbps = testDownMbps
        self.testUpMbps = testUpMbps
    }
}

private final class TransferByteCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var bytes: Int64 = 0

    func add(_ value: Int64) {
        lock.lock()
        bytes += value
        lock.unlock()
    }

    var total: Int64 {
        lock.lock()
        defer { lock.unlock() }
        return bytes
    }
}

enum SpeedTestEngine {
    private static let fastEndpoint = URL(string: "https://api.fast.com/netflix/speedtest/v2?https=true&token=YXNkZmFzZGxmbnNkYWZoYXNkZmhrYWxm&urlCount=5")!
    private static let appleConfigURL = URL(string: "https://mensura.cdn-apple.com/api/v1/gm/config")!
    private static let applePingFallbackURL = URL(string: "https://mensura.cdn-apple.com/api/v1/gm/small")!
    private static let transferWindow: TimeInterval = 8
    private static let fastRangeBytes = 512 * 1_024
    private static let uploadBytes = 512 * 1_024
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.allowsCellularAccess = false
        configuration.waitsForConnectivity = false
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 24
        return URLSession(configuration: configuration)
    }()

    private struct AppleEndpoints: Decodable, Equatable {
        let smallDownload: URL
        let largeDownload: URL
        let upload: URL

        enum CodingKeys: String, CodingKey {
            case smallDownload = "small_https_download_url"
            case largeDownload = "large_https_download_url"
            case upload = "https_upload_url"
        }
    }

    static func runBenchmark(
        gatewayURL: URL? = nil,
        onProgress: @escaping @Sendable (SpeedTestProgress) async -> Void
    ) async throws -> SpeedTestResult {
        try Task.checkCancellation()
        try requireSpeedTestNetwork()
        async let fastTargetsResult = try? fetchFastTargets()
        async let appleResult = try? fetchAppleEndpoints()
        let fastTargets = (await fastTargetsResult) ?? []
        let apple = await appleResult
        try Task.checkCancellation()

        guard !fastTargets.isEmpty || apple != nil else {
            throw SpeedTestError.noServers
        }

        let latency = try await measureLatency(
            gatewayURL: gatewayURL,
            fastTargets: fastTargets,
            appleFallback: apple?.smallDownload,
            onProgress: onProgress
        )
        try Task.checkCancellation()
        await onProgress(.init(
            phase: .ping,
            fraction: 1,
            detail: "Latency measured",
            pingMs: latency.pingMs,
            jitterMs: latency.jitterMs
        ))

        let fastDownloadURLs = fastTargets.compactMap { rangeURL(for: $0, byteCount: fastRangeBytes) }
        var downloadMbps = 0.0
        if !fastDownloadURLs.isEmpty {
            downloadMbps = try await measureTransfer(
                urls: fastDownloadURLs,
                mode: .download,
                phase: .download,
                onProgress: onProgress
            )
        }
        if downloadMbps <= 0, let apple {
            downloadMbps = try await measureTransfer(
                urls: Array(repeating: apple.largeDownload, count: 4),
                mode: .download,
                phase: .download,
                onProgress: onProgress
            )
        }
        try Task.checkCancellation()
        guard downloadMbps > 0 else { throw SpeedTestError.downloadFailed }
        await onProgress(.init(
            phase: .download,
            fraction: 1,
            detail: "Download measured",
            currentMbps: downloadMbps,
            pingMs: latency.pingMs,
            jitterMs: latency.jitterMs,
            elapsed: transferWindow
        ))

        let payload = randomPayload(count: uploadBytes)
        var uploadMbps = 0.0
        if !fastTargets.isEmpty {
            uploadMbps = try await measureTransfer(
                urls: fastTargets,
                mode: .upload(payload),
                phase: .upload,
                onProgress: onProgress
            )
        }
        if uploadMbps <= 0, let apple {
            uploadMbps = try await measureTransfer(
                urls: Array(repeating: apple.upload, count: 4),
                mode: .upload(payload),
                phase: .upload,
                onProgress: onProgress
            )
        }
        try Task.checkCancellation()
        guard uploadMbps > 0 else { throw SpeedTestError.uploadFailed }
        await onProgress(.init(
            phase: .upload,
            fraction: 1,
            detail: "Upload measured",
            currentMbps: uploadMbps,
            pingMs: latency.pingMs,
            jitterMs: latency.jitterMs,
            elapsed: transferWindow
        ))

        return SpeedTestResult(
            pingMs: latency.pingMs,
            jitterMs: latency.jitterMs,
            downloadMbps: downloadMbps,
            uploadMbps: uploadMbps
        )
    }

    private static func fetchFastTargets() async throws -> [URL] {
        try requireSpeedTestNetwork()
        var request = URLRequest(url: fastEndpoint)
        request.timeoutInterval = 10
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let targets = object["targets"] as? [[String: Any]] else {
            throw SpeedTestError.noServers
        }
        return Array(targets.prefix(5).compactMap { item in
            guard let value = item["url"] as? String else { return nil }
            return URL(string: value)
        })
    }

    private static func fetchAppleEndpoints() async throws -> AppleEndpoints {
        try requireSpeedTestNetwork()
        var request = URLRequest(url: appleConfigURL)
        request.timeoutInterval = 10
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw SpeedTestError.noServers
        }
        return try JSONDecoder().decode(AppleEndpoints.self, from: data)
    }

    private static func measureLatency(
        gatewayURL: URL?,
        fastTargets: [URL],
        appleFallback: URL?,
        onProgress: @escaping @Sendable (SpeedTestProgress) async -> Void
    ) async throws -> (pingMs: Double, jitterMs: Double) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpMaximumConnectionsPerHost = 1
        configuration.waitsForConnectivity = false
        configuration.allowsCellularAccess = false
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.timeoutIntervalForRequest = 0.32
        configuration.timeoutIntervalForResource = 0.32
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }

        var candidates = [gatewayURL].compactMap { $0 }
        candidates += Array(fastTargets.filter(isAllowedFastEdge).prefix(1))
        candidates += [appleFallback, applePingFallbackURL]
            .compactMap { $0 }
            .filter(isApplePingHost)

        for candidate in candidates {
            try Task.checkCancellation()
            var samples: [Double] = []
            await onProgress(.init(phase: .ping, fraction: 0, detail: "Probing \(candidate.host ?? "gateway")"))

            for index in 0..<6 {
                try Task.checkCancellation()
                var request = URLRequest(url: candidate)
                request.httpMethod = "HEAD"
                request.timeoutInterval = 0.32
                request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
                let start = ContinuousClock.now
                do {
                    let (_, response) = try await session.data(for: request)
                    guard response is HTTPURLResponse else { break }
                    let duration = start.duration(to: .now)
                    let components = duration.components
                    let milliseconds = Double(components.seconds) * 1_000
                        + Double(components.attoseconds) / 1e15
                    samples.append(milliseconds)
                } catch {
                    if Task.isCancelled { throw CancellationError() }
                    break
                }
                await onProgress(.init(
                    phase: .ping,
                    fraction: Double(index + 1) / 6,
                    detail: "Probe \(index + 1) of 6"
                ))
                if index < 5 {
                    try await Task.sleep(nanoseconds: 50_000_000)
                }
            }

            if samples.count >= 3 {
                let ping = samples.reduce(0, +) / Double(samples.count)
                let jitter = zip(samples, samples.dropFirst())
                    .map { abs($1 - $0) }
                    .reduce(0, +) / Double(max(1, samples.count - 1))
                return (ping, jitter)
            }
        }
        throw SpeedTestError.latencyFailed
    }

    private static func isAllowedFastEdge(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https",
              let host = url.host?.lowercased() else { return false }
        return host != "api.fast.com" && !host.hasSuffix(".api.fast.com")
    }

    private static func isApplePingHost(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "https" && url.host?.lowercased() == "mensura.cdn-apple.com"
    }

    private enum TransferMode: Sendable {
        case download
        case upload(Data)
    }

    private static func measureTransfer(
        urls: [URL],
        mode: TransferMode,
        phase: SpeedTestProgress.Phase,
        onProgress: @escaping @Sendable (SpeedTestProgress) async -> Void
    ) async throws -> Double {
        guard !urls.isEmpty else { return 0 }
        let beganAt = Date()
        let deadline = beganAt.addingTimeInterval(transferWindow)
        let progressBytes = TransferByteCounter()
        let totalBytes = try await withThrowingTaskGroup(of: Int64.self) { group in
            for url in urls.prefix(5) {
                group.addTask {
                    var bytes: Int64 = 0
                    while Date() < deadline && !Task.isCancelled {
                        var request = URLRequest(url: url)
                        guard NetworkMonitor.shared.speedTestAllowed else { break }
                        request.timeoutInterval = transferWindow + 4
                        request.cachePolicy = .reloadIgnoringLocalCacheData
                        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
                        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
                        do {
                            let data: Data
                            let response: URLResponse
                            switch mode {
                            case .download:
                                request.httpMethod = "GET"
                                (data, response) = try await session.data(for: request)
                            case .upload(let body):
                                request.httpMethod = "POST"
                                request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
                                (data, response) = try await session.upload(for: request, from: body)
                            }
                            guard let http = response as? HTTPURLResponse,
                                  (200..<300).contains(http.statusCode) else { break }
                            switch mode {
                            case .download:
                                let transferred = Int64(data.count)
                                bytes += transferred
                                progressBytes.add(transferred)
                            case .upload(let body):
                                let transferred = Int64(body.count)
                                bytes += transferred
                                progressBytes.add(transferred)
                            }
                        } catch {
                            if Task.isCancelled { return bytes }
                            break
                        }
                    }
                    return bytes
                }
            }

            var priorBytes: Int64 = 0
            var priorSampleTime = beganAt
            while Date() < deadline {
                try Task.checkCancellation()
                let now = Date()
                let fraction = min(1, max(0, now.timeIntervalSince(beganAt) / transferWindow))
                let secondsLeft = max(0, Int(ceil(deadline.timeIntervalSinceNow)))
                let currentBytes = progressBytes.total
                let sampleDuration = now.timeIntervalSince(priorSampleTime)
                let currentMbps = sampleDuration > 0
                    ? Double(max(Int64.zero, currentBytes - priorBytes)) * 8 / (sampleDuration * 1_000_000)
                    : 0
                await onProgress(.init(
                    phase: phase,
                    fraction: fraction,
                    detail: "\(secondsLeft)s remaining",
                    currentMbps: currentMbps,
                    elapsed: now.timeIntervalSince(beganAt)
                ))
                priorBytes = currentBytes
                priorSampleTime = now
                try await Task.sleep(nanoseconds: 250_000_000)
            }
            group.cancelAll()
            var total: Int64 = 0
            for try await bytes in group { total += bytes }
            return total
        }
        try Task.checkCancellation()
        return Double(totalBytes) * 8 / (transferWindow * 1_000_000)
    }

    private static func rangeURL(for base: URL, byteCount: Int) -> URL? {
        guard var components = URLComponents(url: base, resolvingAgainstBaseURL: false),
              components.path.hasSuffix("/speedtest") else { return nil }
        components.path += "/range/0-\(byteCount)"
        return components.url
    }

    private static func randomPayload(count: Int) -> Data {
        var generator = SystemRandomNumberGenerator()
        return Data((0..<count).map { _ in UInt8.random(in: UInt8.min...UInt8.max, using: &generator) })
    }

    private static func requireSpeedTestNetwork() throws {
        guard NetworkMonitor.shared.speedTestAllowed else {
            throw SpeedTestError.networkUnavailable
        }
    }

    private enum SpeedTestError: LocalizedError {
        case noServers
        case latencyFailed
        case downloadFailed
        case uploadFailed
        case networkUnavailable

        var errorDescription: String? {
            switch self {
            case .noServers: "Could not reach a speed test server. Check your internet connection and try again."
            case .latencyFailed: "Could not measure latency. Check your internet connection and try again."
            case .downloadFailed: "The download test did not complete. Try again in a moment."
            case .uploadFailed: "The upload test did not complete. Try again in a moment."
            case .networkUnavailable: "Connect to Wi-Fi and an internet path to run a speed test."
            }
        }
    }
}

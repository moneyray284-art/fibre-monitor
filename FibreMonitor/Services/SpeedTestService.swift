import Foundation

struct SpeedTestResult: Equatable, Sendable {
    let pingMs: Double
    let jitterMs: Double
    let downloadMbps: Double
    let uploadMbps: Double
}

struct SpeedTestProgress: Equatable, Sendable {
    enum Phase: String, Equatable, Sendable {
        case ping = "Checking latency"
        case download = "Measuring download"
        case upload = "Measuring upload"
    }

    let phase: Phase
    let fraction: Double
    let detail: String
    var currentMbps: Double? = nil
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

private struct RTTMeasurement: Sendable {
    let milliseconds: Double
    let usedPersistentConnection: Bool
}

enum SpeedTestService {
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

    static func run(
        onProgress: @escaping @MainActor (SpeedTestProgress) -> Void
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
            fastTargets: fastTargets,
            appleFallback: apple?.smallDownload,
            onProgress: onProgress
        )
        try Task.checkCancellation()

        let fastDownloadURLs = fastTargets.compactMap { rangeURL(for: $0, byteCount: fastRangeBytes) }
        var downloadMbps = 0.0
        if !fastDownloadURLs.isEmpty {
            downloadMbps = await measureTransfer(
                urls: fastDownloadURLs,
                mode: .download,
                phase: .download,
                onProgress: onProgress
            )
        }
        if downloadMbps <= 0, let apple {
            downloadMbps = await measureTransfer(
                urls: Array(repeating: apple.largeDownload, count: 4),
                mode: .download,
                phase: .download,
                onProgress: onProgress
            )
        }
        try Task.checkCancellation()
        guard downloadMbps > 0 else { throw SpeedTestError.downloadFailed }

        let payload = randomPayload(count: uploadBytes)
        var uploadMbps = 0.0
        if !fastTargets.isEmpty {
            uploadMbps = await measureTransfer(
                urls: fastTargets,
                mode: .upload(payload),
                phase: .upload,
                onProgress: onProgress
            )
        }
        if uploadMbps <= 0, let apple {
            uploadMbps = await measureTransfer(
                urls: Array(repeating: apple.upload, count: 4),
                mode: .upload(payload),
                phase: .upload,
                onProgress: onProgress
            )
        }
        try Task.checkCancellation()
        guard uploadMbps > 0 else { throw SpeedTestError.uploadFailed }

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
        fastTargets: [URL],
        appleFallback: URL?,
        onProgress: @escaping @MainActor (SpeedTestProgress) -> Void
    ) async throws -> (pingMs: Double, jitterMs: Double) {
        let delegate = RTTMetricsDelegate()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpMaximumConnectionsPerHost = 4
        configuration.waitsForConnectivity = true
        configuration.allowsCellularAccess = false
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.timeoutIntervalForRequest = 5
        configuration.timeoutIntervalForResource = 10

        // Reuse this one session for both warm-ups and probes; URLSession keeps its
        // persistent connection alive between the sequential HEAD tasks.
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }

        let fastEdge = fastTargets.first(where: isAllowedFastEdge)
        var samples: [Double] = []
        if let fastEdge {
            samples = await warmedRTTSamples(
                url: fastEdge,
                label: "Warming Fast edge",
                session: session,
                delegate: delegate,
                onProgress: onProgress
            )
        }

        if samples.count != 8 {
            let appleURL = [appleFallback, applePingFallbackURL]
                .compactMap { $0 }
                .first(where: isApplePingHost)
            if let appleURL {
                samples = await warmedRTTSamples(
                    url: appleURL,
                    label: "Warming Apple edge",
                    session: session,
                    delegate: delegate,
                    onProgress: onProgress
                )
            }
        }

        guard samples.count == 8, let ping = median(samples) else {
            throw SpeedTestError.latencyFailed
        }

        let outlierLimit = ping * 3
        let jitterPairs = zip(samples, samples.dropFirst()).filter {
            $0.0 <= outlierLimit && $0.1 <= outlierLimit
        }
        let jitter = jitterPairs.isEmpty
            ? 0
            : jitterPairs.reduce(0) { $0 + abs($1.1 - $1.0) } / Double(jitterPairs.count)
        return (ping, jitter)
    }

    private static func warmedRTTSamples(
        url: URL,
        label: String,
        session: URLSession,
        delegate: RTTMetricsDelegate,
        onProgress: @escaping @MainActor (SpeedTestProgress) -> Void
    ) async -> [Double] {
        await onProgress(.init(phase: .ping, fraction: 0, detail: label))

        // These requests complete DNS, TCP, and TLS setup but are deliberately discarded.
        for index in 0..<2 {
            guard let warmup = await delegate.measureRTT(to: url, in: session) else { return [] }
            if index == 1 && !warmup.usedPersistentConnection { return [] }
        }

        var samples: [Double] = []
        for index in 0..<8 {
            if let sample = await delegate.measureRTT(to: url, in: session), sample.usedPersistentConnection {
                samples.append(sample.milliseconds)
            }
            await onProgress(.init(
                phase: .ping,
                fraction: Double(index + 1) / 8,
                detail: "Probe \(index + 1) of 8"
            ))
            if index < 7 {
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
        }
        return samples
    }

    private static func isAllowedFastEdge(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https",
              let host = url.host?.lowercased() else { return false }
        return host != "api.fast.com" && !host.hasSuffix(".api.fast.com")
    }

    private static func isApplePingHost(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "https" && url.host?.lowercased() == "mensura.cdn-apple.com"
    }

    private static func median(_ samples: [Double]) -> Double? {
        guard !samples.isEmpty else { return nil }
        let sorted = samples.sorted()
        let middle = sorted.count / 2
        if sorted.count.isMultiple(of: 2) {
            return (sorted[middle - 1] + sorted[middle]) / 2
        }
        return sorted[middle]
    }

    private enum TransferMode: Sendable {
        case download
        case upload(Data)
    }

    private static func measureTransfer(
        urls: [URL],
        mode: TransferMode,
        phase: SpeedTestProgress.Phase,
        onProgress: @escaping @MainActor (SpeedTestProgress) -> Void
    ) async -> Double {
        guard !urls.isEmpty else { return 0 }
        let beganAt = Date()
        let deadline = beganAt.addingTimeInterval(transferWindow)
        let progressBytes = TransferByteCounter()
        let totalBytes = await withTaskGroup(of: Int64.self) { group in
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
                            break
                        }
                    }
                    return bytes
                }
            }

            var priorBytes: Int64 = 0
            var priorSampleTime = beganAt
            while Date() < deadline && !Task.isCancelled {
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
                    currentMbps: currentMbps
                ))
                priorBytes = currentBytes
                priorSampleTime = now
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
            group.cancelAll()
            var total: Int64 = 0
            for await bytes in group { total += bytes }
            return total
        }
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

/// Collects URLSession transaction timing for sequential, warmed HEAD probes.
private final class RTTMetricsDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private struct Probe {
        let continuation: CheckedContinuation<RTTMeasurement?, Never>
        var measurement: RTTMeasurement?
        var hasMetrics = false
        var completedSuccessfully: Bool?
    }

    private struct Completion {
        let continuation: CheckedContinuation<RTTMeasurement?, Never>
        let measurement: RTTMeasurement?
    }

    private let lock = NSLock()
    private var probes: [Int: Probe] = [:]

    func measureRTT(to url: URL, in session: URLSession) async -> RTTMeasurement? {
        guard NetworkMonitor.shared.speedTestAllowed else { return nil }
        return await withCheckedContinuation { (continuation: CheckedContinuation<RTTMeasurement?, Never>) in
            var request = URLRequest(url: url)
            request.httpMethod = "HEAD"
            request.timeoutInterval = 5
            request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData

            let task = session.dataTask(with: request)
            store(Probe(continuation: continuation), for: task.taskIdentifier)
            task.resume()
        }
    }

    private func store(_ probe: Probe, for taskIdentifier: Int) {
        lock.lock()
        probes[taskIdentifier] = probe
        lock.unlock()
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didFinishCollecting metrics: URLSessionTaskMetrics
    ) {
        let lastTransaction = metrics.transactionMetrics.last
        let measurement: RTTMeasurement?
        if let requestStart = lastTransaction?.requestStartDate,
           let responseStart = lastTransaction?.responseStartDate,
           responseStart >= requestStart {
            measurement = RTTMeasurement(
                milliseconds: responseStart.timeIntervalSince(requestStart) * 1_000,
                usedPersistentConnection: lastTransaction?.isReusedConnection ?? false
            )
        } else {
            measurement = nil
        }

        var completion: Completion?
        lock.lock()
        if var probe = probes[task.taskIdentifier] {
            probe.measurement = measurement
            probe.hasMetrics = true
            if let succeeded = probe.completedSuccessfully {
                probes.removeValue(forKey: task.taskIdentifier)
                completion = Completion(
                    continuation: probe.continuation,
                    measurement: succeeded ? measurement : nil
                )
            } else {
                probes[task.taskIdentifier] = probe
            }
        }
        lock.unlock()

        if let completion {
            completion.continuation.resume(returning: completion.measurement)
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        let succeeded = error == nil && task.response is HTTPURLResponse
        var completion: Completion?
        lock.lock()
        if var probe = probes[task.taskIdentifier] {
            probe.completedSuccessfully = succeeded
            if !succeeded {
                probes.removeValue(forKey: task.taskIdentifier)
                completion = Completion(continuation: probe.continuation, measurement: nil)
            } else if probe.hasMetrics {
                probes.removeValue(forKey: task.taskIdentifier)
                completion = Completion(
                    continuation: probe.continuation,
                    measurement: probe.measurement
                )
            } else {
                probes[task.taskIdentifier] = probe
            }
        }
        lock.unlock()

        if let completion {
            completion.continuation.resume(returning: completion.measurement)
        }
    }

    /// Use the server's first response directly instead of timing a redirected host.
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

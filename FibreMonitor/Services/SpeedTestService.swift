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
}

enum SpeedTestService {
    private static let fastEndpoint = URL(string: "https://api.fast.com/netflix/speedtest/v2?https=true&token=YXNkZmFzZGxmbnNkYWZoYXNkZmhrYWxm&urlCount=5")!
    private static let appleConfigURL = URL(string: "https://mensura.cdn-apple.com/api/v1/gm/config")!
    private static let transferWindow: TimeInterval = 8
    private static let fastRangeBytes = 512 * 1_024
    private static let uploadBytes = 512 * 1_024

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
        async let fastTargetsResult = try? fetchFastTargets()
        async let appleResult = try? fetchAppleEndpoints()
        let fastTargets = (await fastTargetsResult) ?? []
        let apple = await appleResult

        guard !fastTargets.isEmpty || apple != nil else {
            throw SpeedTestError.noServers
        }

        var pings: [Double] = []
        if fastTargets.count >= 5 {
            pings = await measureFastPing(targets: Array(fastTargets.prefix(5)), onProgress: onProgress)
        }
        if pings.count < 5, let apple {
            pings = await measureApplePing(endpoint: apple.smallDownload, onProgress: onProgress)
        }
        guard pings.count == 5 else { throw SpeedTestError.latencyFailed }

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
        guard uploadMbps > 0 else { throw SpeedTestError.uploadFailed }

        let ping = pings.reduce(0, +) / Double(pings.count)
        let jitterSamples = zip(pings, pings.dropFirst()).map { abs($1 - $0) }
        let jitter = jitterSamples.isEmpty ? 0 : jitterSamples.reduce(0, +) / Double(jitterSamples.count)
        return SpeedTestResult(pingMs: ping, jitterMs: jitter, downloadMbps: downloadMbps, uploadMbps: uploadMbps)
    }

    private static func fetchFastTargets() async throws -> [URL] {
        var request = URLRequest(url: fastEndpoint)
        request.timeoutInterval = 10
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let (data, response) = try await URLSession.shared.data(for: request)
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
        var request = URLRequest(url: appleConfigURL)
        request.timeoutInterval = 10
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw SpeedTestError.noServers
        }
        return try JSONDecoder().decode(AppleEndpoints.self, from: data)
    }

    private static func measureFastPing(
        targets: [URL],
        onProgress: @escaping @MainActor (SpeedTestProgress) -> Void
    ) async -> [Double] {
        var samples: [Double] = []
        for index in 0..<5 {
            let target = targets[index]
            guard let url = rangeURL(for: target, byteCount: 0) else { continue }
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.timeoutInterval = 5
            request.cachePolicy = .reloadIgnoringLocalCacheData
            let started = ProcessInfo.processInfo.systemUptime
            do {
                let (_, response) = try await URLSession.shared.data(for: request)
                if let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) {
                    samples.append((ProcessInfo.processInfo.systemUptime - started) * 1_000)
                }
            } catch {
                // Continue all five probes; Apple's endpoint is used if Fast cannot complete them.
            }
            await onProgress(.init(phase: .ping, fraction: Double(index + 1) / 5, detail: "Probe \(index + 1) of 5"))
        }
        return samples
    }

    private static func measureApplePing(
        endpoint: URL,
        onProgress: @escaping @MainActor (SpeedTestProgress) -> Void
    ) async -> [Double] {
        var samples: [Double] = []
        for index in 0..<5 {
            var request = URLRequest(url: endpoint)
            request.httpMethod = "HEAD"
            request.timeoutInterval = 5
            request.cachePolicy = .reloadIgnoringLocalCacheData
            let started = ProcessInfo.processInfo.systemUptime
            do {
                let (_, response) = try await URLSession.shared.data(for: request)
                if let http = response as? HTTPURLResponse, (200..<400).contains(http.statusCode) {
                    samples.append((ProcessInfo.processInfo.systemUptime - started) * 1_000)
                }
            } catch {
                // Keep probing so a transient request failure does not end the whole test early.
            }
            await onProgress(.init(phase: .ping, fraction: Double(index + 1) / 5, detail: "Probe \(index + 1) of 5"))
        }
        return samples
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
        let totalBytes = await withTaskGroup(of: Int64.self) { group in
            for url in urls.prefix(5) {
                group.addTask {
                    var bytes: Int64 = 0
                    while Date() < deadline && !Task.isCancelled {
                        var request = URLRequest(url: url)
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
                                (data, response) = try await URLSession.shared.data(for: request)
                            case .upload(let body):
                                request.httpMethod = "POST"
                                request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
                                (data, response) = try await URLSession.shared.upload(for: request, from: body)
                            }
                            guard let http = response as? HTTPURLResponse,
                                  (200..<300).contains(http.statusCode) else { break }
                            switch mode {
                            case .download: bytes += Int64(data.count)
                            case .upload(let body): bytes += Int64(body.count)
                            }
                        } catch {
                            break
                        }
                    }
                    return bytes
                }
            }

            while Date() < deadline && !Task.isCancelled {
                let fraction = min(1, max(0, Date().timeIntervalSince(beganAt) / transferWindow))
                let secondsLeft = max(0, Int(ceil(deadline.timeIntervalSinceNow)))
                await onProgress(.init(phase: phase, fraction: fraction, detail: "\(secondsLeft)s remaining"))
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

    private enum SpeedTestError: LocalizedError {
        case noServers
        case latencyFailed
        case downloadFailed
        case uploadFailed

        var errorDescription: String? {
            switch self {
            case .noServers: "Could not reach a speed test server. Check your internet connection and try again."
            case .latencyFailed: "Could not measure latency. Check your internet connection and try again."
            case .downloadFailed: "The download test did not complete. Try again in a moment."
            case .uploadFailed: "The upload test did not complete. Try again in a moment."
            }
        }
    }
}

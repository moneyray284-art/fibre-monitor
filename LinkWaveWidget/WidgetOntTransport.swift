import Foundation
import Network

public struct OntRequest: Equatable, Sendable {
    public enum Method: String, Sendable { case get = "GET", post = "POST" }

    public var method: Method
    public var path: String
    public var form: [(String, String)]
    public var ajax: Bool
    public var timeoutInterval: TimeInterval?

    public init(
        _ method: Method,
        _ path: String,
        form: [(String, String)] = [],
        ajax: Bool = true,
        timeoutInterval: TimeInterval? = nil
    ) {
        self.method = method
        self.path = path
        self.form = form
        self.ajax = ajax
        self.timeoutInterval = timeoutInterval
    }

    public static func == (lhs: OntRequest, rhs: OntRequest) -> Bool {
        lhs.method == rhs.method && lhs.path == rhs.path && lhs.ajax == rhs.ajax
            && lhs.timeoutInterval == rhs.timeoutInterval
            && lhs.form.map { $0.0 } == rhs.form.map { $0.0 }
            && lhs.form.map { $0.1 } == rhs.form.map { $0.1 }
    }

    public var encodedForm: String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return form.map { key, value in
            let encodedKey = key.addingPercentEncoding(withAllowedCharacters: allowed) ?? key
            let encodedValue = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
            return "\(encodedKey)=\(encodedValue)"
        }.joined(separator: "&")
    }
}

public protocol OntTransport: Sendable {
    var requiresWiFiForRouterRequests: Bool { get }
    func send(_ request: OntRequest, host: String) async throws -> String
    func resetSession(host: String) async
    func validateRouterNetwork() async throws
    func cancelPendingRequests() async
}

public extension OntTransport {
    var requiresWiFiForRouterRequests: Bool { false }
    func validateRouterNetwork() async throws { }
    func cancelPendingRequests() async { }
}

private final class WidgetWiFiPath: @unchecked Sendable {
    static let shared = WidgetWiFiPath()

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "dev.mattdev0.fibremonitor.widget-network")
    private let lock = NSLock()
    private var resolved = false
    private var onWiFi = false

    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            self.lock.lock()
            self.resolved = true
            self.onWiFi = path.status == .satisfied && path.usesInterfaceType(.wifi)
            self.lock.unlock()
        }
        monitor.start(queue: queue)
    }

    func isOnWiFi() async -> Bool {
        for _ in 0..<10 {
            let state = currentState()
            if state.resolved { return state.onWiFi }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return currentState().onWiFi
    }

    private func currentState() -> (resolved: Bool, onWiFi: Bool) {
        lock.lock()
        defer { lock.unlock() }
        return (resolved, onWiFi)
    }
}

public final class URLSessionOntTransport: OntTransport, @unchecked Sendable {
    public var requiresWiFiForRouterRequests: Bool { true }

    private let session: URLSession
    private let cookies: HTTPCookieStorage?

    public init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 4
        configuration.timeoutIntervalForResource = 8
        configuration.waitsForConnectivity = false
        configuration.allowsCellularAccess = false
        configuration.httpCookieAcceptPolicy = .always
        configuration.httpShouldSetCookies = true
        cookies = configuration.httpCookieStorage
        session = URLSession(configuration: configuration)
    }

    public func resetSession(host: String) async {
        for cookie in cookies?.cookies ?? [] { cookies?.deleteCookie(cookie) }
        guard let cookie = HTTPCookie(properties: [
            .name: "Cookie",
            .value: "body:Language:english:id=-1",
            .domain: host,
            .path: "/",
        ]) else { return }
        cookies?.setCookie(cookie)
    }

    public func send(_ request: OntRequest, host: String) async throws -> String {
        try await validateRouterNetwork()
        guard let url = URL(string: "http://\(host)\(request.path)") else { throw URLError(.badURL) }
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = request.method.rawValue
        urlRequest.timeoutInterval = request.timeoutInterval ?? 4
        urlRequest.cachePolicy = .reloadIgnoringLocalCacheData
        urlRequest.setValue("http://\(host)", forHTTPHeaderField: "Origin")
        urlRequest.setValue("http://\(host)/", forHTTPHeaderField: "Referer")
        if request.ajax { urlRequest.setValue("XMLHttpRequest", forHTTPHeaderField: "X-Requested-With") }
        if request.method == .post {
            urlRequest.setValue("application/x-www-form-urlencoded; charset=UTF-8", forHTTPHeaderField: "Content-Type")
            urlRequest.httpBody = Data(request.encodedForm.utf8)
        }
        let (data, response) = try await session.data(for: urlRequest)
        if let response = response as? HTTPURLResponse, !(200...299).contains(response.statusCode) {
            throw URLError(.badServerResponse)
        }
        return String(decoding: data, as: UTF8.self)
    }

    public func validateRouterNetwork() async throws {
        guard await WidgetWiFiPath.shared.isOnWiFi() else { throw URLError(.notConnectedToInternet) }
    }

    public func cancelPendingRequests() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            session.getAllTasks { tasks in
                tasks.forEach { $0.cancel() }
                continuation.resume()
            }
        }
    }
}

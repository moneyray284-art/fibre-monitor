import Combine
import Foundation
import Network

public struct NetworkPathState: Equatable, Sendable {
    public let isConnectedToWiFi: Bool
    public let hasInternetPath: Bool

    public init(isConnectedToWiFi: Bool = false, hasInternetPath: Bool = false) {
        self.isConnectedToWiFi = isConnectedToWiFi
        self.hasInternetPath = hasInternetPath
    }
}

private final class NetworkRequestPolicy: @unchecked Sendable {
    private let lock = NSLock()
    private var pathState = NetworkPathState()

    func update(_ state: NetworkPathState) {
        lock.lock()
        pathState = state
        lock.unlock()
    }

    func currentState() -> NetworkPathState {
        lock.lock()
        defer { lock.unlock() }
        return pathState
    }
}

/// Shared device network state. Router traffic is permitted only over Wi-Fi;
/// the speed test additionally requires a satisfied network path.
public final class NetworkMonitor: ObservableObject, @unchecked Sendable {
    public static let shared = NetworkMonitor()

    @Published public private(set) var pathState = NetworkPathState()

    private let monitor: NWPathMonitor
    private let queue: DispatchQueue
    private let requestPolicy: NetworkRequestPolicy

    public var isConnectedToWiFi: Bool { pathState.isConnectedToWiFi }
    public var hasInternetPath: Bool { pathState.hasInternetPath }

    /// Thread-safe snapshots for URLSession and actor callers.
    public var routerRequestsAllowed: Bool { requestPolicy.currentState().isConnectedToWiFi }
    public var speedTestAllowed: Bool {
        let state = requestPolicy.currentState()
        return state.isConnectedToWiFi && state.hasInternetPath
    }

    private init() {
        let monitor = NWPathMonitor()
        let queue = DispatchQueue(label: "com.linkwave.networkmonitor", qos: .utility)
        let requestPolicy = NetworkRequestPolicy()
        self.monitor = monitor
        self.queue = queue
        self.requestPolicy = requestPolicy

        monitor.pathUpdateHandler = { [weak self, requestPolicy] path in
            let state = NetworkPathState(
                isConnectedToWiFi: path.status == .satisfied && path.usesInterfaceType(.wifi),
                hasInternetPath: path.status == .satisfied
            )
            requestPolicy.update(state)
            Task { @MainActor [weak self] in
                self?.pathState = state
            }
        }
        monitor.start(queue: queue)
    }
}

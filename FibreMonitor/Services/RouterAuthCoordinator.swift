import Foundation

/// Shares one login attempt for every request using the same Huawei client and cookie store.
public actor RouterAuthCoordinator {
    private let transport: OntTransport
    private var credentials: HuaweiOntClient.Credentials
    private var loginTask: Task<Void, Error>?
    private var isAuthenticated = false
    private var credentialsPreviouslyValidated = false
    private var authFailure: RouterAuthFailure?
    private var detectedIdentity: HuaweiOntClient.RouterIdentity?
    private var isUpdatingCredentials = false
    private var sessionGeneration: UInt64 = 0

    public init(credentials: HuaweiOntClient.Credentials, transport: OntTransport) {
        self.credentials = credentials
        self.transport = transport
    }

    public func authenticate() async throws -> HuaweiOntClient.RouterIdentity? {
        guard !isUpdatingCredentials else { throw CancellationError() }

        if case .invalidCredentials? = authFailure {
            throw OntError.loginRejected
        }
        if case .temporarilyLocked(let retryAt)? = authFailure {
            if Date() < retryAt { throw OntError.loginTemporarilyLocked }
            authFailure = nil
        }
        if isAuthenticated { return detectedIdentity }

        if let loginTask {
            try await loginTask.value
            return detectedIdentity
        }

        let loginCredentials = credentials
        let task = Task { try await self.performLogin(using: loginCredentials) }
        loginTask = task
        do {
            try await task.value
            loginTask = nil
            isAuthenticated = true
            credentialsPreviouslyValidated = true
            sessionGeneration &+= 1
            authFailure = nil
            return detectedIdentity
        } catch {
            loginTask = nil
            if let ontError = error as? OntError {
                switch ontError {
                case .loginTemporarilyLocked:
                    authFailure = .temporarilyLocked(retryAt: Date().addingTimeInterval(65))
                case .loginRejected:
                    authFailure = credentialsPreviouslyValidated
                        ? .temporarilyLocked(retryAt: Date().addingTimeInterval(65))
                        : .invalidCredentials
                default:
                    break
                }
            }
            throw error
        }
    }

    public func currentFailure() -> RouterAuthFailure? {
        if case .temporarilyLocked(let retryAt)? = authFailure, Date() >= retryAt {
            return nil
        }
        return authFailure
    }

    public func currentGeneration() -> UInt64 { sessionGeneration }

    public func invalidateSession() {
        isAuthenticated = false
        detectedIdentity = nil
        sessionGeneration &+= 1
    }

    public func beginSessionClose() async {
        isUpdatingCredentials = true
        if let loginTask {
            loginTask.cancel()
            _ = try? await loginTask.value
        }
        loginTask = nil
        invalidateSession()
    }

    public func finishSessionClose() {
        isUpdatingCredentials = false
    }

    @discardableResult
    public func invalidateSession(ifGeneration generation: UInt64) -> Bool {
        guard sessionGeneration == generation else { return false }
        invalidateSession()
        return true
    }

    public func updateCredentials(_ newCredentials: HuaweiOntClient.Credentials) async {
        isUpdatingCredentials = true
        if let loginTask {
            loginTask.cancel()
            _ = try? await loginTask.value
        }
        loginTask = nil
        credentials = newCredentials
        isAuthenticated = false
        credentialsPreviouslyValidated = false
        sessionGeneration &+= 1
        authFailure = nil
        detectedIdentity = nil
        isUpdatingCredentials = false
    }

    private func performLogin(using credentials: HuaweiOntClient.Credentials) async throws {
        await transport.resetSession(host: credentials.host)

        // Token and login requests are deliberately sequential and use this transport's
        // single URLSession cookie store.
        let token = HuaweiJs.clean(try await transport.send(
            .init(.post, "/asp/GetRandCount.asp"),
            host: credentials.host
        ))
        guard !token.isEmpty, !token.contains("<") else {
            // Some firmware returns an empty or HTML body while its login service is busy.
            throw OntError.loginTemporarilyLocked
        }

        let reply = try await transport.send(.init(.post, "/login.cgi", form: [
            ("UserName", credentials.username),
            ("PassWord", Data(credentials.password.utf8).base64EncodedString()),
            ("Language", "english"),
            ("x.X_HW_Token", token),
        ], ajax: false), host: credentials.host)

        guard reply.contains("index.asp") else {
            if Self.looksLikeTemporaryLockout(reply) {
                throw OntError.loginTemporarilyLocked
            }
            throw OntError.loginRejected
        }

        if let indexText = try? await transport.send(
            .init(.get, "/index.asp", ajax: false),
            host: credentials.host
        ) {
            let model = HuaweiJs.stringVar("ProductName", in: indexText)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let cfg = HuaweiJs.stringVar("CfgMode", in: indexText)?.trimmingCharacters(in: .whitespacesAndNewlines)
            if model?.isEmpty == false || cfg?.isEmpty == false {
                detectedIdentity = HuaweiOntClient.RouterIdentity(
                    model: model?.isEmpty == false ? model : nil,
                    cfgMode: cfg?.isEmpty == false ? cfg : nil
                )
            }
        }
    }

    private static func looksLikeTemporaryLockout(_ response: String) -> Bool {
        let text = response.lowercased()
        let indicators = [
            "temporarily locked", "login locked", "account locked", "locked out", "lockout",
            "too many attempts", "too many failed", "login attempts exceeded", "try again later",
            "retry after", "attempt limit", "session busy", "router busy", "please wait",
            "login in progress", "already logged in",
            "another session", "user already", "账号锁定", "登录锁定", "尝试次数过多",
        ]
        return indicators.contains { text.contains($0) }
    }
}

import Foundation

public enum RouterType: String, Codable, CaseIterable, Identifiable, Sendable {
    case huaweiONT
    case generic

    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .huaweiONT: "Huawei ONT"
        case .generic: "Generic router"
        }
    }
}

/// A saved Huawei ONT connection profile with its own credentials and device aliases.
public struct RouterProfile: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var host: String
    public var username: String
    public var lastUsed: Date?
    public var detectedModel: String?
    public var cfgMode: String?
    /// Optional for backwards-compatible decoding of profiles saved before v2.2.
    public var routerType: RouterType?

    public var resolvedRouterType: RouterType { routerType ?? .huaweiONT }

    public init(
        id: UUID = UUID(),
        name: String,
        host: String,
        username: String = "root",
        lastUsed: Date? = nil,
        detectedModel: String? = nil,
        cfgMode: String? = nil,
        routerType: RouterType? = .huaweiONT
    ) {
        self.id = id
        self.name = name
        self.host = host
        self.username = username
        self.lastUsed = lastUsed
        self.detectedModel = detectedModel
        self.cfgMode = cfgMode
        self.routerType = routerType
    }

    /// Backwards-compatible prefilled MTN profile; the Add Router UI now uses its preset selector.
    public static func mtnTemplate(id: UUID = UUID()) -> RouterProfile {
        RouterProfile(id: id, name: "New router (MTN)", host: "192.168.2.1", username: "root")
    }
}

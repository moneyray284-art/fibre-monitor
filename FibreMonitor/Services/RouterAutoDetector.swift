import Foundation

/// A router profile suggested from the Wi-Fi gateway and its unauthenticated web page.
public enum RouterAutoDetector {
    public static func detectProfile(at gateway: String) async -> RouterProfile? {
        guard let host = LocalWiFiAddress.normalizedIPv4(gateway),
              let url = URL(string: "http://\(host)/") else { return nil }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 1.5
        configuration.timeoutIntervalForResource = 1.5
        configuration.waitsForConnectivity = false
        configuration.allowsCellularAccess = false
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 1.5
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData

        guard let (data, response) = try? await session.data(for: request) else { return nil }
        let headers = (response as? HTTPURLResponse)?.allHeaderFields.values
            .map { String(describing: $0) }
            .joined(separator: " ") ?? ""
        let page = (String(decoding: data, as: UTF8.self) + " " + headers).lowercased()
        let hasMTNSignature = page.contains("mtn")
        let hasTelecelSignature = page.contains("telecel")
        let isHuaweiPage = page.contains("huawei")
            || page.contains("hg8145x6-10")
            || page.contains("hg8145v5")
            || (page.contains("login.cgi") && (page.contains("txt_username") || page.contains("txt_password")))
        guard isHuaweiPage || hasMTNSignature || hasTelecelSignature else { return nil }

        let model: String
        if page.contains("hg8145x6-10") {
            model = "HG8145X6-10"
        } else if page.contains("hg8145v5") {
            model = "HG8145V5"
        } else if isHuaweiPage {
            model = "Huawei ONT"
        } else {
            model = ""
        }

        let profileName: String
        if hasTelecelSignature {
            profileName = "Telecel Fibre"
        } else if hasMTNSignature {
            profileName = "MTN Fibre"
        } else if host == "192.168.2.1" {
            profileName = "MTN Fibre"
        } else if host == "192.168.100.1" {
            profileName = "Telecel Fibre"
        } else if !model.isEmpty, model != "Huawei ONT" {
            profileName = "Huawei \(model)"
        } else {
            profileName = "Huawei ONT"
        }

        return RouterProfile(
            name: profileName,
            host: host,
            username: "root",
            detectedModel: model.isEmpty ? nil : model,
            routerType: .huaweiONT
        )
    }
}

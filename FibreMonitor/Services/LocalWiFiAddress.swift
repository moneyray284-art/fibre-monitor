import Darwin
import Foundation

public enum LocalWiFiAddress {
    public static func currentIPv4Address(interface targetInterface: String = "en0") -> String? {
        var firstInterface: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&firstInterface) == 0, let firstInterface else { return nil }
        defer { freeifaddrs(firstInterface) }

        var currentInterface: UnsafeMutablePointer<ifaddrs>? = firstInterface
        while let current = currentInterface {
            let entry = current.pointee
            if String(cString: entry.ifa_name) == targetInterface,
               let socketAddress = entry.ifa_addr,
               socketAddress.pointee.sa_family == UInt8(AF_INET) {
                var address = socketAddress.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                    $0.pointee.sin_addr
                }
                var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                let result = buffer.withUnsafeMutableBufferPointer { bytes in
                    inet_ntop(AF_INET, &address, bytes.baseAddress, socklen_t(INET_ADDRSTRLEN))
                }
                if result != nil {
                    return String(cString: buffer)
                }
            }
            currentInterface = entry.ifa_next
        }
        return nil
    }

    public static func normalizedIPv4(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        guard !trimmed.isEmpty else { return nil }

        var address = in_addr()
        guard trimmed.withCString({ inet_pton(AF_INET, $0, &address) }) == 1 else { return nil }

        var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        let result = buffer.withUnsafeMutableBufferPointer { bytes in
            inet_ntop(AF_INET, &address, bytes.baseAddress, socklen_t(INET_ADDRSTRLEN))
        }
        return result == nil ? nil : String(cString: buffer)
    }
}


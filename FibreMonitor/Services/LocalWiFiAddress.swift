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

    /// Infers the common .1 gateway address from the active Wi-Fi IPv4 /24 subnet.
    /// iOS does not expose a supported public API for reading the default gateway.
    public static func defaultGatewayIPv4(interface targetInterface: String = "en0") -> String? {
        guard let address = currentIPv4Address(interface: targetInterface) else { return nil }
        let octets = address.split(separator: ".")
        guard octets.count == 4,
              let first = Int(octets[0]), (first == 10 || first == 192 || first == 172),
              let third = Int(octets[2]) else { return nil }
        if first == 192, Int(octets[1]) != 168 { return nil }
        if first == 172 {
            guard let second = Int(octets[1]), (16...31).contains(second) else { return nil }
        }
        return "\(octets[0]).\(octets[1]).\(third).1"
    }
}


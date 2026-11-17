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

    /// Reads the active IPv4 default route for Wi-Fi. If iOS does not expose the route
    /// table in the current environment, falls back to the common .1 address in the
    /// iPhone's local /24 subnet.
    public static func defaultGatewayIPv4(interface targetInterface: String = "en0") -> String? {
        if let gateway = routeTableDefaultGateway(interface: targetInterface) {
            return gateway
        }
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

    private static func routeTableDefaultGateway(interface targetInterface: String) -> String? {
        let interfaceIndex = if_nametoindex(targetInterface)
        guard interfaceIndex != 0 else { return nil }

        var mib = [CTL_NET, PF_ROUTE, 0, AF_INET, NET_RT_DUMP, 0]
        var byteCount = 0
        guard sysctl(&mib, u_int(mib.count), nil, &byteCount, nil, 0) == 0,
              byteCount >= MemoryLayout<rt_msghdr>.size else { return nil }

        let table = UnsafeMutableRawPointer.allocate(byteCount: byteCount, alignment: MemoryLayout<rt_msghdr>.alignment)
        defer { table.deallocate() }
        guard sysctl(&mib, u_int(mib.count), table, &byteCount, nil, 0) == 0 else { return nil }

        let routeAlignment = MemoryLayout<Int>.size
        var offset = 0
        while offset + MemoryLayout<rt_msghdr>.size <= byteCount {
            let header = table.advanced(by: offset).assumingMemoryBound(to: rt_msghdr.self).pointee
            let messageLength = Int(header.rtm_msglen)
            guard messageLength >= MemoryLayout<rt_msghdr>.size,
                  offset + messageLength <= byteCount else { break }
            let routeOffset = offset
            offset += messageLength

            let flags = header.rtm_flags
            guard UInt32(header.rtm_index) == interfaceIndex,
                  flags & (RTF_UP | RTF_GATEWAY) == (RTF_UP | RTF_GATEWAY) else { continue }

            var cursor = routeOffset + MemoryLayout<rt_msghdr>.size
            let end = routeOffset + messageLength
            var isDefaultRoute = false
            var gatewayAddress: String?
            let addressMask = Int(header.rtm_addrs)
            for addressBit in 0..<8 where addressMask & (1 << addressBit) != 0 {
                guard cursor + MemoryLayout<sockaddr>.size <= end else { break }
                let address = table.advanced(by: cursor).assumingMemoryBound(to: sockaddr.self)
                let addressLength = max(Int(address.pointee.sa_len), MemoryLayout<sockaddr>.size)
                guard cursor + addressLength <= end else { break }

                if addressBit == 0, address.pointee.sa_family == UInt8(AF_INET) {
                    let destination = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
                    isDefaultRoute = destination.s_addr == 0
                } else if addressBit == 1, address.pointee.sa_family == UInt8(AF_INET) {
                    var gateway = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
                    var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                    let converted = buffer.withUnsafeMutableBufferPointer { bytes in
                        inet_ntop(AF_INET, &gateway, bytes.baseAddress, socklen_t(INET_ADDRSTRLEN))
                    }
                    if converted != nil { gatewayAddress = String(cString: buffer) }
                }

                cursor += ((addressLength + routeAlignment - 1) / routeAlignment) * routeAlignment
            }

            if isDefaultRoute, let gatewayAddress, normalizedIPv4(gatewayAddress) != nil {
                return gatewayAddress
            }
        }
        return nil
    }
}


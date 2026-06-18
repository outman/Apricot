import Foundation
import Darwin

nonisolated enum LocalNetwork {
    struct Interface: Equatable {
        let name: String
        let address: String
    }

    /// Enumerate active, non-loopback IPv4 interfaces.
    static func ipv4Addresses() -> [Interface] {
        var results: [Interface] = []
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return [] }
        defer { freeifaddrs(ifaddr) }

        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let cur = cursor {
            let addrPtr = cur.pointee.ifa_addr
            let flags = cur.pointee.ifa_flags
            if let addr = addrPtr,
               addr.pointee.sa_family == sa_family_t(AF_INET) {
                let isUp = (flags & UInt32(IFF_UP)) != 0
                let isRunning = (flags & UInt32(IFF_RUNNING)) != 0
                let isLoopback = (flags & UInt32(IFF_LOOPBACK)) != 0
                if isUp && isRunning && !isLoopback {
                    var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    let len = socklen_t(addr.pointee.sa_len)
                    if getnameinfo(addr, len, &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                        results.append(Interface(name: String(cString: cur.pointee.ifa_name),
                                                 address: String(cString: host)))
                    }
                }
            }
            cursor = cur.pointee.ifa_next
        }
        return results
    }

    /// Pure: pick the best LAN IPv4 from a candidate list — prefer `en*`, exclude loopback.
    static func bestIPv4(from interfaces: [Interface]) -> String? {
        let candidates = interfaces.filter { !$0.address.hasPrefix("127.") }
        if let en = candidates.first(where: { $0.name.hasPrefix("en") }) {
            return en.address
        }
        return candidates.first?.address
    }
}

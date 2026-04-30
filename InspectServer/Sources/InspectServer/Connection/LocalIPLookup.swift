#if DEBUG || SWIFT_INSPECTOR_ENABLED
import Foundation
import Darwin

/// Resolves the device's IPv4 address on the active Wi-Fi (or USB
/// tethered) interface so the connection-info overlay can display
/// something the macOS client can dial — `192.168.1.42:8765`.
///
/// Uses `getifaddrs` rather than `NWPathMonitor` because we want a
/// concrete address right now (synchronously, on first call), not a
/// stream of path updates. Cellular interfaces are filtered out
/// because the macOS client cannot route to them on most carriers
/// regardless of NAT, and surfacing a cellular IP would just confuse
/// the user when they typed it and it didn't work.
enum LocalIPLookup {
    /// Best-effort guess at the IPv4 address the macOS client should
    /// dial. Returns nil when the device is offline (airplane mode,
    /// no Wi-Fi associated). Prefers `en0` (typical Wi-Fi on iOS)
    /// over other interfaces so multi-interface devices land on the
    /// expected address.
    static func bestIPv4Address() -> String? {
        var addresses: [(interface: String, address: String)] = []

        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let firstAddr = ifaddr else {
            return nil
        }
        defer { freeifaddrs(ifaddr) }

        for ifptr in sequence(first: firstAddr, next: { $0.pointee.ifa_next }) {
            let interface = ifptr.pointee
            // IFF_UP & IFF_RUNNING — interface is administratively up
            // and the link is live; otherwise the address won't actually
            // be reachable.
            let flags = Int32(interface.ifa_flags)
            guard (flags & IFF_UP) == IFF_UP,
                  (flags & IFF_RUNNING) == IFF_RUNNING,
                  (flags & IFF_LOOPBACK) == 0 else {
                continue
            }
            guard let sockaddr = interface.ifa_addr else { continue }
            // IPv4 only — IPv6 link-local addresses (`fe80::…%enX`) are
            // technically reachable but the macOS client's manual entry
            // sheet has no good way to type a scope id.
            guard sockaddr.pointee.sa_family == UInt8(AF_INET) else { continue }

            var hostBuffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let result = getnameinfo(
                sockaddr,
                socklen_t(interface.ifa_addr.pointee.sa_len),
                &hostBuffer,
                socklen_t(hostBuffer.count),
                nil,
                0,
                NI_NUMERICHOST
            )
            guard result == 0 else { continue }
            let address = String(cString: hostBuffer)
            let name = String(cString: interface.ifa_name)
            // Drop link-local fallback addresses (`169.254.x.x`) — they
            // appear when DHCP failed and the host is unreachable from
            // the macOS side anyway.
            if address.hasPrefix("169.254.") { continue }
            addresses.append((interface: name, address: address))
        }

        // Preference order:
        //   en0 (Wi-Fi on iOS) → en1+ (USB / tethering) → anything else.
        // Cellular interfaces (`pdp_ip0…`) sort to the back via the
        // unprefixed branch and only surface as a last resort.
        let interfacePriority: (String) -> Int = { name in
            if name == "en0" { return 0 }
            if name.hasPrefix("en") { return 1 }
            if name.hasPrefix("bridge") { return 2 }
            return 3
        }
        return addresses
            .sorted { interfacePriority($0.interface) < interfacePriority($1.interface) }
            .first?
            .address
    }
}
#endif

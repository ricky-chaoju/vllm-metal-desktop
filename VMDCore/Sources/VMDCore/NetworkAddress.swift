import Foundation

/// Local IPv4 lookups for serving and clustering. The engine's multi-Mac
/// transport is Thunderbolt (Wi-Fi/Ethernet is too slow to serve over), so
/// the bridge interface gets first-class treatment.
public enum NetworkAddress {
    /// This Mac's primary LAN IPv4 on an `en*` interface. Lowest interface
    /// number wins (numerically); self-assigned 169.254.* addresses are
    /// useless to peers and skipped.
    public static func primaryIPv4() -> String? {
        interfaces()
            .filter { $0.name.hasPrefix("en") && Int($0.name.dropFirst(2)) != nil }
            .sorted { (Int($0.name.dropFirst(2)) ?? 0) < (Int($1.name.dropFirst(2)) ?? 0) }
            .first?.address
    }

    /// The Thunderbolt Bridge IPv4 (`bridge*` interface), when the Macs are
    /// cabled. Link-local (169.254.*) counts here: a bridge with no DHCP —
    /// the plain "just connect a cable" setup — self-assigns exactly that,
    /// and it routes fine on the direct link.
    public static func thunderboltBridgeIPv4() -> String? {
        interfaces(includingLinkLocal: true).first { $0.name.hasPrefix("bridge") }?.address
    }

    /// The local IPv4 that can reach `peer` — how a worker picks the address
    /// the head can reach it on (bridge vs LAN falls out naturally). Same /24
    /// for routable addresses; link-local is one /16 segment, so any local
    /// 169.254.* interface matches a 169.254.* peer.
    public static func interfaceIPv4(reaching peer: String) -> String? {
        if peer.hasPrefix("169.254.") {
            return interfaces(includingLinkLocal: true)
                .first { $0.address.hasPrefix("169.254.") }?.address
        }
        let peerPrefix = peer.split(separator: ".").prefix(3)
        guard peerPrefix.count == 3 else { return nil }
        return interfaces().first { candidate in
            candidate.address.split(separator: ".").prefix(3) == peerPrefix
        }?.address
    }

    /// All viable interfaces ordered for cluster use: the user-preferred one
    /// first, then Thunderbolt bridges, then Ethernet/Wi-Fi by number. The
    /// app advertises every address and peers try them in order — a Mac with
    /// its "primary" NIC on the wrong network stays reachable via the others.
    /// Link-local addresses are viable only on bridges (a peer on the same
    /// cable can reach them; on en* they mean "no network").
    public static func allIPv4(preferring preferred: String? = nil) -> [Interface] {
        func rank(_ interface: Interface) -> (Int, Int) {
            if let preferred, interface.name == preferred { return (0, 0) }
            if interface.name.hasPrefix("bridge") { return (1, 0) }
            return (2, Int(interface.name.dropFirst(2)) ?? 99)
        }
        return interfaces(includingLinkLocal: true)
            .filter {
                $0.name.hasPrefix("bridge")
                    || ($0.name.hasPrefix("en") && !$0.address.hasPrefix("169.254."))
            }
            .sorted { rank($0) < rank($1) }
    }

    // MARK: Enumeration

    public struct Interface: Sendable, Equatable, Hashable {
        public var name: String
        public var address: String

        public init(name: String, address: String) {
            self.name = name
            self.address = address
        }
    }

    /// All IPv4 interfaces except loopback (pure transform over getifaddrs).
    /// Link-local addresses are excluded by default — they're useless to a
    /// LAN peer — but bridge-aware callers opt in.
    static func interfaces(includingLinkLocal: Bool = false) -> [Interface] {
        var addrs: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&addrs) == 0, let first = addrs else { return [] }
        defer { freeifaddrs(addrs) }
        var found: [Interface] = []
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let interface = pointer.pointee
            guard let sa = interface.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET) else { continue }
            let name = String(cString: interface.ifa_name)
            let sin = UnsafeRawPointer(sa).assumingMemoryBound(to: sockaddr_in.self).pointee
            // inet_ntop, not inet_ntoa: the latter returns a shared static
            // buffer and this runs from arbitrary concurrent contexts.
            var addr = sin.sin_addr
            var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            guard inet_ntop(AF_INET, &addr, &buffer, socklen_t(INET_ADDRSTRLEN)) != nil else { continue }
            let ip = String(cString: buffer)
            guard ip != "127.0.0.1" else { continue }
            guard includingLinkLocal || !ip.hasPrefix("169.254.") else { continue }
            found.append(Interface(name: name, address: ip))
        }
        return found
    }
}

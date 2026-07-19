import Foundation

/// What one Mac advertises about itself for cluster discovery — carried in a
/// Bonjour TXT record, so it must stay small (RFC 6763 suggests ~200 bytes,
/// keys ≤ 9 chars). These are unauthenticated mDNS hints for *display and
/// preflight*; anything security-relevant is re-verified when pairing.
public struct ClusterNodeInfo: Sendable, Equatable, Codable {
    /// Stable install identity — the pairing key; survives relaunches.
    /// (Self-filtering of a Mac's own advertisement is `launchNonce`'s job.)
    public var id: String
    /// User-facing computer name.
    public var name: String
    /// Chip marketing name ("Apple M2 Ultra").
    public var chip: String
    /// Hardware model code ("Mac14,8") — lets peers show the real product image.
    public var modelIdentifier: String
    public var memoryBytes: Int64
    /// Installed engine version, empty until resolved.
    public var engineVersion: String
    /// Installed Ray version, empty when absent — cluster joins require an
    /// exact match across nodes, so peers compare this before forming one.
    public var rayVersion: String
    public var appVersion: String
    /// Primary IPv4 + control-API port, so peers can reach this app directly.
    public var address: String
    /// Every viable IPv4, primary first — peers try each in order, so one
    /// wrongly-picked "primary" NIC can't make a Mac unreachable.
    public var addresses: [String]
    public var controlPort: Int
    /// Per-launch value used ONLY for filtering our own advertisement out of
    /// our own browse results. `id` is stable across launches (pairing
    /// identity), so it can't double as the self-filter: two app instances on
    /// one Mac — the standard way to develop this feature — share it.
    public var launchNonce: String

    public init(
        id: String,
        name: String,
        chip: String,
        modelIdentifier: String,
        memoryBytes: Int64,
        engineVersion: String,
        rayVersion: String = "",
        appVersion: String,
        address: String = "",
        addresses: [String] = [],
        controlPort: Int = 0,
        launchNonce: String = ""
    ) {
        self.id = id
        self.name = name
        self.chip = chip
        self.modelIdentifier = modelIdentifier
        self.memoryBytes = memoryBytes
        self.engineVersion = engineVersion
        self.rayVersion = rayVersion
        self.appVersion = appVersion
        self.address = address
        self.addresses = addresses.isEmpty ? (address.isEmpty ? [] : [address]) : addresses
        self.controlPort = controlPort
        self.launchNonce = launchNonce
    }

    // MARK: TXT record round-trip

    public var txtDictionary: [String: String] {
        [
            "id": id,
            "name": name,
            "chip": chip,
            "model": modelIdentifier,
            "mem": String(memoryBytes),
            "engv": engineVersion,
            "rayv": rayVersion,
            "appv": appVersion,
            "ip": address,
            "ips": addresses.joined(separator: ","),
            "port": String(controlPort),
            "nonce": launchNonce,
        ]
    }

    /// `nil` when the record lacks the identity key (foreign/garbled service).
    public init?(txtDictionary txt: [String: String]) {
        guard let id = txt["id"], !id.isEmpty else { return nil }
        self.id = id
        self.name = txt["name"] ?? ""
        self.chip = txt["chip"] ?? ""
        self.modelIdentifier = txt["model"] ?? ""
        self.memoryBytes = txt["mem"].flatMap(Int64.init) ?? 0
        self.engineVersion = txt["engv"] ?? ""
        self.rayVersion = txt["rayv"] ?? ""
        self.appVersion = txt["appv"] ?? ""
        self.address = txt["ip"] ?? ""
        let list = (txt["ips"] ?? "").split(separator: ",").map(String.init).filter { !$0.isEmpty }
        self.addresses = list.isEmpty ? (self.address.isEmpty ? [] : [self.address]) : list
        self.controlPort = txt["port"].flatMap(Int.init) ?? 0
        self.launchNonce = txt["nonce"] ?? ""
    }
}

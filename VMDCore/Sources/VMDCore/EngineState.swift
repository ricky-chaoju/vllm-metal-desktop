import Foundation

/// Persisted, app-owned facts about the installed engine. Forward-compatible:
/// every field is optional so older/newer states decode cleanly. The supervised
/// *run* state (pid/port) is added in M2; this M1 shape tracks installation and
/// update-check bookkeeping.
public struct EngineState: Codable, Sendable, Equatable {
    /// Raw `vllm_metal.__version__` recorded at install time.
    public var installedVersion: String?
    public var installedAt: Date?
    /// When the app last queried GitHub Releases.
    public var lastUpdateCheck: Date?
    /// Latest version seen on GitHub Releases at `lastUpdateCheck`.
    public var latestKnownVersion: String?

    public init(
        installedVersion: String? = nil,
        installedAt: Date? = nil,
        lastUpdateCheck: Date? = nil,
        latestKnownVersion: String? = nil
    ) {
        self.installedVersion = installedVersion
        self.installedAt = installedAt
        self.lastUpdateCheck = lastUpdateCheck
        self.latestKnownVersion = latestKnownVersion
    }
}

/// The currently-running served model, persisted so the app can re-adopt an
/// orphaned `vllm serve` after a restart (docs/PLAN.md §3 recovery).
public struct ServeRunState: Codable, Sendable, Equatable {
    public var pid: Int32
    public var port: Int
    public var model: String
    public var startedAt: Date

    public init(pid: Int32, port: Int, model: String, startedAt: Date) {
        self.pid = pid
        self.port = port
        self.model = model
        self.startedAt = startedAt
    }
}

/// Atomically-persisted JSON, written via a temp file + rename so a crash mid-write
/// can never leave a half-written state file. Mirrors lmstack's discipline of
/// never trusting a partially-written `native_processes.json` (docs/PLAN.md §3).
public struct AtomicJSONStore<Value: Codable & Sendable>: Sendable {
    public let url: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(url: URL) {
        self.url = url
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.encoder = encoder
        self.decoder = decoder
    }

    /// Returns the decoded value, or `nil` if the file does not exist yet.
    public func load() throws -> Value? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        return try decoder.decode(Value.self, from: data)
    }

    /// Encodes and writes atomically, creating parent directories as needed.
    public func save(_ value: Value) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try encoder.encode(value)
        try data.write(to: url, options: [.atomic])
    }

    public func delete() throws {
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }
}

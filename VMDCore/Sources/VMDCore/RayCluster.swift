import Foundation

/// A parsed `ray status` summary — the ground truth for "is the cluster up
/// and does every Mac contribute its GPU".
public struct RayClusterStatus: Sendable, Equatable {
    public var activeNodes: Int
    /// The custom `mlx` resource (one per Apple GPU / Mac).
    public var mlxTotal: Double
    public var mlxUsed: Double

    public init(activeNodes: Int, mlxTotal: Double, mlxUsed: Double) {
        self.activeNodes = activeNodes
        self.mlxTotal = mlxTotal
        self.mlxUsed = mlxUsed
    }

    /// Parses `ray status` CLI output (pure; unit-tested). `nil` when the
    /// output doesn't look like a status report (e.g. no cluster running).
    public static func parse(_ output: String) -> RayClusterStatus? {
        guard output.contains("Node status") else { return nil }
        var active = 0
        var inActiveSection = false
        for rawLine in output.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line == "Active:" { inActiveSection = true; continue }
            if line.hasSuffix(":") { inActiveSection = false; continue }
            if inActiveSection, let count = Int(line.split(separator: " ").first ?? "") {
                active += count
            }
        }
        var mlxTotal = 0.0
        var mlxUsed = 0.0
        if let match = output.firstMatch(of: /([\d.]+)\/([\d.]+) mlx/) {
            mlxUsed = Double(match.1) ?? 0
            mlxTotal = Double(match.2) ?? 0
        }
        return RayClusterStatus(activeNodes: active, mlxTotal: mlxTotal, mlxUsed: mlxUsed)
    }
}

/// Drives the venv's `ray` CLI to form and tear down the control plane for
/// multi-Mac serving. Every invocation carries the macOS-cluster gates the
/// engine docs require (`RAY_ENABLE_WINDOWS_OR_OSX_CLUSTER`, Python
/// minor-version matching) plus the custom `mlx` resource that lets vLLM
/// place one worker per Apple GPU.
public struct RayCluster: Sendable {
    public var paths: EnginePaths

    public init(paths: EnginePaths = .standard) {
        self.paths = paths
    }

    public var rayBinary: URL { paths.venvBin.appending(path: "ray", directoryHint: .notDirectory) }
    public var isAvailable: Bool { FileManager.default.fileExists(atPath: rayBinary.path) }

    /// The Ray GCS port workers join through.
    public static let gcsPort = 6379

    private func environment(hostIP: String?) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["VIRTUAL_ENV"] = paths.venvRoot.path
        env["PATH"] = "\(paths.venvBin.path):\(env["PATH"] ?? "/usr/bin:/bin")"
        // macOS clustering is gated behind this flag.
        env["RAY_ENABLE_WINDOWS_OR_OSX_CLUSTER"] = "1"
        // Macs rarely share the exact Python patch release.
        env["RAY_DEFAULT_PYTHON_VERSION_MATCH_LEVEL"] = "minor"
        if let hostIP { env["VLLM_HOST_IP"] = hostIP }
        return env
    }

    /// Installs, upgrades, or pins Ray in the engine venv — a distributed-only
    /// dependency the base engine install doesn't carry. `version: nil` means
    /// latest; a specific version pins (cluster nodes must match exactly, so
    /// downgrading to a peer's version is a first-class move). Streams pip's
    /// output line-by-line so the UI can show a live log.
    public func installRayEvents(version: String? = nil) throws -> AsyncStream<ProcessEvent> {
        let target = version.map { "ray==\($0)" } ?? "ray"
        return try ProcessSession().start(.init(
            executableURL: paths.venvPython,
            arguments: ["-m", "pip", "install", "--upgrade", target],
            environment: environment(hostIP: nil)
        ))
    }

    /// The installed Ray version ("2.44.0"), or nil when absent. Cluster
    /// nodes must match exactly — Ray refuses mixed-version joins — so this
    /// travels in the discovery record for preflight.
    public func version() async -> String? {
        guard let result = try? await ProcessSession.run(.init(
            executableURL: rayBinary,
            arguments: ["--version"],
            environment: environment(hostIP: nil)
        )), result.didSucceed else { return nil }
        return Self.parseVersion(result.standardOutput)
    }

    /// Parses `ray --version` output ("ray, version 2.44.0"). Pure; tested.
    public static func parseVersion(_ output: String) -> String? {
        guard let match = output.firstMatch(of: /version ([0-9][\w.\-]*)/) else { return nil }
        return String(match.1)
    }

    /// Starts this Mac as the cluster head. `nodeIP` must be the address the
    /// other Mac reaches us on (the Thunderbolt bridge IP when cabled).
    public func startHead(nodeIP: String) async throws -> CommandResult {
        try await ProcessSession.run(.init(
            executableURL: rayBinary,
            arguments: [
                "start", "--head",
                "--node-ip-address=\(nodeIP)",
                "--port=\(Self.gcsPort)",
                "--resources={\"mlx\": 1}",
                "--disable-usage-stats",
            ],
            environment: environment(hostIP: nodeIP)
        ))
    }

    /// Joins this Mac to a head at `headAddress` ("ip:6379").
    public func join(headAddress: String, nodeIP: String) async throws -> CommandResult {
        try await ProcessSession.run(.init(
            executableURL: rayBinary,
            arguments: [
                "start",
                "--address=\(headAddress)",
                "--node-ip-address=\(nodeIP)",
                "--resources={\"mlx\": 1}",
                "--disable-usage-stats",
            ],
            environment: environment(hostIP: nodeIP)
        ))
    }

    /// Leaves/tears down the local Ray node (head or worker).
    public func stopNode() async throws -> CommandResult {
        try await ProcessSession.run(.init(
            executableURL: rayBinary,
            arguments: ["stop", "--force"],
            environment: environment(hostIP: nil)
        ))
    }

    /// The live cluster summary, or `nil` when no local Ray node is running.
    public func status() async -> RayClusterStatus? {
        guard let result = try? await ProcessSession.run(.init(
            executableURL: rayBinary,
            arguments: ["status"],
            environment: environment(hostIP: nil)
        )), result.didSucceed else { return nil }
        return RayClusterStatus.parse(result.standardOutput)
    }
}

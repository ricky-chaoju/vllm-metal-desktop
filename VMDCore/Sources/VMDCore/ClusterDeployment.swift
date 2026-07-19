import Foundation

/// How a cluster deployment spreads a model across Macs.
public enum ClusterServeMode: String, Codable, Sendable, CaseIterable {
    /// One model's layers split across the nodes — serves a model bigger
    /// than any single Mac.
    case pipelineParallel
    /// One full replica per node behind a single endpoint — multiplies
    /// throughput for a model that already fits.
    case dataParallel
}

/// Builds the `vllm serve` additions that turn a plain deployment into a
/// cluster one. Pure — the app merges these into a `ServeFlags` and launches
/// through the normal single-Mac path, so cluster serving never grows a
/// parallel launch pipeline.
public enum ClusterServeCommand {
    /// Arguments for `mode` on a cluster of `nodeCount` Macs. The count is
    /// clamped to 2 — a "cluster" of one is a plain deployment, and callers
    /// only reach this after the head verified a live multi-node cluster.
    public static func arguments(
        mode: ClusterServeMode,
        nodeCount: Int,
        headIP: String
    ) -> [String] {
        let nodes = max(2, nodeCount)
        switch mode {
        case .pipelineParallel:
            // PP requires disabling async scheduling (the engine fails loud
            // without it); TP stays 1 — Metal has no tensor parallelism.
            return [
                "--distributed-executor-backend", "ray",
                "--pipeline-parallel-size", String(nodes),
                "--tensor-parallel-size", "1",
                "--no-async-scheduling",
            ]
        case .dataParallel:
            // The default mp backend can't place a replica on a second Mac.
            return [
                "--data-parallel-size", String(nodes),
                "--data-parallel-backend", "ray",
                "--data-parallel-size-local", "1",
                "--data-parallel-address", headIP,
            ]
        }
    }

    /// Environment for a cluster serve: attach to the running Ray cluster and
    /// bind the engine's inter-node transport to the address the workers
    /// reach the head on (the Thunderbolt bridge IP when cabled).
    public static func environment(headIP: String) -> [String: String] {
        [
            "RAY_ADDRESS": "auto",
            "VLLM_HOST_IP": headIP,
        ]
    }

    /// Recovers the mode from a deployment's raw argument string — how the
    /// head tells cluster deployments apart from single-Mac ones (`nil`)
    /// without persisting a separate marker.
    public static func detectMode(inArguments arguments: String) -> ClusterServeMode? {
        let tokens = Set(arguments.split(whereSeparator: \.isWhitespace).map(String.init))
        if tokens.contains("--pipeline-parallel-size") { return .pipelineParallel }
        if tokens.contains("--data-parallel-backend") { return .dataParallel }
        return nil
    }
}

/// A serve deployment as it travels over the cluster control channel — the
/// head's answer to `GET /deployments`, rendered identically on every member
/// so the whole cluster sees one list.
public struct ClusterDeploymentSummary: Codable, Sendable, Equatable, Identifiable {
    /// Coarse lifecycle, deliberately smaller than the head's internal serve
    /// status: remote Macs can't act on the fine distinctions.
    public enum State: String, Codable, Sendable {
        case starting
        case running
        case stopped
        case failed
    }

    public var model: String
    public var port: Int
    public var state: State
    public var mode: ClusterServeMode

    public init(model: String, port: Int, state: State, mode: ClusterServeMode) {
        self.model = model
        self.port = port
        self.state = state
        self.mode = mode
    }

    public var id: String { "\(model):\(port)" }

    /// The OpenAI-compatible base URL, from whichever address the caller
    /// knows the serving Mac by.
    public func endpoint(host: String) -> String {
        "http://\(host):\(port)/v1"
    }
}

extension ClusterDeploymentSummary.State {
    /// Collapses the head's fine-grained serve status into what a remote Mac
    /// can act on — a stopping engine is already gone for its purposes.
    public init(_ status: ServeStatus) {
        switch status {
        case .starting: self = .starting
        case .running: self = .running
        case .idle, .stopping, .stopped: self = .stopped
        case .failed: self = .failed
        }
    }
}

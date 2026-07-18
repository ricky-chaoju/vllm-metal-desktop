import Foundation

/// Configuration for one `vllm serve` invocation. `launchArguments` is pure and
/// unit-tested; the supervisor turns it into a `ProcessLaunch`. Metal pins
/// tensor-parallel to 1 (docs/PLAN.md §2.2), so it is never exposed here.
public struct ServeConfig: Sendable, Equatable {
    public var model: String
    public var port: Int
    public var servedModelName: String?
    public var maxModelLen: Int?
    public var extraArguments: [String]
    /// Extra environment for the serve process (e.g. VLLM_METAL_* tunings).
    public var extraEnvironment: [String: String]

    public init(
        model: String,
        port: Int,
        servedModelName: String? = nil,
        maxModelLen: Int? = nil,
        extraArguments: [String] = [],
        extraEnvironment: [String: String] = [:]
    ) {
        self.model = model
        self.port = port
        self.servedModelName = servedModelName
        self.maxModelLen = maxModelLen
        self.extraArguments = extraArguments
        self.extraEnvironment = extraEnvironment
    }

    /// The name the server reports at `/v1/models` (and that chat requests use).
    public var effectiveModelName: String {
        servedModelName ?? model
    }

    public var launchArguments: [String] {
        var args = ["serve", model, "--port", String(port)]
        if let servedModelName {
            args += ["--served-model-name", servedModelName]
        }
        if let maxModelLen {
            args += ["--max-model-len", String(maxModelLen)]
        }
        args += extraArguments
        return args
    }
}

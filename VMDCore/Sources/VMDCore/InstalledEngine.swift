import Foundation

/// Reads facts about the engine currently installed in the managed venv.
public struct InstalledEngine: Sendable {
    public var paths: EnginePaths

    public init(paths: EnginePaths = .standard) {
        self.paths = paths
    }

    /// Whether a venv interpreter exists on disk.
    public var isInstalled: Bool {
        FileManager.default.fileExists(atPath: paths.venvPython.path)
    }

    /// Reads `vllm_metal.__version__` by importing it in the venv interpreter.
    /// Returns `nil` if the engine isn't installed or can't be imported.
    public func installedVersion() async -> EngineVersion? {
        guard isInstalled else { return nil }
        let launch = ProcessLaunch(
            executableURL: paths.venvPython,
            arguments: ["-c", "import vllm_metal; print(vllm_metal.__version__)"]
        )
        guard let result = try? await ProcessSession.run(launch), result.didSucceed else { return nil }
        return Self.parseVersion(result.standardOutput)
    }

    /// Reads the compiled vLLM *core* version (`vllm.__version__`). The wheel-only
    /// engine update never touches the core, so this is what reveals a stale base
    /// (the version banner `vllm serve` prints at startup).
    public func installedCoreVersion() async -> EngineVersion? {
        guard isInstalled else { return nil }
        let launch = ProcessLaunch(
            executableURL: paths.venvPython,
            arguments: ["-c", "import vllm; print(vllm.__version__)"]
        )
        guard let result = try? await ProcessSession.run(launch), result.didSucceed else { return nil }
        return Self.parseVersion(result.standardOutput)
    }

    /// Removes the managed venv entirely (`~/.venv-vllm-metal`). Model weights
    /// in the HF cache are untouched — reinstalling the engine reuses them.
    public func uninstall() throws {
        guard FileManager.default.fileExists(atPath: paths.venvRoot.path) else { return }
        try FileManager.default.removeItem(at: paths.venvRoot)
    }

    /// Parses the interpreter's printed version (pure; unit-tested).
    public static func parseVersion(_ output: String) -> EngineVersion? {
        let line = output
            .split(whereSeparator: \.isNewline)
            .last
            .map(String.init) ?? output
        return EngineVersion(line.trimmingCharacters(in: .whitespaces))
    }
}

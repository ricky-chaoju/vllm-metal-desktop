import Foundation

/// Progress emitted while installing/updating the engine.
public enum InstallProgress: Sendable, Equatable {
    case started(totalSteps: Int)
    case stepStarted(id: String, title: String, index: Int)
    case log(String)
    case stepFinished(id: String)
    case failed(stepID: String, code: Int32)
    case completed
}

/// Executes an `EngineInstallPlan` against the real system, streaming progress.
///
/// Stateless: each install is independent and uses a fresh `ProcessSession` per
/// step. Step *construction* is the pure, unit-tested `buildSteps`; the run
/// itself is integration (needs network + minutes) and is validated manually
/// (docs/PLAN.md §9). uv is bootstrapped to the upstream default `~/.local/bin`.
public struct EngineInstaller: Sendable {
    public var paths: EnginePaths
    public var config: EngineInstallConfig

    public init(paths: EnginePaths = .standard, config: EngineInstallConfig = .init()) {
        self.paths = paths
        self.config = config
    }

    /// A fresh install (re)creates the venv and compiles vLLM core; an update
    /// just installs the new wheel in place (no recompile) — docs/PLAN.md §4.
    public enum InstallMode: Sendable {
        case fresh
        case update
    }

    /// Whether a wheel-only update suffices, or the compiled vLLM core must be
    /// rebuilt because the target release was built against a different base
    /// (the wheel swap never touches the core — the "updated but serve still
    /// shows the old vLLM version" trap). Unknown versions don't force the slow
    /// path; the post-install import verification catches real breakage.
    public static func needsCoreRebuild(requiredBase: EngineVersion?, installedCore: EngineVersion?) -> Bool {
        guard let requiredBase, let installedCore else { return false }
        return requiredBase != installedCore
    }

    /// The ordered step list for the mode. Pure — unit-tested.
    public func buildSteps(mode: InstallMode, uvExists: Bool, wheelURL: URL) -> [InstallStep] {
        let env = EngineInstallPlan.installEnvironment(
            paths: paths, uvDirectory: paths.uvBinary.deletingLastPathComponent()
        )
        switch mode {
        case .fresh:
            var steps: [InstallStep] = []
            if !uvExists {
                steps.append(EngineInstallPlan.bootstrapUVStep(config: config, installDir: paths.localBin))
            }
            steps.append(contentsOf: EngineInstallPlan.steps(
                config: config, paths: paths, uv: paths.uvBinary, wheelURL: wheelURL
            ))
            return steps
        case .update:
            // uv can vanish independently of the venv (it lives in ~/.local/bin);
            // re-bootstrap it rather than failing the wheel step on a missing binary.
            var steps: [InstallStep] = []
            if !uvExists {
                steps.append(EngineInstallPlan.bootstrapUVStep(config: config, installDir: paths.localBin))
            }
            steps.append(EngineInstallPlan.installWheelStep(uv: paths.uvBinary, wheelURL: wheelURL, environment: env))
            steps.append(EngineInstallPlan.verifyStep(paths: paths, environment: env))
            return steps
        }
    }

    /// Installs or updates the engine, streaming progress. The stream ends with
    /// `.completed` or `.failed`. Cancelling the consumer terminates the child.
    public func install(wheelURL: URL, mode: InstallMode = .fresh) -> AsyncStream<InstallProgress> {
        let (stream, continuation) = AsyncStream<InstallProgress>.makeStream()
        let task = Task {
            defer { continuation.finish() }
            let uvExists = FileManager.default.fileExists(atPath: paths.uvBinary.path)
            let steps = buildSteps(mode: mode, uvExists: uvExists, wheelURL: wheelURL)
            continuation.yield(.started(totalSteps: steps.count))
            do {
                for (index, step) in steps.enumerated() {
                    continuation.yield(.stepStarted(id: step.id, title: step.title, index: index))
                    let code = try await runStep(step) { continuation.yield(.log($0)) }
                    if code != 0 {
                        continuation.yield(.failed(stepID: step.id, code: code))
                        return
                    }
                    continuation.yield(.stepFinished(id: step.id))
                }
                continuation.yield(.completed)
            } catch is CancellationError {
                // Consumer cancelled; the child was terminated. Report nothing further.
            } catch {
                continuation.yield(.failed(stepID: "launch", code: -1))
            }
        }
        continuation.onTermination = { _ in task.cancel() }
        return stream
    }

    private func runStep(_ step: InstallStep, emit: @Sendable (String) -> Void) async throws -> Int32 {
        let session = ProcessSession()
        return try await withTaskCancellationHandler {
            var exitCode: Int32 = -1
            for await event in try session.start(step.launch) {
                switch event {
                case .stdout(let line), .stderr(let line): emit(line)
                case .exit(let code): exitCode = code
                }
            }
            // If we were cancelled, surface it instead of a bogus exit code.
            try Task.checkCancellation()
            return exitCode
        } onCancel: {
            session.terminate()
        }
    }
}

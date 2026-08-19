import Foundation

/// The app's own pinned versions and the download URLs derived from them.
///
/// These two pins are ours to choose; both mirror `vllm-metal/install.sh`. The
/// vLLM *core* version deliberately isn't here — it belongs to the release
/// being installed, moves whenever upstream bumps vLLM, and is read from that
/// tag's install.sh (`GitHubReleaseClient.fetchRequiredVLLMBase`). Carrying a
/// default for it would mean guessing a core version, which is how a wheel
/// built against one base ends up installed onto another.
public struct EngineInstallConfig: Sendable, Equatable {
    public var uvVersion: String
    public var pythonVersion: String

    public init(
        uvVersion: String = "0.9.18",
        pythonVersion: String = "3.12"
    ) {
        self.uvVersion = uvVersion
        self.pythonVersion = pythonVersion
    }

    /// The prebuilt macOS arm64 vLLM core wheel attached to vLLM's own
    /// release (v0.26.0 was the first to ship one — the tag install.sh pins
    /// by full URL because no index serves it). The "+cpu" local version
    /// must be percent-encoded in the asset name. `coreVersion` comes from
    /// install.sh's own `VLLM_VERSION` pin, so it is always URL-safe.
    public func vllmWheelURL(coreVersion: String) -> URL {
        let cp = "cp" + pythonVersion.replacingOccurrences(of: ".", with: "")
        return URL(string: "https://github.com/vllm-project/vllm/releases/download/v\(coreVersion)/vllm-\(coreVersion)%2Bcpu-\(cp)-\(cp)-macosx_11_0_arm64.whl")!
    }

    public var uvInstallerURL: URL {
        URL(string: "https://astral.sh/uv/\(uvVersion)/install.sh")!
    }
}

/// One ordered, executable installation step.
public struct InstallStep: Sendable, Identifiable {
    public let id: String
    public var title: String
    public var launch: ProcessLaunch
    /// True for steps that take minutes — the multi-gigabyte wheel downloads.
    /// The UI sets expectations accordingly.
    public var isLongRunning: Bool

    public init(id: String, title: String, launch: ProcessLaunch, isLongRunning: Bool = false) {
        self.id = id
        self.title = title
        self.launch = launch
        self.isLongRunning = isLongRunning
    }
}

/// Builds the ordered command sequence that provisions `~/.venv-vllm-metal`.
///
/// This faithfully mirrors `install.sh`, which since 2026-07 installs vLLM
/// core from a prebuilt macOS wheel — the from-source compile (and its
/// several-minute build step) is gone. Pure and unit-tested for correct
/// command construction; the run itself is integration.
public enum EngineInstallPlan {
    /// Environment for uv invocations: targets the managed venv and puts uv on PATH.
    public static func installEnvironment(paths: EnginePaths, uvDirectory: URL) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["VIRTUAL_ENV"] = paths.venvRoot.path
        let inheritedPath = env["PATH"] ?? "/usr/bin:/bin"
        env["PATH"] = "\(uvDirectory.path):\(paths.venvBin.path):\(inheritedPath)"
        return env
    }

    /// Bootstraps a pinned `uv` into `installDir`. uv self-provisions a native
    /// arm64 CPython, eliminating the "user must supply arm64 Python" blocker.
    public static func bootstrapUVStep(config: EngineInstallConfig, installDir: URL) -> InstallStep {
        var env = ProcessInfo.processInfo.environment
        env["UV_INSTALL_DIR"] = installDir.path
        env["INSTALLER_NO_MODIFY_PATH"] = "1"
        let script = "set -euo pipefail; curl -LsSf '\(config.uvInstallerURL.absoluteString)' | sh"
        return InstallStep(
            id: "bootstrap-uv",
            title: "Install uv \(config.uvVersion)",
            launch: ProcessLaunch(
                executableURL: URL(filePath: "/bin/sh"),
                arguments: ["-c", script],
                environment: env
            )
        )
    }

    /// The provisioning steps, assuming `uv` is the absolute path to the binary
    /// produced by `bootstrapUVStep` (or an existing system uv).
    public static func steps(
        config: EngineInstallConfig,
        vllmCoreVersion: String,
        paths: EnginePaths,
        uv: URL,
        wheelURL: URL
    ) -> [InstallStep] {
        let env = installEnvironment(paths: paths, uvDirectory: uv.deletingLastPathComponent())

        let createVenv = InstallStep(
            id: "create-venv",
            title: "Create virtual environment",
            launch: ProcessLaunch(
                executableURL: uv,
                arguments: ["venv", paths.venvRoot.path, "--clear", "--python", config.pythonVersion, "--seed"],
                environment: env
            )
        )

        // Mirrors install.sh's `require_arm64_python` — reject a Rosetta /
        // x86_64 interpreter, which would otherwise only fail later at first Metal use.
        let validatePythonArch = InstallStep(
            id: "validate-python-arch",
            title: "Verify native arm64 Python",
            launch: ProcessLaunch(
                executableURL: paths.venvPython,
                arguments: ["-c", "import platform, sys; m = platform.machine(); print(m); sys.exit(0 if m == 'arm64' else 1)"],
                environment: env
            )
        )

        // Mirrors install.sh's install_vllm — the prebuilt wheel; its own
        // metadata pulls torch et al. from PyPI (still gigabytes, so the
        // step stays marked long-running).
        let installVLLM = InstallStep(
            id: "install-vllm",
            title: "Install vLLM \(vllmCoreVersion) (prebuilt wheel)",
            launch: ProcessLaunch(
                executableURL: uv,
                arguments: ["pip", "install", config.vllmWheelURL(coreVersion: vllmCoreVersion).absoluteString],
                environment: env
            ),
            isLongRunning: true
        )

        return [
            createVenv,
            validatePythonArch,
            installVLLM,
            installWheelStep(uv: uv, wheelURL: wheelURL, environment: env),
            verifyStep(paths: paths, environment: env),
        ]
    }

    /// `uv pip install <wheel>` — the only step needed for an in-place update.
    /// Resolving the wheel's dependencies reaches a git-pinned `mlx-lm`, which
    /// uv fetches with the git CLI — hence Preflight's Command Line Tools check.
    /// `--reinstall-package` makes the outcome deterministic for every version
    /// switch: upgrade, downgrade, or reinstalling the already-installed version
    /// (which uv would otherwise skip as "already satisfied").
    public static func installWheelStep(uv: URL, wheelURL: URL, environment: [String: String]) -> InstallStep {
        InstallStep(
            id: "install-vllm-metal",
            title: "Install vllm-metal engine",
            launch: ProcessLaunch(
                executableURL: uv,
                arguments: ["pip", "install", "--reinstall-package", "vllm-metal", wheelURL.absoluteString],
                environment: environment
            )
        )
    }

    /// Imports the engine and prints its version — a smoke test after install or
    /// update (docs/PLAN.md §8 risk #3). A non-zero exit fails the run.
    public static func verifyStep(paths: EnginePaths, environment: [String: String]) -> InstallStep {
        InstallStep(
            id: "verify-engine",
            title: "Verify engine",
            launch: ProcessLaunch(
                executableURL: paths.venvPython,
                arguments: ["-c", "import vllm_metal; print(vllm_metal.__version__)"],
                environment: environment
            )
        )
    }
}

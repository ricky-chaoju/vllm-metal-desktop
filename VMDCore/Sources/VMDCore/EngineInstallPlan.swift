import Foundation

/// Pinned versions and derived download URLs for an engine install.
/// Defaults mirror `vllm-metal/install.sh` (docs/PLAN.md §2.1). `vllmVersion` is
/// only a fallback — installs resolve the real base from the selected release's
/// own install.sh (`GitHubReleaseClient.fetchRequiredVLLMBase`), so this never
/// silently drifts behind upstream bumps.
public struct EngineInstallConfig: Sendable, Equatable {
    public var vllmVersion: String
    public var uvVersion: String
    public var pythonVersion: String

    public init(
        vllmVersion: String = "0.25.1",
        uvVersion: String = "0.9.18",
        pythonVersion: String = "3.12"
    ) {
        self.vllmVersion = vllmVersion
        self.uvVersion = uvVersion
        self.pythonVersion = pythonVersion
    }

    public var vllmTarballURL: URL {
        URL(string: "https://github.com/vllm-project/vllm/releases/download/v\(vllmVersion)/vllm-\(vllmVersion).tar.gz")!
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
    /// True for steps that take minutes (downloads, the vLLM core compile) — the
    /// UI sets expectations accordingly.
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
/// This faithfully mirrors `install.sh` — including that the prebuilt-wheel path
/// *still* compiles vLLM core from source (`CXXFLAGS=-Wno-parentheses uv pip
/// install .`, install.sh:214). It is pure and unit-tested for correct command
/// construction; a real end-to-end run (a documented blocking unknown,
/// docs/PLAN.md §9) is needed to validate timing/footprint.
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

        // Mirrors install.sh:196-199 (require_arm64_python) — reject a Rosetta /
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

        // Mirrors install.sh:201-214 — download the sdist, install CPU deps, then
        // compile vLLM core from source into the venv.
        let vllmScript = """
        set -euo pipefail
        tmp="$(mktemp -d)"
        trap 'rm -rf "$tmp"' EXIT
        echo "Downloading vLLM \(config.vllmVersion)…"
        curl -fSL '\(config.vllmTarballURL.absoluteString)' -o "$tmp/vllm.tar.gz"
        tar -xzf "$tmp/vllm.tar.gz" -C "$tmp"
        cd "$tmp/vllm-\(config.vllmVersion)/"
        echo "Installing CPU dependencies…"
        '\(uv.path)' pip install -r requirements/cpu.txt --index-strategy unsafe-best-match
        echo "Compiling vLLM core (slow step, several minutes)…"
        CXXFLAGS="-Wno-parentheses" '\(uv.path)' pip install .
        """
        let installVLLM = InstallStep(
            id: "install-vllm",
            title: "Download & build vLLM \(config.vllmVersion)",
            launch: ProcessLaunch(
                executableURL: URL(filePath: "/bin/sh"),
                arguments: ["-c", vllmScript],
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

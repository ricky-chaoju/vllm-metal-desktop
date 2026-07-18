import Foundation

/// Canonical filesystem locations the app and the `vllm-metal` engine share.
///
/// The engine venv deliberately lives at the *upstream default*
/// `~/.venv-vllm-metal`, so an environment provisioned by this app is
/// interchangeable with one created by `install.sh` from the command line —
/// which matters for the long-term goal of upstreaming into vLLM. See
/// docs/PLAN.md §2.1, §4.
///
/// `home` is injectable so tests don't touch the real home directory.
public struct EnginePaths: Sendable, Hashable {
    public let home: URL

    public init(home: URL) {
        self.home = home
    }

    /// Paths rooted at the current user's real home directory.
    public static var standard: EnginePaths {
        EnginePaths(home: FileManager.default.homeDirectoryForCurrentUser)
    }

    /// `~/.venv-vllm-metal` — the managed virtualenv (upstream default).
    public var venvRoot: URL {
        home.appending(path: ".venv-vllm-metal", directoryHint: .isDirectory)
    }

    /// `~/.venv-vllm-metal/bin/python` — the interpreter that runs `vllm serve`.
    public var venvPython: URL {
        venvRoot.appending(path: "bin/python", directoryHint: .notDirectory)
    }

    /// `~/.venv-vllm-metal/bin/vllm` — the CLI that starts the OpenAI server.
    public var venvVLLM: URL {
        venvRoot.appending(path: "bin/vllm", directoryHint: .notDirectory)
    }

    /// `~/.venv-vllm-metal/bin` — prepended to PATH for spawned engine processes.
    public var venvBin: URL {
        venvRoot.appending(path: "bin", directoryHint: .isDirectory)
    }

    /// `~/.local/bin` — where the Astral `uv` installer places `uv` by default
    /// (matching vllm-metal/scripts/lib.sh, so an app-bootstrapped uv and a
    /// CLI-bootstrapped uv are the same binary).
    public var localBin: URL {
        home.appending(path: ".local/bin", directoryHint: .isDirectory)
    }

    /// `~/.local/bin/uv`.
    public var uvBinary: URL {
        localBin.appending(path: "uv", directoryHint: .notDirectory)
    }

    /// `~/.cache/huggingface/hub` — the HF Hub cache the engine reads from and
    /// that the engine and `snapshot_download` write to (so the app never
    /// double-downloads weights).
    public var huggingFaceCache: URL {
        home.appending(path: ".cache/huggingface/hub", directoryHint: .isDirectory)
    }

    /// `~/Library/Application Support/<bundleID>`.
    public func appSupport(bundleID: String) -> URL {
        home
            .appending(path: "Library/Application Support", directoryHint: .isDirectory)
            .appending(path: bundleID, directoryHint: .isDirectory)
    }

    /// `~/Library/Application Support/<bundleID>/engine_state.json` — the
    /// supervisor's atomically-written run-state file (analog of lmstack's
    /// `~/.lmstack/native_processes.json`). See docs/PLAN.md §3.
    public func engineStateFile(bundleID: String) -> URL {
        appSupport(bundleID: bundleID).appending(path: "engine_state.json", directoryHint: .notDirectory)
    }

    /// `~/Library/Application Support/<bundleID>/logs` — per-deployment engine logs.
    public func logsDirectory(bundleID: String) -> URL {
        appSupport(bundleID: bundleID).appending(path: "logs", directoryHint: .isDirectory)
    }
}

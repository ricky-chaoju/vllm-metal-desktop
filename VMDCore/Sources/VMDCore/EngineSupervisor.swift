import Foundation

/// Lifecycle of a supervised `vllm serve` process.
public enum ServeStatus: Sendable, Equatable {
    case idle
    case starting
    case running
    case stopping
    case stopped
    case failed(String)
}

/// Emitted while supervising a serve process.
public enum ServeEvent: Sendable, Equatable {
    case status(ServeStatus)
    case log(String)
}

/// Starts, supervises, and stops a single `vllm serve` process — the analog of
/// lmstack's `process_manager.py` (docs/PLAN.md §3). Readiness is the engine's
/// `/v1/models` answering 200; shutdown is SIGTERM then SIGKILL after a grace
/// period. A user-initiated stop reports `.stopped`, while an unexpected exit
/// reports `.failed`.
///
/// v1 supervises only processes it launched; reattaching to an orphaned serve
/// after an app restart (full recovery) is a later refinement.
public final class EngineSupervisor: @unchecked Sendable {
    public let paths: EnginePaths
    private let lock = NSLock()
    private var session: ProcessSession?
    private var stopRequested = false

    public init(paths: EnginePaths = .standard) {
        self.paths = paths
    }

    /// Environment so the venv's `vllm`/`python` and the Metal plugin are used.
    public var serveEnvironment: [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["VIRTUAL_ENV"] = paths.venvRoot.path
        let inherited = env["PATH"] ?? "/usr/bin:/bin"
        env["PATH"] = "\(paths.venvBin.path):\(inherited)"
        // vLLM only colors output on a TTY; our log view renders ANSI itself,
        // so force color even though stdout is a file (vllm/logger.py honors this).
        env["VLLM_LOGGING_COLOR"] = "1"
        return env
    }

    public var isRunning: Bool {
        lock.withLock { session?.isRunning ?? false }
    }

    /// PID of the running serve process (for persisting recovery state).
    public var processID: Int32? {
        lock.withLock {
            guard let session, session.isRunning else { return nil }
            return session.processIdentifier
        }
    }

    /// Starts `vllm serve` for the given config. With `logFileURL`, the child's
    /// output is redirected to that file (so it survives this app exiting — a
    /// relaunched app re-reads and tails it) and `.log` events come from tailing;
    /// without it, output streams from pipes as before (the unit-test seam).
    public func start(
        _ config: ServeConfig,
        logFileURL: URL? = nil,
        readinessTimeout: Duration = .seconds(900)
    ) -> AsyncStream<ServeEvent> {
        var environment = serveEnvironment
        for (key, value) in config.extraEnvironment { environment[key] = value }
        let launch = ProcessLaunch(
            executableURL: paths.venvVLLM,
            arguments: config.launchArguments,
            environment: environment
        )
        return start(launch: launch, port: config.port, logFileURL: logFileURL, readinessTimeout: readinessTimeout)
    }

    /// Core launcher (also the seam unit tests drive with a stub command).
    public func start(
        launch: ProcessLaunch,
        port: Int,
        logFileURL: URL? = nil,
        readinessTimeout: Duration = .seconds(900)
    ) -> AsyncStream<ServeEvent> {
        let (stream, continuation) = AsyncStream<ServeEvent>.makeStream()
        let session = ProcessSession()
        lock.withLock {
            self.session = session
            self.stopRequested = false
        }

        continuation.yield(.status(.starting))

        let worker = Task { [self] in
            defer { continuation.finish() }
            let client = OpenAIClient(port: port)
            let readiness = Task {
                if await client.waitUntilReady(timeout: readinessTimeout) {
                    continuation.yield(.status(.running))
                }
            }
            var tail: Task<Void, Never>?
            do {
                let events: AsyncStream<ProcessEvent>
                if let logFileURL {
                    events = try session.start(launch, redirectingOutputTo: logFileURL)
                    tail = Task {
                        for await line in FileTailer(url: logFileURL).lines() {
                            continuation.yield(.log(line))
                        }
                    }
                } else {
                    events = try session.start(launch)
                }
                for await event in events {
                    switch event {
                    case .stdout(let line), .stderr(let line):
                        continuation.yield(.log(line))
                    case .exit(let code):
                        readiness.cancel()
                        // Give the tail a moment to drain the last lines.
                        try? await Task.sleep(for: .milliseconds(500))
                        tail?.cancel()
                        let userStopped = lock.withLock { () -> Bool in
                            let stopped = self.stopRequested
                            // Identity-guarded: a quick stop→start replaces
                            // `self.session` with the new run's before this
                            // drain-delayed exit handler fires — never clobber
                            // the successor's handle.
                            if self.session === session { self.session = nil }
                            return stopped
                        }
                        if userStopped || code == 0 {
                            continuation.yield(.status(.stopped))
                        } else {
                            continuation.yield(.status(.failed("vllm serve exited with code \(code)")))
                        }
                    }
                }
            } catch {
                readiness.cancel()
                tail?.cancel()
                lock.withLock { if self.session === session { self.session = nil } }
                continuation.yield(.status(.failed("Failed to launch vllm: \(error.localizedDescription)")))
            }
        }

        continuation.onTermination = { _ in worker.cancel() }
        return stream
    }

    /// Gracefully stops the process: SIGTERM, then SIGKILL after `graceSeconds`.
    public func stop(graceSeconds: Double = 10) async {
        let session = lock.withLock { () -> ProcessSession? in
            self.stopRequested = true
            return self.session
        }
        guard let session else { return }

        session.terminate()
        let deadline = ContinuousClock.now.advanced(by: .seconds(graceSeconds))
        while ContinuousClock.now < deadline {
            if !session.isRunning { return }
            try? await Task.sleep(for: .milliseconds(200))
        }
        if session.isRunning { session.sendSIGKILL() }
    }
}

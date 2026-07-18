import Foundation
import Observation
import VMDCore

/// One running (or starting) `vllm serve` engine: its process, port, status,
/// and log stream. `ServeController` manages a list of these — one model per
/// engine process is a vLLM invariant, so "run several models" means several
/// deployments side by side.
@MainActor
@Observable
final class ServeDeployment: Identifiable {
    let id = UUID()
    /// The model id this deployment was started with.
    let model: String
    let port: Int

    private(set) var status: ServeStatus = .idle
    private(set) var servedModelName: String?
    private(set) var adoptedPID: Int32?
    /// The serve configuration this deployment was (last) deployed with —
    /// kept after a stop so the user's setup survives until they delete the
    /// deployment. `nil` only for legacy-recovered entries (falls back to the
    /// global defaults on restart).
    private(set) var flags: ServeFlags?
    var logs: [LogLine] = []

    private let supervisor = EngineSupervisor()
    private let paths = EnginePaths.standard
    private let bundleID: String
    private var runTask: Task<Void, Never>?
    private var tailTask: Task<Void, Never>?
    private var nextLogID = 0
    private var pendingLog: [String] = []
    private var logFlushScheduled = false
    /// Called on lifecycle transitions so the controller can persist/recover.
    var onStateChange: (() -> Void)?

    init(model: String, port: Int, bundleID: String) {
        self.model = model
        self.port = port
        self.bundleID = bundleID
    }

    var isRunning: Bool { status == .running }
    var isStarting: Bool { status == .starting }
    var isStopping: Bool { status == .stopping }
    var isFailed: Bool { if case .failed = status { true } else { false } }
    /// Parked (stopped/failed/never started) — restartable and deletable.
    var isRestartable: Bool { status == .idle || status == .stopped || isFailed }
    var openAIClient: OpenAIClient? { isRunning ? OpenAIClient(port: port) : nil }

    var statusText: String {
        switch status {
        case .idle: "Not running"
        case .starting: "Loading model…"
        case .running: "Running"
        case .stopping: "Stopping…"
        case .stopped: "Stopped"
        case .failed(let message): "Failed: \(message)"
        }
    }

    /// PID for run-state persistence (launched or adopted).
    var processID: Int32? { adoptedPID ?? supervisor.processID }

    /// Each deployment logs to its own file, so an adopted engine's history and
    /// live output survive app restarts.
    var logFileURL: URL {
        paths.logsDirectory(bundleID: bundleID)
            .appending(path: "serve-\(port).log", directoryHint: .notDirectory)
    }

    // MARK: Lifecycle

    /// Starts (or restarts a stopped/failed) deployment with `flags`. A restart
    /// begins a fresh run: previous logs clear and any adopted-process handle is
    /// dropped — the log-line ids keep counting up so the log view's tail-follow
    /// stays monotonic.
    func start(flags: ServeFlags) {
        guard isRestartable else { return }
        self.flags = flags
        adoptedPID = nil
        tailTask?.cancel()
        tailTask = nil
        runTask?.cancel()
        pendingLog.removeAll()
        logs.removeAll()

        let config = ServeConfig(
            model: model,
            port: port,
            extraArguments: flags.cliArguments(),
            extraEnvironment: flags.environment
        )
        servedModelName = config.effectiveModelName
        status = .starting

        try? FileManager.default.createDirectory(
            at: paths.logsDirectory(bundleID: bundleID), withIntermediateDirectories: true
        )
        runTask = Task { [supervisor, logFileURL] in
            for await event in supervisor.start(config, logFileURL: logFileURL) {
                switch event {
                case .status(let newStatus):
                    status = newStatus
                    onStateChange?()
                case .log(let line):
                    appendLog(line)
                }
            }
        }
    }

    /// Restores a parked deployment from persistence (its engine isn't running;
    /// the saved configuration is).
    func restore(flags: ServeFlags?) {
        self.flags = flags
        status = .stopped
    }

    /// Attaches the persisted configuration to a re-adopted (running) engine.
    func adoptFlags(_ flags: ServeFlags?) {
        self.flags = flags
    }

    /// Re-attaches to an orphaned serve process after an app restart. Only
    /// adopts when the persisted PID still owns the port AND the server answers
    /// — both together defeat PID reuse. Returns success.
    func adopt(state: ServeRunState) async -> Bool {
        guard await Self.portOwnerPID(state.port) == state.pid else { return false }
        let client = OpenAIClient(port: state.port)
        guard await client.isReady() else { return false }

        adoptedPID = state.pid
        servedModelName = (try? await client.listModels())?.first ?? state.model
        status = .running

        let tailer = FileTailer(url: logFileURL)
        let history = tailer.snapshot(maxLines: 600)
        for line in history.lines { appendLog(line) }
        tailTask = Task { [weak self] in
            for await line in tailer.lines(fromOffset: history.endOffset) {
                self?.appendLog(line)
            }
        }
        return true
    }

    func stop() {
        // A failed engine already exited — its supervisor session is gone, so
        // routing through .stopping would wedge there forever. Just retire it.
        if case .failed = status {
            status = .stopped
            onStateChange?()
            return
        }
        status = .stopping
        if let pid = adoptedPID {
            // Adopted process — verify the PID still owns the serve port before
            // signalling, so PID reuse can never kill an unrelated process.
            Task {
                if await Self.portOwnerPID(port) == pid {
                    kill(pid, SIGTERM)
                    try? await Task.sleep(for: .seconds(8))
                    if await Self.portOwnerPID(port) == pid { kill(pid, SIGKILL) }
                }
                tailTask?.cancel()
                tailTask = nil
                status = .stopped
                onStateChange?()
            }
        } else {
            Task { [supervisor] in await supervisor.stop() }
        }
    }

    // MARK: Helpers

    /// The PID currently listening on `port`, via `lsof`, or nil if none.
    static func portOwnerPID(_ port: Int) async -> Int32? {
        guard let result = try? await ProcessSession.run(.init(
            executableURL: URL(filePath: "/usr/sbin/lsof"),
            arguments: ["-nP", "-ti", "tcp:\(port)", "-sTCP:LISTEN"]
        )), result.didSucceed else { return nil }
        let firstLine = result.standardOutput.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        return Int32(firstLine.trimmingCharacters(in: .whitespaces))
    }

    /// Coalesces log lines into ~80ms batches — the engine bursts dozens of
    /// lines at once and one observable mutation per line would re-render the
    /// whole colored log view per line.
    private func appendLog(_ line: String) {
        pendingLog.append(line)
        guard !logFlushScheduled else { return }
        logFlushScheduled = true
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(80))
            self?.flushPendingLog()
        }
    }

    private func flushPendingLog() {
        logFlushScheduled = false
        guard !pendingLog.isEmpty else { return }
        for line in pendingLog {
            logs.append(LogLine(id: nextLogID, text: line))
            nextLogID += 1
        }
        pendingLog.removeAll()
        if logs.count > 600 { logs.removeFirst(logs.count - 600) }
    }
}

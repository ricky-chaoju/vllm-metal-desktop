import Foundation
import os

/// Emits lines from a file handle, splitting on `\n` OR `\r` so carriage-return
/// progress updates (uv/pip during engine installs) stream incrementally.
private func streamLines(
    from handle: FileHandle,
    as makeEvent: @escaping @Sendable (String) -> ProcessEvent,
    into continuation: AsyncStream<ProcessEvent>.Continuation
) async {
    // NOT `handle.bytes`: FileHandle.AsyncBytes buffers pipe reads in large
    // chunks, so low-rate output (a ~70-byte progress line every half second)
    // sits undelivered for minutes and then floods out at process exit. The
    // readability handler hands over every write the moment it lands.
    let chunks = AsyncStream<Data> { chunkContinuation in
        handle.readabilityHandler = { fileHandle in
            let data = fileHandle.availableData
            if data.isEmpty { // EOF
                fileHandle.readabilityHandler = nil
                chunkContinuation.finish()
            } else {
                chunkContinuation.yield(data)
            }
        }
        chunkContinuation.onTermination = { _ in
            handle.readabilityHandler = nil
        }
    }

    var buffer: [UInt8] = []
    for await chunk in chunks {
        for byte in chunk {
            if byte == 0x0A || byte == 0x0D {
                if !buffer.isEmpty {
                    continuation.yield(makeEvent(String(decoding: buffer, as: UTF8.self)))
                    buffer.removeAll(keepingCapacity: true)
                }
            } else {
                buffer.append(byte)
            }
        }
    }
    if !buffer.isEmpty {
        continuation.yield(makeEvent(String(decoding: buffer, as: UTF8.self)))
    }
}

/// A `Sendable` shim that carries a non-`Sendable` value into a child task.
/// Safe here because each boxed value is used by exactly one task at a time.
struct UncheckedBox<T>: @unchecked Sendable {
    let value: T
    init(_ value: T) { self.value = value }
}

/// Describes a process to launch. Paths must be **absolute** — hardened programs
/// reject relative `dlopen`/exec paths (proven in tools/poc-dylib-load).
public struct ProcessLaunch: Sendable {
    public var executableURL: URL
    public var arguments: [String]
    /// Full environment for the child, or `nil` to inherit the app's.
    public var environment: [String: String]?
    public var currentDirectoryURL: URL?

    public init(
        executableURL: URL,
        arguments: [String] = [],
        environment: [String: String]? = nil,
        currentDirectoryURL: URL? = nil
    ) {
        self.executableURL = executableURL
        self.arguments = arguments
        self.environment = environment
        self.currentDirectoryURL = currentDirectoryURL
    }
}

/// A line of child output, or its final exit status.
public enum ProcessEvent: Sendable, Equatable {
    case stdout(String)
    case stderr(String)
    case exit(Int32)
}

/// The collected result of a process that ran to completion.
public struct CommandResult: Sendable, Equatable {
    public var exitCode: Int32
    public var standardOutput: String
    public var standardError: String

    public var didSucceed: Bool { exitCode == 0 }

    public init(exitCode: Int32, standardOutput: String, standardError: String) {
        self.exitCode = exitCode
        self.standardOutput = standardOutput
        self.standardError = standardError
    }
}

/// Launches and supervises **one** child process, streaming its output
/// line-by-line. A session is single-use: create a fresh one per launch —
/// a second `start` call throws instead of relaunching.
///
/// This is the foundation for both the engine installer (driving `uv`/`pip`) and
/// the M2 `EngineSupervisor` (driving `vllm serve`). Output is read concurrently
/// from both pipes — no pipe-buffer deadlock — and exactly one `.exit` is emitted
/// after both streams drain.
public final class ProcessSession: @unchecked Sendable {
    private let process = Process()
    private let launched = OSAllocatedUnfairLock(initialState: false)

    public init() {}

    /// `Process.run()` on an already-launched instance raises an uncatchable
    /// ObjC exception — turn API misuse into a recoverable Swift error instead.
    private func claimLaunch() throws {
        try launched.withLock { alreadyLaunched in
            guard !alreadyLaunched else {
                throw CocoaError(.executableLoad, userInfo: [
                    NSLocalizedDescriptionKey: "ProcessSession is single-use — create a new session per launch."
                ])
            }
            alreadyLaunched = true
        }
    }

    public var processIdentifier: Int32 { process.processIdentifier }
    public var isRunning: Bool { process.isRunning }

    /// Launches the process and returns a stream of stdout/stderr lines followed
    /// by a single `.exit`. Throws if the executable cannot be launched.
    public func start(_ launch: ProcessLaunch) throws -> AsyncStream<ProcessEvent> {
        try claimLaunch()  // before configuring: NSTask also traps on post-launch property sets
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.executableURL = launch.executableURL
        process.arguments = launch.arguments
        if let env = launch.environment { process.environment = env }
        if let cwd = launch.currentDirectoryURL { process.currentDirectoryURL = cwd }
        process.standardOutput = outPipe
        process.standardError = errPipe
        process.standardInput = FileHandle.nullDevice

        try process.run()

        let resources = UncheckedBox((
            proc: process,
            out: outPipe.fileHandleForReading,
            err: errPipe.fileHandleForReading
        ))

        return AsyncStream<ProcessEvent> { continuation in
            let worker = Task {
                let bundle = resources.value
                defer { continuation.finish() }
                await withTaskGroup(of: Void.self) { group in
                    let outBox = UncheckedBox(bundle.out)
                    let errBox = UncheckedBox(bundle.err)
                    group.addTask {
                        await streamLines(from: outBox.value, as: ProcessEvent.stdout, into: continuation)
                    }
                    group.addTask {
                        await streamLines(from: errBox.value, as: ProcessEvent.stderr, into: continuation)
                    }
                    await group.waitForAll()
                }
                bundle.proc.waitUntilExit()
                continuation.yield(.exit(bundle.proc.terminationStatus))
            }

            continuation.onTermination = { _ in
                worker.cancel()
                let bundle = resources.value
                if bundle.proc.isRunning { bundle.proc.terminate() }
            }
        }
    }

    /// Launches the process with stdout+stderr redirected to `fileURL` (created/
    /// truncated first). The returned stream emits only the final `.exit` — the
    /// output lives in the file, where it survives this app exiting entirely
    /// (tail it with `FileTailer`). This is how long-lived children like
    /// `vllm serve` keep loggable output after the app that spawned them is gone.
    public func start(_ launch: ProcessLaunch, redirectingOutputTo fileURL: URL) throws -> AsyncStream<ProcessEvent> {
        try claimLaunch()
        FileManager.default.createFile(atPath: fileURL.path, contents: nil)
        let handle = try FileHandle(forWritingTo: fileURL)
        try handle.truncate(atOffset: 0)

        process.executableURL = launch.executableURL
        process.arguments = launch.arguments
        if let env = launch.environment { process.environment = env }
        if let cwd = launch.currentDirectoryURL { process.currentDirectoryURL = cwd }
        process.standardOutput = handle
        process.standardError = handle
        process.standardInput = FileHandle.nullDevice

        try process.run()

        let resources = UncheckedBox((proc: process, file: handle))
        return AsyncStream<ProcessEvent> { continuation in
            let worker = Task {
                let bundle = resources.value
                defer { continuation.finish() }
                while bundle.proc.isRunning, !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(200))
                }
                try? bundle.file.close()
                guard !bundle.proc.isRunning else { return }  // cancelled mid-run
                continuation.yield(.exit(bundle.proc.terminationStatus))
            }
            continuation.onTermination = { _ in
                worker.cancel()
                let bundle = resources.value
                if bundle.proc.isRunning { bundle.proc.terminate() }
            }
        }
    }

    /// Sends SIGTERM for a graceful shutdown.
    public func terminate() {
        if process.isRunning { process.terminate() }
    }

    /// Sends SIGKILL — last resort after a SIGTERM grace period.
    public func sendSIGKILL() {
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
    }

    /// Convenience: run to completion, collecting all output.
    public static func run(_ launch: ProcessLaunch) async throws -> CommandResult {
        let session = ProcessSession()
        var out = ""
        var err = ""
        var code: Int32 = -1
        for await event in try session.start(launch) {
            switch event {
            case .stdout(let line): out += line + "\n"
            case .stderr(let line): err += line + "\n"
            case .exit(let c): code = c
            }
        }
        return CommandResult(
            exitCode: code,
            standardOutput: out.trimmingCharacters(in: .newlines),
            standardError: err.trimmingCharacters(in: .newlines)
        )
    }
}

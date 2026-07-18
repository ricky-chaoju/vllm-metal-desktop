import Foundation

/// Downloads a model into the shared HuggingFace cache so the engine can serve it
/// later without re-downloading (docs/PLAN.md §5).
///
/// `huggingface_hub.snapshot_download` is the transfer engine (cache layout,
/// auth, retries); progress is measured the way established projects do it:
///
/// - **Total** comes from the Hub API once, up front — every file's exact size
///   and blob name. The denominator never grows mid-download.
/// - **Downloaded** is real bytes on disk, sampled on a steady half-second
///   clock: completed blobs count in full, in-flight `*.incomplete` files at
///   their current size, already-cached files from the first tick. Classic
///   (non-xet) downloads append sequentially, so the counter is monotonic and
///   survives any `huggingface_hub` version's progress-bar internals (whose
///   tqdm hooks changed incompatibly across 0.x → 1.18 → 1.23 — the previous
///   tqdm-interception approach double-counted on 1.23+, where transfer and
///   reconstruction bars both report).
/// - **Speed** is computed Swift-side by `DownloadRateEstimator` (Ollama-style
///   ten-second sliding window over cumulative samples), so a stall decays to
///   zero smoothly and inter-file gaps never flicker the readout.
public struct ModelDownloader: Sendable {
    public var paths: EnginePaths

    public init(paths: EnginePaths = .standard) {
        self.paths = paths
    }

    /// Downloads run through the venv interpreter, so they use the engine's pinned
    /// `huggingface_hub` (and its xet/hf_transfer acceleration) — not the app's.
    public var isAvailable: Bool {
        FileManager.default.fileExists(atPath: paths.venvPython.path)
    }

    private var environment: [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["VIRTUAL_ENV"] = paths.venvRoot.path
        env["PATH"] = "\(paths.venvBin.path):\(env["PATH"] ?? "/usr/bin:/bin")"
        // Unbuffered stdout so JSON progress lines reach us as they happen.
        env["PYTHONUNBUFFERED"] = "1"
        // Progress comes from the filesystem, not tqdm — silence the bars.
        env["HF_HUB_DISABLE_PROGRESS_BARS"] = "1"
        // Byte accounting relies on classic sequential-append downloads. The
        // xet/hf_transfer backends write chunks at parallel offsets, which makes
        // on-disk size meaningless mid-flight (and their own progress reporting
        // is bursty). Trade a little peak throughput for honest progress.
        env["HF_HUB_DISABLE_XET"] = "1"
        env["HF_HUB_ENABLE_HF_TRANSFER"] = "0"
        return env
    }

    /// A download's lifecycle, derived from the helper's JSON stream.
    public enum DownloadEvent: Sendable, Equatable {
        /// Real bytes on disk against the resolved total (`totalBytes == 0` while
        /// file sizes are still being resolved — show an indeterminate state).
        /// `bytesPerSecond` is the sliding-window rate (0 until measurable).
        case progress(downloadedBytes: Int64, totalBytes: Int64, bytesPerSecond: Int64)
        /// The snapshot finished; `path` is its local directory.
        case finished(path: String)
        case failed(reason: String)
    }

    /// The bundled Python helper (a SwiftPM resource, so it stays a real,
    /// lintable `.py` file). Internal for the resource-presence test.
    static var helperScriptURL: URL? {
        Bundle.module.url(forResource: "hf_download", withExtension: "py")
    }

    /// Streams download progress and the terminal outcome. Cancelling the consumer
    /// terminates the helper process.
    public func download(modelID: String, revision: String? = nil) -> AsyncStream<DownloadEvent> {
        let (stream, continuation) = AsyncStream<DownloadEvent>.makeStream()
        let session = ProcessSession()
        let env = environment
        let python = paths.venvPython

        let task = Task {
            guard let scriptURL = Self.helperScriptURL else {
                continuation.yield(.failed(reason: "The downloader helper is missing from the app bundle."))
                continuation.finish()
                return
            }

            var arguments = [scriptURL.path, modelID]
            if let revision { arguments.append(revision) }
            let launch = ProcessLaunch(executableURL: python, arguments: arguments, environment: env)

            var resolvedPath: String?
            var failureReason: String?
            // Speed lives here, not in the helper: cumulative on-disk samples in,
            // windowed rate out — measured, smoothed, and unit-testable.
            var estimator = DownloadRateEstimator()
            do {
                for await event in try session.start(launch) {
                    switch event {
                    case .stdout(let line):
                        switch Self.parse(line) {
                        case .progress(let downloaded, let total):
                            estimator.record(bytes: downloaded, at: ProcessInfo.processInfo.systemUptime)
                            continuation.yield(.progress(
                                downloadedBytes: downloaded,
                                totalBytes: total,
                                bytesPerSecond: estimator.bytesPerSecond
                            ))
                        case .finished(let path):
                            resolvedPath = path
                        case .failed(let reason):
                            failureReason = reason
                        case nil:
                            break
                        }
                    case .stderr:
                        break // tqdm bars / auth warnings — logs only, never progress
                    case .exit(let code):
                        if let resolvedPath {
                            continuation.yield(.finished(path: resolvedPath))
                        } else {
                            continuation.yield(.failed(reason: failureReason ?? "Download exited with code \(code)"))
                        }
                    }
                }
            } catch {
                continuation.yield(.failed(reason: "Failed to launch the downloader: \(error.localizedDescription)"))
            }
            continuation.finish()
        }

        continuation.onTermination = { _ in
            task.cancel()
            session.terminate()
        }
        return stream
    }

    // MARK: - JSON line parsing

    /// Internal (not private) so tests can lock down the helper-protocol
    /// decoding that drives the download UI.
    enum Parsed: Equatable {
        case progress(downloaded: Int64, total: Int64)
        case finished(path: String)
        case failed(reason: String)
    }

    private struct Line: Decodable {
        let type: String
        let downloaded: Int64?
        let total: Int64?
        let path: String?
        let message: String?
    }

    static func parse(_ line: String) -> Parsed? {
        guard let data = line.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(Line.self, from: data) else { return nil }
        switch decoded.type {
        case "progress":
            return .progress(downloaded: decoded.downloaded ?? 0, total: decoded.total ?? 0)
        case "done":
            return .finished(path: decoded.path ?? "")
        case "error":
            return .failed(reason: decoded.message ?? "Unknown error")
        default:
            return nil
        }
    }

}

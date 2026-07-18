import Foundation

/// Follows an append-only text file (`tail -f`), yielding complete lines as they
/// are written. Survives the file not existing yet and detects truncation
/// (offset beyond EOF → restart from the top). Polling-based: simple, reliable,
/// and cheap at the ~300ms cadence a log view needs.
public struct FileTailer: Sendable {
    public var url: URL
    public var pollInterval: Duration

    public init(url: URL, pollInterval: Duration = .milliseconds(300)) {
        self.url = url
        self.pollInterval = pollInterval
    }

    /// Lines appended from `offset` onward, following until cancelled.
    public func lines(fromOffset offset: UInt64 = 0) -> AsyncStream<String> {
        let (stream, continuation) = AsyncStream<String>.makeStream()
        let url = url
        let pollInterval = pollInterval

        let worker = Task {
            var position = offset
            var partial = Data()
            defer { continuation.finish() }

            while !Task.isCancelled {
                if let handle = try? FileHandle(forReadingFrom: url) {
                    defer { try? handle.close() }
                    let size = (try? handle.seekToEnd()) ?? 0
                    if size < position {  // truncated/rotated — start over
                        position = 0
                        partial.removeAll()
                    }
                    if size > position {
                        try? handle.seek(toOffset: position)
                        let data = (try? handle.readToEnd()) ?? Data()
                        position += UInt64(data.count)
                        partial.append(data)
                        while let newline = partial.firstIndex(of: 0x0A) {
                            let lineData = partial.prefix(upTo: newline)
                            partial.removeSubrange(...newline)
                            continuation.yield(String(decoding: lineData, as: UTF8.self))
                        }
                    }
                }
                try? await Task.sleep(for: pollInterval)
            }
        }
        continuation.onTermination = { _ in worker.cancel() }
        return stream
    }

    /// The last `maxLines` complete lines currently in the file, and the size to
    /// continue tailing from — for showing history before following.
    public func snapshot(maxLines: Int) -> (lines: [String], endOffset: UInt64) {
        guard let data = try? Data(contentsOf: url) else { return ([], 0) }
        let all = String(decoding: data, as: UTF8.self)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
        // The final element is either "" (file ends in \n) or a partial line with
        // no newline yet — drop it either way; the tail picks the partial up when
        // its newline lands.
        let complete = all.dropLast()
        // The resume offset is derived from raw bytes (one past the last \n),
        // never from decoded-string lengths — lossy UTF-8 decoding inserts
        // replacement characters whose byte counts don't match the file.
        let endOffset = data.lastIndex(of: 0x0A).map { UInt64($0 + 1) } ?? 0
        return (Array(complete.suffix(maxLines)), endOffset)
    }
}

import Foundation

/// The displayed-rate estimator every mature downloader converges on (Ollama's
/// `progress/bar.go`, curl's speeder, Chromium's `RateEstimator`): sample the
/// session-cumulative byte counter on a steady clock into one-second buckets,
/// keep a short sliding window, and report the byte delta across it.
///
/// Sampling *cumulative* bytes — including zero-delta ticks — is what makes the
/// readout honest: a stall drains the window and the rate decays to zero within
/// `windowBuckets` seconds instead of freezing at the last burst, and the burst
/// after a stall is diluted across the window instead of spiking.
public struct DownloadRateEstimator: Sendable {
    private var buckets: [(time: TimeInterval, bytes: Int64)] = []
    private let bucketSeconds: TimeInterval
    private let maxBuckets: Int

    /// Defaults match Ollama/Chromium: ten one-second buckets → a ~10 s window.
    public init(windowBuckets: Int = 10, bucketSeconds: TimeInterval = 1) {
        self.maxBuckets = max(2, windowBuckets)
        self.bucketSeconds = bucketSeconds
    }

    /// Records the cumulative byte count at `time` (any monotonic clock).
    /// At most one bucket per `bucketSeconds` is kept — extra samples within a
    /// bucket are ignored, so callers can feed updates at any cadence.
    public mutating func record(bytes: Int64, at time: TimeInterval) {
        if let last = buckets.last {
            guard time - last.time >= bucketSeconds else { return }
            // A cumulative counter never goes backwards; clamp defensively so a
            // misbehaving source can only flatten the rate, not turn it negative.
            buckets.append((time, max(bytes, last.bytes)))
        } else {
            buckets.append((time, bytes))
        }
        if buckets.count > maxBuckets {
            buckets.removeFirst(buckets.count - maxBuckets)
        }
    }

    /// Bytes per second across the window; 0 until two buckets exist.
    public var bytesPerSecond: Int64 {
        guard let first = buckets.first, let last = buckets.last, last.time > first.time else { return 0 }
        return Int64(max(0, Double(last.bytes - first.bytes) / (last.time - first.time)))
    }

    public mutating func reset() {
        buckets.removeAll()
    }
}

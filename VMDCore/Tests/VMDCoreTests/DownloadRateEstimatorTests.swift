import Foundation
import Testing
@testable import VMDCore

@Suite("DownloadRateEstimator")
struct DownloadRateEstimatorTests {
    @Test("No rate until two buckets exist")
    func coldStart() {
        var estimator = DownloadRateEstimator()
        #expect(estimator.bytesPerSecond == 0)
        estimator.record(bytes: 1_000_000, at: 0)
        #expect(estimator.bytesPerSecond == 0)
    }

    @Test("Steady transfer reports the true rate")
    func steadyRate() {
        var estimator = DownloadRateEstimator()
        for second in 0...5 {
            estimator.record(bytes: Int64(second) * 2_000_000, at: TimeInterval(second))
        }
        #expect(estimator.bytesPerSecond == 2_000_000)
    }

    @Test("Sub-second samples collapse into one bucket")
    func subSecondSamplesIgnored() {
        var estimator = DownloadRateEstimator()
        estimator.record(bytes: 0, at: 0)
        estimator.record(bytes: 500_000, at: 0.2)
        estimator.record(bytes: 900_000, at: 0.7)
        // Still a single bucket — no rate yet.
        #expect(estimator.bytesPerSecond == 0)
        estimator.record(bytes: 1_000_000, at: 1.0)
        #expect(estimator.bytesPerSecond == 1_000_000)
    }

    @Test("Rate reflects only the sliding window, not ancient history")
    func windowEviction() {
        var estimator = DownloadRateEstimator(windowBuckets: 10)
        // 10 s of fast transfer (10 MB/s), then 10 s of slow (1 MB/s).
        var bytes: Int64 = 0
        for second in 0..<10 {
            bytes += 10_000_000
            estimator.record(bytes: bytes, at: TimeInterval(second))
        }
        for second in 10..<20 {
            bytes += 1_000_000
            estimator.record(bytes: bytes, at: TimeInterval(second))
        }
        // The fast era has been fully evicted; only the slow rate remains.
        #expect(estimator.bytesPerSecond == 1_000_000)
    }

    @Test("A stall decays the rate to zero instead of freezing it")
    func stallDecaysToZero() {
        var estimator = DownloadRateEstimator(windowBuckets: 10)
        estimator.record(bytes: 0, at: 0)
        estimator.record(bytes: 50_000_000, at: 1)
        #expect(estimator.bytesPerSecond == 50_000_000)
        // Zero-delta ticks (the download stalled, sampler keeps ticking).
        for second in 2...12 {
            estimator.record(bytes: 50_000_000, at: TimeInterval(second))
        }
        #expect(estimator.bytesPerSecond == 0)
    }

    @Test("A backwards-moving source clamps flat, never negative")
    func nonMonotonicClamped() {
        var estimator = DownloadRateEstimator()
        estimator.record(bytes: 5_000_000, at: 0)
        estimator.record(bytes: 3_000_000, at: 1)
        #expect(estimator.bytesPerSecond == 0)
    }

    @Test("Reset clears all history")
    func reset() {
        var estimator = DownloadRateEstimator()
        estimator.record(bytes: 0, at: 0)
        estimator.record(bytes: 9_000_000, at: 1)
        estimator.reset()
        #expect(estimator.bytesPerSecond == 0)
    }
}

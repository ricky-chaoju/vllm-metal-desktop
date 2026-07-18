import Foundation
import Testing
@testable import VMDCore

@Suite("HardwareInfo")
struct HardwareInfoTests {
    let sample = HardwareInfo(
        modelIdentifier: "Mac14,5",
        marketingName: "MacBook Pro (14-inch, 2023)",
        chip: "Apple M2 Max",
        totalCPUCores: 12,
        performanceCores: 8,
        efficiencyCores: 4,
        gpuName: "Apple M2 Max",
        unifiedMemoryBytes: 34_359_738_368, // 32 GiB
        metalBudgetBytes: 25_769_803_776,   // 24 GiB
        hasUnifiedMemory: true,
        isAppleSilicon: true,
        osVersion: "macOS 26.5.0",
        appVersion: "1.0 (1)",
        freeDiskBytes: 500_000_000_000,
        totalDiskBytes: 1_000_000_000_000
    )

    @Test("binary GiB formatting")
    func gib() {
        #expect(HardwareInfo.gibString(34_359_738_368) == "32 GB")
        #expect(HardwareInfo.gibString(1_073_741_824) == "1 GB")
        #expect(HardwareInfo.gibString(1_610_612_736) == "1.5 GB")
    }

    @Test("cpu description includes the core split")
    func cpu() {
        #expect(sample.cpuDescription == "12 cores (8 performance + 4 efficiency)")
        var noSplit = sample
        noSplit.performanceCores = 0
        noSplit.efficiencyCores = 0
        #expect(noSplit.cpuDescription == "12 cores")
    }

    @Test("report contains the key facts for a bug report")
    func report() {
        let text = sample.formattedReport()
        #expect(text.contains("MacBook Pro (14-inch, 2023) — Mac14,5"))
        #expect(text.contains("Apple M2 Max"))
        #expect(text.contains("12 cores (8 performance + 4 efficiency)"))
        #expect(text.contains("32 GB"))
        #expect(text.contains("24 GB"))
        #expect(text.contains("arm64 (Apple Silicon)"))
        #expect(text.contains("macOS 26.5.0"))
        #expect(text.contains("1.0 (1)"))
    }

    @Test("report values align in one column, whichever optional rows exist")
    func reportAlignment() {
        for info in [sample, {
            var trimmed = sample
            trimmed.appVersion = nil        // shorter label set
            trimmed.metalBudgetBytes = nil
            trimmed.marketingName = nil
            return trimmed
        }()] {
            let lines = info.formattedReport().split(separator: "\n").dropFirst()
            let valueColumns = Set(lines.compactMap { line -> Int? in
                guard let colon = line.firstIndex(of: ":") else { return nil }
                let after = line[line.index(after: colon)...]
                let padding = after.prefix { $0 == " " }.count
                return line.distance(from: line.startIndex, to: colon) + 1 + padding
            })
            #expect(valueColumns.count == 1, "values start at one shared column")
        }
    }

    @Test("device-tree product name parsing")
    func productName() {
        #expect(HardwareInfo.parseProductName(Data("Mac Pro (2023)\0".utf8)) == "Mac Pro (2023)")
        #expect(HardwareInfo.parseProductName(Data("\0".utf8)) == nil)
        #expect(HardwareInfo.parseProductName(Data()) == nil)
    }

    @Test("live probe reads this Mac")
    func liveProbe() {
        let hw = HardwareInfo.current()
        #expect(hw.unifiedMemoryBytes > 0)
        #expect(hw.totalCPUCores > 0)
        // Architecture-specific expectations follow the machine actually
        // running the tests (Intel CI runners exist).
        #if arch(arm64)
        #expect(hw.isAppleSilicon)
        #expect(hw.chip != "Unknown")
        #else
        #expect(!hw.isAppleSilicon)
        #endif
        #expect(!hw.formattedReport().isEmpty)
    }
}

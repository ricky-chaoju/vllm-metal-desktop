import Testing
@testable import VMDCore

@Suite("SystemUsage")
struct SystemUsageTests {
    @Test("memory fraction is used over total")
    func memoryFraction() {
        let usage = SystemUsage(memoryUsedBytes: 50, memoryTotalBytes: 200)
        #expect(usage.memoryFraction == 0.25)
    }

    @Test("zero total never divides by zero")
    func zeroTotalGuard() {
        let usage = SystemUsage(memoryUsedBytes: 50, memoryTotalBytes: 0)
        #expect(usage.memoryFraction == 0)
    }
}

import Foundation
import Testing
@testable import VMDCore

@Suite("Preflight")
struct PreflightTests {
    /// The wheel install path compiles nothing, but it does need `git`: the
    /// engine wheel pins `mlx-lm` to a git URL and uv resolves it with the git
    /// CLI, which on macOS arrives with the Command Line Tools.
    @Test("checklist covers arch, OS, disk, and the tools that carry git")
    func kinds() {
        #expect(PreflightItem.Kind.allCases
            == [.architecture, .operatingSystem, .diskSpace, .commandLineTools])
    }

    @Test("architecture evaluation")
    func architecture() {
        #expect(Preflight.evaluateArchitecture(isAppleSilicon: true) == .ok)
        #expect(!Preflight.evaluateArchitecture(isAppleSilicon: false).isOK)
    }

    @Test("OS evaluation honors the minimum")
    func os() {
        #expect(Preflight.evaluateOS(major: 14, minimum: 14) == .ok)
        #expect(Preflight.evaluateOS(major: 26, minimum: 14) == .ok)
        #expect(!Preflight.evaluateOS(major: 13, minimum: 14).isOK)
    }

    @Test("disk evaluation honors the requirement")
    func disk() {
        #expect(Preflight.evaluateDisk(freeBytes: 10_000_000_000, requiredBytes: 6_000_000_000) == .ok)
        #expect(Preflight.evaluateDisk(freeBytes: 6_000_000_000, requiredBytes: 6_000_000_000) == .ok)
        #expect(!Preflight.evaluateDisk(freeBytes: 1_000_000_000, requiredBytes: 6_000_000_000).isOK)
    }

    @Test("live run produces one item per kind")
    func liveRun() async {
        let items = await Preflight().run()
        #expect(items.count == PreflightItem.Kind.allCases.count)
        #expect(Set(items.map(\.kind)) == Set(PreflightItem.Kind.allCases))
        // Only assert the architecture verdict where it's knowable from the
        // test host (Intel CI runners exist).
        #if arch(arm64)
        let arch = items.first { $0.kind == .architecture }
        #expect(arch?.status == .ok)
        #endif
    }
}

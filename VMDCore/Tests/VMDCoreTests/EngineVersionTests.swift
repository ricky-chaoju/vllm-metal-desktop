import Testing
@testable import VMDCore

@Suite("EngineVersion")
struct EngineVersionTests {
    @Test("parses a dev-timestamped release")
    func parsesDevTimestamp() throws {
        let v = try #require(EngineVersion("0.3.0.dev20260620073347"))
        #expect(v.release == [0, 3, 0])
        #expect(v.dev == 20_260_620_073_347)
        #expect(v.isDev)
        #expect(v.releaseString == "0.3.0")
    }

    @Test("parses a final release")
    func parsesFinal() throws {
        let v = try #require(EngineVersion("0.3.0"))
        #expect(v.release == [0, 3, 0])
        #expect(v.dev == nil)
        #expect(!v.isDev)
    }

    @Test("accepts a leading v and ignores +local metadata")
    func leadingVAndLocal() throws {
        let tag = try #require(EngineVersion("v0.3.0.dev20260620073347"))
        #expect(tag.dev == 20_260_620_073_347)

        let fallback = try #require(EngineVersion("0.0.0+unknown"))
        #expect(fallback.release == [0, 0, 0])
        #expect(fallback.dev == nil)
    }

    @Test("rejects non-versions")
    func rejectsGarbage() {
        #expect(EngineVersion("") == nil)
        #expect(EngineVersion("not-a-version") == nil)
        #expect(EngineVersion("0.3.x") == nil)
        #expect(EngineVersion("0.3.0.dev") == nil)
        #expect(EngineVersion("0.3.0.devabc") == nil)
    }

    @Test("orders dev builds by timestamp, not lexically")
    func ordersDevByTimestamp() throws {
        let older = try #require(EngineVersion("0.3.0.dev20260620073347"))
        let newer = try #require(EngineVersion("0.3.0.dev20260621000000"))
        #expect(older < newer)

        // The lexical trap: "dev9" must sort *before* "dev10".
        let dev9 = try #require(EngineVersion("0.3.0.dev9"))
        let dev10 = try #require(EngineVersion("0.3.0.dev10"))
        #expect(dev9 < dev10)
    }

    @Test("a dev build precedes its final release")
    func devPrecedesFinal() throws {
        let dev = try #require(EngineVersion("0.3.0.dev20260620073347"))
        let final = try #require(EngineVersion("0.3.0"))
        #expect(dev < final)
        #expect(final > dev)
    }

    @Test("compares the numeric release before the dev segment")
    func releaseDominatesDev() throws {
        let lowBaseHighDev = try #require(EngineVersion("0.3.0.dev99999999999999"))
        let highBaseLowDev = try #require(EngineVersion("0.4.0.dev1"))
        #expect(lowBaseHighDev < highBaseLowDev)
    }

    @Test("treats trailing-zero releases as equal")
    func trailingZeroEquality() throws {
        let a = try #require(EngineVersion("0.3"))
        let b = try #require(EngineVersion("0.3.0"))
        #expect(a == b)
        #expect(a.hashValue == b.hashValue)
    }

    @Test("upgrade detection is conservative")
    func upgradeDetection() throws {
        let installed = EngineVersion("0.3.0.dev20260620073347")
        let newer = EngineVersion("0.3.0.dev20260621000000")
        let older = EngineVersion("0.3.0.dev20260619000000")

        #expect(EngineVersion.isUpgrade(from: installed, to: newer))
        #expect(!EngineVersion.isUpgrade(from: installed, to: older))
        #expect(!EngineVersion.isUpgrade(from: installed, to: installed))
        // Unparseable inputs never trigger an update.
        #expect(!EngineVersion.isUpgrade(from: installed, to: EngineVersion("garbage")))
        #expect(!EngineVersion.isUpgrade(from: EngineVersion("garbage"), to: newer))
    }
}

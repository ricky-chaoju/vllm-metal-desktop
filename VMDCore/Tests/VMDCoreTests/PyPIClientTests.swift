import Foundation
import Testing
@testable import VMDCore

@Suite("PyPIClient")
struct PyPIClientTests {
    static let fixture = Data("""
    {
      "info": {"version": "2.56.1"},
      "releases": {
        "2.56.1": [{}],
        "2.56.0": [{}],
        "2.55.1": [{}],
        "3.0.0rc1": [{}],
        "2.50.0.post1": [{}],
        "2.9.3": [{}],
        "2.10.0": [{}]
      }
    }
    """.utf8)

    @Test("keeps stable versions, newest first, dropping rc/post releases")
    func parsesAndFilters() throws {
        let versions = try PyPIClient.parse(Self.fixture)
        #expect(versions.latest == "2.56.1")
        #expect(versions.stable == ["2.56.1", "2.56.0", "2.55.1", "2.10.0", "2.9.3"])
    }

    @Test("numeric ordering beats lexicographic (2.10 > 2.9)")
    func numericOrdering() throws {
        let versions = try PyPIClient.parse(Self.fixture)
        let ten = try #require(versions.stable.firstIndex(of: "2.10.0"))
        let nine = try #require(versions.stable.firstIndex(of: "2.9.3"))
        #expect(ten < nine)
    }

    @Test("garbage payload throws")
    func garbageThrows() {
        #expect(throws: (any Error).self) {
            _ = try PyPIClient.parse(Data("not json".utf8))
        }
    }
}

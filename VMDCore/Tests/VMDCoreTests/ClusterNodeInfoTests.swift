import Testing
@testable import VMDCore

@Suite("ClusterNodeInfo")
struct ClusterNodeInfoTests {
    @Test("TXT record round-trip preserves every field")
    func roundTrip() {
        let node = ClusterNodeInfo(
            id: "ABC-123",
            name: "Ricky's Mac Pro",
            chip: "Apple M2 Ultra",
            modelIdentifier: "Mac14,8",
            memoryBytes: 206_158_430_208,
            engineVersion: "0.3.0",
            appVersion: "0.1.0"
        )
        let decoded = ClusterNodeInfo(txtDictionary: node.txtDictionary)
        #expect(decoded == node)
    }

    @Test("TXT keys stay within Bonjour's 9-character guidance")
    func keyLengths() {
        let node = ClusterNodeInfo(
            id: "x", name: "n", chip: "c", modelIdentifier: "m",
            memoryBytes: 1, engineVersion: "1", appVersion: "1"
        )
        #expect(node.txtDictionary.keys.allSatisfy { $0.count <= 9 })
    }

    @Test("a record without an id is rejected; missing extras degrade gracefully")
    func partialRecords() {
        #expect(ClusterNodeInfo(txtDictionary: ["name": "Ghost"]) == nil)
        let sparse = ClusterNodeInfo(txtDictionary: ["id": "X"])
        #expect(sparse?.name == "")
        #expect(sparse?.memoryBytes == 0)
        #expect(sparse?.engineVersion == "")
    }
}

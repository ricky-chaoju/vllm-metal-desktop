import Foundation
import Testing
@testable import VMDCore

@Suite("AtomicJSONStore")
struct EngineStateTests {
    private func tempStateURL() -> URL {
        FileManager.default.temporaryDirectory
            .appending(path: "vmdtests-\(UUID().uuidString)", directoryHint: .isDirectory)
            .appending(path: "engine_state.json", directoryHint: .notDirectory)
    }

    @Test("returns nil before anything is saved")
    func loadMissing() throws {
        let store = AtomicJSONStore<EngineState>(url: tempStateURL())
        #expect(try store.load() == nil)
    }

    @Test("round-trips state and creates parent directories")
    func roundTrip() throws {
        let url = tempStateURL()
        let store = AtomicJSONStore<EngineState>(url: url)
        let state = EngineState(
            installedVersion: "0.3.0.dev20260620073347",
            installedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        try store.save(state)
        #expect(FileManager.default.fileExists(atPath: url.path))
        #expect(try store.load() == state)
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }

    @Test("overwrites prior content")
    func overwrite() throws {
        let store = AtomicJSONStore<EngineState>(url: tempStateURL())
        try store.save(EngineState(installedVersion: "0.3.0"))
        try store.save(EngineState(installedVersion: "0.4.0"))
        #expect(try store.load()?.installedVersion == "0.4.0")
        try? store.delete()
        #expect(try store.load() == nil)
    }
}

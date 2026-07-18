import Foundation
import Testing
@testable import VMDCore

@Suite("EnginePaths")
struct EnginePathsTests {
    let paths = EnginePaths(home: URL(filePath: "/Users/test"))

    @Test("venv uses the upstream default location")
    func venvLocation() {
        #expect(paths.venvRoot.path == "/Users/test/.venv-vllm-metal")
        #expect(paths.venvPython.path == "/Users/test/.venv-vllm-metal/bin/python")
        #expect(paths.venvBin.path == "/Users/test/.venv-vllm-metal/bin")
    }

    @Test("shares the engine's HuggingFace cache")
    func hfCache() {
        #expect(paths.huggingFaceCache.path == "/Users/test/.cache/huggingface/hub")
    }

    @Test("uv resolves to the Astral installer default")
    func uvLocation() {
        #expect(paths.localBin.path == "/Users/test/.local/bin")
        #expect(paths.uvBinary.path == "/Users/test/.local/bin/uv")
    }

    @Test("derives Application Support locations from the bundle id")
    func appSupport() {
        let bundleID = "com.infinirc.vllm-metal-desktop"
        #expect(paths.appSupport(bundleID: bundleID).path
            == "/Users/test/Library/Application Support/\(bundleID)")
        #expect(paths.engineStateFile(bundleID: bundleID).lastPathComponent == "engine_state.json")
        #expect(paths.logsDirectory(bundleID: bundleID).lastPathComponent == "logs")
    }
}

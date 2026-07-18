import Foundation
import Testing
@testable import VMDCore

@Suite("EngineInstaller")
struct EngineInstallerTests {
    let installer = EngineInstaller(paths: EnginePaths(home: URL(filePath: "/Users/test")))
    let wheel = URL(string: "https://example.com/vllm_metal-0.3.0-cp312-cp312-macosx_15_0_arm64.whl")!

    @Test("uv resolves to the upstream default ~/.local/bin")
    func uvLocation() {
        #expect(installer.paths.uvBinary.path == "/Users/test/.local/bin/uv")
    }

    @Test("fresh install includes uv bootstrap only when uv is missing")
    func freshSteps() {
        let withBootstrap = installer.buildSteps(mode: .fresh, uvExists: false, wheelURL: wheel)
        #expect(withBootstrap.map(\.id)
            == ["bootstrap-uv", "create-venv", "validate-python-arch", "install-vllm", "install-vllm-metal", "verify-engine"])

        let withoutBootstrap = installer.buildSteps(mode: .fresh, uvExists: true, wheelURL: wheel)
        #expect(withoutBootstrap.map(\.id)
            == ["create-venv", "validate-python-arch", "install-vllm", "install-vllm-metal", "verify-engine"])
    }

    @Test("update only installs the wheel and verifies (no recompile)")
    func updateSteps() {
        let steps = installer.buildSteps(mode: .update, uvExists: true, wheelURL: wheel)
        #expect(steps.map(\.id) == ["install-vllm-metal", "verify-engine"])
    }

    @Test("update re-bootstraps uv when it has gone missing")
    func updateStepsWithoutUV() {
        let steps = installer.buildSteps(mode: .update, uvExists: false, wheelURL: wheel)
        #expect(steps.map(\.id) == ["bootstrap-uv", "install-vllm-metal", "verify-engine"])
    }
}

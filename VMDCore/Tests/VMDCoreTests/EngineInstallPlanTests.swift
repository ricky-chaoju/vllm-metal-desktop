import Foundation
import Testing
@testable import VMDCore

@Suite("EngineInstallPlan")
struct EngineInstallPlanTests {
    let paths = EnginePaths(home: URL(filePath: "/Users/test"))
    let config = EngineInstallConfig()
    let uv = URL(filePath: "/Users/test/.local/bin/uv")
    let wheel = URL(string: "https://github.com/vllm-project/vllm-metal/releases/download/v0.3.0.dev20260620073347/vllm_metal-0.3.0.dev20260620073347-cp312-cp312-macosx_15_0_arm64.whl")!

    @Test("config derives the documented download URLs")
    func urls() {
        #expect(config.vllmVersion == "0.25.1")
        #expect(config.vllmTarballURL.absoluteString
            == "https://github.com/vllm-project/vllm/releases/download/v0.25.1/vllm-0.25.1.tar.gz")
        #expect(config.uvInstallerURL.absoluteString == "https://astral.sh/uv/0.9.18/install.sh")
    }

    @Test("produces ordered steps incl. the arm64 guard and a verify")
    func stepOrder() {
        let steps = EngineInstallPlan.steps(config: config, paths: paths, uv: uv, wheelURL: wheel)
        #expect(steps.map(\.id) == ["create-venv", "validate-python-arch", "install-vllm", "install-vllm-metal", "verify-engine"])
        #expect(steps.first { $0.id == "install-vllm" }?.isLongRunning == true)
    }

    @Test("verify step imports vllm_metal in the venv python")
    func verifyStep() {
        let step = EngineInstallPlan.verifyStep(paths: paths, environment: [:])
        #expect(step.id == "verify-engine")
        #expect(step.launch.executableURL == paths.venvPython)
        #expect((step.launch.arguments.last ?? "").contains("import vllm_metal"))
    }

    @Test("create-venv targets the managed venv with the pinned Python")
    func createVenv() {
        let step = EngineInstallPlan.steps(config: config, paths: paths, uv: uv, wheelURL: wheel)[0]
        #expect(step.launch.executableURL == uv)
        #expect(step.launch.arguments == ["venv", "/Users/test/.venv-vllm-metal", "--clear", "--python", "3.12", "--seed"])
    }

    @Test("arch guard runs the venv python and checks platform.machine")
    func archGuard() {
        let step = EngineInstallPlan.steps(config: config, paths: paths, uv: uv, wheelURL: wheel)[1]
        #expect(step.id == "validate-python-arch")
        #expect(step.launch.executableURL == paths.venvPython)
        let code = step.launch.arguments.last ?? ""
        #expect(code.contains("platform.machine()"))
        #expect(code.contains("arm64"))
    }

    @Test("vLLM step mirrors install.sh (tarball, cpu reqs, explicit dir, source compile)")
    func vllmStep() {
        let step = EngineInstallPlan.steps(config: config, paths: paths, uv: uv, wheelURL: wheel)[2]
        #expect(step.launch.executableURL.path == "/bin/sh")
        let script = step.launch.arguments.last ?? ""
        #expect(script.contains(config.vllmTarballURL.absoluteString))
        #expect(script.contains("requirements/cpu.txt"))
        #expect(script.contains("--index-strategy unsafe-best-match"))
        #expect(script.contains("CXXFLAGS=\"-Wno-parentheses\""))
        #expect(script.contains("pip install ."))
        // Explicit, deterministic extraction dir (no ambiguous glob).
        #expect(script.contains("cd \"$tmp/vllm-0.25.1/\""))
    }

    @Test("wheel step force-reinstalls the resolved wheel url")
    func wheelStep() {
        let step = EngineInstallPlan.steps(config: config, paths: paths, uv: uv, wheelURL: wheel)[3]
        #expect(step.launch.executableURL == uv)
        // --reinstall-package makes upgrade, downgrade, and same-version
        // reinstall all behave identically (uv skips "already satisfied" otherwise).
        #expect(step.launch.arguments
            == ["pip", "install", "--reinstall-package", "vllm-metal", wheel.absoluteString])
    }

    @Test("install environment targets the venv and puts uv on PATH")
    func environment() {
        let env = EngineInstallPlan.installEnvironment(paths: paths, uvDirectory: uv.deletingLastPathComponent())
        #expect(env["VIRTUAL_ENV"] == "/Users/test/.venv-vllm-metal")
        let path = env["PATH"] ?? ""
        #expect(path.hasPrefix("/Users/test/.local/bin:/Users/test/.venv-vllm-metal/bin:"))
    }

    @Test("uv bootstrap pins the version and installs into the given directory")
    func bootstrap() {
        let dir = URL(filePath: "/Users/test/.local/bin")
        let step = EngineInstallPlan.bootstrapUVStep(config: config, installDir: dir)
        #expect(step.id == "bootstrap-uv")
        #expect(step.launch.environment?["UV_INSTALL_DIR"] == dir.path)
        let script = step.launch.arguments.last ?? ""
        #expect(script.contains("https://astral.sh/uv/0.9.18/install.sh"))
    }
}

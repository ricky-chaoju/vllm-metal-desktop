import Foundation
import Testing
@testable import VMDCore

@Suite("EngineInstallPlan")
struct EngineInstallPlanTests {
    let paths = EnginePaths(home: URL(filePath: "/Users/test"))
    let config = EngineInstallConfig()
    /// Stands in for the pin resolved from the selected release's install.sh.
    let core = "0.27.1"
    let uv = URL(filePath: "/Users/test/.local/bin/uv")
    let wheel = URL(string: "https://github.com/vllm-project/vllm-metal/releases/download/v0.3.0.dev20260620073347/vllm_metal-0.3.0.dev20260620073347-cp312-cp312-macosx_15_0_arm64.whl")!

    @Test("config derives the documented download URLs")
    func urls() {
        // The "+cpu" local version is percent-encoded in the asset name.
        #expect(config.vllmWheelURL(coreVersion: core).absoluteString
            == "https://github.com/vllm-project/vllm/releases/download/v0.27.1/vllm-0.27.1%2Bcpu-cp312-cp312-macosx_11_0_arm64.whl")
        #expect(config.uvInstallerURL.absoluteString == "https://astral.sh/uv/0.9.18/install.sh")
    }

    /// The core version is an input, never a stored default — a stale pin
    /// would pair an old core with a wheel built against a newer one.
    @Test("the core wheel url follows the version it is handed")
    func coreVersionIsAnInput() {
        #expect(config.vllmWheelURL(coreVersion: "0.26.0").absoluteString
            == "https://github.com/vllm-project/vllm/releases/download/v0.26.0/vllm-0.26.0%2Bcpu-cp312-cp312-macosx_11_0_arm64.whl")
        let step = EngineInstallPlan.steps(
            config: config, vllmCoreVersion: "0.26.0", paths: paths, uv: uv, wheelURL: wheel
        )[2]
        #expect(step.title == "Install vLLM 0.26.0 (prebuilt wheel)")
        #expect((step.launch.arguments.last ?? "").contains("/v0.26.0/"))
    }

    @Test("produces ordered steps incl. the arm64 guard and a verify")
    func stepOrder() {
        let steps = EngineInstallPlan.steps(config: config, vllmCoreVersion: core, paths: paths, uv: uv, wheelURL: wheel)
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
        let step = EngineInstallPlan.steps(config: config, vllmCoreVersion: core, paths: paths, uv: uv, wheelURL: wheel)[0]
        #expect(step.launch.executableURL == uv)
        #expect(step.launch.arguments == ["venv", "/Users/test/.venv-vllm-metal", "--clear", "--python", "3.12", "--seed"])
    }

    @Test("arch guard runs the venv python and checks platform.machine")
    func archGuard() {
        let step = EngineInstallPlan.steps(config: config, vllmCoreVersion: core, paths: paths, uv: uv, wheelURL: wheel)[1]
        #expect(step.id == "validate-python-arch")
        #expect(step.launch.executableURL == paths.venvPython)
        let code = step.launch.arguments.last ?? ""
        #expect(code.contains("platform.machine()"))
        #expect(code.contains("arm64"))
    }

    @Test("vLLM step mirrors install.sh (prebuilt core wheel, no source compile)")
    func vllmStep() {
        let step = EngineInstallPlan.steps(config: config, vllmCoreVersion: core, paths: paths, uv: uv, wheelURL: wheel)[2]
        #expect(step.launch.executableURL == uv)
        #expect(step.launch.arguments
            == ["pip", "install", config.vllmWheelURL(coreVersion: core).absoluteString])
        #expect(step.isLongRunning)
    }

    @Test("wheel step force-reinstalls the resolved wheel url")
    func wheelStep() {
        let step = EngineInstallPlan.steps(config: config, vllmCoreVersion: core, paths: paths, uv: uv, wheelURL: wheel)[3]
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

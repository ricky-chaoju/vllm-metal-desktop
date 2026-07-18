import Foundation
import Observation
import VMDCore

/// App-level manager of running engines, shared via the SwiftUI environment.
///
/// vLLM runs one model per engine process, so multiple models means multiple
/// `ServeDeployment`s side by side (each with its own port and log). One
/// deployment is *active* — the one Chat talks to and the toolbar reflects;
/// the Server page manages all of them. Run state persists so orphaned engines
/// are re-adopted after an app restart (docs/PLAN.md §3).
@MainActor
@Observable
final class ServeController {
    private let paths = EnginePaths.standard
    private let bundleID = Bundle.main.bundleIdentifier ?? VMDLog.subsystem

    /// Small, fast, and thinking-capable — the one-click starter model
    /// (onboarding and the default deploy target share this).
    static let recommendedModel = "Qwen/Qwen3-0.6B"

    var modelInput = ServeController.recommendedModel
    var flags = ServeFlags()
    private(set) var deployments: [ServeDeployment] = []
    var activeID: UUID?

    /// The deployment Chat is pointed at (falls back to the first one).
    var active: ServeDeployment? {
        deployments.first { $0.id == activeID } ?? deployments.first
    }

    // MARK: Active-deployment conveniences (what most of the UI binds to)

    var status: ServeStatus { active?.status ?? .idle }
    var statusText: String { active?.statusText ?? "Not running" }
    var isRunning: Bool { active?.isRunning ?? false }
    var isStarting: Bool { active?.isStarting ?? false }
    var isStopping: Bool { active?.isStopping ?? false }
    var port: Int? { active.map(\.port) }
    var servedModelName: String? { active?.servedModelName }
    var adoptedPID: Int32? { active?.adoptedPID }
    var openAIClient: OpenAIClient? { active?.openAIClient }
    var logs: [LogLine] { active?.logs ?? [] }

    /// Deployments that answer requests right now.
    var runningDeployments: [ServeDeployment] {
        deployments.filter { $0.isRunning || $0.isStarting }
    }

    private var runStatesStore: AtomicJSONStore<[ServeRunState]> {
        AtomicJSONStore(url: paths.appSupport(bundleID: bundleID)
            .appending(path: "serve_states.json", directoryHint: .notDirectory))
    }

    /// Pre-multi-deployment single-state file, still read for recovery.
    private var legacyRunStateStore: AtomicJSONStore<ServeRunState> {
        AtomicJSONStore(url: paths.appSupport(bundleID: bundleID)
            .appending(path: "serve_state.json", directoryHint: .notDirectory))
    }

    private var flagsStore: AtomicJSONStore<ServeFlags> {
        AtomicJSONStore(url: paths.appSupport(bundleID: bundleID)
            .appending(path: "serve_flags.json", directoryHint: .notDirectory))
    }

    init() {
        if let loaded = try? flagsStore.load() { flags = loaded }
    }

    /// Persists edited serve flags.
    func applyFlags(_ newFlags: ServeFlags) {
        flags = newFlags
        try? flagsStore.save(newFlags)
    }

    var engineInstalled: Bool { FileManager.default.fileExists(atPath: paths.venvVLLM.path) }

    // MARK: Lifecycle

    /// Starts a deployment for `modelInput` (or just activates it if that model
    /// is already up). Other deployments keep running.
    func run() {
        let model = modelInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !model.isEmpty else { return }

        if let existing = deployments.first(where: { $0.model == model && ($0.isRunning || $0.isStarting) }) {
            activeID = existing.id
            return
        }
        guard let port = allocatePort() else { return }

        let deployment = ServeDeployment(model: model, port: port, bundleID: bundleID)
        deployment.onStateChange = { [weak self, weak deployment] in
            guard let self, let deployment else { return }
            self.reap(deployment)
            self.persistRunStates()
        }
        deployments.append(deployment)
        activeID = deployment.id
        deployment.start(flags: flags)
    }

    /// Stops the active deployment (the Server page can stop any).
    func stop() {
        if let active { stop(active) }
    }

    func stop(_ deployment: ServeDeployment) {
        deployment.stop()
    }

    /// The preferred port if free, else the next free rung on the ladder
    /// (8000, 8001, …) so multiple deployments get predictable addresses.
    private func allocatePort() -> Int? {
        let taken = Set(deployments.map(\.port))
        for candidate in flags.serverPort..<(flags.serverPort + 32) {
            if !taken.contains(candidate), PortFinder.isFree(candidate) {
                return candidate
            }
        }
        return PortFinder.findFree()
    }

    /// Drops deployments that reached a terminal state (keeps failures visible
    /// while they're active so the error can be read).
    private func reap(_ deployment: ServeDeployment) {
        switch deployment.status {
        case .stopped:
            deployments.removeAll { $0.id == deployment.id }
            if activeID == deployment.id { activeID = deployments.first?.id }
        default:
            break
        }
    }

    /// Removes a failed deployment after the user has seen the error.
    func dismiss(_ deployment: ServeDeployment) {
        deployments.removeAll { $0.id == deployment.id }
        if activeID == deployment.id { activeID = deployments.first?.id }
    }

    // MARK: Recovery

    /// On launch, re-adopt still-running serves persisted by a previous app run
    /// (including the pre-multi-deployment single-state file).
    func recover() async {
        guard deployments.isEmpty else { return }
        var states = (try? runStatesStore.load()) ?? []
        if states.isEmpty, let legacy = try? legacyRunStateStore.load() {
            states = [legacy]
        }
        guard !states.isEmpty else { return }

        for state in states {
            let deployment = ServeDeployment(model: state.model, port: state.port, bundleID: bundleID)
            deployment.onStateChange = { [weak self, weak deployment] in
                guard let self, let deployment else { return }
                self.reap(deployment)
                self.persistRunStates()
            }
            if await deployment.adopt(state: state) {
                deployments.append(deployment)
                if activeID == nil {
                    activeID = deployment.id
                    modelInput = state.model
                }
            }
        }
        try? legacyRunStateStore.delete()
        persistRunStates()
    }

    private func persistRunStates() {
        let states = deployments.compactMap { deployment -> ServeRunState? in
            guard deployment.isRunning, let pid = deployment.processID else { return nil }
            return ServeRunState(
                pid: pid,
                port: deployment.port,
                model: deployment.servedModelName ?? deployment.model,
                startedAt: Date()
            )
        }
        if states.isEmpty {
            try? runStatesStore.delete()
        } else {
            try? runStatesStore.save(states)
        }
    }
}

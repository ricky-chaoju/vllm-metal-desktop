import Foundation
import Observation
import VMDCore

/// Every deployment the user has set up — running or parked — with its own
/// configuration, so a stop never loses their setup.
private nonisolated struct PersistedDeployment: Codable, Sendable {
    var model: String
    var port: Int
    var flags: ServeFlags?
}

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

    private var deploymentsStore: AtomicJSONStore<[PersistedDeployment]> {
        AtomicJSONStore(url: paths.appSupport(bundleID: bundleID)
            .appending(path: "deployments.json", directoryHint: .notDirectory))
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

    /// Starts a deployment for `modelInput`: activates it if already up,
    /// restarts a parked deployment of that model (keeping its saved
    /// configuration), or creates a new one. Other deployments keep running.
    func run() {
        let model = modelInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !model.isEmpty else { return }

        if let existing = deployments.first(where: { $0.model == model && ($0.isRunning || $0.isStarting) }) {
            activeID = existing.id
            return
        }
        if let parked = deployments.first(where: { $0.model == model && $0.isRestartable }) {
            // A fresh deploy request supersedes the parked configuration —
            // the Deploy sheet just applied the flags the user asked for.
            activeID = parked.id
            parked.start(flags: flags)
            persistDeployments()
            return
        }
        guard let port = allocatePort() else { return }

        let deployment = ServeDeployment(model: model, port: port, bundleID: bundleID)
        wire(deployment)
        deployments.append(deployment)
        activeID = deployment.id
        deployment.start(flags: flags)
        persistDeployments()
    }

    /// Starts (or restarts) a specific deployment with its own saved
    /// configuration, falling back to the global defaults.
    func start(_ deployment: ServeDeployment) {
        deployment.start(flags: deployment.flags ?? flags)
        persistDeployments()
    }

    /// Stops the active deployment (the Server page can stop any). The
    /// deployment stays in the list with its configuration — delete it
    /// explicitly to make it go away.
    func stop() {
        if let active { stop(active) }
    }

    func stop(_ deployment: ServeDeployment) {
        deployment.stop()
    }

    /// Deletes a deployment outright (stopping its engine first if needed).
    func remove(_ deployment: ServeDeployment) {
        if deployment.isRunning || deployment.isStarting {
            deployment.stop()
        }
        deployments.removeAll { $0.id == deployment.id }
        if activeID == deployment.id { activeID = deployments.first?.id }
        persistDeployments()
    }

    /// Saves an edited per-deployment configuration. When the deployment is
    /// running, redeploys: stop, wait for the engine to exit, start with the
    /// new flags — the "Redeploy" the config sheet promises.
    func update(_ deployment: ServeDeployment, flags newFlags: ServeFlags) {
        let wasRunning = deployment.isRunning || deployment.isStarting
        if wasRunning {
            // "Done" with nothing changed shouldn't bounce a healthy engine.
            guard newFlags != deployment.flags else { return }
            deployment.stop()
            Task {
                // The engine needs a beat to release the port; poll briefly.
                for _ in 0..<75 where !deployment.isRestartable {
                    try? await Task.sleep(for: .milliseconds(200))
                }
                // The user may have deleted the deployment while we waited —
                // starting it anyway would leak an engine the UI can't manage.
                guard deployments.contains(where: { $0.id == deployment.id }) else { return }
                deployment.start(flags: newFlags)
                persistDeployments()
            }
        } else {
            deployment.restore(flags: newFlags)
            persistDeployments()
        }
    }

    private func wire(_ deployment: ServeDeployment) {
        deployment.onStateChange = { [weak self] in
            self?.persistRunStates()
        }
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

    // MARK: Recovery

    /// On launch, restore the deployment list: still-running engines are
    /// re-adopted (PID + port + API verified), everything else comes back
    /// parked with its saved configuration. Legacy single/run-state files are
    /// folded in for upgrades.
    func recover() async {
        guard deployments.isEmpty else { return }

        var states = (try? runStatesStore.load()) ?? []
        if states.isEmpty, let legacy = try? legacyRunStateStore.load() {
            states = [legacy]
        }
        let persisted = (try? deploymentsStore.load()) ?? []

        for entry in persisted {
            let deployment = ServeDeployment(model: entry.model, port: entry.port, bundleID: bundleID)
            wire(deployment)
            if let state = states.first(where: { $0.port == entry.port }),
               await deployment.adopt(state: state) {
                states.removeAll { $0.port == entry.port }
                deployment.adoptFlags(entry.flags)
            } else {
                deployment.restore(flags: entry.flags)
            }
            deployments.append(deployment)
        }

        // Run states with no persisted entry (pre-persistence versions).
        for state in states {
            let deployment = ServeDeployment(model: state.model, port: state.port, bundleID: bundleID)
            wire(deployment)
            if await deployment.adopt(state: state) {
                deployments.append(deployment)
            }
        }

        activeID = (deployments.first { $0.isRunning } ?? deployments.first)?.id
        if let active { modelInput = active.servedModelName ?? active.model }
        try? legacyRunStateStore.delete()
        persistRunStates()
        persistDeployments()
    }

    private func persistDeployments() {
        let entries = deployments.map {
            PersistedDeployment(model: $0.model, port: $0.port, flags: $0.flags)
        }
        if entries.isEmpty {
            try? deploymentsStore.delete()
        } else {
            try? deploymentsStore.save(entries)
        }
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

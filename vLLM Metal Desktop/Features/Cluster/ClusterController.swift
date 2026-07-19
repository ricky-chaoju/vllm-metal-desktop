import Foundation
import Network
import Observation
import VMDCore
import dnssd

// MARK: - Wire payloads (nonisolated: they cross into the control server)

private nonisolated struct PairRequestPayload: Codable, Sendable {
    var id: String
    var name: String
    var token: String
}

private nonisolated struct PairResponsePayload: Codable, Sendable {
    var id: String
    var name: String
}

nonisolated struct NodeStatusPayload: Codable, Sendable {
    var info: ClusterNodeInfo
    var bridgeIP: String?
    var rayAvailable: Bool
    var role: String
    /// Whether the answering Mac still honors the caller's token — how an
    /// unpair on one side reaches the other even when the push notification
    /// was missed (offline, stale address, older build). Optional so older
    /// builds' responses still decode.
    var paired: Bool?
}

private nonisolated struct JoinRequestPayload: Codable, Sendable {
    var headAddress: String
}

private nonisolated struct EnsureModelPayload: Codable, Sendable {
    var model: String
}

private nonisolated struct StatePayload: Codable, Sendable {
    var state: String
}

private nonisolated struct LogsRequestPayload: Codable, Sendable {
    var port: Int
    /// Only lines with id > after are returned — incremental tailing.
    var after: Int
}

nonisolated struct LogLinePayload: Codable, Sendable {
    var id: Int
    var text: String
}

private nonisolated struct PersistedClusterState: Codable, Sendable {
    var role: String
    var headIP: String
    var peerID: String?
}

nonisolated struct ManualNode: Codable, Sendable, Equatable, Identifiable {
    var address: String
    var port: Int
    var id: String { "\(address):\(port)" }
}

nonisolated struct PairedPeer: Codable, Sendable, Equatable, Identifiable {
    var id: String
    var name: String
    var token: String
}

/// The cluster brain: advertises this app over Bonjour (the control server's
/// listener carries the service), browses for peers, pairs with user consent,
/// forms/dissolves the Ray control plane, and deploys models across it.
///
/// Trust model: discovery is open (mDNS is), but every privileged operation
/// (join/leave/model transfer) requires the shared token minted at pairing —
/// and pairing itself requires a human click on the other Mac.
@MainActor
@Observable
final class ClusterController {
    static let serviceType = "_vllm-metal._tcp"

    struct DiscoveredNode: Identifiable, Equatable, Sendable {
        var info: ClusterNodeInfo
        /// Manually-added nodes (by IP) persist and are never auto-pruned.
        var isManual: Bool = false
        /// Row identity — id + endpoint, so a ghost and its relaunched
        /// successor never collide in the list.
        var id: String { "\(info.id)|\(info.address):\(info.controlPort)" }
        /// Pairing identity (stable across launches).
        var stableID: String { info.id }
    }

    enum Role: String, Equatable {
        case none, head, worker
    }

    struct PendingPairRequest: Identifiable {
        let id = UUID()
        let peerID: String
        let peerName: String
        let respond: (Bool) -> Void
    }

    // MARK: Observable state

    private(set) var localInfo: ClusterNodeInfo
    private(set) var nodes: [DiscoveredNode] = []
    private(set) var localNetworkDenied = false
    private(set) var pairedPeers: [PairedPeer] = []
    /// An incoming pair request awaiting the user's approval on THIS Mac.
    var pendingPairRequest: PendingPairRequest?
    private(set) var role: Role = .none
    private(set) var clusterStatus: RayClusterStatus?
    /// The head's serve/cluster IP while a cluster is up (either role).
    private(set) var headIP: String?
    /// Human-readable current operation, or nil when idle.
    private(set) var busy: String?
    private(set) var lastError: String?
    /// Ray is a distributed-only venv dependency — false until installed.
    private(set) var rayAvailable = false
    /// Installed Ray version ("2.44.0"), nil when absent.
    private(set) var rayVersion: String?
    /// Live pip output while Ray installs/updates.
    private(set) var installLogs: [LogLine] = []
    /// PyPI's latest stable Ray, and recent versions for pinning.
    private(set) var latestRayVersion: String?
    private(set) var availableRayVersions: [String] = []

    /// True when PyPI has a newer stable Ray than the venv.
    var rayUpdateAvailable: Bool {
        guard let rayVersion, let latestRayVersion else { return false }
        return EngineVersion.isUpgrade(from: EngineVersion(rayVersion), to: EngineVersion(latestRayVersion))
    }

    /// What the cluster serves, as one shared list: the head reads its own
    /// deployments, workers poll the head over the control channel — so every
    /// member's Cluster page shows the same thing.
    private(set) var clusterDeployments: [ClusterDeploymentSummary] = []
    /// Supplies the head's cluster-mode deployments to the control channel and
    /// status polling. Wired by the app: the serve controller owns the
    /// processes, this controller only reports them.
    var deploymentsProvider: (() -> [ClusterDeploymentSummary])?
    /// Supplies a deployment's log tail (port, afterID) for the control
    /// channel — how the worker's Cluster page shows the head's engine log.
    var logsProvider: ((Int, Int) -> [LogLinePayload])?
    /// Mirrored log lines of the head's deployments (worker side), by port.
    private(set) var remoteLogs: [Int: [LogLine]] = [:]
    /// The cluster deployment Chat is pointed at (worker side; nil = the
    /// local serve deployment). Lives here so the Cluster page's "Chat"
    /// button and the Chat page share one selection.
    var chatTarget: ClusterDeploymentSummary?
    private var logStreamTask: Task<Void, Never>?

    /// Whether this Mac advertises itself over Bonjour (paired peers can
    /// still reach us directly — this only hides us from discovery).
    private(set) var discoverable = true
    /// Manually-added peers (by IP) — the escape hatch for networks without
    /// multicast (different subnets, VPNs, cloud VPCs).
    private(set) var manualNodes: [ManualNode] = []

    /// The user's preferred network interface name (nil = automatic:
    /// Thunderbolt bridge first, then Ethernet/Wi-Fi).
    private(set) var preferredInterface: String?
    /// This Mac's viable interfaces (for the picker).
    private(set) var localInterfaces: [NetworkAddress.Interface] = []

    /// The peer that's in the cluster with us (either direction).
    private(set) var clusterPeerID: String?
    /// Remote model lists, fetched when a node row expands.
    private(set) var remoteModels: [String: [String]] = [:]

    private var server: ControlServer?
    private var browser: NWBrowser?
    private var statusTask: Task<Void, Never>?
    private var pruneTask: Task<Void, Never>?
    private var nodeStrikes: [String: Int] = [:]
    /// Which of a peer's advertised addresses answered last (stableID → host).
    private var workingHosts: [String: String] = [:]
    private var ensuringModels: Set<String> = []
    private let ray = RayCluster()
    private let paths = EnginePaths.standard

    private var peersStore: AtomicJSONStore<[PairedPeer]> {
        AtomicJSONStore(url: paths.appSupport(bundleID: Bundle.main.bundleIdentifier ?? "vmd")
            .appending(path: "cluster_peers.json", directoryHint: .notDirectory))
    }

    private var stateStore: AtomicJSONStore<PersistedClusterState> {
        AtomicJSONStore(url: paths.appSupport(bundleID: Bundle.main.bundleIdentifier ?? "vmd")
            .appending(path: "cluster_state.json", directoryHint: .notDirectory))
    }

    private var manualNodesStore: AtomicJSONStore<[ManualNode]> {
        AtomicJSONStore(url: paths.appSupport(bundleID: Bundle.main.bundleIdentifier ?? "vmd")
            .appending(path: "cluster_manual_nodes.json", directoryHint: .notDirectory))
    }

    init() {
        // Stable across launches so pairings survive restarts.
        let stableID: String
        if let existing = UserDefaults.standard.string(forKey: "VMDClusterNodeID") {
            stableID = existing
        } else {
            stableID = UUID().uuidString
            UserDefaults.standard.set(stableID, forKey: "VMDClusterNodeID")
        }
        let preferred = UserDefaults.standard.string(forKey: "VMDClusterInterface")
        preferredInterface = preferred
        let hardware = HardwareInfo.current()
        let interfaces = NetworkAddress.allIPv4(preferring: preferred)
        localInterfaces = interfaces
        localInfo = ClusterNodeInfo(
            id: stableID,
            name: Host.current().localizedName ?? "This Mac",
            chip: hardware.chip,
            modelIdentifier: hardware.modelIdentifier,
            memoryBytes: hardware.unifiedMemoryBytes,
            engineVersion: "",
            appVersion: Bundle.main.appShortVersion,
            address: interfaces.first?.address ?? "",
            addresses: interfaces.map(\.address),
            launchNonce: UUID().uuidString
        )
        pairedPeers = (try? peersStore.load()) ?? []
        manualNodes = (try? manualNodesStore.load()) ?? []
        if UserDefaults.standard.object(forKey: "VMDClusterDiscoverable") != nil {
            discoverable = UserDefaults.standard.bool(forKey: "VMDClusterDiscoverable")
        }
    }

    // MARK: Lifecycle

    func start() {
        guard server == nil else { return }
        rayAvailable = ray.isAvailable
        startControlServer()
        startBrowser()
        startPruning()
        Task { await resolveEngineVersion() }
        Task {
            await resolveRayVersion()
            await refreshRayCatalog()
        }
        Task { await restoreClusterState() }
        Task { await refreshManualNodes() }
    }

    /// The Ray cluster outlives page switches and app restarts — restore the
    /// remembered role, but only if a local Ray node actually still runs.
    private func restoreClusterState() async {
        guard role == .none, let saved = try? stateStore.load() else { return }
        if await ray.status() != nil {
            role = Role(rawValue: saved.role) ?? .none
            headIP = saved.headIP
            clusterPeerID = saved.peerID
            if role != .none { startStatusPolling() }
        } else {
            try? stateStore.delete()
        }
    }

    private func persistClusterState() {
        if role == .none {
            try? stateStore.delete()
        } else if let headIP {
            try? stateStore.save(PersistedClusterState(
                role: role.rawValue, headIP: headIP, peerID: clusterPeerID
            ))
        }
    }

    /// mDNS records linger after a crash/kill (no goodbye packet, TTLs run to
    /// minutes) — actively health-check discovered nodes and drop ghosts after
    /// two misses. Strikes are keyed on id+port so a node that really comes
    /// back (it re-advertises on a fresh port) is never blocked, while the
    /// browser re-applying the stale cache can't resurrect a pruned ghost.
    private func startPruning() {
        pruneTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(10))
                guard let self else { return }
                self.refreshLocalAddresses()
                self.reprobeStruckRecords()
                await self.refreshManualNodes()
                for node in self.nodes where !node.isManual {
                    let key = Self.strikeKey(node.info)
                    let sentToken = self.token(for: node)
                    let answer = try? await self.call(
                        node, method: "GET", path: "/node", token: sentToken, timeout: 3
                    )
                    let reachable = answer?.status == 200
                    if reachable {
                        self.nodeStrikes[key] = 0
                        if sentToken != nil {
                            self.reconcilePairing(peerID: node.stableID, from: answer?.body)
                        }
                    } else {
                        let strikes = (self.nodeStrikes[key] ?? 0) + 1
                        self.nodeStrikes[key] = strikes
                        if strikes >= 2 {
                            self.nodes.removeAll { Self.strikeKey($0.info) == key }
                        }
                    }
                }
            }
        }
    }

    /// A peer we authenticated to answered whether it still honors our token.
    /// An explicit "no" means it unpaired us (perhaps while we were away) —
    /// drop our side too so both UIs agree. Only called when a token was
    /// actually sent: absent/nil never removes anything.
    private func reconcilePairing(peerID: String, from body: Data?) {
        guard let body,
              let payload = try? JSONDecoder().decode(NodeStatusPayload.self, from: body),
              // The answer must come from the Mac we think we're paired
              // with — a stranger squatting on a stale IP saying "I don't
              // know you" must not tear down a valid pairing.
              payload.info.id == peerID,
              payload.paired == false,
              pairedPeers.contains(where: { $0.id == peerID }) else { return }
        pairedPeers.removeAll { $0.id == peerID }
        try? peersStore.save(pairedPeers)
    }

    /// Shows/hides this Mac in other Macs' discovery (the control server
    /// stays up either way, so paired peers keep working).
    func setDiscoverable(_ visible: Bool) {
        discoverable = visible
        UserDefaults.standard.set(visible, forKey: "VMDClusterDiscoverable")
        server?.updateService(visible ? makeService() : nil)
    }

    /// Switches the advertised/preferred interface and re-advertises.
    func setPreferredInterface(_ name: String?) {
        preferredInterface = name
        if let name {
            UserDefaults.standard.set(name, forKey: "VMDClusterInterface")
        } else {
            UserDefaults.standard.removeObject(forKey: "VMDClusterInterface")
        }
        refreshLocalAddresses()
    }

    /// Recomputes the interface list (cables come and go) and re-advertises.
    private func refreshLocalAddresses() {
        let interfaces = NetworkAddress.allIPv4(preferring: preferredInterface)
        // Re-advertising is not free (every record change ripples through
        // the LAN's mDNS caches) — only do it when something changed.
        guard interfaces != localInterfaces else { return }
        localInterfaces = interfaces
        localInfo.address = interfaces.first?.address ?? ""
        localInfo.addresses = interfaces.map(\.address)
        server?.updateService(discoverable ? makeService() : nil)
    }

    /// One call to a peer, tried across every address it advertises (the
    /// last-working one first). Any HTTP answer marks the host reachable.
    private func call(
        _ node: DiscoveredNode,
        method: String,
        path: String,
        token: String? = nil,
        body: Data? = nil,
        timeout: TimeInterval = 10
    ) async throws -> (status: Int, body: Data) {
        var hosts = node.info.addresses
        if let known = workingHosts[node.stableID], let index = hosts.firstIndex(of: known) {
            hosts.remove(at: index)
            hosts.insert(known, at: 0)
        }
        if hosts.isEmpty { hosts = [node.info.address] }
        var lastError: Error = URLError(.cannotConnectToHost)
        for host in hosts where !host.isEmpty {
            do {
                let result = try await ControlClient.request(
                    host: host, port: node.info.controlPort,
                    method: method, path: path, token: token, body: body, timeout: timeout
                )
                workingHosts[node.stableID] = host
                return result
            } catch {
                lastError = error
            }
        }
        throw lastError
    }

    private static func strikeKey(_ info: ClusterNodeInfo) -> String {
        "\(info.id)|\(info.address):\(info.controlPort)"
    }

    /// Resolves the installed Ray version and folds it into the advertisement
    /// (peers preflight version equality before forming a cluster).
    private func resolveRayVersion() async {
        rayVersion = await ray.version()
        localInfo.rayVersion = rayVersion ?? ""
        server?.updateService(discoverable ? makeService() : nil)
    }

    /// Fetches Ray's version catalog from PyPI (drives "Update to X" and the
    /// version picker). Network-optional: failure just hides the affordances.
    private func refreshRayCatalog() async {
        guard let catalog = try? await PyPIClient().versions(package: "ray") else { return }
        latestRayVersion = catalog.latest
        availableRayVersions = Array(catalog.stable.prefix(10))
    }

    /// Ray install/update/pin in the engine venv, with pip's output streamed
    /// into `installLogs` so the UI shows the work, not a spinner.
    func installRay(version: String? = nil) async {
        busy = version.map { "Installing Ray \($0)…" } ?? (rayAvailable ? "Updating Ray…" : "Installing Ray…")
        installLogs = []
        defer { busy = nil }
        lastError = nil
        do {
            var exitCode: Int32 = 0
            for await event in try ray.installRayEvents(version: version) {
                switch event {
                case .stdout(let line), .stderr(let line):
                    installLogs.append(LogLine(id: installLogs.count, text: line))
                case .exit(let code):
                    exitCode = code
                }
            }
            if exitCode != 0 {
                lastError = "Ray install failed (exit \(exitCode)) — see the log below."
            }
            rayAvailable = ray.isAvailable
            await resolveRayVersion()
        } catch {
            lastError = "Ray install failed: \(error.localizedDescription)"
        }
    }

    private func startControlServer() {
        guard let server = try? ControlServer(service: discoverable ? makeService() : nil, handler: { [weak self] request in
            guard let self else { return .error(500) }
            return await self.handle(request)
        }) else {
            lastError = "Couldn't start the cluster control server — pairing and clustering are unavailable."
            return
        }
        server.start()
        self.server = server
        // The port binds async — advertise it once known.
        Task { @MainActor [weak self] in
            for _ in 0..<100 {
                if let port = server.port, port > 0 {
                    self?.localInfo.controlPort = Int(port)
                    server.updateService(self?.discoverable == true ? self?.makeService() : nil)
                    return
                }
                guard (try? await Task.sleep(for: .milliseconds(50))) != nil else { return }
            }
            self?.lastError = "The control server never obtained a port — other Macs can't reach this one."
        }
    }

    private func makeService() -> NWListener.Service {
        NWListener.Service(
            name: nil, // computer name; Bonjour auto-renames on conflict
            type: Self.serviceType,
            domain: nil,
            txtRecord: NWTXTRecord(localInfo.txtDictionary)
        )
    }

    private func resolveEngineVersion() async {
        guard let version = await InstalledEngine().installedVersion() else { return }
        localInfo.engineVersion = version.description
        server?.updateService(discoverable ? makeService() : nil)
    }

    /// The latest raw browse results — kept so a struck record that turns
    /// out to be alive again can be re-applied without waiting for mDNS to
    /// emit a change event (cached records often never do).
    private var lastBrowseResults: Set<NWBrowser.Result> = []
    /// Strike keys currently being re-verified, so each gets one probe at a
    /// time.
    private var reprobing: Set<String> = []

    /// A struck record still being advertised might be a live node that had
    /// a bad moment (sleep, Wi-Fi drop) — without this, two missed health
    /// checks would hide a Mac until one of the apps relaunched. One probe
    /// per pruner tick; success clears the strikes and re-lists it.
    private func reprobeStruckRecords() {
        for result in lastBrowseResults {
            guard case .bonjour(let txt) = result.metadata,
                  let info = ClusterNodeInfo(txtDictionary: txt.dictionary),
                  info.id != localInfo.id,
                  info.launchNonce != localInfo.launchNonce,
                  (nodeStrikes[Self.strikeKey(info)] ?? 0) >= 2 else { continue }
            let key = Self.strikeKey(info)
            guard !reprobing.contains(key) else { continue }
            reprobing.insert(key)
            Task { @MainActor [weak self] in
                defer { self?.reprobing.remove(key) }
                guard let self,
                      (try? await self.call(
                        DiscoveredNode(info: info), method: "GET", path: "/node", timeout: 3
                      )) != nil else { return }
                self.nodeStrikes[key] = 0
                self.apply(self.lastBrowseResults)
            }
        }
    }

    private func startBrowser() {
        let browser = NWBrowser(
            for: .bonjourWithTXTRecord(type: Self.serviceType, domain: nil),
            using: NWParameters()
        )
        browser.stateUpdateHandler = { [weak self] state in
            MainActor.assumeIsolated {
                guard let self else { return }
                switch state {
                case .waiting(let error):
                    if case .dns(let code) = error,
                       code == DNSServiceErrorType(kDNSServiceErr_PolicyDenied) {
                        self.localNetworkDenied = true
                    }
                case .ready:
                    self.localNetworkDenied = false
                default:
                    break
                }
            }
        }
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            MainActor.assumeIsolated {
                self?.apply(results)
            }
        }
        browser.start(queue: .main)
        self.browser = browser
    }

    private func apply(_ results: Set<NWBrowser.Result>) {
        lastBrowseResults = results
        var found: [DiscoveredNode] = []
        for result in results {
            guard case .bonjour(let txt) = result.metadata,
                  let info = ClusterNodeInfo(txtDictionary: txt.dictionary),
                  // Never show this Mac to itself: filter both the stable
                  // install id (any instance on this machine) and the launch
                  // nonce. Dev testing on one Mac passes distinct
                  // `-VMDClusterNodeID` launch args to lift the veil.
                  info.id != localInfo.id,
                  info.launchNonce != localInfo.launchNonce,
                  // Don't resurrect pruned ghosts from the stale mDNS cache.
                  (nodeStrikes[Self.strikeKey(info)] ?? 0) < 2 else { continue }
            found.append(DiscoveredNode(info: info))
        }
        // One row per Mac: a machine advertises once, so multiple records
        // with the same stable id are a live instance plus stale ghosts —
        // keep the healthiest-looking one and let the pruner reap the rest.
        // Sorted first so score ties break deterministically, not by Set
        // iteration order.
        found.sort { $0.id < $1.id }
        var byStableID: [String: DiscoveredNode] = [:]
        for candidate in found {
            if let existing = byStableID[candidate.stableID],
               healthScore(existing) >= healthScore(candidate) {
                continue
            }
            byStableID[candidate.stableID] = candidate
        }
        let manual = nodes.filter(\.isManual)
        let manualIDs = Set(manual.map(\.stableID))
        nodes = (manual + byStableID.values.filter { !manualIDs.contains($0.stableID) }).sorted {
            $0.info.name.localizedCaseInsensitiveCompare($1.info.name) == .orderedAscending
        }
    }

    private func healthScore(_ node: DiscoveredNode) -> Int {
        var score = 0
        if node.info.controlPort > 0 { score += 2 }
        if (nodeStrikes[Self.strikeKey(node.info)] ?? 0) == 0 { score += 1 }
        return score
    }

    // MARK: Control API (server side)

    /// Control-channel trust model: `GET /node` and `GET /models` answer any
    /// LAN host — discovery UX needs them before pairing exists, and they
    /// expose only what the Bonjour TXT record already broadcasts plus the
    /// downloaded-model list. Everything that *does* something requires the
    /// pairing token. The Discoverable toggle hides the advertisement only;
    /// the listener stays up so paired peers keep working.
    private func handle(_ request: ControlRequest) async -> ControlResponse {
        switch (request.method, request.path) {
        case ("GET", "/node"):
            return .json(NodeStatusPayload(
                info: localInfo,
                bridgeIP: NetworkAddress.thunderboltBridgeIPv4(),
                rayAvailable: ray.isAvailable,
                role: role.rawValue,
                paired: isAuthorized(request)
            ))

        case ("POST", "/pair"):
            return await handlePair(request)

        case ("POST", "/pair/remove"):
            // The token identifies the requester — drop exactly that pairing.
            guard let token = request.headers["x-vmd-token"],
                  pairedPeers.contains(where: { $0.token == token }) else { return .error(401) }
            pairedPeers.removeAll { $0.token == token }
            try? peersStore.save(pairedPeers)
            return .json(StatePayload(state: "unpaired"))

        case ("POST", "/cluster/join"):
            guard isAuthorized(request) else { return .error(401) }
            return await handleJoin(request)

        case ("POST", "/cluster/leave"):
            guard isAuthorized(request) else { return .error(401) }
            try? await ray.stopNode()
            role = .none
            headIP = nil
            clusterStatus = nil
            clusterPeerID = nil
            clusterDeployments = []
            remoteLogs = [:]
            chatTarget = nil
            stopLogStream()
            statusTask?.cancel()
            persistClusterState()
            return .json(StatePayload(state: "left"))

        case ("GET", "/deployments"):
            guard isAuthorized(request) else { return .error(401) }
            return .json(deploymentsProvider?() ?? [])

        case ("POST", "/deployments/logs"):
            guard isAuthorized(request) else { return .error(401) }
            guard let payload = try? JSONDecoder().decode(LogsRequestPayload.self, from: request.body) else {
                return .error(400)
            }
            return .json(logsProvider?(payload.port, payload.after) ?? [])

        case ("GET", "/models"):
            return .json(LocalModels().cachedModelIDs())

        case ("POST", "/models/ensure"):
            guard isAuthorized(request) else { return .error(401) }
            guard let payload = try? JSONDecoder().decode(EnsureModelPayload.self, from: request.body) else {
                return .error(400)
            }
            return ensureModel(payload.model)

        default:
            return .error(404)
        }
    }

    private func isAuthorized(_ request: ControlRequest) -> Bool {
        guard let token = request.headers["x-vmd-token"] else { return false }
        return pairedPeers.contains { $0.token == token }
    }

    private func handlePair(_ request: ControlRequest) async -> ControlResponse {
        guard let payload = try? JSONDecoder().decode(PairRequestPayload.self, from: request.body) else {
            return .error(400)
        }
        // Refreshing an existing pairing's token requires the *current*
        // token — the stable id is public (it rides the TXT record), so an
        // id match alone must never hand out a new credential. Anyone else
        // goes through human approval like a first-time pair.
        if let existing = pairedPeers.first(where: { $0.id == payload.id }),
           request.headers["x-vmd-token"] == existing.token {
            savePeer(PairedPeer(id: payload.id, name: payload.name, token: payload.token))
            return .json(PairResponsePayload(id: localInfo.id, name: localInfo.name))
        }

        // One approval dialog at a time — a second concurrent request would
        // orphan the first one's continuation (and confuse the human).
        guard pendingPairRequest == nil else { return .error(429) }
        let approved = await requestApproval(peerID: payload.id, peerName: payload.name)
        guard approved else { return .error(403) }
        savePeer(PairedPeer(id: payload.id, name: payload.name, token: payload.token))
        return .json(PairResponsePayload(id: localInfo.id, name: localInfo.name))
    }

    /// Surfaces the request to the UI and waits (max 60 s) for a decision.
    private func requestApproval(peerID: String, peerName: String) async -> Bool {
        final class Once: @unchecked Sendable {
            var done = false
        }
        let once = Once()
        return await withCheckedContinuation { continuation in
            let request = PendingPairRequest(peerID: peerID, peerName: peerName) { approved in
                guard !once.done else { return }
                once.done = true
                continuation.resume(returning: approved)
            }
            pendingPairRequest = request
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(60))
                if self?.pendingPairRequest?.id == request.id {
                    self?.pendingPairRequest = nil
                    request.respond(false)
                }
            }
        }
    }

    private func savePeer(_ peer: PairedPeer) {
        pairedPeers.removeAll { $0.id == peer.id }
        pairedPeers.append(peer)
        try? peersStore.save(pairedPeers)
    }

    private func ensureModel(_ model: String) -> ControlResponse {
        if LocalModels().cachedModelIDs().contains(model) {
            return .json(StatePayload(state: "present"))
        }
        if !ensuringModels.contains(model) {
            ensuringModels.insert(model)
            Task { @MainActor [weak self] in
                // Drain the stream; completion shows up in GET /models.
                for await _ in ModelDownloader().download(modelID: model) {}
                self?.ensuringModels.remove(model)
            }
        }
        return .json(StatePayload(state: "downloading"))
    }

    /// Adds a peer by IP — for networks where mDNS can't cross (different
    /// subnets, VPNs, cloud VPCs). Verified reachable before it's kept.
    func addManualNode(address: String, port: Int) async -> Bool {
        busy = "Contacting \(address)…"
        defer { busy = nil }
        lastError = nil
        guard let (status, body) = try? await ControlClient.request(
            host: address, port: port, method: "GET", path: "/node", timeout: 5
        ), status == 200,
        let payload = try? JSONDecoder().decode(NodeStatusPayload.self, from: body) else {
            lastError = "No vLLM Metal Desktop responded at \(address):\(port)."
            return false
        }
        guard payload.info.id != localInfo.id else {
            lastError = "\(address) is this Mac."
            return false
        }
        let entry = ManualNode(address: address, port: port)
        manualNodes.removeAll { $0.id == entry.id }
        manualNodes.append(entry)
        try? manualNodesStore.save(manualNodes)
        insertManual(payload.info, entry: entry)
        return true
    }

    func removeManualNode(_ node: DiscoveredNode) {
        manualNodes.removeAll { $0.address == node.info.address || node.info.addresses.contains($0.address) }
        try? manualNodesStore.save(manualNodes)
        nodes.removeAll { $0.id == node.id }
    }

    /// Re-resolves manual entries (start + every prune tick): reachable ones
    /// appear/update, unreachable ones stay listed via their last-known info.
    private func refreshManualNodes() async {
        for entry in manualNodes {
            let knownID = nodes.first {
                $0.isManual && $0.info.address == entry.address && $0.info.controlPort == entry.port
            }?.stableID
            let sentToken = knownID.flatMap { id in pairedPeers.first { $0.id == id }?.token }
            guard let (status, body) = try? await ControlClient.request(
                host: entry.address, port: entry.port, method: "GET", path: "/node",
                token: sentToken, timeout: 3
            ), status == 200,
            let payload = try? JSONDecoder().decode(NodeStatusPayload.self, from: body),
            payload.info.id != localInfo.id else { continue }
            if sentToken != nil {
                reconcilePairing(peerID: payload.info.id, from: body)
            }
            insertManual(payload.info, entry: entry)
        }
    }

    private func insertManual(_ info: ClusterNodeInfo, entry: ManualNode) {
        var adjusted = info
        // The address the user typed is the one that provably works from
        // here — it leads, whatever the peer thinks its own addresses are.
        adjusted.address = entry.address
        adjusted.addresses = [entry.address] + adjusted.addresses.filter { $0 != entry.address }
        adjusted.controlPort = entry.port
        nodes.removeAll { $0.stableID == adjusted.id }
        nodes.append(DiscoveredNode(info: adjusted, isManual: true))
        nodes.sort { $0.info.name.localizedCaseInsensitiveCompare($1.info.name) == .orderedAscending }
    }

    /// Fetches a peer's downloaded models (shown when its row expands).
    func fetchRemoteModels(for node: DiscoveredNode) async {
        guard let (status, body) = try? await call(
            node, method: "GET", path: "/models", timeout: 5
        ), status == 200,
        let models = try? JSONDecoder().decode([String].self, from: body) else { return }
        remoteModels[node.id] = models.sorted()
    }

    /// Cluster members in rank order — the head first (Ray's rank 0), no
    /// matter which Mac is looking.
    var clusterMembers: [ClusterNodeInfo] {
        var members = [localInfo]
        if let clusterPeerID, let peer = nodes.first(where: { $0.stableID == clusterPeerID }) {
            members.append(peer.info)
        }
        return role == .worker ? members.reversed() : members
    }

    var clusterTotalMemoryBytes: Int64 {
        clusterMembers.reduce(0) { $0 + $1.memoryBytes }
    }

    // MARK: Pairing (client side)

    func isPaired(_ node: DiscoveredNode) -> Bool {
        pairedPeers.contains { $0.id == node.stableID }
    }

    func pair(with node: DiscoveredNode) async {
        busy = "Waiting for approval on \(node.info.name)…"
        defer { busy = nil }
        lastError = nil
        let token = UUID().uuidString
        do {
            let payload = try JSONEncoder().encode(PairRequestPayload(
                id: localInfo.id, name: localInfo.name, token: token
            ))
            let (status, responseBody) = try await call(
                node, method: "POST", path: "/pair", token: self.token(for: node),
                body: payload, timeout: 90
            )
            if status == 200 {
                // The authenticated response, not the TXT advertisement, is
                // the identity we store.
                let responder = try? JSONDecoder().decode(PairResponsePayload.self, from: responseBody)
                savePeer(PairedPeer(
                    id: responder?.id ?? node.stableID,
                    name: responder?.name ?? node.info.name,
                    token: token
                ))
            } else if status == 403 {
                lastError = "\(node.info.name) declined the pairing."
            } else if status == 429 {
                lastError = "\(node.info.name) is answering another pairing request — try again in a moment."
            } else {
                lastError = "Pairing failed (HTTP \(status))."
            }
        } catch {
            lastError = "Couldn't reach \(node.info.name): \(error.localizedDescription)"
        }
    }

    /// Forgets the peer on both sides: tells them first (best effort — they
    /// may be offline, and we forget them locally regardless).
    func unpair(_ peer: PairedPeer) async {
        if let node = nodes.first(where: { $0.stableID == peer.id }) {
            _ = try? await call(node, method: "POST", path: "/pair/remove", token: peer.token, timeout: 5)
        }
        pairedPeers.removeAll { $0.id == peer.id }
        try? peersStore.save(pairedPeers)
    }

    // MARK: Cluster lifecycle (head side)

    private func token(for node: DiscoveredNode) -> String? {
        pairedPeers.first { $0.id == node.stableID }?.token
    }

    /// This Mac becomes the head; `node` joins as the worker.
    func createCluster(with node: DiscoveredNode) async {
        guard let token = token(for: node), role == .none, busy == nil else { return }
        lastError = nil
        busy = "Checking \(node.info.name)…"
        defer { busy = nil }
        var joined = false
        do {
            // 1. Peer preflight: reachable, engine + ray present, bridge info.
            let (nodeStatus, nodeBody) = try await call(
                node, method: "GET", path: "/node", token: token
            )
            guard nodeStatus == 200,
                  let peer = try? JSONDecoder().decode(NodeStatusPayload.self, from: nodeBody) else {
                lastError = "Couldn't read \(node.info.name)'s state."
                return
            }
            guard peer.rayAvailable else {
                lastError = "\(node.info.name) doesn't have Ray yet — install it from the Cluster page on that Mac."
                return
            }
            guard peer.role == Role.none.rawValue else {
                lastError = "\(node.info.name) is already in a cluster — dissolve that one first."
                return
            }
            // Ray refuses mixed-version joins — fail with a clear message
            // instead of a cryptic ray start error.
            if let mine = rayVersion, !peer.info.rayVersion.isEmpty, peer.info.rayVersion != mine {
                lastError = "Ray versions differ: this Mac has \(mine), \(node.info.name) has \(peer.info.rayVersion). Update Ray on both Macs first."
                return
            }

            // 2. Pick the serving network: the user's chosen interface wins,
            //    then the Thunderbolt bridge when both ends have one (the
            //    supported transport), then LAN (functional, but too slow to
            //    serve over — the UI warns).
            let chosen = preferredInterface.flatMap { name in
                localInterfaces.first { $0.name == name }?.address
            }
            let bridge = peer.bridgeIP != nil ? NetworkAddress.thunderboltBridgeIPv4() : nil
            guard let myIP = chosen ?? bridge ?? NetworkAddress.primaryIPv4() else {
                lastError = "No usable network interface found."
                return
            }

            // 3. Bring up the head (tear down any stale local node first).
            busy = "Starting Ray head…"
            _ = try? await ray.stopNode()
            let head = try await ray.startHead(nodeIP: myIP)
            guard head.didSucceed else {
                lastError = "Ray head failed: \(head.standardError.suffix(300))"
                return
            }

            // 4. Ask the peer to join.
            busy = "Joining \(node.info.name)…"
            let joinBody = try JSONEncoder().encode(JoinRequestPayload(headAddress: "\(myIP):\(RayCluster.gcsPort)"))
            let (joinStatus, joinResponse) = try await call(
                node, method: "POST", path: "/cluster/join",
                token: token, body: joinBody, timeout: 60
            )
            guard joinStatus == 200 else {
                lastError = "\(node.info.name) couldn't join (HTTP \(joinStatus)): \(String(decoding: joinResponse, as: UTF8.self).prefix(200))"
                _ = try? await ray.stopNode()
                return
            }
            joined = true

            // 5. Wait for both nodes to show up.
            busy = "Waiting for the cluster…"
            for _ in 0..<30 {
                if let status = await ray.status(), status.activeNodes >= 2 {
                    clusterStatus = status
                    role = .head
                    headIP = myIP
                    clusterPeerID = node.stableID
                    persistClusterState()
                    startStatusPolling()
                    return
                }
                guard (try? await Task.sleep(for: .seconds(1))) != nil else { break }
            }
            lastError = "The cluster never reached 2 nodes — check the connection and try again."
            await abandonAttempt(with: node, token: token, joined: joined)
        } catch {
            lastError = error.localizedDescription
            await abandonAttempt(with: node, token: token, joined: joined)
        }
    }

    /// Unwinds a failed create: stop our half-started head, and if the peer
    /// already joined, release it too — otherwise it keeps polling a dead
    /// head as a phantom worker until someone dissolves it by hand.
    private func abandonAttempt(with node: DiscoveredNode, token: String, joined: Bool) async {
        if joined {
            _ = try? await call(node, method: "POST", path: "/cluster/leave", token: token, timeout: 10)
        }
        _ = try? await ray.stopNode()
    }

    /// Starts this Mac as a Ray head with no app-driven worker — the head
    /// address shows in the UI so other Macs (paired or not, even ones this
    /// Mac can't discover) can join it manually.
    func startStandaloneHead() async {
        guard role == .none, busy == nil else { return }
        lastError = nil
        busy = "Starting Ray head…"
        defer { busy = nil }
        let chosen = preferredInterface.flatMap { name in
            localInterfaces.first { $0.name == name }?.address
        }
        guard let myIP = chosen ?? NetworkAddress.thunderboltBridgeIPv4() ?? NetworkAddress.primaryIPv4() else {
            lastError = "No usable network interface found."
            return
        }
        _ = try? await ray.stopNode()
        do {
            let head = try await ray.startHead(nodeIP: myIP)
            guard head.didSucceed else {
                lastError = "Ray head failed: \(head.standardError.suffix(300))"
                return
            }
            clusterStatus = await ray.status()
            role = .head
            headIP = myIP
            clusterPeerID = nil
            persistClusterState()
            startStatusPolling()
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Joins a Ray head by address ("10.0.0.1" or "10.0.0.1:6379") — the
    /// escape hatch when the head can't reach us over the control channel
    /// (different subnets, no discovery). Deployment lists and logs still
    /// need the head paired; plain Ray membership works without it.
    func joinCluster(address raw: String) async {
        guard role == .none, busy == nil else { return }
        lastError = nil
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        let parts = trimmed.split(separator: ":")
        let host = String(parts.first ?? "")
        guard !host.isEmpty else {
            lastError = "Enter the head's address (like 10.0.0.1:\(RayCluster.gcsPort))."
            return
        }
        let port: String
        if parts.count > 1 {
            guard let numeric = Int(parts[1]), (1...65535).contains(numeric) else {
                lastError = "\(parts[1]) isn't a valid port."
                return
            }
            port = String(numeric)
        } else {
            port = String(RayCluster.gcsPort)
        }
        busy = "Joining \(host)…"
        defer { busy = nil }
        guard let myIP = NetworkAddress.interfaceIPv4(reaching: host) ?? NetworkAddress.primaryIPv4() else {
            lastError = "No usable network interface found."
            return
        }
        _ = try? await ray.stopNode()
        do {
            let result = try await ray.join(headAddress: "\(host):\(port)", nodeIP: myIP)
            guard result.didSucceed else {
                lastError = "Join failed: \(result.standardError.suffix(300))"
                return
            }
            role = .worker
            headIP = host
            clusterPeerID = nodes.first { $0.info.addresses.contains(host) }?.stableID
            persistClusterState()
            startStatusPolling()
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Tears the cluster down on both ends.
    func dissolveCluster() async {
        busy = "Dissolving cluster…"
        defer { busy = nil }
        // Only the Mac we're actually clustered with — other paired peers
        // may be running clusters of their own.
        if let node = nodes.first(where: { $0.stableID == clusterPeerID }),
           let token = token(for: node) {
            _ = try? await call(node, method: "POST", path: "/cluster/leave", token: token)
        }
        _ = try? await ray.stopNode()
        role = .none
        headIP = nil
        clusterStatus = nil
        clusterPeerID = nil
        clusterDeployments = []
        remoteLogs = [:]
        chatTarget = nil
        stopLogStream()
        persistClusterState()
        statusTask?.cancel()
    }

    // MARK: Worker side

    private func handleJoin(_ request: ControlRequest) async -> ControlResponse {
        guard let payload = try? JSONDecoder().decode(JoinRequestPayload.self, from: request.body) else {
            return .error(400)
        }
        let headHost = String(payload.headAddress.split(separator: ":").first ?? "")
        // Refuse to be stolen out of a live cluster; the current head may
        // re-join us (retry after a partial failure). `busy` covers the
        // in-flight case: role only transitions at the end of createCluster,
        // so two Macs clicking "Create Cluster" at each other would otherwise
        // pass this guard and stop each other's half-started heads.
        if busy != nil || (role != .none && headIP != headHost) {
            return ControlResponse(status: 409, body: Data("already in a cluster".utf8))
        }
        busy = "Joining \(headHost)…"
        defer { busy = nil }
        let myIP = NetworkAddress.interfaceIPv4(reaching: headHost) ?? NetworkAddress.primaryIPv4()
        guard let myIP else { return .error(500) }
        _ = try? await ray.stopNode()
        do {
            let result = try await ray.join(headAddress: payload.headAddress, nodeIP: myIP)
            guard result.didSucceed else {
                return ControlResponse(status: 500, body: Data(result.standardError.suffix(300).utf8))
            }
            role = .worker
            headIP = headHost
            clusterPeerID = nodes.first { $0.info.addresses.contains(headHost) }?.stableID
            persistClusterState()
            startStatusPolling()
            return .json(StatePayload(state: "joined"))
        } catch {
            return .error(500)
        }
    }

    // MARK: Status polling

    private func startStatusPolling() {
        statusTask?.cancel()
        statusTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self, self.role != .none else { return }
                self.clusterStatus = await self.ray.status()
                await self.refreshClusterDeployments()
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    private func refreshClusterDeployments() async {
        switch role {
        case .head:
            clusterDeployments = deploymentsProvider?() ?? []
        case .worker:
            // The head is whoever we joined: by remembered id, else by address.
            guard let node = nodes.first(where: { $0.stableID == clusterPeerID })
                    ?? nodes.first(where: { $0.info.addresses.contains(headIP ?? "") }),
                  let token = token(for: node),
                  let (status, body) = try? await call(
                    node, method: "GET", path: "/deployments", token: token, timeout: 5
                  ),
                  status == 200,
                  let summaries = try? JSONDecoder().decode(
                    [ClusterDeploymentSummary].self, from: body
                  ) else {
                // Keep the last-known rows through a blip, but not through a
                // gone head — stale "Running" is worse than an empty list.
                deploymentFetchMisses += 1
                if deploymentFetchMisses >= 3 { clusterDeployments = [] }
                return
            }
            // The cluster may have been dissolved under us while the fetch
            // was in flight — don't resurrect what the teardown just cleared.
            guard role == .worker else { return }
            deploymentFetchMisses = 0
            clusterDeployments = summaries
        case .none:
            deploymentFetchMisses = 0
            clusterDeployments = []
        }
    }

    private var deploymentFetchMisses = 0

    // MARK: Cross-Mac logs (worker side)

    /// Starts mirroring the head's log for `port` (2 s tail polls) — driven
    /// by the deployment detail being on screen; call `stopLogStream()` when
    /// it leaves. The head reads its own deployment's log directly and never
    /// needs this.
    func startLogStream(port: Int) {
        guard role == .worker else { return }
        logStreamTask?.cancel()
        logStreamTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self, self.role == .worker else { return }
                await self.fetchLogChunk(port: port)
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    func stopLogStream() {
        logStreamTask?.cancel()
        logStreamTask = nil
    }

    private func fetchLogChunk(port: Int) async {
        guard let node = nodes.first(where: { $0.stableID == clusterPeerID })
                ?? nodes.first(where: { $0.info.addresses.contains(headIP ?? "") }),
              let token = token(for: node) else { return }
        let after = remoteLogs[port]?.last?.id ?? -1
        guard let body = try? JSONEncoder().encode(LogsRequestPayload(port: port, after: after)),
              let (status, response) = try? await call(
                node, method: "POST", path: "/deployments/logs", token: token, body: body, timeout: 5
              ),
              status == 200,
              let lines = try? JSONDecoder().decode([LogLinePayload].self, from: response),
              !lines.isEmpty else { return }
        var kept = (remoteLogs[port] ?? []) + lines.map { LogLine(id: $0.id, text: $0.text) }
        // A restarted engine restarts its line ids — detect the reset and
        // drop the stale prefix rather than rendering interleaved runs.
        if let first = lines.first, first.id <= after {
            kept = lines.map { LogLine(id: $0.id, text: $0.text) }
        }
        remoteLogs[port] = Array(kept.suffix(4000))
    }

    // MARK: Cluster deployment (head side)

    /// Ensures the model exists on the workers, then starts a cluster serve
    /// deployment on the head via the normal deployment machinery, so the
    /// result is an ordinary Server-page deployment with cluster arguments.
    func deploy(model: String, mode: ClusterServeMode, flags baseFlags: ServeFlags, serve: ServeController) async {
        guard role == .head, headIP != nil, busy == nil else { return }
        lastError = nil
        defer { busy = nil }

        // A live single-Mac deployment of the same model would swallow this
        // request — run() would just activate it, Ray arguments ignored —
        // so fail loud instead of pretending.
        if let existing = serve.deployments.first(where: {
            $0.model == model && ($0.isRunning || $0.isStarting)
        }) {
            lastError = "\(model) is already running on port \(existing.port) — stop that deployment first."
            return
        }

        // 1. The cluster peer needs the weights locally too — when we can
        //    reach one over the control channel. A manually-joined worker
        //    (no pairing) is on its own for the download; the deploy still
        //    proceeds and any missing weights surface in the engine log.
        if let node = nodes.first(where: { $0.stableID == clusterPeerID }),
           let peerToken = token(for: node) {
            busy = "Preparing \(model) on \(node.info.name)…"
            let ensureBody = try? JSONEncoder().encode(EnsureModelPayload(model: model))
            _ = try? await call(
                node, method: "POST", path: "/models/ensure",
                token: peerToken, body: ensureBody
            )
            // Poll until it lands (model downloads can take a while) — and
            // verify it actually did: launching without the weights would
            // only crash inside the Ray workers later, much less legibly.
            var present = false
            var unreachable = 0
            for _ in 0..<720 where !present {
                if let (status, body) = try? await call(
                    node, method: "GET", path: "/models"
                ), status == 200 {
                    unreachable = 0
                    let models = (try? JSONDecoder().decode([String].self, from: body)) ?? []
                    if models.contains(model) {
                        present = true
                        continue
                    }
                } else {
                    // A dead peer must fail the deploy within a minute, not
                    // hold the head busy for the full hour.
                    unreachable += 1
                    if unreachable >= 12 { break }
                }
                guard (try? await Task.sleep(for: .seconds(5))) != nil else { break }
            }
            guard present else {
                lastError = "\(node.info.name) couldn't download \(model) — check its network and disk space, then deploy again."
                return
            }
        }

        // Re-validate: the download wait can run an hour, and the world may
        // have moved — cluster dissolved, or the model deployed single-Mac
        // from the Server page (run() would silently activate that one and
        // drop every Ray argument).
        guard role == .head, let currentHeadIP = self.headIP else {
            lastError = "The cluster went away while preparing \(model) — re-create it and deploy again."
            return
        }
        if let existing = serve.deployments.first(where: {
            $0.model == model && ($0.isRunning || $0.isStarting)
        }) {
            lastError = "\(model) is already running on port \(existing.port) — stop that deployment first."
            return
        }

        // 2. Launch through the standard deployment path with cluster args.
        busy = "Starting cluster deployment…"
        let nodeCount = clusterStatus?.activeNodes ?? 2
        var flags = baseFlags
        let clusterArguments = ClusterServeCommand.arguments(
            mode: mode, nodeCount: nodeCount, headIP: currentHeadIP
        )
        flags.extraArguments = (flags.extraArguments + " " + clusterArguments.joined(separator: " "))
            .trimmingCharacters(in: .whitespaces)
        flags.additionalEnvironment = ClusterServeCommand.environment(headIP: currentHeadIP)
        serve.modelInput = model
        serve.run(flags: flags)
    }
}

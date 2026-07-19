import SwiftUI
import VMDCore

/// The cluster surface: this Mac, the Macs discovered around it, and — once
/// paired — the Ray cluster's live state with cross-Mac deployment. Pairing
/// requires a click on the *other* Mac; everything privileged rides the token
/// that pairing minted.
struct ClusterView: View {
    @Environment(ServeController.self) private var serve
    @Environment(ClusterController.self) private var cluster
    @Environment(AppNavigation.self) private var navigation
    @State private var showDeploySheet = false
    @State private var expandedNodeID: String?
    @State private var showManualAdd = false
    @State private var showJoinPopover = false
    @State private var joinAddress = ""
    @State private var selectedDeploymentID: String?
    @State private var showConfigSheet = false
    @State private var manualAddress = ""
    @State private var manualPort = ""
    @State private var manualAddBusy = false

    var body: some View {
        GeometryReader { geo in
            splitLayout(width: geo.size.width)
        }
        .navigationTitle("Cluster")
        // The log stream follows the selection from here — the page root —
        // because the wide and narrow layouts are distinct view identities:
        // hanging start/stop on their own lifecycles let a window resize
        // fire the incoming branch's start and then the outgoing branch's
        // stop, killing the stream while the detail was still on screen.
        .onChange(of: logStreamKey, initial: true) { _, _ in
            syncLogStream(port: selectedDeployment?.port)
        }
        .onDisappear { cluster.stopLogStream() }
        .sheet(isPresented: $showDeploySheet) {
            ClusterDeploySheet(cluster: cluster, flags: serve.flags)
        }
        .sheet(isPresented: $showConfigSheet) {
            // The same configuration editor the vLLM Server page uses —
            // editing a live deployment promises a Redeploy.
            if let live = serve.deployments.first(where: { $0.port == selectedDeployment?.port }) {
                ServeFlagsSheet(
                    flags: live.flags ?? serve.flags,
                    fixedPort: live.port,
                    changedActionTitle: live.isRestartable ? nil : "Redeploy"
                ) { newFlags in
                    serve.update(live, flags: newFlags)
                }
            }
        }
    }

    /// Sidebar-style split at every window size: everything about the
    /// cluster itself on the left, what it serves on the right — pick a
    /// deployment and its live log fills the rest of the window.
    private func splitLayout(width: CGFloat) -> some View {
        HStack(alignment: .top, spacing: Theme.Spacing.l) {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Spacing.xl) {
                    banners
                    thisMacSection
                    if cluster.role != .none {
                        clusterSection
                    }
                    discoveredSection
                    roadmapFooter
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, Theme.Spacing.xl)
            }
            .frame(width: max(360, min(560, width * 0.34)))

            Group {
                if cluster.role != .none {
                    deploymentsSection
                } else {
                    ScrollView { clusterPlaceholder.padding(.vertical, Theme.Spacing.xl) }
                }
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .padding(.vertical, Theme.Spacing.xl)
        }
        .padding(.horizontal, Theme.Spacing.xl)
        .pageWidth(max: 2400)
    }

    @ViewBuilder
    private var banners: some View {
        if cluster.localNetworkDenied {
            permissionBanner
        }
        if let error = cluster.lastError {
            errorBanner(error)
        }
    }

    private var clusterPlaceholder: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            sectionTitle("Cluster")
            card {
                VStack(alignment: .leading, spacing: Theme.Spacing.s) {
                    Label("No cluster yet", systemImage: "square.stack.3d.up")
                        .foregroundStyle(.secondary)
                    Text("Pair another Mac and create a cluster to serve one model across machines. Deployments will show up here for every member.")
                        .scaledFont(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(14)
            }
        }
    }

    private var interfaceSelection: Binding<String> {
        Binding(
            get: { cluster.preferredInterface ?? "auto" },
            set: { cluster.setPreferredInterface($0 == "auto" ? nil : $0) }
        )
    }

    // MARK: Banners

    private var permissionBanner: some View {
        HStack(spacing: Theme.Spacing.m) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("Local Network access is off")
                    .scaledFont(.body, weight: .medium)
                Text("Discovery needs it to see your other Macs. Enable it for vLLM Metal Desktop under Privacy & Security → Local Network.")
                    .scaledFont(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Open Settings") {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocalNetwork") {
                    NSWorkspace.shared.open(url)
                }
            }
        }
        .padding(Theme.Spacing.m)
        .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func errorBanner(_ message: String) -> some View {
        Label(message, systemImage: "xmark.octagon.fill")
            .scaledFont(.callout)
            .foregroundStyle(.red)
            .padding(Theme.Spacing.m)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.red.opacity(0.1), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    // MARK: This Mac

    private var thisMacSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            sectionTitle("This Mac")
            card {
                nodeRow(
                    name: cluster.localInfo.name,
                    detail: nodeDetail(cluster.localInfo)
                        + (cluster.localInfo.controlPort > 0
                            ? " · \(cluster.localInfo.address):\(cluster.localInfo.controlPort)"
                            : ""),
                    modelIdentifier: cluster.localInfo.modelIdentifier
                ) {
                    if let busy = cluster.busy {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.mini)
                            Text(busy).scaledFont(.caption).foregroundStyle(.secondary)
                        }
                    } else {
                        HStack(spacing: Theme.Spacing.s) {
                            Circle().fill(roleColor).frame(width: 7, height: 7)
                            Text(roleLabel)
                                .scaledFont(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize()
                            if cluster.role == .none {
                                Toggle("", isOn: Binding(
                                    get: { cluster.discoverable },
                                    set: { cluster.setDiscoverable($0) }
                                ))
                                .toggleStyle(.switch)
                                .controlSize(.mini)
                                .labelsHidden()
                                .help("Whether other Macs can discover this one")
                            }
                        }
                    }
                }
            }
            HStack(spacing: Theme.Spacing.s) {
                if let version = cluster.rayVersion {
                    Label {
                        Text("Ray \(version)")
                        if !cluster.rayUpdateAvailable, cluster.latestRayVersion != nil {
                            Text("· up to date").foregroundStyle(.tertiary)
                        }
                    } icon: {
                        Image(systemName: "shippingbox")
                    }
                    .scaledFont(.caption)
                    .foregroundStyle(.secondary)
                    Spacer()
                    // The update button only appears when PyPI actually has a
                    // newer stable release.
                    if cluster.rayUpdateAvailable, let latest = cluster.latestRayVersion {
                        Button("Update to \(latest)") {
                            Task { await cluster.installRay() }
                        }
                        .controlSize(.small)
                        .buttonStyle(.borderedProminent)
                        .disabled(cluster.busy != nil || cluster.role != .none)
                    }
                    // Cluster nodes must match exactly, so pinning to a peer's
                    // (possibly older) version is a first-class move.
                    if !cluster.availableRayVersions.isEmpty {
                        Menu {
                            ForEach(cluster.availableRayVersions, id: \.self) { candidate in
                                Button {
                                    Task { await cluster.installRay(version: candidate) }
                                } label: {
                                    if candidate == version {
                                        Label(candidate, systemImage: "checkmark")
                                    } else {
                                        Text(candidate)
                                    }
                                }
                                .disabled(candidate == version)
                            }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                        }
                        .menuStyle(.button)
                        .buttonStyle(.plain)
                        .menuIndicator(.hidden)
                        .fixedSize()
                        .help("Install a specific Ray version")
                        .disabled(cluster.busy != nil || cluster.role != .none)
                    }
                } else {
                    Label(
                        "Clustering needs Ray in the engine — a one-time install.",
                        systemImage: "shippingbox"
                    )
                    .scaledFont(.caption)
                    .foregroundStyle(.secondary)
                    Spacer()
                    Button("Install Ray") {
                        Task { await cluster.installRay() }
                    }
                    .controlSize(.small)
                    .disabled(cluster.busy != nil)
                }
            }
            // Which network this Mac advertises/prefers. Every address is
            // advertised regardless — peers try them all — but the preferred
            // one leads and is what the cluster serves over.
            HStack(spacing: Theme.Spacing.s) {
                Label("Network", systemImage: "network")
                    .scaledFont(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Picker("", selection: interfaceSelection) {
                    Text("Automatic").tag("auto")
                    ForEach(cluster.localInterfaces, id: \.name) { interface in
                        Text(verbatim: "\(interface.name) · \(interface.address)")
                            .tag(interface.name)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .fixedSize()
                .disabled(cluster.role != .none)
            }

            // Manual Ray membership — for setups discovery can't cover (a
            // head on another subnet, or forming one before the peer pairs).
            if cluster.role == .none, cluster.rayVersion != nil {
                HStack(spacing: Theme.Spacing.s) {
                    Label("Ray cluster", systemImage: "point.3.connected.trianglepath.dotted")
                        .scaledFont(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Start Head") {
                        Task { await cluster.startStandaloneHead() }
                    }
                    .controlSize(.small)
                    .fixedSize()
                    .disabled(cluster.busy != nil)
                    .help("Start a Ray head here — other Macs join it by address")
                    Button("Join…") { showJoinPopover = true }
                        .controlSize(.small)
                        .fixedSize()
                        .disabled(cluster.busy != nil)
                        .help("Join a Ray head by address")
                        .popover(isPresented: $showJoinPopover, arrowEdge: .bottom) {
                            joinForm
                        }
                }
            }

            // pip's live output while Ray installs/updates — show the work,
            // not just a spinner.
            if !cluster.installLogs.isEmpty {
                EngineLogView(lines: cluster.installLogs, emptyText: "")
                    .frame(height: 150)
                    .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
        }
    }

    private var roleLabel: String {
        switch cluster.role {
        case .none: cluster.discoverable ? "Discoverable" : "Hidden"
        case .head: "Cluster head"
        case .worker: "Cluster worker"
        }
    }

    private var roleColor: Color {
        if cluster.role != .none { return .blue }
        return cluster.discoverable ? .green : .secondary
    }

    // MARK: Cluster (active)

    private var clusterSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            HStack {
                sectionTitle("Cluster")
                Spacer()
                Button("Dissolve", role: .destructive) {
                    Task { await cluster.dissolveCluster() }
                }
                .controlSize(.small)
            }
            card {
                // Headline: what clustering buys — the combined memory pool.
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Cluster Unified Memory")
                            .scaledFont(.caption)
                            .foregroundStyle(.secondary)
                        Text(cluster.clusterTotalMemoryBytes.formatted(.byteCount(style: .memory)))
                            .scaledFont(.title2, weight: .semibold)
                            .monospacedDigit()
                    }
                    Spacer()
                    if let status = cluster.clusterStatus {
                        Text(verbatim: "\(status.activeNodes) nodes · mlx \(Int(status.mlxUsed))/\(Int(status.mlxTotal))")
                            .scaledFont(.caption)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    } else {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.mini)
                            Text("Checking…").scaledFont(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)

                // Ranks: one row per member, LM Studio-style.
                ForEach(Array(cluster.clusterMembers.enumerated()), id: \.element.id) { index, member in
                    rowDivider
                    HStack(spacing: Theme.Spacing.m) {
                        MacModelIcon(
                            modelIdentifier: member.modelIdentifier.isEmpty ? nil : member.modelIdentifier,
                            size: 24
                        )
                        Text(verbatim: "Rank \(index)")
                            .scaledFont(.caption, design: .monospaced)
                            .foregroundStyle(.secondary)
                        Text(member.name)
                        if index == 0 {
                            Text("Head")
                                .scaledFont(.caption2, weight: .semibold)
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(Color.accentColor.opacity(0.18), in: Capsule())
                                .foregroundStyle(Color.accentColor)
                        }
                        Spacer()
                        Text(member.memoryBytes.formatted(.byteCount(style: .memory)))
                            .scaledFont(.caption)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                }

                if let headIP = cluster.headIP {
                    rowDivider
                    row("Head address") {
                        Text(verbatim: "\(headIP):\(RayCluster.gcsPort)")
                            .scaledFont(.callout, design: .monospaced)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString("\(headIP):\(RayCluster.gcsPort)", forType: .string)
                        } label: {
                            Image(systemName: "doc.on.doc")
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .help("Copy the head address")
                    }
                }
                if cluster.role == .head, cluster.clusterPeerID == nil {
                    rowDivider
                    Text("Waiting for workers — other Macs join with this address from their Cluster page.")
                        .scaledFont(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                }
            }
            if NetworkAddress.thunderboltBridgeIPv4() == nil {
                Label(
                    "No Thunderbolt Bridge detected — the cluster is on your LAN, which works for testing but is too slow to serve over. Connect the Macs with a Thunderbolt cable for real use.",
                    systemImage: "bolt.trianglebadge.exclamationmark"
                )
                .scaledFont(.caption)
                .foregroundStyle(.orange)
            }
        }
    }

    // MARK: Cluster deployments

    private var selectedDeployment: ClusterDeploymentSummary? {
        cluster.clusterDeployments.first { $0.id == selectedDeploymentID }
            ?? cluster.clusterDeployments.first
    }

    /// One list for the whole cluster — the head reads its own deployments,
    /// workers see the same rows via the control channel. Selecting a row
    /// opens its detail (status, endpoint, live log) below; the log fills
    /// the column.
    private var deploymentsSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            HStack {
                sectionTitle("Cluster Deployments")
                Spacer()
                if cluster.role == .head {
                    Button("Deploy on Cluster…") { showDeploySheet = true }
                        .controlSize(.small)
                        .buttonStyle(.borderedProminent)
                        .fixedSize()
                        .disabled(cluster.busy != nil || (cluster.clusterStatus?.activeNodes ?? 0) < 2)
                        .help((cluster.clusterStatus?.activeNodes ?? 0) < 2
                            ? "Deploying needs at least 2 Macs in the cluster"
                            : "Deploy a model across the cluster")
                }
            }
            if cluster.clusterDeployments.isEmpty {
                card {
                    VStack(alignment: .leading, spacing: Theme.Spacing.s) {
                        Label("Nothing deployed on the cluster yet", systemImage: "shippingbox")
                            .foregroundStyle(.secondary)
                        Text(deploymentsHint)
                            .scaledFont(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(14)
                }
            } else {
                if cluster.clusterDeployments.count > 4 {
                    // Many deployments must not push the log off the bottom
                    // of the fixed-height wide column.
                    ScrollView {
                        card {
                            ForEach(Array(cluster.clusterDeployments.enumerated()), id: \.element.id) { index, deployment in
                                if index > 0 { rowDivider }
                                deploymentRow(deployment, isSelected: deployment.id == selectedDeployment?.id)
                            }
                        }
                    }
                    .frame(maxHeight: 300)
                } else {
                    card {
                        ForEach(Array(cluster.clusterDeployments.enumerated()), id: \.element.id) { index, deployment in
                            if index > 0 { rowDivider }
                            deploymentRow(deployment, isSelected: deployment.id == selectedDeployment?.id)
                        }
                    }
                }
                if let deployment = selectedDeployment {
                    deploymentDetail(deployment)
                }
            }
        }
    }

    private func deploymentRow(_ deployment: ClusterDeploymentSummary, isSelected: Bool) -> some View {
        Button {
            selectedDeploymentID = deployment.id
        } label: {
            HStack(spacing: Theme.Spacing.m) {
                deploymentStateIndicator(deployment.state)
                VStack(alignment: .leading, spacing: 2) {
                    Text(deployment.model).scaledFont(.body, weight: .medium)
                    if let host = cluster.headIP {
                        Text(deployment.endpoint(host: host))
                            .scaledFont(.caption, design: .monospaced)
                            .foregroundStyle(.secondary)
                    }
                }
                modeBadge(deployment.mode)
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark")
                        .scaledFont(.caption, weight: .semibold)
                        .foregroundStyle(Color.accentColor)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(isSelected ? Color.accentColor.opacity(0.08) : .clear)
    }

    /// The selected deployment, vLLM Server-style: status, endpoint, actions,
    /// and the engine's live log — on every member, not just the head (the
    /// worker tails it over the control channel).
    private func deploymentDetail(_ deployment: ClusterDeploymentSummary) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            card {
                HStack(spacing: Theme.Spacing.m) {
                    deploymentStateIndicator(deployment.state)
                    Text(stateLabel(deployment.state))
                        .scaledFont(.callout, weight: .medium)
                    Spacer()
                    Button("Chat") {
                        if cluster.role == .head {
                            if let live = serve.deployments.first(where: { $0.port == deployment.port }) {
                                serve.activeID = live.id
                            }
                        } else {
                            cluster.chatTarget = deployment
                        }
                        navigation.section = .chat
                    }
                    .controlSize(.small)
                    .buttonStyle(.borderedProminent)
                    .fixedSize()
                    .disabled(deployment.state != .running)
                    .help("Talk to this model on the Chat page")
                    if cluster.role == .head,
                       let live = serve.deployments.first(where: { $0.port == deployment.port }) {
                        Button("Config…") { showConfigSheet = true }
                            .controlSize(.small)
                            .fixedSize()
                            .help("Edit this deployment's serve configuration")
                        if live.isRunning || live.isStarting {
                            Button("Stop", role: .destructive) { serve.stop(live) }
                                .controlSize(.small)
                                .fixedSize()
                        } else if live.isRestartable {
                            Button("Start") { serve.start(live) }
                                .controlSize(.small)
                                .fixedSize()
                            Button("Remove", role: .destructive) { serve.remove(live) }
                                .controlSize(.small)
                                .fixedSize()
                                .help("Delete this deployment")
                        }
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                if let host = cluster.headIP {
                    rowDivider
                    HStack(spacing: Theme.Spacing.s) {
                        Text(deployment.endpoint(host: host))
                            .scaledFont(.callout, design: .monospaced)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(deployment.endpoint(host: host), forType: .string)
                        } label: {
                            Image(systemName: "doc.on.doc")
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .help("Copy endpoint URL")
                        Spacer()
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                }
            }
            EngineLogView(
                lines: logLines(for: deployment),
                emptyText: cluster.role == .head
                    ? "No engine log yet."
                    : "Waiting for the head's log…"
            )
            // Fresh view identity per deployment — line ids restart at 0 for
            // every engine, so a reused view can't tell the logs apart.
            .id(deployment.id)
            .frame(minHeight: 220)
            .frame(maxHeight: .infinity)
            .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .frame(maxHeight: .infinity)
    }

    /// Head: straight from the local serve process. Worker: the mirror the
    /// controller tails over the control channel.
    private func logLines(for deployment: ClusterDeploymentSummary) -> [LogLine] {
        if cluster.role == .head {
            return serve.deployments.first { $0.port == deployment.port }?.logs ?? []
        }
        return cluster.remoteLogs[deployment.port] ?? []
    }

    /// Role is part of the key so joining/leaving starts/stops the stream.
    private var logStreamKey: String {
        "\(cluster.role)|\(selectedDeployment?.port ?? -1)"
    }

    private func syncLogStream(port: Int?) {
        if let port, cluster.role == .worker {
            cluster.startLogStream(port: port)
        } else {
            cluster.stopLogStream()
        }
    }

    private var deploymentsHint: String {
        if cluster.role == .head {
            return "Deploy a model to serve it across every Mac in the cluster."
        }
        if cluster.clusterPeerID == nil {
            return "Pair with the head Mac to see its deployments and logs here — Ray membership alone doesn't carry them."
        }
        return "Deployments started on the head appear here for the whole cluster."
    }

    private func stateLabel(_ state: ClusterDeploymentSummary.State) -> String {
        switch state {
        case .starting: "Loading model…"
        case .running: "Running"
        case .stopped: "Stopped"
        case .failed: "Failed"
        }
    }

    @ViewBuilder
    private func deploymentStateIndicator(_ state: ClusterDeploymentSummary.State) -> some View {
        if state == .starting {
            ProgressView().controlSize(.mini)
        } else {
            Circle()
                .fill(state == .running ? Color.green : state == .failed ? Color.red : Color.secondary)
                .frame(width: 7, height: 7)
                .help(state == .running ? "Running" : state == .failed ? "Failed" : "Stopped")
        }
    }

    private func modeBadge(_ mode: ClusterServeMode) -> some View {
        Text(mode.badge)
            .scaledFont(.caption2, weight: .semibold)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Color.accentColor.opacity(0.18), in: Capsule())
            .foregroundStyle(Color.accentColor)
            .help(mode.title)
    }

    // MARK: Discovered Macs

    private var discoveredSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            HStack {
                sectionTitle("Macs on Your Network")
                Spacer()
                // Escape hatch for networks mDNS can't cross (subnets, VPNs).
                Button {
                    showManualAdd = true
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.primary)
                        .padding(6)
                }
                .buttonStyle(.plain)
                .fixedSize()
                .glassCapsule(interactive: true)
                .pointingHandCursor()
                .help("Add a Mac by IP address")
                .popover(isPresented: $showManualAdd, arrowEdge: .bottom) {
                    manualAddForm
                }
            }
            if cluster.nodes.isEmpty {
                card {
                    VStack(alignment: .leading, spacing: Theme.Spacing.s) {
                        Label("Looking for other Macs…", systemImage: "antenna.radiowaves.left.and.right")
                            .foregroundStyle(.secondary)
                        Text("Open vLLM Metal Desktop on another Mac on the same network and it will appear here automatically.")
                            .scaledFont(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(14)
                }
            } else {
                card {
                    ForEach(Array(cluster.nodes.enumerated()), id: \.element.id) { index, node in
                        if index > 0 { Divider().padding(.leading, 14) }
                        discoveredNodeRow(node)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func discoveredNodeRow(_ node: ClusterController.DiscoveredNode) -> some View {
        let expanded = expandedNodeID == node.id
        Button {
            expandedNodeID = expanded ? nil : node.id
            if !expanded {
                Task { await cluster.fetchRemoteModels(for: node) }
            }
        } label: {
            HStack(spacing: Theme.Spacing.m) {
                MacModelIcon(
                    modelIdentifier: node.info.modelIdentifier.isEmpty ? nil : node.info.modelIdentifier,
                    size: 34
                )
                VStack(alignment: .leading, spacing: 2) {
                    Text(node.info.name)
                        .scaledFont(.body, weight: .medium)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(nodeDetail(node.info))
                        .scaledFont(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer(minLength: Theme.Spacing.s)
                if cluster.isPaired(node) {
                    // Icon-only: the buttons need the room in a narrow
                    // column, and the expanded detail spells pairing out.
                    Image(systemName: "link")
                        .scaledFont(.caption)
                        .foregroundStyle(.secondary)
                        .help("Paired")
                }
                nodeActions(node)
                Image(systemName: "chevron.right")
                    .scaledFont(.caption2, weight: .semibold)
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(expanded ? 90 : 0))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)

        if expanded {
            VStack(alignment: .leading, spacing: Theme.Spacing.s) {
                LabeledContent("Device ID") {
                    Text(node.id)
                        .scaledFont(.caption, design: .monospaced)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                LabeledContent("Address") {
                    Text(verbatim: "\(node.info.address):\(node.info.controlPort)")
                        .scaledFont(.caption, design: .monospaced)
                        .foregroundStyle(.secondary)
                }
                LabeledContent("Ray") {
                    Text(node.info.rayVersion.isEmpty ? "not installed" : node.info.rayVersion)
                        .scaledFont(.caption, design: .monospaced)
                        .foregroundStyle(
                            !node.info.rayVersion.isEmpty && node.info.rayVersion == cluster.rayVersion
                                ? AnyShapeStyle(.secondary)
                                : AnyShapeStyle(.orange)
                        )
                }
                Divider()
                Text("Models on this Mac")
                    .scaledFont(.caption, weight: .medium)
                    .foregroundStyle(.secondary)
                if let models = cluster.remoteModels[node.id] {
                    if models.isEmpty {
                        Text("No downloaded models.")
                            .scaledFont(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(models, id: \.self) { model in
                            Label(model, systemImage: "shippingbox")
                                .scaledFont(.caption)
                        }
                    }
                } else {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.mini)
                        Text("Loading…").scaledFont(.caption).foregroundStyle(.secondary)
                    }
                }
                if cluster.isPaired(node) || node.isManual {
                    Divider()
                    HStack(spacing: Theme.Spacing.s) {
                        Spacer()
                        if node.isManual {
                            Button("Remove", role: .destructive) {
                                cluster.removeManualNode(node)
                            }
                            .controlSize(.small)
                        }
                        if cluster.isPaired(node) {
                            Button("Unpair", role: .destructive) {
                                if let peer = cluster.pairedPeers.first(where: { $0.id == node.stableID }) {
                                    Task { await cluster.unpair(peer) }
                                }
                            }
                            .controlSize(.small)
                            // Not while we're in a cluster with them.
                            .disabled(cluster.clusterPeerID == node.stableID && cluster.role != .none)
                        }
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 12)
            .animation(nil, value: expandedNodeID)
        }
    }

    @ViewBuilder
    private func nodeActions(_ node: ClusterController.DiscoveredNode) -> some View {
        if cluster.isPaired(node) {
            if cluster.role == .none {
                Button("Create Cluster") {
                    Task { await cluster.createCluster(with: node) }
                }
                .controlSize(.small)
                .buttonStyle(.borderedProminent)
                .fixedSize()
                .disabled(cluster.busy != nil)
            } else {
                Label("In cluster", systemImage: "checkmark.circle.fill")
                    .scaledFont(.caption)
                    .foregroundStyle(.blue)
                    .fixedSize()
            }
        } else {
            Button("Pair…") {
                Task { await cluster.pair(with: node) }
            }
            .controlSize(.small)
            .fixedSize()
            .disabled(cluster.busy != nil)
        }
    }

    private var joinForm: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.m) {
            Text("Join a Ray Head")
                .scaledFont(.headline)
            Text("Enter the head address shown on the other Mac's Cluster page. Port defaults to \(RayCluster.gcsPort).")
                .scaledFont(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 260, alignment: .leading)
            TextField("10.0.0.1:\(RayCluster.gcsPort)", text: $joinAddress)
                .textFieldStyle(.roundedBorder)
                .frame(width: 260)
            HStack {
                Spacer()
                Button("Join") {
                    showJoinPopover = false
                    Task { await cluster.joinCluster(address: joinAddress) }
                }
                .buttonStyle(.borderedProminent)
                .disabled(joinAddress.trimmingCharacters(in: .whitespaces).isEmpty || cluster.busy != nil)
            }
        }
        .padding(Theme.Spacing.m)
    }

    private var manualAddForm: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.m) {
            Text("Add a Mac by Address")
                .scaledFont(.headline)
            Text("For networks discovery can't cross — enter the other Mac's IP and the control port shown on its Cluster page.")
                .scaledFont(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 260, alignment: .leading)
            HStack(spacing: Theme.Spacing.s) {
                TextField("IP address", text: $manualAddress)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 160)
                TextField("Port", text: $manualPort)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 80)
            }
            HStack {
                Spacer()
                if manualAddBusy { ProgressView().controlSize(.small) }
                Button("Add") {
                    manualAddBusy = true
                    Task {
                        let port = Int(manualPort) ?? 0
                        if await cluster.addManualNode(address: manualAddress.trimmingCharacters(in: .whitespaces), port: port) {
                            showManualAdd = false
                            manualAddress = ""
                            manualPort = ""
                        }
                        manualAddBusy = false
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(manualAddress.isEmpty || Int(manualPort) == nil || manualAddBusy)
            }
        }
        .padding(Theme.Spacing.m)
    }

    // MARK: Roadmap footer

    private var roadmapFooter: some View {
        Text("Pipeline parallel splits one model's layers across Macs; data parallel runs a replica per Mac for throughput. Both run their traffic over Thunderbolt — connect the Macs with a Thunderbolt cable and macOS creates the bridge network automatically.")
            .scaledFont(.caption)
            .foregroundStyle(.secondary)
    }

    // MARK: Pieces

    private func nodeRow(
        name: String,
        detail: String,
        modelIdentifier: String,
        @ViewBuilder trailing: () -> some View
    ) -> some View {
        HStack(spacing: Theme.Spacing.m) {
            MacModelIcon(modelIdentifier: modelIdentifier.isEmpty ? nil : modelIdentifier, size: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .scaledFont(.body, weight: .medium)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(detail)
                    .scaledFont(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: Theme.Spacing.s)
            trailing()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private func nodeDetail(_ info: ClusterNodeInfo) -> String {
        var parts: [String] = []
        if !info.chip.isEmpty { parts.append(info.chip) }
        if info.memoryBytes > 0 {
            parts.append(info.memoryBytes.formatted(.byteCount(style: .memory)))
        }
        parts.append(info.engineVersion.isEmpty ? "engine not installed" : "engine \(info.engineVersion)")
        return parts.joined(separator: " · ")
    }

    private func row(_ label: String, @ViewBuilder value: () -> some View) -> some View {
        HStack(spacing: Theme.Spacing.s) {
            Text(label)
            Spacer()
            value()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var rowDivider: some View {
        Divider().padding(.leading, 14)
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title)
            .scaledFont(.headline)
            .foregroundStyle(.secondary)
    }

    private func card(@ViewBuilder _ content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 0, content: content)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

// MARK: - Cluster deploy sheet

/// Pick a downloaded model + parallelism mode, tune the serve configuration,
/// deploy across the cluster. The workers download the model first if they
/// don't have it (that's the long pole — the sheet stays up with progress).
private struct ClusterDeploySheet: View {
    let cluster: ClusterController

    @Environment(ServeController.self) private var serve
    @Environment(\.dismiss) private var dismiss

    @State private var flags: ServeFlags
    @State private var models: [String] = []
    @State private var selectedModel: String?
    @State private var mode: ClusterServeMode = .pipelineParallel
    @State private var isDeploying = false

    init(cluster: ClusterController, flags: ServeFlags) {
        self.cluster = cluster
        _flags = State(initialValue: flags)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Deploy on Cluster").scaledFont(.headline)
                Spacer()
            }
            .padding(.horizontal, Theme.Spacing.m)
            .padding(.vertical, 10)
            .background(.bar)

            Divider()

            Form {
                Section("Model") {
                    if models.isEmpty {
                        Text("No downloaded models yet — grab one on the Models page.")
                            .foregroundStyle(.secondary)
                    } else {
                        Picker("Model", selection: $selectedModel) {
                            ForEach(models, id: \.self) { model in
                                Text(model).tag(String?.some(model))
                            }
                        }
                    }
                }
                Section {
                    Picker("Mode", selection: $mode) {
                        ForEach(ClusterServeMode.allCases, id: \.self) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    .pickerStyle(.radioGroup)
                } header: {
                    Text("Parallelism")
                } footer: {
                    Text(mode.summary)
                }

                ServeFlagsForm(flags: $flags)
                if let busy = cluster.busy, isDeploying {
                    Section {
                        HStack(spacing: Theme.Spacing.s) {
                            ProgressView().controlSize(.small)
                            Text(busy).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)

            Divider()

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Deploy") { deploy() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(selectedModel == nil || isDeploying)
            }
            .padding(Theme.Spacing.m)
            .background(.bar)
        }
        .frame(width: 540, height: 640)
        .presentationBackground(.ultraThinMaterial)
        .onAppear {
            models = LocalModels().cachedModelIDs()
            if selectedModel == nil { selectedModel = models.first }
        }
    }

    private func deploy() {
        guard let model = selectedModel else { return }
        isDeploying = true
        Task {
            await cluster.deploy(model: model, mode: mode, flags: flags, serve: serve)
            isDeploying = false
            dismiss()
        }
    }
}

/// Display strings for the deploy sheet and deployment badges — UI-side so
/// VMDCore stays presentation-free.
private extension ClusterServeMode {
    var title: String {
        switch self {
        case .pipelineParallel: "Pipeline Parallel"
        case .dataParallel: "Data Parallel"
        }
    }

    var badge: String {
        switch self {
        case .pipelineParallel: "PP"
        case .dataParallel: "DP"
        }
    }

    var summary: String {
        switch self {
        case .pipelineParallel: "Splits one model's layers across the cluster's Macs — serves a model bigger than any one of them."
        case .dataParallel: "One full copy per Mac behind a single endpoint — multiplies throughput for a model that already fits."
        }
    }
}

#Preview {
    NavigationStack { ClusterView() }
        .environment(ServeController())
        .environment(ClusterController())
        .environment(AppNavigation())
}

import SwiftUI
import VMDCore

/// Developer surface (LM Studio-style): running deployments in a sidebar,
/// with the selected server's OpenAI-compatible address, live log, and
/// endpoints on the right for wiring up other apps.
struct ServerView: View {
    @Environment(ServeController.self) private var serve
    @State private var selection: ServeDeployment.ID?
    @State private var showFlags = false
    @State private var showDeploy = false

    var body: some View {
        HSplitView {
            sidebar
                .frame(minWidth: 210, idealWidth: 240, maxWidth: 320, maxHeight: .infinity)
            detail
                .frame(minWidth: 400, maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle("Server")
        .toolbar {
            Button { showFlags = true } label: {
                Image(systemName: "gearshape")
            }
            .help("Serve configuration (vLLM flags)")
        }
        .sheet(isPresented: $showFlags) {
            ServeFlagsSheet(flags: serve.flags) { serve.applyFlags($0) }
        }
        .sheet(isPresented: $showDeploy) {
            DeploySheet(flags: serve.flags) { started in selection = started.id }
        }
        .onAppear {
            // Debug/UI-test hooks: `-VMDShowFlagsSheet YES` / `-VMDShowDeploySheet YES`
            // open the respective sheet on launch.
            if UserDefaults.standard.bool(forKey: "VMDShowFlagsSheet") { showFlags = true }
            if UserDefaults.standard.bool(forKey: "VMDShowDeploySheet") { showDeploy = true }
        }
        .task {
            if selection == nil { selection = serve.deployments.first?.id }
        }
        // A stopped deployment is reaped from the list — don't leave the
        // sidebar selection pointing at it (the pane would silently show a
        // different deployment with no row highlighted).
        .onChange(of: serve.deployments.map(\.id)) { _, ids in
            if let selection, !ids.contains(selection) {
                self.selection = ids.first
            }
        }
    }

    // MARK: Sidebar

    private var sidebar: some View {
        List(selection: $selection) {
            Section {
                if serve.deployments.isEmpty {
                    Text("No models running")
                        .foregroundStyle(.secondary)
                        .scaledFont(.callout)
                }
                ForEach(serve.deployments) { deployment in
                    HStack(spacing: 7) {
                        Circle()
                            .fill(statusColor(deployment))
                            .frame(width: 7, height: 7)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(shortName(deployment.servedModelName ?? deployment.model))
                                .lineLimit(1).truncationMode(.middle)
                            Text(verbatim: ":\(deployment.port)")
                                .scaledFont(.caption2).foregroundStyle(.secondary).monospacedDigit()
                        }
                    }
                    .tag(deployment.id)
                    .contextMenu {
                        if deployment.isRestartable {
                            Button { serve.start(deployment) } label: {
                                Label("Start", systemImage: "play")
                            }
                        } else {
                            Button { serve.stop(deployment) } label: {
                                Label("Stop", systemImage: "stop")
                            }
                            .disabled(deployment.isStopping)
                        }
                        Divider()
                        Button(role: .destructive) { serve.remove(deployment) } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                }
            } header: {
                HStack {
                    Text("Deployments")
                    Spacer()
                    // Deploy another model without leaving the page.
                    Button {
                        showDeploy = true
                    } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(.primary)
                            .padding(7)
                    }
                    .buttonStyle(.plain)
                    .fixedSize()
                    // Round Liquid-Glass button (Capsule over square content = circle).
                    .glassCapsule(interactive: true)
                    .pointingHandCursor()
                    .help("Deploy a model")
                }
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
    }

    private func shortName(_ model: String) -> String {
        model.split(separator: "/").last.map(String.init) ?? model
    }

    private func statusColor(_ deployment: ServeDeployment) -> Color {
        if deployment.isRunning { return .green }
        if deployment.isStarting || deployment.isStopping { return .orange }
        if deployment.isFailed { return .red }
        return .secondary
    }

    // MARK: Detail

    private var detail: some View {
        ServerDetail(
            deployment: serve.deployments.first(where: { $0.id == selection }) ?? serve.deployments.first
        )
    }
}

// MARK: - Server detail

/// One deployment's address, a paste-ready example, and its endpoints.
private struct ServerDetail: View {
    let deployment: ServeDeployment?

    @Environment(ServeController.self) private var serve
    @Environment(AppNavigation.self) private var navigation

    private var baseURL: String? {
        deployment.map { "http://127.0.0.1:\($0.port)/v1" }
    }

    /// The engine binds every interface, so the LAN address works for other
    /// devices on the same network. Resolved once per appearance, not per
    /// render — the log stream re-evaluates this view every ~80ms.
    @State private var lanIP: String?
    @State private var showConfiguration = false

    private var networkURL: String? {
        guard let port = deployment?.port, let ip = lanIP else { return nil }
        return "http://\(ip):\(port)/v1"
    }

    /// This Mac's primary IPv4 on an `en*` interface (Wi-Fi/Ethernet), if any.
    /// Lowest interface number wins (numerically — en2 beats en10); self-
    /// assigned 169.254.* addresses are useless to other devices and skipped.
    private static func primaryIPv4() -> String? {
        var addrs: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&addrs) == 0, let first = addrs else { return nil }
        defer { freeifaddrs(addrs) }
        var best: (number: Int, ip: String)?
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let interface = pointer.pointee
            guard let sa = interface.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET) else { continue }
            let name = String(cString: interface.ifa_name)
            guard name.hasPrefix("en"), let number = Int(name.dropFirst(2)) else { continue }
            let sin = UnsafeRawPointer(sa).assumingMemoryBound(to: sockaddr_in.self).pointee
            var addr = sin.sin_addr
            guard let cString = inet_ntoa(addr) else { continue }
            _ = addr
            let ip = String(cString: cString)
            guard !ip.hasPrefix("169.254.") else { continue }
            if best == nil || number < best!.number { best = (number, ip) }
        }
        return best?.ip
    }

    /// The grouped-form look, hand-built: a grouped Form caps its own content
    /// width, which left half the window empty at fullscreen. Custom cards keep
    /// the styling but let the page adapt — one column in small windows (with
    /// slim margins), and a side-by-side layout with a full-height log when
    /// there's room.
    var body: some View {
        GeometryReader { geo in
            if deployment != nil && geo.size.width >= 1350 {
                wideLayout(width: geo.size.width)
            } else {
                narrowLayout
            }
        }
        .task { lanIP = Self.primaryIPv4() }
        .sheet(isPresented: $showConfiguration) {
            if let deployment {
                // Editing a live deployment's config promises a restart —
                // the sheet's primary button reads "Redeploy" once changed.
                ServeFlagsSheet(
                    flags: deployment.flags ?? serve.flags,
                    changedActionTitle: deployment.isRestartable ? nil : "Redeploy"
                ) { newFlags in
                    serve.update(deployment, flags: newFlags)
                }
            }
        }
    }

    private var narrowLayout: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.xl) {
                serverInfo
                if deployment != nil { logPanel(fixedHeight: 300) }
                exampleBlock
                apiBlock
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Theme.Spacing.xl)
            .pageWidth(max: 1300)
        }
    }

    /// Fullscreen-friendly: reference on the left, the live log filling the
    /// window's full height on the right. At in-between widths the reference
    /// column shrinks first — the log is the live panel, so it gets the room.
    private func wideLayout(width: CGFloat) -> some View {
        HStack(alignment: .top, spacing: Theme.Spacing.xl) {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Spacing.xl) {
                    serverInfo
                    exampleBlock
                    apiBlock
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, Theme.Spacing.xl)
            }
            .frame(width: max(560, min(860, width * 0.42)))

            logPanel(fixedHeight: nil)
                .frame(maxWidth: 1500)
                .padding(.vertical, Theme.Spacing.xl)
        }
        .padding(.horizontal, Theme.Spacing.xl)
        .pageWidth(max: 2500)
    }

    // MARK: Cards

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

    @ViewBuilder
    private var serverInfo: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            sectionTitle("vLLM Server")
            if let deployment, let baseURL {
                card {
                    row("Status") {
                        if deployment.isStarting { ProgressView().controlSize(.mini) }
                        Text("\(deployment.statusText) — \(deployment.servedModelName ?? deployment.model)")
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Button {
                            showConfiguration = true
                        } label: {
                            Image(systemName: "gearshape")
                        }
                        .controlSize(.small)
                        .help("Configuration for this deployment")
                        if deployment.isRestartable {
                            Button("Start") { serve.start(deployment) }
                                .controlSize(.small)
                                .buttonStyle(.borderedProminent)
                        } else {
                            Button("Stop", role: .destructive) { serve.stop(deployment) }
                                .controlSize(.small)
                                .disabled(deployment.isStopping)
                        }
                    }
                    rowDivider
                    row("Base URL") { CopyableURL(url: baseURL) }
                    if let networkURL {
                        rowDivider
                        row("Network URL") { CopyableURL(url: networkURL) }
                    }
                }
                Text("OpenAI-compatible API. Base URL is this Mac; the Network URL works for other devices on your network (consider setting an API key in Serve Configuration when sharing). Each running model has its own port.")
                    .scaledFont(.caption)
                    .foregroundStyle(.secondary)
            } else {
                card {
                    HStack(spacing: Theme.Spacing.s) {
                        Text("No models running — start one from the sidebar's + or in Chat.")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Open Chat") { navigation.section = .chat }
                    }
                    .padding(14)
                }
            }
        }
    }

    /// This deployment's own engine output. `fixedHeight: nil` → fill the
    /// available height (the wide layout's right pane).
    private func logPanel(fixedHeight: CGFloat?) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            HStack {
                sectionTitle("Log")
                if deployment?.isStarting == true { ProgressView().controlSize(.mini) }
                Spacer()
                Button {
                    Pasteboard.copy((deployment?.logs ?? []).map(\.text).joined(separator: "\n"))
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(.plain)
                .controlSize(.small)
                .help("Copy log")
                .disabled(deployment?.logs.isEmpty ?? true)
            }
            EngineLogView(lines: deployment?.logs ?? [])
                // Fresh identity per deployment: switching in the sidebar
                // re-runs onAppear and snaps to that log's tail.
                .id(deployment?.id)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .frame(height: fixedHeight)
                .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }

    /// A ready-to-paste request. Also shown with no deployment — curlExample
    /// then falls back to the default port and the last-typed model.
    private var exampleBlock: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            sectionTitle("Example Request")
            CodeBlock(language: "bash", code: curlExample)
        }
    }

    private var curlExample: String {
        """
        curl \(baseURL ?? "http://127.0.0.1:\(ServeFlags.defaultServerPort)/v1")/chat/completions \\
          -H "Content-Type: application/json" \\
          -d '{
            "model": "\(deployment.map { $0.servedModelName ?? $0.model } ?? serve.modelInput)",
            "messages": [{"role": "user", "content": "Hello!"}]
          }'
        """
    }

    /// Swagger's functionality in native clothes: expandable endpoints with
    /// editable try-it requests while the server runs, plain reference when not.
    private var apiBlock: some View {
        APIExplorer(
            baseURL: deployment.flatMap { $0.isRunning ? "http://127.0.0.1:\($0.port)" : nil },
            model: deployment.map { $0.servedModelName ?? $0.model } ?? serve.modelInput
        )
    }
}

/// A monospaced URL with a copy button that flips to a checkmark.
private struct CopyableURL: View {
    let url: String
    @State private var copied = false

    var body: some View {
        HStack(spacing: Theme.Spacing.s) {
            Text(url)
                .scaledFont(.callout, design: .monospaced)
                .textSelection(.enabled)
                .lineLimit(1)
                .truncationMode(.middle)
            Button {
                Pasteboard.copy(url)
                copied = true
                Task { try? await Task.sleep(for: .seconds(1.2)); copied = false }
            } label: {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .pointingHandCursor()
            .help("Copy")
        }
    }
}

#Preview {
    NavigationStack { ServerView() }
        .environment(ServeController())
        .environment(AppNavigation())
}

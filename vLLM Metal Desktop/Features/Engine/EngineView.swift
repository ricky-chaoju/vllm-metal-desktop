import SwiftUI
import VMDCore

/// The engine management surface: preflight checklist, install state, installed
/// vs. available version, and a one-click install/update with a live log.
/// Engine updates are independent of app updates (docs/PLAN.md §4).
struct EngineView: View {
    @State private var vm = EngineViewModel()
    @Environment(ServeController.self) private var serve
    @Environment(\.openURL) private var openURL
    @State private var showUninstallConfirm = false
    // Optional: absent in previews. Kept in sync so the window-toolbar badge
    // reflects this page's fresher knowledge (checks and finished installs).
    @Environment(EngineUpdateMonitor.self) private var updateMonitor: EngineUpdateMonitor?

    var body: some View {
        Form {
            if !serve.deployments.isEmpty {
                runningModelSection
            }
            preflightSection
            statusSection
            updatesSection
            if vm.isBusy || !vm.logLines.isEmpty {
                logSection
            }
            actionSection
            githubFooter
        }
        .formStyle(.grouped)
        // Let the shared AppBackground glow through, matching Chat/Models.
        .scrollContentBackground(.hidden)
        .pageWidth()
        .navigationTitle("Engine")
        .task {
            await vm.refresh()
            updateMonitor?.reconcile(installed: vm.installedVersion, latest: vm.latestRelease?.version)
        }
        .onChange(of: vm.phase) { _, phase in
            // A finished install changes the installed version; clear/refresh the badge.
            if phase == .completed {
                updateMonitor?.reconcile(installed: vm.installedVersion, latest: vm.latestRelease?.version)
            }
        }
        .toolbar {
            Button {
                Task {
                    await vm.refresh(forceUpdateCheck: true)
                    updateMonitor?.reconcile(installed: vm.installedVersion, latest: vm.latestRelease?.version)
                }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .help("Re-run checks and refresh releases")
            .disabled(vm.isBusy)
        }
    }

    // MARK: Running model (shared with Chat)

    private var runningModelSection: some View {
        Section("Running Models") {
            ForEach(serve.runningDeployments) { deployment in
                HStack(spacing: Theme.Spacing.s) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(deployment.servedModelName ?? deployment.model)
                            .lineLimit(1).truncationMode(.middle)
                        Text("\(deployment.statusText) · port \(String(deployment.port))")
                            .scaledFont(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Stop", role: .destructive) { serve.stop(deployment) }
                        .controlSize(.small)
                        .disabled(deployment.isStopping)
                }
            }
        }
    }

    // MARK: Preflight

    private var preflightSection: some View {
        Section {
            if vm.preflight.isEmpty && vm.isCheckingPreflight {
                HStack { ProgressView().controlSize(.small); Text("Checking system…") }
            }
            ForEach(vm.preflight) { item in
                PreflightRow(item: item) { fix in
                    Task { await vm.runFix(fix) }
                }
            }
        } header: {
            Text("System Requirements")
        }
    }

    // MARK: Status

    private var statusSection: some View {
        Section("Engine") {
            LabeledContent("Status") {
                Label(
                    vm.isInstalled ? "Installed" : "Not installed",
                    systemImage: vm.isInstalled ? "checkmark.seal.fill" : "exclamationmark.triangle.fill"
                )
                .foregroundStyle(vm.isInstalled ? Color.green : Color.orange)
            }
            LabeledContent("Installed version", value: vm.installedVersion?.description ?? "—")
            LabeledContent("vLLM core", value: vm.installedCoreVersion?.description ?? "—")
            LabeledContent("Location") {
                Text(EnginePaths.standard.venvRoot.path)
                    .scaledFont(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
    }

    // MARK: Updates

    /// Releases feed: checked automatically, with a version picker and the selected
    /// release's changes and contributors (mirroring the GitHub releases page).
    @ViewBuilder
    private var updatesSection: some View {
        Section {
            if (vm.isCheckingUpdates || !vm.hasCompletedUpdateCheck) && vm.releases.isEmpty {
                HStack(spacing: Theme.Spacing.s) {
                    ProgressView().controlSize(.small)
                    Text("Checking for updates…").foregroundStyle(.secondary)
                }
            } else if let updateError = vm.updateError, vm.releases.isEmpty {
                Label(updateError, systemImage: "wifi.exclamationmark")
                    .scaledFont(.callout)
                    .foregroundStyle(.red)
                Button("Retry") { Task { await vm.checkForUpdates(force: true) } }
            } else if vm.releases.isEmpty {
                // Successful check, zero releases (e.g. none published yet).
                Label("No releases found on GitHub.", systemImage: "shippingbox")
                    .scaledFont(.callout)
                    .foregroundStyle(.secondary)
                Button("Check Again") { Task { await vm.checkForUpdates(force: true) } }
            } else {
                LabeledContent("Latest") {
                    HStack(spacing: Theme.Spacing.s) {
                        Text(vm.latestRelease?.version?.description ?? vm.latestRelease?.tag ?? "—")
                        if vm.updateAvailable {
                            Text("Update available")
                                .scaledFont(.caption2, weight: .semibold)
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(Color.accentColor, in: Capsule())
                                .foregroundStyle(.white)
                        } else if vm.isInstalled, vm.installedVersion == vm.latestRelease?.version {
                            Text("Up to date")
                                .scaledFont(.caption2, weight: .semibold)
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(Color.green.opacity(0.2), in: Capsule())
                                .foregroundStyle(.green)
                        }
                    }
                }

                Picker("Version to install", selection: versionSelection) {
                    ForEach(vm.releases) { release in
                        Text(releaseLabel(release)).tag(release.tag)
                    }
                }
                .pickerStyle(.menu)
                .disabled(vm.isBusy)

                if let release = vm.selectedRelease {
                    ReleaseDetails(release: release, installedVersion: vm.installedVersion)
                        .id(release.tag) // fresh disclosure state per release
                }
            }
        } header: {
            Text("Updates")
        } footer: {
            if vm.updateError != nil && !vm.releases.isEmpty {
                Text("Couldn't refresh releases — showing the last loaded list.")
            }
        }
    }

    /// Picker binding: selection is the selected release's tag, defaulting to latest.
    private var versionSelection: Binding<String> {
        Binding(
            get: { vm.selectedRelease?.tag ?? "" },
            set: { vm.selectedTag = $0 }
        )
    }

    private func releaseLabel(_ release: ReleaseInfo) -> String {
        var label = release.version?.description ?? release.tag
        if release.tag == vm.latestRelease?.tag { label += "  · latest" }
        if let version = release.version, version == vm.installedVersion { label += "  · installed" }
        return label
    }

    // MARK: Log

    private var logSection: some View {
        Section {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(vm.logLines) { line in
                            Text(line.text)
                                .scaledFont(.caption, design: .monospaced)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id(line.id)
                        }
                    }
                    .padding(.vertical, Theme.Spacing.xs)
                }
                .frame(height: 220)
                .onChange(of: vm.logLines.last?.id) { _, lastID in
                    if let lastID { proxy.scrollTo(lastID, anchor: .bottom) }
                }
            }
        } header: {
            HStack {
                Text("Log")
                Spacer()
                Button {
                    Pasteboard.copy(vm.logLines.map(\.text).joined(separator: "\n"))
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .disabled(vm.logLines.isEmpty)
            }
            .textCase(nil)
        }
    }

    // MARK: GitHub footer

    /// A quiet home link for the engine project, GitHub-mark style.
    private var githubFooter: some View {
        Section {
            EmptyView()
        } footer: {
            Button {
                if let url = URL(string: "https://github.com/vllm-project/vllm-metal") { openURL(url) }
            } label: {
                HStack(spacing: 6) {
                    Image("GitHubMark")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 14, height: 14)
                    Text("vllm-project/vllm-metal")
                        .scaledFont(.callout)
                    Image(systemName: "arrow.up.right")
                        .scaledFont(.caption2)
                }
                .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .pointingHandCursor()
            .help("Open the vllm-metal repository on GitHub")
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.top, 4)
        }
    }

    // MARK: Action

    @ViewBuilder
    private var actionSection: some View {
        Section {
            switch vm.phase {
            case .running(let title, let index, let total):
                VStack(alignment: .leading, spacing: Theme.Spacing.s) {
                    HStack(spacing: Theme.Spacing.s) {
                        ProgressView().controlSize(.small)
                        Text("Step \(min(index + 1, total)) of \(total): \(title)")
                            .scaledFont(.callout)
                    }
                    ProgressView(value: Double(index), total: Double(max(total, 1)))
                }
            case .failed(let message):
                Label(message, systemImage: "xmark.octagon.fill")
                    .foregroundStyle(.red)
                    .scaledFont(.callout)
            case .completed:
                Label("Engine installed.", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            case .idle:
                EmptyView()
            }

            Button {
                Task { await vm.installOrUpdate() }
            } label: {
                Text(vm.primaryActionTitle)
                    .frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
            .disabled(!vm.preflightPassed || vm.isBusy)

            if vm.isInstalled {
                Button("Rebuild from Scratch…") {
                    Task { await vm.rebuild() }
                }
                .disabled(!vm.preflightPassed || vm.isBusy)

                Button("Uninstall Engine…", role: .destructive) {
                    showUninstallConfirm = true
                }
                .disabled(vm.isBusy || !serve.deployments.isEmpty)
                .help(serve.deployments.isEmpty
                      ? "Remove the engine (~/.venv-vllm-metal). Downloaded models stay."
                      : "Stop all running models first.")
                .confirmationDialog(
                    "Uninstall the engine?",
                    isPresented: $showUninstallConfirm,
                    titleVisibility: .visible
                ) {
                    Button("Uninstall", role: .destructive) {
                        Task { await vm.uninstall() }
                    }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("Removes ~/.venv-vllm-metal. Downloaded models are kept and reused when you reinstall. Setup will run again on next launch.")
                }
            }
        } footer: {
            if !vm.preflightPassed {
                Text("Resolve the system requirements above to enable installation.")
            } else {
                Text("First install downloads ~2–3 GB and compiles vLLM core (several minutes). Engine updates are separate from app updates.")
            }
        }
    }
}

/// The selected release, presented like its GitHub releases entry: publication
/// date, the merged changes with author attribution, and a contributors row.
private struct ReleaseDetails: View {
    let release: ReleaseInfo
    let installedVersion: EngineVersion?

    @Environment(\.openURL) private var openURL

    /// Changes shown before collapsing behind "+N more".
    private static let maxVisibleChanges = 5
    @State private var showAllChanges = false

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.m) {
            HStack(spacing: Theme.Spacing.s) {
                if let date = release.publishedAt {
                    Text(date, format: .relative(presentation: .named))
                        .foregroundStyle(.secondary)
                }
                if release.isPrerelease {
                    Text("Pre-release")
                        .scaledFont(.caption2, weight: .semibold)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Color.orange.opacity(0.2), in: Capsule())
                        .foregroundStyle(.orange)
                }
                Spacer()
                if let url = release.htmlURL {
                    Button {
                        openURL(url)
                    } label: {
                        HStack(spacing: 4) {
                            Text("View on GitHub")
                            Image(systemName: "arrow.up.right")
                        }
                        .scaledFont(.callout)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.accentColor)
                    .pointingHandCursor()
                }
            }
            .scaledFont(.callout)

            if release.changes.isEmpty {
                Text("No change notes for this release.")
                    .scaledFont(.callout)
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: Theme.Spacing.s) {
                    ForEach(visibleChanges) { change in
                        changeRow(change)
                    }
                    if release.changes.count > Self.maxVisibleChanges {
                        Button {
                            withAnimation(.easeInOut(duration: 0.15)) { showAllChanges.toggle() }
                        } label: {
                            Text(showAllChanges
                                 ? "Show fewer"
                                 : "+\(release.changes.count - Self.maxVisibleChanges) more changes")
                                .scaledFont(.caption)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(Color.accentColor)
                        .pointingHandCursor()
                    }
                }

                contributorsRow
            }
        }
        .padding(.vertical, 2)
    }

    private var visibleChanges: [ReleaseChange] {
        showAllChanges ? release.changes : Array(release.changes.prefix(Self.maxVisibleChanges))
    }

    private func changeRow(_ change: ReleaseChange) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.s) {
            GitHubAvatar(login: change.author, size: 16)
                .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 3 }
            Text(change.summary)
                .scaledFont(.callout)
                .lineLimit(2)
            Spacer(minLength: 4)
            if let pr = change.pullRequestURL, let number = change.pullRequestNumber {
                Button {
                    openURL(pr)
                } label: {
                    Text("#\(number)")
                        .scaledFont(.caption, design: .monospaced)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .pointingHandCursor()
                .help("Open pull request by @\(change.author)")
            }
        }
    }

    /// Contributor chips shown before collapsing into "+N".
    private static let visibleContributors = 5

    private var contributorsRow: some View {
        let logins = release.contributors
        let shown = Array(logins.prefix(Self.visibleContributors))
        return HStack(spacing: Theme.Spacing.s) {
            Text("Contributors")
                .scaledFont(.caption)
                .foregroundStyle(.secondary)
            ForEach(shown, id: \.self) { login in
                Button {
                    if let url = URL(string: "https://github.com/\(login)") { openURL(url) }
                } label: {
                    HStack(spacing: 4) {
                        GitHubAvatar(login: login, size: 18)
                        Text("@\(login)").scaledFont(.caption).lineLimit(1).fixedSize()
                    }
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .pointingHandCursor()
                .help("Open @\(login) on GitHub")
            }
            if logins.count > shown.count {
                Text("+\(logins.count - shown.count)")
                    .scaledFont(.caption)
                    .foregroundStyle(.secondary)
                    .help(logins.dropFirst(shown.count).map { "@\($0)" }.joined(separator: ", "))
            }
        }
    }
}

/// A GitHub user's avatar, loaded straight from github.com (no API quota).
/// Backed by an in-memory store so one login is fetched once, not per row, and
/// re-selecting a release doesn't flash placeholders.
private struct GitHubAvatar: View {
    let login: String
    var size: CGFloat = 18

    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().scaledToFill()
            } else {
                Circle().fill(.quaternary)
                    .overlay(
                        Text(login.prefix(1).uppercased())
                            .font(.system(size: size * 0.55, weight: .semibold))
                            .foregroundStyle(.secondary)
                    )
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .task(id: login) { image = await GitHubAvatarStore.shared.image(for: login) }
    }
}

/// One in-flight request and one cached image per login, app-wide.
@MainActor
private final class GitHubAvatarStore {
    static let shared = GitHubAvatarStore()
    private var cache: [String: NSImage] = [:]
    private var inFlight: [String: Task<NSImage?, Never>] = [:]

    func image(for login: String) async -> NSImage? {
        if let hit = cache[login] { return hit }
        if let pending = inFlight[login] { return await pending.value }
        let fetch = Task<NSImage?, Never> {
            guard let url = URL(string: "https://github.com/\(login).png?size=80"),
                  let (data, _) = try? await URLSession.shared.data(from: url) else { return nil }
            return NSImage(data: data)
        }
        inFlight[login] = fetch
        let image = await fetch.value
        inFlight[login] = nil
        if let image { cache[login] = image }
        return image
    }
}

/// One preflight checklist row with an optional one-click fix.
private struct PreflightRow: View {
    let item: PreflightItem
    let onFix: (ProcessLaunch) -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.s) {
            Image(systemName: item.status.isOK ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(item.status.isOK ? Color.green : Color.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                if let reason = failureReason {
                    Text(reason).scaledFont(.caption).foregroundStyle(.secondary)
                } else if let detail = item.detail {
                    Text(detail).scaledFont(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if !item.status.isOK, let fix = item.fix {
                Button("Fix") { onFix(fix) }
                    .controlSize(.small)
            }
        }
    }

    private var failureReason: String? {
        if case .failed(let reason) = item.status { return reason }
        return nil
    }
}

#Preview {
    NavigationStack { EngineView() }
        .environment(ServeController())
}

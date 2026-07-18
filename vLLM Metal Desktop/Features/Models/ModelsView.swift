import SwiftUI
import VMDCore

/// HuggingFace model browser: filterable search (All / MLX / GGUF / on-this-Mac)
/// on the left, a model card with VRAM-fit guidance and a Download action on the
/// right. Running happens in Chat after a model is downloaded (docs/PLAN.md §5).
struct ModelsView: View {
    @Environment(ServeController.self) private var serve
    @Environment(AppNavigation.self) private var navigation
    @State private var vm = ModelsViewModel()

    var body: some View {
        HSplitView {
            sidebar
                .frame(minWidth: 230, idealWidth: 280, maxWidth: 360, maxHeight: .infinity)
            detail
                .frame(minWidth: 360, maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle("Models")
        .task {
            await vm.loadInitial()
            // Debug/UI-test hook: `-VMDAutoDownload org/model` selects the model
            // and starts a download on launch (screenshot verification of live
            // progress).
            if let id = UserDefaults.standard.string(forKey: "VMDAutoDownload"), vm.downloadingModel == nil {
                vm.selectedID = id
                vm.download(id)
            }
        }
        .toolbar {
            Button {
                Task { vm.refreshLocal(); await vm.search() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .help("Reload models")
            .disabled(vm.isSearching)
        }
    }

    // MARK: Sidebar

    private var sidebar: some View {
        @Bindable var vm = vm
        return VStack(spacing: 0) {
            HStack(spacing: Theme.Spacing.s) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary).scaledFont(.caption)
                    TextField("Search Hugging Face", text: $vm.query)
                        .textFieldStyle(.plain)
                        .onSubmit { Task { await vm.search() } }
                }
                .padding(.horizontal, 11).padding(.vertical, 7)
                .glassCapsule()
                .onChange(of: vm.query) { _, _ in vm.queryChanged() }

                Menu {
                    ForEach(ModelsViewModel.Filter.allCases) { option in
                        Button {
                            vm.filter = option
                            Task { await vm.search() }
                        } label: {
                            if vm.filter == option { Label(option.rawValue, systemImage: "checkmark") }
                            else { Label(option.rawValue, systemImage: option.systemImage) }
                        }
                    }
                } label: {
                    Image(systemName: vm.filter.systemImage)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Filter: \(vm.filter.rawValue)")
            }
            .padding(.horizontal, Theme.Spacing.s)
            .frame(height: 48)

            Divider()

            if vm.isSearching {
                Spacer(); ProgressView(); Spacer()
            } else if let error = vm.errorText {
                ContentUnavailableView("Search failed", systemImage: "wifi.exclamationmark", description: Text(error))
            } else {
                List(selection: $vm.selectedID) {
                    ForEach(vm.results) { model in
                        ModelRow(model: model, isLocal: vm.isLocal(model.id)).tag(model.id)
                    }
                }
                .task(id: vm.selectedID) {
                    if let id = vm.selectedID { await vm.loadInfo(for: id) }
                }
                .listStyle(.sidebar)
                .scrollContentBackground(.hidden)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    // MARK: Detail

    @ViewBuilder
    private var detail: some View {
        if vm.isLoadingInfo {
            ProgressView("Loading model…")
        } else if let info = vm.info {
            ModelCard(
                info: info,
                fit: vm.fit(for: info),
                hardware: vm.hardware,
                isLocal: vm.isLocal(info.id),
                isDownloading: vm.downloadingModel == info.id,
                downloadProgress: vm.downloadProgress,
                downloadSpeed: vm.downloadSpeed,
                downloadPercent: vm.downloadPercent,
                canDownload: vm.engineInstalled && vm.downloadingModel == nil,
                engineInstalled: vm.engineInstalled,
                onDownload: { vm.download(info.id) },
                onCancel: { vm.cancelDownload() },
                onUseInChat: {
                    // Chat no longer deploys — start the engine here, then chat.
                    serve.modelInput = info.id
                    serve.run()
                    navigation.section = .chat
                },
                onDelete: { vm.deleteLocal(info.id) }
            )
        } else {
            ContentUnavailableView {
                Label("Select a Model", systemImage: "square.stack.3d.up")
            } description: {
                Text("Pick a model to see its size, whether it fits this Mac, and download it.")
            }
        }
    }
}

// MARK: - Org avatar

struct OrgAvatar: View {
    let modelID: String
    var size: CGFloat = 24

    @State private var imageURL: URL?

    private var org: String { modelID.split(separator: "/").first.map(String.init) ?? "?" }

    var body: some View {
        Group {
            if let imageURL {
                AsyncImage(url: imageURL) { phase in
                    if let image = phase.image { image.resizable().scaledToFill() }
                    else { fallback }
                }
            } else {
                fallback
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.28, style: .continuous))
        .task(id: org) { await resolve() }
    }

    private var fallback: some View {
        RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
            .fill(Color.accentColor.opacity(0.22))
            .overlay(
                Text(org.prefix(1).uppercased())
                    .font(.system(size: size * 0.5, weight: .bold))
                    .foregroundStyle(Color.accentColor)
            )
    }

    private func resolve() async {
        let cached = OrgAvatarCache.shared.lookup(org)
        if cached.hit { imageURL = cached.url; return }
        let url = await HuggingFaceClient().organizationAvatarImageURL(forModelID: modelID)
        OrgAvatarCache.shared.store(url, for: org)
        imageURL = url
    }
}

/// In-memory cache so each org avatar is resolved once, not per row.
@MainActor
final class OrgAvatarCache {
    static let shared = OrgAvatarCache()
    private var cache: [String: URL?] = [:]

    func lookup(_ org: String) -> (hit: Bool, url: URL?) {
        if let value = cache[org] { return (true, value) }
        return (false, nil)
    }

    func store(_ url: URL?, for org: String) { cache[org] = url }
}

// MARK: - Rows & card

private struct ModelRow: View {
    let model: HFModelSummary
    let isLocal: Bool

    private var name: String { model.id.split(separator: "/").last.map(String.init) ?? model.id }
    private var org: String { model.id.split(separator: "/").first.map(String.init) ?? "" }

    var body: some View {
        HStack(spacing: Theme.Spacing.s) {
            OrgAvatar(modelID: model.id, size: 26)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(name).scaledFont(.callout, weight: .medium).lineLimit(1).truncationMode(.middle)
                    if isLocal {
                        Text("Downloaded")
                            .font(.system(size: 9, weight: .semibold))
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Color.green.opacity(0.2), in: Capsule())
                            .foregroundStyle(.green)
                    }
                }
                HStack(spacing: 8) {
                    Text(org).lineLimit(1)
                    Spacer(minLength: 4)
                    if let downloads = model.downloads {
                        Label(Format.count(downloads), systemImage: "arrow.down.circle")
                    }
                }
                .scaledFont(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 3)
    }
}

private struct ModelCard: View {
    let info: HFModelInfo
    let fit: ModelsViewModel.Fit?
    let hardware: HardwareInfo
    let isLocal: Bool
    let isDownloading: Bool
    let downloadProgress: String
    let downloadSpeed: String
    let downloadPercent: Double?
    let canDownload: Bool
    let engineInstalled: Bool
    let onDownload: () -> Void
    let onCancel: () -> Void
    let onUseInChat: () -> Void
    let onDelete: () -> Void

    @Environment(\.openURL) private var openURL
    @State private var showDeleteConfirm = false
    @State private var readme: String?
    @State private var readmeLoading = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.l) {
                header
                actionArea
                badges
                vramCard
                if !info.tags.isEmpty { tagsView }
                readmeSection
            }
            .padding(Theme.Spacing.l)
            .frame(maxWidth: .infinity, alignment: .leading)
            .pageWidth(max: 1300)
        }
        .task(id: info.id) { await loadReadme() }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: Theme.Spacing.m) {
            OrgAvatar(modelID: info.id, size: 44)
            VStack(alignment: .leading, spacing: Theme.Spacing.s) {
                Button {
                    if let url = URL(string: "https://huggingface.co/\(info.id)") { openURL(url) }
                } label: {
                    HStack(spacing: 6) {
                        Text(info.id).scaledFont(.title2, weight: .semibold)
                        Image(systemName: "arrow.up.right").scaledFont(.callout).foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)
                .pointingHandCursor()
                .help("Open on Hugging Face")
                HStack(spacing: 16) {
                    if let downloads = info.downloads {
                        Label(Format.count(downloads), systemImage: "arrow.down.circle")
                    }
                    if let likes = info.likes {
                        Label(Format.count(likes), systemImage: "heart")
                    }
                    if let params = info.parameterCount {
                        Label(Format.params(params), systemImage: "number")
                    }
                }
                .scaledFont(.callout)
                .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var actionArea: some View {
        if isDownloading {
            VStack(alignment: .leading, spacing: Theme.Spacing.s) {
                HStack(spacing: Theme.Spacing.s) {
                    if let percent = downloadPercent {
                        ProgressView(value: percent, total: 100)
                            // Glide between byte updates so the bar advances continuously.
                            .animation(.linear(duration: 0.5), value: downloadPercent)
                        Text(String(format: "%.0f%%", percent))
                            .monospacedDigit().foregroundStyle(.secondary)
                            .frame(minWidth: 36, alignment: .trailing)
                    } else {
                        ProgressView().controlSize(.small)
                        Spacer()
                    }
                    Button("Cancel", role: .destructive) { onCancel() }
                }
                HStack(spacing: 6) {
                    Text(downloadProgress).lineLimit(1).truncationMode(.middle)
                    if !downloadSpeed.isEmpty {
                        Text("·").foregroundStyle(.tertiary)
                        Text(downloadSpeed).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .scaledFont(.caption, design: .monospaced)
                .foregroundStyle(.secondary)
            }
        } else if isLocal {
            VStack(alignment: .leading, spacing: Theme.Spacing.s) {
                Label("Downloaded — on this Mac", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                HStack(spacing: Theme.Spacing.s) {
                    Button { onUseInChat() } label: {
                        Label("Deploy & Chat", systemImage: "play.fill").frame(maxWidth: .infinity)
                    }
                    .controlSize(.large)
                    .buttonStyle(.borderedProminent)
                    Button(role: .destructive) { showDeleteConfirm = true } label: {
                        Image(systemName: "trash")
                    }
                    .controlSize(.large)
                    .help("Delete from this Mac")
                }
            }
            .confirmationDialog("Delete this model from this Mac?", isPresented: $showDeleteConfirm, titleVisibility: .visible) {
                Button("Delete", role: .destructive) { onDelete() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(info.id)
            }
        } else {
            VStack(alignment: .leading, spacing: Theme.Spacing.s) {
                Button { onDownload() } label: {
                    Label("Download", systemImage: "arrow.down.circle").frame(maxWidth: .infinity)
                }
                .controlSize(.large)
                .buttonStyle(.borderedProminent)
                .disabled(!canDownload)
                if !engineInstalled {
                    Text("Install the engine (Engine tab) to download models.")
                        .scaledFont(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var badges: some View {
        HStack(spacing: Theme.Spacing.s) {
            if let pipeline = info.pipelineTag { Badge(text: pipeline, color: .blue) }
            if info.isMLXReady { Badge(text: "MLX-ready", color: .green) }
            if info.hasGGUF { Badge(text: "GGUF", color: .purple) }
            if info.gated.isGated { Badge(text: "Gated", color: .orange) }
        }
    }

    @ViewBuilder
    private var vramCard: some View {
        GroupBox {
            if let fit {
                VStack(alignment: .leading, spacing: Theme.Spacing.s) {
                    HStack {
                        Circle().fill(fitColor(fit.verdict)).frame(width: 10, height: 10)
                        Text(fitText(fit.verdict)).scaledFont(.headline)
                        Spacer()
                        Text(fit.precision.label)
                            .scaledFont(.caption, weight: .medium)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(.quaternary, in: Capsule())
                    }
                    Text("Estimated \(HardwareInfo.gibString(fit.estimate.totalBytes)) at 4K context · this Mac has \(HardwareInfo.gibString(hardware.metalBudgetBytes ?? hardware.unifiedMemoryBytes)) Metal budget")
                        .scaledFont(.callout).foregroundStyle(.secondary)
                    Divider()
                    breakdownRow("Weights", fit.estimate.weightsBytes)
                    breakdownRow("KV cache", fit.estimate.kvCacheBytes)
                    breakdownRow("Overhead", fit.estimate.overheadBytes)
                }
            } else {
                Text("Model size unknown — can't estimate memory.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        } label: {
            Label("Memory fit", systemImage: "memorychip")
        }
    }

    private func breakdownRow(_ name: String, _ bytes: Int64) -> some View {
        HStack {
            Text(name).foregroundStyle(.secondary)
            Spacer()
            Text(HardwareInfo.gibString(bytes)).monospacedDigit()
        }
        .scaledFont(.callout)
    }

    private var tagsView: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            Text("Tags").scaledFont(.headline)
            Text(info.tags.prefix(20).joined(separator: " · "))
                .scaledFont(.caption).foregroundStyle(.secondary).textSelection(.enabled)
        }
    }

    @ViewBuilder
    private var readmeSection: some View {
        if readmeLoading {
            HStack(spacing: Theme.Spacing.s) {
                ProgressView().controlSize(.small)
                Text("Loading README…").foregroundStyle(.secondary)
            }
            .scaledFont(.callout)
        } else if let readme, !readme.isEmpty {
            VStack(alignment: .leading, spacing: Theme.Spacing.m) {
                Divider()
                Text("README").scaledFont(.headline)
                MarkdownText(text: readme, baseURL: URL(string: "https://huggingface.co/\(info.id)/resolve/main/"))
            }
        }
    }

    private func loadReadme() async {
        readme = nil
        readmeLoading = true
        let text = try? await HuggingFaceClient().readme(id: info.id)
        readmeLoading = false
        if let text {
            readme = String(Self.stripFrontmatter(text).prefix(12000))
        }
    }

    private static func stripFrontmatter(_ text: String) -> String {
        guard text.hasPrefix("---") else { return text }
        let lines = text.components(separatedBy: "\n")
        var index = 1
        while index < lines.count, lines[index].trimmingCharacters(in: .whitespaces) != "---" {
            index += 1
        }
        guard index < lines.count else { return text }
        return lines[(index + 1)...].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func fitColor(_ verdict: FitVerdict) -> Color {
        switch verdict {
        case .fits: .green
        case .tight: .orange
        case .tooLarge: .red
        }
    }

    private func fitText(_ verdict: FitVerdict) -> String {
        switch verdict {
        case .fits: "Fits comfortably"
        case .tight: "Tight fit"
        case .tooLarge: "Too large for this Mac"
        }
    }
}

private struct Badge: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .scaledFont(.caption, weight: .medium)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(color.opacity(0.18), in: Capsule())
            .foregroundStyle(color)
    }
}

private enum Format {
    static func count(_ n: Int) -> String {
        let d = Double(n)
        if d >= 1_000_000 { return String(format: "%.1fM", d / 1_000_000) }
        if d >= 1_000 { return String(format: "%.0fK", d / 1_000) }
        return String(n)
    }

    static func params(_ n: Int) -> String {
        let d = Double(n)
        if d >= 1_000_000_000 { return String(format: "%.1fB", d / 1_000_000_000) }
        if d >= 1_000_000 { return String(format: "%.0fM", d / 1_000_000) }
        return String(n)
    }
}

#Preview {
    NavigationStack { ModelsView() }
        .environment(ServeController())
        .environment(AppNavigation())
}

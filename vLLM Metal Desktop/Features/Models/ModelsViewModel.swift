import Foundation
import Observation
import VMDCore

@MainActor
@Observable
final class ModelsViewModel {
    enum Filter: String, CaseIterable, Identifiable {
        case all = "All"
        case mlx = "MLX-ready"
        case gguf = "GGUF"
        case local = "On this Mac"
        var id: String { rawValue }
        var systemImage: String {
            switch self {
            case .all: "square.stack.3d.up"
            case .mlx: "bolt.fill"
            case .gguf: "shippingbox"
            case .local: "internaldrive"
            }
        }
    }

    private let hf = HuggingFaceClient()
    let hardware = HardwareInfo.current()

    var query = ""
    var filter: Filter = .all
    var results: [HFModelSummary] = []
    var isSearching = false
    var selectedID: String?
    var info: HFModelInfo?
    /// Architecture facts from the repo's raw config.json (GQA heads etc.).
    var modelConfig: HFModelConfig?
    var isLoadingInfo = false
    var errorText: String?

    var localModelIDs: Set<String> = []
    var downloadingModel: String?
    var downloadProgress = ""
    var downloadSpeed = ""
    var downloadPercent: Double?

    private var downloadTask: Task<Void, Never>?
    private var searchGeneration = 0

    var engineInstalled: Bool { ModelDownloader().isAvailable }

    func loadInitial() async {
        refreshLocal()
        if results.isEmpty { await search() }
    }

    func refreshLocal() {
        localModelIDs = Set(LocalModels().cachedModelIDs())
    }

    func isLocal(_ id: String) -> Bool { localModelIDs.contains(id) }

    private var searchDebounce: Task<Void, Never>?

    /// Called on every keystroke — searches after a short idle so results update as
    /// you type without firing a request per character.
    func queryChanged() {
        searchDebounce?.cancel()
        searchDebounce = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(280))
            if Task.isCancelled { return }
            await self?.search()
        }
    }

    func search() async {
        searchGeneration += 1
        let generation = searchGeneration
        isSearching = true
        errorText = nil
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            let found: [HFModelSummary]
            // Pipeline filtering only curates the default (empty-query) browse:
            // a typed search must match by name regardless of modality — VL models
            // are tagged image-text-to-text, not text-generation.
            let curated = q.isEmpty ? ["text-generation"] : []
            switch filter {
            case .all:
                found = try await hf.searchModels(query: q, filters: curated, limit: 40)
            case .mlx:
                found = try await hf.searchModels(query: q, author: "mlx-community", filters: curated, limit: 40)
            case .gguf:
                found = try await hf.searchModels(query: q, filters: ["text-generation", "gguf"], limit: 40)
            case .local:
                refreshLocal()
                found = localModelIDs.sorted()
                    .filter { q.isEmpty || $0.localizedCaseInsensitiveContains(q) }
                    .map { HFModelSummary(id: $0) }
            }
            guard generation == searchGeneration else { return }
            results = found
        } catch {
            guard generation == searchGeneration else { return }
            errorText = String(describing: error)
            results = []
        }
        isSearching = false
    }

    func loadInfo(for id: String) async {
        isLoadingInfo = true
        info = nil
        modelConfig = nil
        // The info API omits architecture facts (layers/heads) — the raw
        // config.json supplies them for an honest memory estimate. Optional:
        // a missing config just means the estimate falls back to heuristics.
        async let loadedInfo = try? hf.modelInfo(id: id)
        async let loadedConfig = try? hf.modelConfig(id: id)
        let (loaded, config) = await (loadedInfo, loadedConfig)
        guard selectedID == id else { return }
        info = loaded
        modelConfig = config
        isLoadingInfo = false
    }

    // MARK: Download

    func download(_ id: String) {
        guard downloadingModel == nil else { return }
        downloadingModel = id
        downloadProgress = "Preparing…"
        downloadSpeed = ""
        downloadPercent = nil
        downloadTask = Task {
            for await event in ModelDownloader().download(modelID: id) {
                if Task.isCancelled { break }
                switch event {
                case .progress(let downloaded, let total, let speed):
                    if total > 0 {
                        downloadPercent = min(100, max(0, Double(downloaded) / Double(total) * 100))
                        downloadProgress = "\(downloaded.formatted(.byteCount(style: .file))) / \(total.formatted(.byteCount(style: .file)))"
                    } else {
                        downloadPercent = nil
                        downloadProgress = "Preparing…"
                    }
                    downloadSpeed = speed > 0 ? "\(speed.formatted(.byteCount(style: .file)))/s" : ""
                case .finished:
                    refreshLocal()
                    downloadPercent = 100
                    downloadProgress = "Downloaded"
                    downloadSpeed = ""
                case .failed(let reason):
                    downloadPercent = nil
                    downloadProgress = "Download failed: \(reason)"
                    downloadSpeed = ""
                }
            }
            downloadingModel = nil
        }
    }

    func cancelDownload() {
        guard let id = downloadingModel else { return }
        downloadTask?.cancel()           // SIGTERMs the download process via the stream
        downloadingModel = nil
        downloadProgress = ""
        downloadSpeed = ""
        downloadPercent = nil
        // Give the process a moment to exit, then delete the partial (.incomplete)
        // blobs so a cancel leaves nothing behind. This task isn't the cancelled one.
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(700))
            try? LocalModels().delete(modelID: id)
            refreshLocal()
        }
    }

    func deleteLocal(_ id: String) {
        try? LocalModels().delete(modelID: id)
        refreshLocal()
        if selectedID == id { Task { await loadInfo(for: id) } }
    }

    // MARK: VRAM fit

    struct Fit {
        var precision: WeightPrecision
        var estimate: VRAMEstimate
        var verdict: FitVerdict
    }

    func fit(for info: HFModelInfo, contextLength: Int = 4096) -> Fit? {
        guard let params = info.parameterCount, params > 0 else { return nil }
        let precision = WeightPrecision.infer(modelID: info.id, tags: info.tags)
        let estimate = VRAMEstimator.estimate(
            parameterCount: params,
            precision: precision,
            contextLength: contextLength,
            hiddenSize: modelConfig?.hiddenSize ?? info.hiddenSize,
            numLayers: modelConfig?.numHiddenLayers ?? info.numLayers,
            numAttentionHeads: modelConfig?.numAttentionHeads,
            numKeyValueHeads: modelConfig?.numKeyValueHeads,
            headDim: modelConfig?.headDim
        )
        let verdict = VRAMEstimator.fits(
            estimate: estimate,
            unifiedMemoryBytes: hardware.unifiedMemoryBytes,
            metalBudgetBytes: hardware.metalBudgetBytes
        )
        return Fit(precision: precision, estimate: estimate, verdict: verdict)
    }
}

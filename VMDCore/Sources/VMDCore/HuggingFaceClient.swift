import Foundation

/// HuggingFace `gated` flag (the API returns `false`, `"auto"`, or `"manual"`).
public enum HFGated: Decodable, Sendable, Equatable {
    case no, auto, manual

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let boolean = try? container.decode(Bool.self) {
            self = boolean ? .manual : .no
        } else if let string = try? container.decode(String.self) {
            switch string {
            case "auto": self = .auto
            case "manual": self = .manual
            default: self = .no
            }
        } else {
            self = .no
        }
    }

    public var isGated: Bool { self != .no }
}

/// A row in HuggingFace model search results.
public struct HFModelSummary: Decodable, Sendable, Equatable, Identifiable {
    public var id: String
    public var downloads: Int?
    public var likes: Int?
    public var tags: [String]?
    public var pipelineTag: String?

    public init(id: String, downloads: Int? = nil, likes: Int? = nil, tags: [String]? = nil, pipelineTag: String? = nil) {
        self.id = id
        self.downloads = downloads
        self.likes = likes
        self.tags = tags
        self.pipelineTag = pipelineTag
    }

    enum CodingKeys: String, CodingKey {
        case id, downloads, likes, tags
        case pipelineTag = "pipeline_tag"
    }
}

/// Detailed model metadata for the model-card view + VRAM estimation.
public struct HFModelInfo: Sendable, Equatable, Identifiable {
    public var id: String
    public var downloads: Int?
    public var likes: Int?
    public var tags: [String]
    public var pipelineTag: String?
    public var gated: HFGated
    public var files: [String]
    public var parameterCount: Int?
    public var numLayers: Int?
    public var hiddenSize: Int?
    public var modelType: String?

    public var hasGGUF: Bool { files.contains { $0.lowercased().hasSuffix(".gguf") } }
    public var hasSafetensors: Bool { files.contains { $0.lowercased().hasSuffix(".safetensors") } }

    /// MLX-ready heuristic: the mlx-community org or an `mlx` tag (docs/PLAN.md §5).
    public var isMLXReady: Bool {
        id.lowercased().hasPrefix("mlx-community/") || tags.contains { $0.lowercased() == "mlx" }
    }
}

/// The architecture facts from a repo's raw `config.json`. The model-info API's
/// `config` object omits all of these (it carries only architectures/tokenizer
/// data), so accurate memory estimates need this extra one-file fetch.
public struct HFModelConfig: Sendable, Equatable {
    public var hiddenSize: Int?
    public var numHiddenLayers: Int?
    public var numAttentionHeads: Int?
    /// GQA: the number of KV heads (≪ attention heads on modern models) —
    /// the difference between an honest KV-cache estimate and a several-fold
    /// overestimate.
    public var numKeyValueHeads: Int?
    public var headDim: Int?

    public init(
        hiddenSize: Int? = nil,
        numHiddenLayers: Int? = nil,
        numAttentionHeads: Int? = nil,
        numKeyValueHeads: Int? = nil,
        headDim: Int? = nil
    ) {
        self.hiddenSize = hiddenSize
        self.numHiddenLayers = numHiddenLayers
        self.numAttentionHeads = numAttentionHeads
        self.numKeyValueHeads = numKeyValueHeads
        self.headDim = headDim
    }
}

private struct HFSibling: Decodable { let rfilename: String }
private struct HFSafetensors: Decodable { let total: Int? }
private struct HFConfig: Decodable {
    let numHiddenLayers: Int?
    let hiddenSize: Int?
    let modelType: String?
    enum CodingKeys: String, CodingKey {
        case numHiddenLayers = "num_hidden_layers"
        case hiddenSize = "hidden_size"
        case modelType = "model_type"
    }
}
private struct HFModelInfoRaw: Decodable {
    let id: String
    let downloads: Int?
    let likes: Int?
    let tags: [String]?
    let pipelineTag: String?
    let gated: HFGated?
    let siblings: [HFSibling]?
    let safetensors: HFSafetensors?
    let config: HFConfig?
    enum CodingKeys: String, CodingKey {
        case id, downloads, likes, tags, gated, siblings, safetensors, config
        case pipelineTag = "pipeline_tag"
    }
}

public enum HuggingFaceError: Error, Sendable, Equatable {
    case notHTTP
    case httpStatus(Int)
}

/// Reads the public HuggingFace Hub API directly (no backend proxy — docs/PLAN.md
/// §5). Parsing is pure and unit-tested against fixtures; only the `async`
/// methods touch the network.
public struct HuggingFaceClient: Sendable {
    public var session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func searchModels(
        query: String,
        author: String? = nil,
        filters: [String] = ["text-generation"],
        limit: Int = 25
    ) async throws -> [HFModelSummary] {
        var components = URLComponents(string: "https://huggingface.co/api/models")!
        var items: [URLQueryItem] = [
            URLQueryItem(name: "sort", value: "downloads"),
            URLQueryItem(name: "direction", value: "-1"),
            URLQueryItem(name: "limit", value: String(limit)),
        ]
        for filter in filters { items.append(URLQueryItem(name: "filter", value: filter)) }
        if !query.isEmpty { items.append(URLQueryItem(name: "search", value: query)) }
        if let author { items.append(URLQueryItem(name: "author", value: author)) }
        components.queryItems = items

        let (data, response) = try await session.data(from: components.url!)
        try Self.checkOK(response)
        return try JSONDecoder().decode([HFModelSummary].self, from: data)
    }

    /// Resolves the actual avatar image URL for a model id's organization. The
    /// `…/avatar` endpoint returns JSON (`{"avatarUrl": …}`), not the image, so
    /// this fetches that and returns the CDN image URL (or nil for users/no org).
    public func organizationAvatarImageURL(forModelID id: String) async -> URL? {
        guard let org = id.split(separator: "/").first, !org.isEmpty,
              let url = URL(string: "https://huggingface.co/api/organizations/\(org)/avatar"),
              let (data, response) = try? await session.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        struct AvatarResponse: Decodable { let avatarUrl: String? }
        guard let parsed = try? JSONDecoder().decode(AvatarResponse.self, from: data),
              let avatarURL = parsed.avatarUrl else { return nil }
        return URL(string: avatarURL)
    }

    public func modelInfo(id: String) async throws -> HFModelInfo {
        // `appending(path:)` percent-encodes each component (keeping the org/name
        // slash), so an unusual id can't make `URL(string:)` return nil and crash.
        let url = URL(string: "https://huggingface.co/api/models")!.appending(path: id)
        let (data, response) = try await session.data(from: url)
        try Self.checkOK(response)
        return try Self.parseModelInfo(data)
    }

    /// Fetches the repo's raw `config.json` for architecture facts the
    /// model-info API doesn't carry (layers, heads, GQA KV heads).
    public func modelConfig(id: String) async throws -> HFModelConfig {
        let url = URL(string: "https://huggingface.co")!
            .appending(path: id)
            .appending(path: "raw/main/config.json")
        let (data, response) = try await session.data(from: url)
        try Self.checkOK(response)
        return try Self.parseModelConfig(data)
    }

    public func readme(id: String) async throws -> String {
        let url = URL(string: "https://huggingface.co")!
            .appending(path: id)
            .appending(path: "raw/main/README.md")
        let (data, response) = try await session.data(from: url)
        try Self.checkOK(response)
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: Pure parsing

    public static func parseModelInfo(_ data: Data) throws -> HFModelInfo {
        let raw = try JSONDecoder().decode(HFModelInfoRaw.self, from: data)
        return HFModelInfo(
            id: raw.id,
            downloads: raw.downloads,
            likes: raw.likes,
            tags: raw.tags ?? [],
            pipelineTag: raw.pipelineTag,
            gated: raw.gated ?? .no,
            files: raw.siblings?.map(\.rfilename) ?? [],
            parameterCount: raw.safetensors?.total,
            numLayers: raw.config?.numHiddenLayers,
            hiddenSize: raw.config?.hiddenSize,
            modelType: raw.config?.modelType
        )
    }

    public static func parseModelConfig(_ data: Data) throws -> HFModelConfig {
        struct Raw: Decodable {
            let hiddenSize: Int?
            let numHiddenLayers: Int?
            let numAttentionHeads: Int?
            let numKeyValueHeads: Int?
            let headDim: Int?
            // Multimodal configs (Qwen-VL et al.) nest the LLM under text_config.
            let textConfig: RawText?
            struct RawText: Decodable {
                let hiddenSize: Int?
                let numHiddenLayers: Int?
                let numAttentionHeads: Int?
                let numKeyValueHeads: Int?
                let headDim: Int?
                enum CodingKeys: String, CodingKey {
                    case hiddenSize = "hidden_size"
                    case numHiddenLayers = "num_hidden_layers"
                    case numAttentionHeads = "num_attention_heads"
                    case numKeyValueHeads = "num_key_value_heads"
                    case headDim = "head_dim"
                }
            }
            enum CodingKeys: String, CodingKey {
                case hiddenSize = "hidden_size"
                case numHiddenLayers = "num_hidden_layers"
                case numAttentionHeads = "num_attention_heads"
                case numKeyValueHeads = "num_key_value_heads"
                case headDim = "head_dim"
                case textConfig = "text_config"
            }
        }
        let raw = try JSONDecoder().decode(Raw.self, from: data)
        return HFModelConfig(
            hiddenSize: raw.hiddenSize ?? raw.textConfig?.hiddenSize,
            numHiddenLayers: raw.numHiddenLayers ?? raw.textConfig?.numHiddenLayers,
            numAttentionHeads: raw.numAttentionHeads ?? raw.textConfig?.numAttentionHeads,
            numKeyValueHeads: raw.numKeyValueHeads ?? raw.textConfig?.numKeyValueHeads,
            headDim: raw.headDim ?? raw.textConfig?.headDim
        )
    }

    private static func checkOK(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { throw HuggingFaceError.notHTTP }
        guard http.statusCode == 200 else { throw HuggingFaceError.httpStatus(http.statusCode) }
    }
}

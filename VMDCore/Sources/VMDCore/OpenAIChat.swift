import Foundation

// OpenAI-compatible chat types. vllm-metal exposes the standard
// `/v1/chat/completions` surface (docs/PLAN.md §2.2).

/// One part of a multimodal message (OpenAI content-parts shape).
public enum ChatContentPart: Codable, Sendable, Equatable {
    case text(String)
    /// An image reference — for local serving, a `data:image/...;base64,...` URI.
    case imageURL(String)

    enum CodingKeys: String, CodingKey {
        case type, text
        case imageURL = "image_url"
    }

    private struct ImageRef: Codable {
        var url: String
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(String.self, forKey: .type) {
        case "image_url":
            self = .imageURL(try container.decode(ImageRef.self, forKey: .imageURL).url)
        default:
            self = .text(try container.decodeIfPresent(String.self, forKey: .text) ?? "")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .text(let text):
            try container.encode("text", forKey: .type)
            try container.encode(text, forKey: .text)
        case .imageURL(let url):
            try container.encode("image_url", forKey: .type)
            try container.encode(ImageRef(url: url), forKey: .imageURL)
        }
    }
}

/// Message content: a plain string for text-only turns, or content parts when
/// images ride along. Encodes to the exact OpenAI JSON either way.
public enum ChatContent: Codable, Sendable, Equatable {
    case text(String)
    case parts([ChatContentPart])

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let string = try? container.decode(String.self) {
            self = .text(string)
        } else {
            self = .parts(try container.decode([ChatContentPart].self))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .text(let text): try container.encode(text)
        case .parts(let parts): try container.encode(parts)
        }
    }

    /// The text portions joined — what history filtering and copy work with.
    public var plainText: String {
        switch self {
        case .text(let text): return text
        case .parts(let parts):
            return parts.compactMap { if case .text(let text) = $0 { text } else { nil } }
                .joined(separator: "\n")
        }
    }
}

public struct ChatMessagePayload: Codable, Sendable, Equatable {
    public var role: String
    public var content: ChatContent

    public init(role: String, content: String) {
        self.role = role
        self.content = .text(content)
    }

    public init(role: String, content: ChatContent) {
        self.role = role
        self.content = content
    }
}

/// Extra arguments forwarded to the model's chat template (vLLM's
/// `chat_template_kwargs`). Qwen3 defaults thinking ON while Qwen3.5 defaults it
/// OFF — this is the switch that overrides either.
public struct ChatTemplateKwargs: Codable, Sendable, Equatable {
    public var enableThinking: Bool?

    enum CodingKeys: String, CodingKey {
        case enableThinking = "enable_thinking"
    }

    public init(enableThinking: Bool? = nil) {
        self.enableThinking = enableThinking
    }
}

/// Streaming extras (`stream_options`); `include_usage` asks the server to append
/// a final chunk carrying real token counts.
public struct StreamOptions: Codable, Sendable, Equatable {
    public var includeUsage: Bool

    enum CodingKeys: String, CodingKey {
        case includeUsage = "include_usage"
    }

    public init(includeUsage: Bool = true) {
        self.includeUsage = includeUsage
    }
}

/// Token accounting reported by the server (exact, not estimated).
public struct ChatUsage: Codable, Sendable, Equatable {
    public var promptTokens: Int
    public var completionTokens: Int
    public var totalTokens: Int

    enum CodingKeys: String, CodingKey {
        case promptTokens = "prompt_tokens"
        case completionTokens = "completion_tokens"
        case totalTokens = "total_tokens"
    }

    public init(promptTokens: Int, completionTokens: Int, totalTokens: Int) {
        self.promptTokens = promptTokens
        self.completionTokens = completionTokens
        self.totalTokens = totalTokens
    }
}

public struct ChatCompletionRequest: Codable, Sendable, Equatable {
    public var model: String
    public var messages: [ChatMessagePayload]
    public var stream: Bool
    public var temperature: Double?
    public var maxTokens: Int?
    public var chatTemplateKwargs: ChatTemplateKwargs?
    public var streamOptions: StreamOptions?

    enum CodingKeys: String, CodingKey {
        case model, messages, stream, temperature
        case maxTokens = "max_tokens"
        case chatTemplateKwargs = "chat_template_kwargs"
        case streamOptions = "stream_options"
    }

    public init(
        model: String,
        messages: [ChatMessagePayload],
        stream: Bool = true,
        temperature: Double? = nil,
        maxTokens: Int? = nil,
        chatTemplateKwargs: ChatTemplateKwargs? = nil,
        streamOptions: StreamOptions? = nil
    ) {
        self.model = model
        self.messages = messages
        self.stream = stream
        self.temperature = temperature
        self.maxTokens = maxTokens
        self.chatTemplateKwargs = chatTemplateKwargs
        self.streamOptions = streamOptions
    }
}

/// A streaming chunk from `/v1/chat/completions` with `stream: true`.
public struct ChatCompletionChunk: Codable, Sendable, Equatable {
    public struct Choice: Codable, Sendable, Equatable {
        public struct Delta: Codable, Sendable, Equatable {
            public var role: String?
            public var content: String?
        }
        public var delta: Delta
        public var finishReason: String?

        enum CodingKeys: String, CodingKey {
            case delta
            case finishReason = "finish_reason"
        }
    }
    public var choices: [Choice]
    /// Present only on the final chunk when `stream_options.include_usage` is set.
    public var usage: ChatUsage?
}

/// `/v1/models` response (used for readiness and listing served models).
public struct ModelsResponse: Codable, Sendable, Equatable {
    public struct Model: Codable, Sendable, Equatable {
        public var id: String
    }
    public var data: [Model]
}

/// Pure parser for one Server-Sent-Events line of a streaming chat response.
/// Mirrors lmstack's buffered SSE semantics: `data:` prefix + `[DONE]` sentinel
/// (docs/PLAN.md §5).
public enum SSEChatParser {
    public enum Token: Sendable, Equatable {
        case delta(String)
        case usage(ChatUsage)
        case done
        case ignore
    }

    public static func parse(line: String) -> Token {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("data:") else { return .ignore }
        let payload = trimmed.dropFirst("data:".count).trimmingCharacters(in: .whitespaces)
        if payload == "[DONE]" { return .done }
        guard
            let data = payload.data(using: .utf8),
            let chunk = try? JSONDecoder().decode(ChatCompletionChunk.self, from: data)
        else { return .ignore }
        if let content = chunk.choices.first?.delta.content, !content.isEmpty {
            return .delta(content)
        }
        // The usage-only chunk arrives last, with empty `choices`.
        if let usage = chunk.usage {
            return .usage(usage)
        }
        return .ignore
    }
}

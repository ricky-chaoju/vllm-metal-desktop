import Foundation
import Testing
@testable import VMDCore

@Suite("SSEChatParser")
struct OpenAIChatTests {
    @Test("accumulates content deltas across a stream")
    func accumulatesDeltas() {
        let lines = [
            #"data: {"choices":[{"delta":{"role":"assistant"},"finish_reason":null}]}"#,
            #"data: {"choices":[{"delta":{"content":"Hello"},"finish_reason":null}]}"#,
            #"data: {"choices":[{"delta":{"content":" world"},"finish_reason":null}]}"#,
            #"data: {"choices":[{"delta":{},"finish_reason":"stop"}]}"#,
            "data: [DONE]",
        ]
        var text = ""
        var sawDone = false
        for line in lines {
            switch SSEChatParser.parse(line: line) {
            case .delta(let content): text += content
            case .done: sawDone = true
            case .usage, .ignore: break
            }
        }
        #expect(text == "Hello world")
        #expect(sawDone)
    }

    @Test("ignores blank and non-data lines")
    func ignoresNoise() {
        #expect(SSEChatParser.parse(line: "") == .ignore)
        #expect(SSEChatParser.parse(line: ": keep-alive") == .ignore)
        #expect(SSEChatParser.parse(line: "event: ping") == .ignore)
        #expect(SSEChatParser.parse(line: "data: {not json}") == .ignore)
    }

    @Test("recognizes the DONE sentinel with extra spacing")
    func doneSentinel() {
        #expect(SSEChatParser.parse(line: "data: [DONE]") == .done)
        #expect(SSEChatParser.parse(line: "data:[DONE]") == .done)
    }

    @Test("request encodes max_tokens with the OpenAI key")
    func requestEncoding() throws {
        let request = ChatCompletionRequest(
            model: "Qwen/Qwen3-0.6B",
            messages: [.init(role: "user", content: "hi")],
            temperature: 0.7,
            maxTokens: 128
        )
        let data = try JSONEncoder().encode(request)
        let json = String(decoding: data, as: UTF8.self)
        #expect(json.contains("\"max_tokens\":128"))
        #expect(json.contains("\"stream\":true"))
        // No thinking override → the key is omitted entirely.
        #expect(!json.contains("chat_template_kwargs"))
    }

    @Test("usage-only final chunk parses into a usage token")
    func usageChunk() {
        let line = #"data: {"choices":[],"usage":{"prompt_tokens":12,"completion_tokens":379,"total_tokens":391}}"#
        #expect(SSEChatParser.parse(line: line)
            == .usage(ChatUsage(promptTokens: 12, completionTokens: 379, totalTokens: 391)))
        // A finish chunk without content or usage stays ignored.
        let finish = #"data: {"choices":[{"delta":{},"finish_reason":"stop"}]}"#
        #expect(SSEChatParser.parse(line: finish) == .ignore)
    }

    @Test("stream options encode with the OpenAI key")
    func streamOptionsEncoding() throws {
        let request = ChatCompletionRequest(
            model: "m", messages: [], streamOptions: StreamOptions(includeUsage: true)
        )
        let json = String(decoding: try JSONEncoder().encode(request), as: UTF8.self)
        #expect(json.contains("\"stream_options\":{\"include_usage\":true}"))
    }

    @Test("text-only content encodes as a plain string")
    func textContentEncoding() throws {
        let payload = ChatMessagePayload(role: "user", content: "hi")
        let json = String(decoding: try JSONEncoder().encode(payload), as: UTF8.self)
        #expect(json.contains(#""content":"hi""#))
    }

    @Test("image attachments encode as OpenAI content parts")
    func multimodalEncoding() throws {
        let payload = ChatMessagePayload(role: "user", content: .parts([
            .text("What is this?"),
            .imageURL("data:image/jpeg;base64,AAAA"),
        ]))
        let json = String(decoding: try JSONEncoder().encode(payload), as: UTF8.self)
        #expect(json.contains(#""type":"text""#))
        #expect(json.contains(#""text":"What is this?""#))
        #expect(json.contains(#""type":"image_url""#))
        #expect(json.contains(#""url":"data:image\/jpeg;base64,AAAA""#))
        // Round-trips.
        let decoded = try JSONDecoder().decode(ChatMessagePayload.self, from: Data(json.utf8))
        #expect(decoded == payload)
        #expect(decoded.content.plainText == "What is this?")
    }

    @Test("vision support detected from model config")
    func visionDetection() {
        let vl = #"{"architectures":["Qwen3VLForConditionalGeneration"],"vision_config":{"depth":32}}"#
        let textOnly = #"{"architectures":["Qwen3ForCausalLM"],"model_type":"qwen3"}"#
        #expect(LocalModels.supportsVision(configJSON: Data(vl.utf8)))
        #expect(!LocalModels.supportsVision(configJSON: Data(textOnly.utf8)))
    }

    @Test("thinking override rides in chat_template_kwargs")
    func thinkingEncoding() throws {
        let request = ChatCompletionRequest(
            model: "Qwen/Qwen3.5-0.8B",
            messages: [.init(role: "user", content: "hi")],
            chatTemplateKwargs: ChatTemplateKwargs(enableThinking: true)
        )
        let json = String(decoding: try JSONEncoder().encode(request), as: UTF8.self)
        #expect(json.contains("\"chat_template_kwargs\":{\"enable_thinking\":true}"))
    }
}

@Suite("ServeConfig")
struct ServeConfigTests {
    @Test("builds the vllm serve argument list")
    func arguments() {
        let config = ServeConfig(model: "Qwen/Qwen3-0.6B", port: 8123, maxModelLen: 4096)
        #expect(config.launchArguments == ["serve", "Qwen/Qwen3-0.6B", "--port", "8123", "--max-model-len", "4096"])
        #expect(config.effectiveModelName == "Qwen/Qwen3-0.6B")
    }

    @Test("served-model-name overrides the reported name")
    func servedName() {
        let config = ServeConfig(model: "org/Model", port: 8001, servedModelName: "my-model")
        #expect(config.launchArguments.contains("--served-model-name"))
        #expect(config.launchArguments.contains("my-model"))
        #expect(config.effectiveModelName == "my-model")
    }
}

@Suite("PortFinder")
struct PortFinderTests {
    @Test("returns a usable port")
    func findsPort() {
        let port = PortFinder.findFree()
        #expect(port != nil)
        if let port { #expect((1...65535).contains(port)) }
    }

    @Test("a freshly found port reports as free")
    func isFreeAgreesWithFindFree() throws {
        let port = try #require(PortFinder.findFree())
        #expect(PortFinder.isFree(port))
    }

    @Test("successive calls succeed")
    func repeatable() {
        #expect(PortFinder.findFree() != nil)
        #expect(PortFinder.findFree() != nil)
    }
}

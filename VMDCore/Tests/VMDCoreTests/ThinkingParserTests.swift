import Foundation
import Testing
@testable import VMDCore

@Suite("ThinkingParser")
struct ThinkingParserTests {
    @Test("template support classification")
    func templateSupport() {
        // Qwen3-style: the template branches on enable_thinking.
        #expect(ThinkingParser.templateSupport(
            "{%- if enable_thinking is defined and enable_thinking is false %}…{%- endif %}"
        ) == .toggleable)
        // R1-style: unconditionally opens a <think> block.
        #expect(ThinkingParser.templateSupport(
            "{{'<think>\\n'}}{% for message in messages %}…{% endfor %}"
        ) == .always)
        // Plain chat model (Qwen2.5 / Llama): no reasoning markers.
        #expect(ThinkingParser.templateSupport(
            "{% for message in messages %}{{ message.content }}{% endfor %}"
        ) == .none)
        #expect(ThinkingParser.templateSupport(nil) == .none)
    }

    @Test("tokenizer_config chat_template extraction, string and named list")
    func chatTemplateExtraction() {
        let plain = LocalModels.chatTemplate(fromTokenizerConfig: Data(
            #"{"chat_template": "{% for m in messages %}{{ m.content }}{% endfor %}"}"#.utf8
        ))
        #expect(plain?.contains("messages") == true)

        let named = LocalModels.chatTemplate(fromTokenizerConfig: Data(#"""
        {"chat_template": [
            {"name": "tool_use", "template": "TOOLS"},
            {"name": "default", "template": "DEFAULT"}
        ]}
        """#.utf8))
        #expect(named == "DEFAULT")

        #expect(LocalModels.chatTemplate(fromTokenizerConfig: Data("{}".utf8)) == nil)
    }

    @Test("plain text has no thinking")
    func plain() {
        let split = ThinkingParser.split("Hello there")
        #expect(split.thinking == nil)
        #expect(split.answer == "Hello there")
        #expect(!split.isThinking)
    }

    @Test("closed think block splits reasoning from answer")
    func closed() {
        let split = ThinkingParser.split("<think>\nOkay, 2+2 is 4.\n</think>\n\nThe answer is 4.")
        #expect(split.thinking == "Okay, 2+2 is 4.")
        #expect(split.answer == "The answer is 4.")
        #expect(!split.isThinking)
    }

    @Test("open think block is still reasoning, no answer yet")
    func open() {
        let split = ThinkingParser.split("<think>Let me consider the options")
        #expect(split.thinking == "Let me consider the options")
        #expect(split.answer == "")
        #expect(split.isThinking)
    }

    @Test("bare open tag reports thinking with no text")
    func bareOpen() {
        let split = ThinkingParser.split("<think>")
        #expect(split.thinking == nil)
        #expect(split.isThinking)
        #expect(split.answer == "")
    }

    @Test("a literal <think> later in the answer is not treated as reasoning")
    func literalTagInAnswer() {
        let split = ThinkingParser.split("To use it, write the <think> tag at the start.")
        #expect(split.thinking == nil)
        #expect(!split.isThinking)
        #expect(split.answer == "To use it, write the <think> tag at the start.")
    }

    @Test("closing tag without opener: prompt-prefilled thinking (Qwen3.5 enable_thinking)")
    func prefilledThink() {
        // The template put `<think>\n` in the prompt, so the completion starts
        // mid-reasoning and only carries the closing tag.
        let split = ThinkingParser.split("The user asks 17*23. 17*23 = 391.\n</think>\n\n17 × 23 = **391**.")
        #expect(split.thinking == "The user asks 17*23. 17*23 = 391.")
        #expect(split.answer == "17 × 23 = **391**.")
        #expect(!split.isThinking)
    }

    @Test("prefilled thinking with empty reasoning still yields the answer")
    func prefilledEmptyThink() {
        let split = ThinkingParser.split("\n</think>\n\nHi!")
        #expect(split.thinking == nil)
        #expect(split.answer == "Hi!")
        #expect(!split.isThinking)
    }
}

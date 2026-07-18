import Foundation

/// A chat reply split into a model's `<think>` reasoning and its visible answer.
public struct ThinkingSplit: Sendable, Equatable {
    /// Reasoning text (may be partial while streaming). `nil` if none yet.
    public var thinking: String?
    /// The user-facing answer.
    public var answer: String
    /// True while inside an unclosed `<think>` block (still reasoning).
    public var isThinking: Bool
}

/// What a model's chat template says about reasoning, so the UI can gate the
/// Thinking control instead of letting users force a mode the model ignores
/// (forcing On seeds a `<think>` prefix — on a non-thinking model that would
/// swallow the whole answer into a never-closing reasoning section).
public enum ThinkingSupport: Sendable, Equatable {
    /// The template honors `enable_thinking` (Qwen3 family) — On/Off both work.
    case toggleable
    /// The template emits `<think>` unconditionally (R1-style distills) —
    /// reasoning shows, but there is nothing to toggle.
    case always
    /// No reasoning markers in the template — a plain chat model.
    case none
}

/// Splits assistant content from reasoning models (e.g. Qwen3) that emit
/// `<think>…</think>` before the answer. Pure and unit-tested; the chat UI calls
/// it on the accumulating text each render so reasoning can be shown collapsed.
public enum ThinkingParser {
    /// Classifies a chat template's reasoning support (pure; unit-tested).
    /// `nil` template (model not downloaded / no template) → `.none`.
    public static func templateSupport(_ chatTemplate: String?) -> ThinkingSupport {
        guard let chatTemplate else { return .none }
        if chatTemplate.contains("enable_thinking") { return .toggleable }
        if chatTemplate.contains("<think>") { return .always }
        return .none
    }

    public static func split(_ text: String) -> ThinkingSplit {
        // Reasoning models emit `<think>` as the very first content, so anchor to
        // the start. This avoids misparsing a literal "<think>" that appears later
        // inside a normal answer (e.g. code or discussion about the tag).
        let leading = text.drop { $0.isWhitespace }
        if leading.hasPrefix("<think>"), let open = text.range(of: "<think>") {
            if let close = text.range(of: "</think>") {
                let thinking = String(text[open.upperBound..<close.lowerBound])
                let after = String(text[close.upperBound...])
                return ThinkingSplit(
                    thinking: trimmedOrNil(thinking),
                    answer: after.trimmingCharacters(in: .whitespacesAndNewlines),
                    isThinking: false
                )
            }
            // Open tag with no close yet — still reasoning.
            let thinking = String(text[open.upperBound...])
            return ThinkingSplit(thinking: trimmedOrNil(thinking), answer: "", isThinking: true)
        }

        // Closing tag with no opener: templates that force thinking pre-fill
        // `<think>\n` in the *prompt* (e.g. Qwen3.5 with enable_thinking), so the
        // completion carries only the reasoning followed by `</think>`.
        if let close = text.range(of: "</think>") {
            let thinking = String(text[..<close.lowerBound])
            let after = String(text[close.upperBound...])
            return ThinkingSplit(
                thinking: trimmedOrNil(thinking),
                answer: after.trimmingCharacters(in: .whitespacesAndNewlines),
                isThinking: false
            )
        }

        return ThinkingSplit(thinking: nil, answer: text, isThinking: false)
    }

    private static func trimmedOrNil(_ string: String) -> String? {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

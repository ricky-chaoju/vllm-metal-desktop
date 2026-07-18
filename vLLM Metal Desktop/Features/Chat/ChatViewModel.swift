import Foundation
import Observation
import SwiftData
import VMDCore

/// Streams assistant replies into a persisted `Conversation`. History survives
/// relaunch. Supports regeneration and records reasoning time.
@MainActor
@Observable
final class ChatViewModel {
    var input = ""
    var isStreaming = false
    /// Files staged for the next message (chips above the composer).
    var attachments: [ComposerAttachment] = []
    /// True while an input method holds uncommitted (marked) text — e.g. pinyin
    /// or zhuyin before the candidate is confirmed. The bound `input` only
    /// updates on commit, so the send button lights up from this too.
    var isComposing = false

    /// Whether to override the model's own thinking default. Qwen3 templates
    /// think by default; Qwen3.5 templates don't — "Model default" respects each.
    enum ThinkingMode: String, CaseIterable, Identifiable {
        case modelDefault = "Model default"
        case on = "On"
        case off = "Off"
        var id: String { rawValue }

        var templateKwargs: ChatTemplateKwargs? {
            switch self {
            case .modelDefault: nil
            case .on: ChatTemplateKwargs(enableThinking: true)
            case .off: ChatTemplateKwargs(enableThinking: false)
            }
        }
    }

    // Generation parameters (chat inspector).
    var temperature: Double = 0.7
    /// Reasoning models can burn thousands of tokens inside <think> alone; a low
    /// cap cuts generation mid-think and the answer never arrives.
    var maxTokens: Int = 8192
    var systemPrompt: String = ""
    var thinkingMode: ThinkingMode = .modelDefault
    /// What the running model's chat template supports (ChatView keeps this in
    /// sync with the active deployment). Gates the Thinking control: On/Off is
    /// only sent — and `<think>` only seeded — when the template can honor it.
    var thinkingSupport: ThinkingSupport = .none

    private var streamTask: Task<Void, Never>?

    var canSend: Bool {
        let hasContent = !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !attachments.isEmpty
            || isComposing
        return hasContent && !isStreaming
    }

    func send(into conversation: Conversation, client: OpenAIClient, model: String, context: ModelContext) {
        let prompt = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty || !attachments.isEmpty, !isStreaming else { return }
        input = ""
        let attached = attachments
        attachments = []

        let user = ChatMessage(role: .user, content: prompt, conversation: conversation)
        if !attached.isEmpty {
            user.attachmentPaths = attached.map(\.url.path)
        }
        context.insert(user)
        conversation.updatedAt = .now
        conversation.modelName = model
        if conversation.title == "New Chat" {
            let title = prompt.isEmpty ? (attached.first?.displayName ?? "Attachment") : prompt
            conversation.title = String(title.prefix(48))
        }
        streamReply(in: conversation, client: client, model: model, context: context)
    }

    /// Removes `assistant` and streams a fresh reply into its place in the
    /// transcript, from the history *up to* it — regenerating a mid-thread
    /// reply neither jumps to the bottom nor sees later turns.
    func regenerate(_ assistant: ChatMessage, in conversation: Conversation, client: OpenAIClient, model: String, context: ModelContext) {
        guard !isStreaming, assistant.role == .assistant else { return }
        let slot = assistant.timestamp
        context.delete(assistant)
        // The relationship may still list the deleted message until the context
        // saves — exclude it explicitly so the old answer isn't replayed.
        streamReply(in: conversation, excluding: assistant, replacingAt: slot, client: client, model: model, context: context)
    }

    func stopStreaming() {
        streamTask?.cancel()
        isStreaming = false
    }

    private func streamReply(
        in conversation: Conversation,
        excluding excluded: ChatMessage? = nil,
        replacingAt slot: Date? = nil,
        client: OpenAIClient,
        model: String,
        context: ModelContext
    ) {
        streamTask?.cancel()

        // With forced thinking, templates pre-fill `<think>` in the *prompt*, so
        // the stream carries bare reasoning with only a closing tag. Seed the tag
        // ourselves so the UI shows "Thinking…" from the first token instead of
        // rendering reasoning as the answer until `</think>` arrives. Only for
        // templates that honor the toggle — seeding on a plain model would
        // trap the whole reply in a never-closing reasoning section.
        let seededThink = thinkingMode == .on && thinkingSupport == .toggleable
        let assistant = ChatMessage(
            role: .assistant,
            content: seededThink ? "<think>\n" : "",
            modelName: model,
            conversation: conversation
        )
        // A regenerated reply takes over the deleted one's transcript slot.
        if let slot { assistant.timestamp = slot }
        context.insert(assistant)

        var payload: [ChatMessagePayload] = []
        let system = systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if !system.isEmpty {
            payload.append(ChatMessagePayload(role: "system", content: system))
        }
        payload += conversation.messages
            .filter { $0 !== assistant && $0 !== excluded }
            .filter { message in slot.map { message.timestamp < $0 } ?? true }
            .sorted { $0.timestamp < $1.timestamp }
            .map { message in
                if message.role == .assistant {
                    // History carries only the visible answer — replaying a prior
                    // turn's raw <think> block derails reasoning chat templates.
                    return ChatMessagePayload(role: "assistant", content: ThinkingParser.split(message.content).answer)
                }
                // User turns rebuild their attachments (inlined file text +
                // image parts) so multi-turn context keeps them in play.
                let attached = (message.attachmentPaths ?? []).compactMap(ComposerAttachment.fromPath)
                if attached.isEmpty {
                    return ChatMessagePayload(role: "user", content: message.content)
                }
                return ChatMessagePayload(
                    role: "user",
                    content: ComposerAttachment.buildContent(text: message.content, attachments: attached)
                )
            }

        let request = ChatCompletionRequest(
            model: model, messages: payload, stream: true,
            temperature: temperature, maxTokens: maxTokens,
            chatTemplateKwargs: thinkingSupport == .toggleable ? thinkingMode.templateKwargs : nil,
            streamOptions: StreamOptions(includeUsage: true)
        )

        isStreaming = true
        streamTask = Task {
            let started = Date()
            var recordedThinking = false
            var cancelled = false
            do {
                for try await event in client.chatCompletionStream(request) {
                    switch event {
                    case .delta(let delta):
                        assistant.content += delta
                        if !recordedThinking, assistant.content.contains("</think>") {
                            assistant.thinkingSeconds = Date().timeIntervalSince(started)
                            recordedThinking = true
                        }
                    case .usage(let usage):
                        assistant.completionTokens = usage.completionTokens
                        assistant.totalTokens = usage.totalTokens
                    }
                }
                assistant.generationSeconds = Date().timeIntervalSince(started)
            } catch is CancellationError {
                cancelled = true
            } catch {
                assistant.content += "\n\n_[error: \(error.localizedDescription)]_"
            }
            // A model that ignored the thinking request completed a normal answer
            // with no `</think>` — drop the seeded tag so it renders as an answer.
            // (Keep it when cancelled: partial reasoning should read as interrupted.)
            if seededThink, !cancelled, !assistant.content.contains("</think>"),
               assistant.content.hasPrefix("<think>\n") {
                assistant.content = String(assistant.content.dropFirst("<think>\n".count))
            }
            conversation.updatedAt = .now
            try? context.save()
            isStreaming = false
        }
    }
}

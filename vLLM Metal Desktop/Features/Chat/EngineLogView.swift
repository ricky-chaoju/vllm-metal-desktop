import SwiftUI
import VMDCore

/// Terminal-style colored engine output: ANSI escapes render in their own
/// colors, otherwise the level/context structure is tinted. Auto-follows the
/// tail. Shared by the Chat log drawer and each deployment on the Server page.
struct EngineLogView: View {
    let lines: [LogLine]
    var emptyText = "No engine log yet."

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                // One Text so the whole log selects across lines.
                Text(attributed)
                    .scaledFont(.caption2, design: .monospaced)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(Theme.Spacing.s)
                Color.clear.frame(height: 1).id("log-bottom")
            }
            // Keyed on the last line's id, not the count: the 600-line ring
            // buffer keeps the count pinned at the cap while lines churn.
            .onChange(of: lines.last?.id) { _, _ in
                proxy.scrollTo("log-bottom", anchor: .bottom)
            }
            // Opening the panel lands on the latest output, not the top.
            .onAppear {
                proxy.scrollTo("log-bottom", anchor: .bottom)
            }
        }
    }

    private var attributed: AttributedString {
        guard !lines.isEmpty else {
            var empty = AttributedString(emptyText)
            empty.foregroundColor = .secondary
            return empty
        }
        var output = AttributedString()
        for (index, line) in lines.enumerated() {
            if index > 0 { output += AttributedString("\n") }
            output += Self.colored(line.text)
        }
        return output
    }

    private static func colored(_ raw: String) -> AttributedString {
        // Lines with real ANSI escapes (the engine runs with VLLM_LOGGING_COLOR=1)
        // render in their own colors — the vLLM banner, level tags, everything.
        if raw.contains("\u{1B}") {
            var output = AttributedString()
            for segment in ANSIParser.parse(raw) {
                var part = AttributedString(segment.text)
                if let code = segment.colorCode { part.foregroundColor = ansiColor(code) }
                output += part
            }
            return output
        }

        let parsed = EngineLogLine.parse(raw)
        guard let level = parsed.level else {
            return AttributedString(parsed.message)
        }
        var output = AttributedString()
        if !parsed.processTag.isEmpty {
            var tagPart = AttributedString(parsed.processTag + " ")
            tagPart.foregroundColor = .secondary
            output += tagPart
        }
        var levelPart = AttributedString(level.rawValue + " ")
        levelPart.foregroundColor = levelColor(level)
        output += levelPart
        if !parsed.context.isEmpty {
            var contextPart = AttributedString(parsed.context + " ")
            contextPart.foregroundColor = .secondary
            output += contextPart
        }
        return output + AttributedString(parsed.message)
    }

    /// The 16-color ANSI palette mapped to adaptive SwiftUI colors
    /// (white/black map to primary so they read in both appearances).
    private static func ansiColor(_ code: Int) -> Color {
        switch code {
        case 30, 90: .gray
        case 31, 91: .red
        case 32, 92: .green
        case 33, 93: .orange
        case 34, 94: .blue
        case 35, 95: .purple
        case 36, 96: .cyan
        default: .primary
        }
    }

    private static func levelColor(_ level: EngineLogLine.Level) -> Color {
        switch level {
        case .debug: .secondary
        case .info: .green
        case .warning: .orange
        case .error, .critical: .red
        }
    }
}

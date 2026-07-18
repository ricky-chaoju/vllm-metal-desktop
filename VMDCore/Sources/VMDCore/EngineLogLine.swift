import Foundation

/// One parsed engine log line, split for terminal-style coloring.
/// vLLM's format: `INFO 07-17 10:41:29 [api_server.py:123] message` — but any
/// line whose first token isn't a known level renders as plain text.
public struct EngineLogLine: Sendable, Equatable {
    public enum Level: String, Sendable {
        case debug = "DEBUG"
        case info = "INFO"
        case warning = "WARNING"
        case error = "ERROR"
        case critical = "CRITICAL"
    }

    public var level: Level?
    /// A leading process tag like `(APIServer pid=19997)`, or empty.
    public var processTag: String
    /// Everything between the level and the message (timestamp + `[file:line]`).
    public var context: String
    public var message: String

    /// Parses a raw line, stripping ANSI escape sequences first (the engine may
    /// emit color codes depending on its logging config; we re-color ourselves).
    public static func parse(_ raw: String) -> EngineLogLine {
        let line = stripANSI(raw)

        // Multi-process serving prefixes every line with `(Role pid=N) `.
        var tag = ""
        var body = Substring(line)
        if body.first == "(", let close = body.firstIndex(of: ")") {
            tag = String(body[...close])
            body = body[body.index(after: close)...].drop { $0 == " " }
        }

        guard let firstSpace = body.firstIndex(of: " "),
              let level = Level(rawValue: String(body[..<firstSpace])) else {
            return EngineLogLine(level: nil, processTag: tag, context: "", message: String(body))
        }
        let rest = body[body.index(after: firstSpace)...]
        // Context ends at the closing bracket of `[file:line]`, when present.
        if let bracketEnd = rest.range(of: "] ") {
            return EngineLogLine(
                level: level,
                processTag: tag,
                context: String(rest[..<bracketEnd.upperBound]).trimmingCharacters(in: .whitespaces),
                message: String(rest[bracketEnd.upperBound...])
            )
        }
        return EngineLogLine(level: level, processTag: tag, context: "", message: String(rest))
    }

    private static let ansiPattern = try? NSRegularExpression(pattern: "\u{1B}\\[[0-9;]*[A-Za-z]")

    public static func stripANSI(_ string: String) -> String {
        guard string.contains("\u{1B}"), let regex = ansiPattern else { return string }
        return regex.stringByReplacingMatches(
            in: string, range: NSRange(string.startIndex..., in: string), withTemplate: ""
        )
    }
}

import Foundation

/// Parses ANSI SGR color escapes (`ESC[…m`) into styled text segments, so the
/// log view can render the engine's real terminal colors (vLLM's banner and
/// level tags). Handles the 16-color set + bold + reset; other escape kinds are
/// dropped from the text.
public enum ANSIParser {
    public struct Segment: Sendable, Equatable {
        public var text: String
        /// SGR foreground code (30–37 normal, 90–97 bright), `nil` = default color.
        public var colorCode: Int?
        public var isBold: Bool

        public init(text: String, colorCode: Int? = nil, isBold: Bool = false) {
            self.text = text
            self.colorCode = colorCode
            self.isBold = isBold
        }
    }

    public static func parse(_ string: String) -> [Segment] {
        var segments: [Segment] = []
        var current = ""
        var color: Int?
        var bold = false

        func flush() {
            if !current.isEmpty {
                segments.append(Segment(text: current, colorCode: color, isBold: bold))
                current = ""
            }
        }

        var index = string.startIndex
        while index < string.endIndex {
            let character = string[index]
            // A bare ESC (not starting a CSI sequence) is still a control byte —
            // drop it rather than leak it into the rendered text.
            if character == "\u{1B}",
               string.index(after: index) >= string.endIndex || string[string.index(after: index)] != "[" {
                index = string.index(after: index)
                continue
            }
            if character == "\u{1B}",
               string.index(after: index) < string.endIndex,
               string[string.index(after: index)] == "[" {
                // Collect parameter bytes up to the terminating letter.
                var cursor = string.index(index, offsetBy: 2)
                var params = ""
                while cursor < string.endIndex, !string[cursor].isLetter {
                    params.append(string[cursor])
                    cursor = string.index(after: cursor)
                }
                if cursor < string.endIndex, string[cursor] == "m" {
                    flush()
                    if params.isEmpty { color = nil; bold = false }  // ESC[m == reset
                    for token in params.split(separator: ";") {
                        guard let code = Int(token) else { continue }
                        switch code {
                        case 0: color = nil; bold = false
                        case 1: bold = true
                        case 22: bold = false
                        case 30...37, 90...97: color = code
                        case 39: color = nil
                        default: break  // backgrounds/256-color unsupported, ignored
                        }
                    }
                }
                // Skip the whole escape (SGR or otherwise).
                index = cursor < string.endIndex ? string.index(after: cursor) : cursor
                continue
            }
            current.append(character)
            index = string.index(after: index)
        }
        flush()
        return segments
    }
}

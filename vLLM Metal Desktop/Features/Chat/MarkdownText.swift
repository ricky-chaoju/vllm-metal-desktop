import AppKit
import SwiftUI

/// The display width an image asks for (HTML `<img width=…>`); Markdown images have none.
enum ImageWidth: Equatable {
    case natural        // no hint — cap to a sane size
    case points(CGFloat) // explicit pixel width
    case fill           // percentage width (e.g. 100%) — span the container
}

/// A parsed Markdown block.
enum MarkdownBlock: Equatable {
    case heading(level: Int, text: String)
    case paragraph(String)
    case centeredParagraph(String)
    case svg(String)
    case bullet(String)
    case numbered(Int, String)
    case quote(String)
    case code(language: String?, code: String)
    case image(url: URL, alt: String, width: ImageWidth)
    case table(headers: [String], rows: [[String]])
    case rule

    var isListItem: Bool {
        switch self {
        case .bullet, .numbered: return true
        default: return false
        }
    }

    /// Line-based Markdown parser covering the blocks that show up in chat
    /// replies and HF READMEs: headings, lists, quotes, rules, fenced code,
    /// standalone images, and paragraphs (with inline styling applied later).
    static func parse(_ rawMarkdown: String, baseURL: URL? = nil) -> [MarkdownBlock] {
        // Normalise embedded HTML first: drop <svg>/<style>/<script>, turn <a> into
        // Markdown links, and fold the inner whitespace of <div>/<p> blocks onto one
        // line — so a centered nav split across source lines renders as one line.
        let markdown = normalizeHTML(rawMarkdown)

        var blocks: [MarkdownBlock] = []
        var paragraph: [String] = []
        var codeLines: [String] = []
        var language: String?
        var inCode = false
        var htmlSkipClose: String?   // when set, drop lines until this close tag (e.g. "</svg>")
        var alignStack: [Bool] = []  // centered? per open <div>/<p>/<center>

        func flushParagraph() {
            // Join soft-wrapped source lines with a space so the paragraph flows and
            // re-wraps to the view width (Markdown treats a single newline as a space).
            let text = paragraph.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                blocks.append(alignStack.contains(true) ? .centeredParagraph(text) : .paragraph(text))
            }
            paragraph.removeAll()
        }

        var quoteLines: [String] = []
        func flushQuote() {
            if !quoteLines.isEmpty {
                blocks.append(.quote(quoteLines.joined(separator: " ")))
                quoteLines.removeAll()
            }
        }

        var tableRows: [String] = []
        func flushTable() {
            defer { tableRows.removeAll() }
            guard tableRows.count >= 2, isSeparatorRow(tableRows[1]) else {
                for row in tableRows { blocks.append(.paragraph(row)) }
                return
            }
            let headers = cells(tableRows[0])
            let dataRows = tableRows.dropFirst(2).map { cells($0) }
            blocks.append(.table(headers: headers, rows: Array(dataRows)))
        }

        for line in markdown.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Drop multi-line embedded HTML blocks (SVG logos, <style>, <script>)
            // wholesale — otherwise their raw guts (e.g. <path> coordinates) leak in.
            if !inCode {
                if let close = htmlSkipClose {
                    if trimmed.range(of: close, options: .caseInsensitive) != nil { htmlSkipClose = nil }
                    continue
                }
                if let svg = svgMarkup(trimmed) {
                    flushParagraph(); blocks.append(.svg(svg)); continue
                }
                if let tag = multilineHTMLBlock(trimmed) {
                    flushParagraph()
                    if trimmed.range(of: "</\(tag)>", options: .caseInsensitive) == nil {
                        htmlSkipClose = "</\(tag)>"
                    }
                    continue
                }
            }

            let isTableRow = !inCode && trimmed.hasPrefix("|") && trimmed.dropFirst().contains("|")
            if !isTableRow && !tableRows.isEmpty { flushTable() }

            // A run of consecutive `>` lines is one quote; flush it when the run ends.
            if !(trimmed.hasPrefix(">")) && !quoteLines.isEmpty { flushQuote() }

            if trimmed.hasPrefix("```") {
                if inCode {
                    blocks.append(.code(language: language, code: codeLines.joined(separator: "\n")))
                    codeLines.removeAll(); language = nil; inCode = false
                } else {
                    flushParagraph()
                    inCode = true
                    let tag = trimmed.dropFirst(3).trimmingCharacters(in: .whitespaces)
                    language = tag.isEmpty ? nil : tag
                }
                continue
            }
            if inCode { codeLines.append(line); continue }

            if isTableRow { flushParagraph(); tableRows.append(trimmed); continue }

            if trimmed.isEmpty { flushParagraph(); continue }

            if let htmlImage = htmlImageSrc(trimmed, baseURL: baseURL) {
                flushParagraph(); blocks.append(.image(url: htmlImage.url, alt: "", width: htmlImage.width)); continue
            }
            if let tag = htmlWrapperTag(trimmed) {
                flushParagraph()
                if tag.isCenterableClose { if !alignStack.isEmpty { alignStack.removeLast() } }
                else if tag.isCenterableOpen { alignStack.append(tag.centered) }
                continue
            }

            if let heading = headingMatch(trimmed) {
                flushParagraph(); blocks.append(.heading(level: heading.level, text: heading.text)); continue
            }
            if isRule(trimmed) {
                flushParagraph(); blocks.append(.rule); continue
            }
            if let image = imageMatch(trimmed, baseURL: baseURL) {
                flushParagraph(); blocks.append(.image(url: image.url, alt: image.alt, width: .natural)); continue
            }
            if trimmed.hasPrefix(">") {
                flushParagraph()
                quoteLines.append(String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces))
                continue
            }
            if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") || trimmed.hasPrefix("+ ") {
                flushParagraph(); blocks.append(.bullet(String(trimmed.dropFirst(2)))); continue
            }
            if let numbered = numberedMatch(trimmed) {
                flushParagraph(); blocks.append(.numbered(numbered.n, numbered.text)); continue
            }

            paragraph.append(line)
        }
        if inCode {
            blocks.append(.code(language: language, code: codeLines.joined(separator: "\n")))
        } else {
            flushTable()
            flushQuote()
            flushParagraph()
        }
        return blocks
    }

    private static func cells(_ row: String) -> [String] {
        var parts = row.split(separator: "|", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        if parts.first == "" { parts.removeFirst() }
        if parts.last == "" { parts.removeLast() }
        return parts
    }

    private static func isSeparatorRow(_ row: String) -> Bool {
        let columns = cells(row)
        guard !columns.isEmpty else { return false }
        return columns.allSatisfy { cell in
            !cell.isEmpty && cell.contains("-") && Set(cell).isSubset(of: [":", "-", " "])
        }
    }

    private static func headingMatch(_ s: String) -> (level: Int, text: String)? {
        guard let range = s.range(of: #"^#{1,6} "#, options: .regularExpression) else { return nil }
        let level = s[s.startIndex..<range.upperBound].filter { $0 == "#" }.count
        return (level, String(s[range.upperBound...]).trimmingCharacters(in: .whitespaces))
    }

    private static func numberedMatch(_ s: String) -> (n: Int, text: String)? {
        guard let range = s.range(of: #"^\d{1,3}\. "#, options: .regularExpression) else { return nil }
        let n = Int(s[s.startIndex..<range.upperBound].prefix(while: \.isNumber)) ?? 0
        return (n, String(s[range.upperBound...]))
    }

    private static func isRule(_ s: String) -> Bool {
        let chars = Set(s.replacingOccurrences(of: " ", with: ""))
        return s.count >= 3 && (chars == ["-"] || chars == ["*"] || chars == ["_"])
    }

    private static func imageMatch(_ s: String, baseURL: URL?) -> (url: URL, alt: String)? {
        guard let regex = try? NSRegularExpression(pattern: #"^!\[([^\]]*)\]\(([^)\s]+)[^)]*\)$"#),
              let match = regex.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)),
              let altRange = Range(match.range(at: 1), in: s),
              let urlRange = Range(match.range(at: 2), in: s),
              let url = resolveURL(String(s[urlRange]), baseURL: baseURL) else { return nil }
        return (url, String(s[altRange]))
    }

    /// Extracts the `src` (and any `width`) of an HTML `<img …>`.
    private static func htmlImageSrc(_ s: String, baseURL: URL?) -> (url: URL, width: ImageWidth)? {
        guard s.range(of: "<img", options: .caseInsensitive) != nil,
              let regex = try? NSRegularExpression(pattern: #"<img[^>]*\ssrc\s*=\s*["']([^"']+)["']"#, options: [.caseInsensitive]),
              let match = regex.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)),
              let range = Range(match.range(at: 1), in: s),
              let url = resolveURL(String(s[range]), baseURL: baseURL) else { return nil }
        return (url, htmlImageWidth(s))
    }

    /// Reads `width="200"` (points) or `width="100%"` (fill) from an `<img>` tag.
    private static func htmlImageWidth(_ s: String) -> ImageWidth {
        guard let regex = try? NSRegularExpression(pattern: #"<img[^>]*\swidth\s*=\s*["']?\s*([0-9]+%?)"#, options: [.caseInsensitive]),
              let match = regex.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)),
              let range = Range(match.range(at: 1), in: s) else { return .natural }
        let token = String(s[range])
        if token.hasSuffix("%") { return .fill }
        if let value = Double(token), value > 0 { return .points(CGFloat(value)) }
        return .natural
    }

    /// Resolves an image/link target to an absolute URL — relative paths in HF
    /// READMEs (`figures/x.png`) resolve against the repo's `resolve/main/` base.
    private static func resolveURL(_ string: String, baseURL: URL?) -> URL? {
        let trimmed = string.trimmingCharacters(in: .whitespaces)
        if let absolute = URL(string: trimmed), absolute.scheme != nil { return absolute }
        if let base = baseURL, let resolved = URL(string: trimmed, relativeTo: base) { return resolved.absoluteURL }
        return URL(string: trimmed)
    }

    /// If the line opens a multi-line embedded HTML block we render nothing for
    /// (`<svg>`, `<style>`, `<script>`), returns its tag name so the caller can
    /// drop everything through the matching close tag.
    private static func multilineHTMLBlock(_ s: String) -> String? {
        for tag in ["style", "script"] where s.range(of: "<\(tag)", options: .caseInsensitive) != nil {
            return tag
        }
        return nil
    }

    /// Extracts a whole `<svg …>…</svg>` element from a (normalised, single-line) line.
    private static func svgMarkup(_ s: String) -> String? {
        guard s.range(of: "<svg", options: .caseInsensitive) != nil,
              let regex = try? NSRegularExpression(pattern: #"<svg\b[^>]*>.*</svg>"#, options: [.caseInsensitive, .dotMatchesLineSeparators]),
              let match = regex.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)),
              let range = Range(match.range, in: s) else { return nil }
        return String(s[range])
    }

    /// Rasterises inline SVG markup. `currentColor` (usually a wordmark) resolves
    /// to the appearance's text color so it stays visible in both modes, and the
    /// CSS width/height are dropped so AppKit sizes from the `viewBox` aspect.
    static func svgImage(_ markup: String, darkMode: Bool) -> NSImage? {
        var resolved = markup.replacingOccurrences(of: "currentColor", with: darkMode ? "#F2F2F2" : "#1F2328")
        resolved = resolved.replacingOccurrences(of: #"\s(?:width|height)\s*=\s*"[^"]*""#, with: "", options: [.regularExpression, .caseInsensitive])
        let image = NSImage(data: Data(resolved.utf8))
        return (image?.isValid ?? false) ? image : nil
    }

    /// Classifies a line that is *only* an HTML wrapper tag (`<div …>`, `</p>`, …).
    /// Returns `nil` for non-wrapper lines. `isCenterable*` flag `<div>/<p>/<center>`
    /// open/close so the parser can track a centered context; `centered` is true when
    /// that container requests center alignment.
    private static func htmlWrapperTag(_ s: String) -> (isCenterableOpen: Bool, isCenterableClose: Bool, centered: Bool)? {
        guard let regex = try? NSRegularExpression(pattern: #"^</?([a-zA-Z][a-zA-Z0-9]*)\b[^>]*>$"#, options: [.caseInsensitive]),
              let match = regex.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)),
              let nameRange = Range(match.range(at: 1), in: s) else { return nil }
        let name = s[nameRange].lowercased()
        let known: Set<String> = ["p", "div", "center", "span", "a", "picture", "source",
                                   "table", "tr", "td", "th", "tbody", "thead",
                                   "details", "summary", "font", "br", "hr", "figure", "video"]
        guard known.contains(name) else { return nil }
        let isClose = s.hasPrefix("</")
        let centerable = (name == "div" || name == "p" || name == "center")
        let centered = name == "center"
            || s.range(of: #"(align\s*=\s*["']?center|text-align\s*:\s*center)"#, options: [.regularExpression, .caseInsensitive]) != nil
        return (centerable && !isClose, centerable && isClose, centered)
    }

    // MARK: - HTML normalisation

    /// Pre-pass that makes embedded HTML survive the line-based Markdown parser:
    /// removes non-rendered blocks, converts anchors to Markdown links, and folds
    /// the inner whitespace of `<div>`/`<p>` containers so inline content sits on one
    /// line (HTML collapses that whitespace; the parser otherwise wouldn't).
    static func normalizeHTML(_ text: String) -> String {
        var s = text
        // Strip blocks we never render…
        for tag in ["style", "script"] {
            s = replacingMatches(s, pattern: "<\(tag)\\b[^>]*>.*?</\(tag)>", options: [.caseInsensitive, .dotMatchesLineSeparators]) { _, _ in "" }
        }
        // …but keep <svg> logos: fold them onto a single line so the parser can
        // capture the whole element and render it as an image.
        s = replacingMatches(s, pattern: #"<svg\b[^>]*>.*?</svg>"#, options: [.caseInsensitive, .dotMatchesLineSeparators]) { match, ns in
            "\n" + collapseWhitespace(ns.substring(with: match.range)) + "\n"
        }
        // <br> → newline.
        s = replacingMatches(s, pattern: #"<br\s*/?>"#, options: [.caseInsensitive]) { _, _ in "\n" }
        // <a href="URL">TEXT</a> → [TEXT](URL), collapsing TEXT across lines.
        s = replacingMatches(s, pattern: #"<a\b[^>]*?href\s*=\s*["']([^"']+)["'][^>]*>(.*?)</a>"#,
                             options: [.caseInsensitive, .dotMatchesLineSeparators]) { match, ns in
            let url = ns.substring(with: match.range(at: 1))
            let label = collapseWhitespace(ns.substring(with: match.range(at: 2)))
            return label.isEmpty ? "" : "[\(label)](\(url))"
        }
        // Fold <div>/<p> inner newlines to spaces, keeping the tags on their own lines.
        s = replacingMatches(s, pattern: #"(<(div|p)\b[^>]*>)(.*?)(</\2>)"#,
                             options: [.caseInsensitive, .dotMatchesLineSeparators]) { match, ns in
            let open = ns.substring(with: match.range(at: 1))
            let inner = collapseWhitespace(ns.substring(with: match.range(at: 3)))
            let close = ns.substring(with: match.range(at: 4))
            return "\(open)\n\(inner)\n\(close)"
        }
        return s
    }

    private static func collapseWhitespace(_ s: String) -> String {
        s.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }

    /// Forward-assembles a new string, replacing each regex match with `transform`'s
    /// result. Iterating forward keeps group ranges valid against the original string.
    private static func replacingMatches(
        _ text: String,
        pattern: String,
        options: NSRegularExpression.Options,
        transform: (NSTextCheckingResult, NSString) -> String
    ) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else { return text }
        let ns = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return text }
        var result = ""
        var cursor = 0
        for match in matches {
            result += ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            result += transform(match, ns)
            cursor = match.range.location + match.range.length
        }
        result += ns.substring(from: cursor)
        return result
    }
}

/// Renders Markdown — headings, lists, quotes, rules, images, and code blocks —
/// with inline styling for prose. Used for chat replies and model READMEs.
struct MarkdownText: View {
    let text: String
    /// Base for resolving relative image/link paths (e.g. a HF repo's `resolve/main/`).
    var baseURL: URL? = nil

    // Window-level lightbox host (absent in previews — tapping is then a no-op).
    @Environment(ImageZoomModel.self) private var imageZoom: ImageZoomModel?
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.appTextScale) private var textScale

    /// A run of consecutive flow blocks merged into one selectable string, or a
    /// standalone block (code/image/svg/table/centered/rule) rendered on its own.
    private enum Segment {
        case flow(AttributedString)
        case block(MarkdownBlock)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                switch segment {
                case .flow(let attributed):
                    // One Text per run → text selection spans across paragraphs,
                    // list items and quotes so the user can copy a continuous range.
                    Text(attributed)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                case .block(let block):
                    view(for: block)
                }
            }
        }
        // Body text everywhere markdown renders (chat, READMEs, docs) follows
        // the Text size setting.
        .scaledFont(.body)
        // Merged list items sit one bare newline apart — a little leading
        // keeps them (and wrapped paragraphs) from feeling cramped.
        .lineSpacing(3)
    }

    private var segments: [Segment] {
        var result: [Segment] = []
        var flow: [MarkdownBlock] = []
        func flush() {
            if !flow.isEmpty { result.append(.flow(Self.buildFlow(flow, scale: textScale))); flow.removeAll() }
        }
        for block in MarkdownBlock.parse(text, baseURL: baseURL) {
            switch block {
            case .heading, .paragraph, .bullet, .numbered:
                flow.append(block)
            default:
                // Quotes/code/images/tables/SVG render standalone (a quote keeps its
                // left rule; it stays internally selectable as one block).
                flush(); result.append(.block(block))
            }
        }
        flush()
        return result
    }

    /// Concatenates flow blocks into a single styled `AttributedString`.
    private static func buildFlow(_ blocks: [MarkdownBlock], scale: CGFloat) -> AttributedString {
        var out = AttributedString()
        for (index, block) in blocks.enumerated() {
            if index > 0 {
                let tight = block.isListItem && blocks[index - 1].isListItem
                out += AttributedString(tight ? "\n" : "\n\n")
            }
            out += piece(for: block, scale: scale)
        }
        return out
    }

    private static func piece(for block: MarkdownBlock, scale: CGFloat) -> AttributedString {
        switch block {
        case .heading(let level, let text):
            var s = inline(text)
            s.font = .system(size: headingSize(level) * scale, weight: .bold)
            return s
        case .paragraph(let text):
            return inline(text)
        case .bullet(let text):
            var marker = AttributedString("•  ")
            marker.foregroundColor = .secondary
            return marker + inline(text)
        case .numbered(let n, let text):
            var marker = AttributedString("\(n).  ")
            marker.foregroundColor = .secondary
            return marker + inline(text)
        case .quote(let text):
            var s = inline(text)
            s.foregroundColor = .secondary
            return s
        default:
            return AttributedString()
        }
    }

    /// Heading point sizes (title2/title3/headline/subheadline macOS metrics),
    /// multiplied by the Text size setting's scale.
    private static func headingSize(_ level: Int) -> CGFloat {
        switch level {
        case 1: 17
        case 2: 15
        case 3: 13
        default: 11
        }
    }

    @ViewBuilder
    private func view(for block: MarkdownBlock) -> some View {
        switch block {
        case .heading(let level, let text):
            Text(Self.inline(text))
                .font(.system(size: Self.headingSize(level) * textScale, weight: .bold))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, level <= 2 ? 4 : 0)
        case .paragraph(let text):
            inlineText(text).frame(maxWidth: .infinity, alignment: .leading)
        case .centeredParagraph(let text):
            inlineText(text)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity, alignment: .center)
        case .bullet(let text):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("•").foregroundStyle(.secondary)
                inlineText(text).frame(maxWidth: .infinity, alignment: .leading)
            }
        case .numbered(let n, let text):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("\(n).").foregroundStyle(.secondary).monospacedDigit()
                inlineText(text).frame(maxWidth: .infinity, alignment: .leading)
            }
        case .quote(let text):
            Text(Self.inline(text))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .padding(.leading, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .overlay(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                        .fill(.secondary.opacity(0.45))
                        .frame(width: 3)
                }
        case .code(let language, let code):
            CodeBlock(language: language, code: code)
        case .svg(let markup):
            if let image = MarkdownBlock.svgImage(markup, darkMode: colorScheme == .dark) {
                Image(nsImage: image)
                    .resizable().scaledToFit()
                    .frame(maxHeight: 60)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 4)
            }
        case .image(let url, _, let width):
            imageView(url: url, width: width)
        case .table(let headers, let rows):
            tableView(headers: headers, rows: rows)
        case .rule:
            Divider()
        }
    }

    private func inlineText(_ string: String) -> some View {
        let attributed = Self.inline(string)
        let hasLink = attributed.runs.contains { $0.link != nil }
        // Selection comes from the document-level `.textSelection`; link lines
        // additionally get the pointing-hand cursor.
        return Text(attributed).pointingHandCursor(hasLink)
    }

    /// Renders an image at the size the document asks for — explicit `<img width>`
    /// is honoured (so badges/logos stay small), percentage widths fill the column,
    /// and unsized Markdown images cap to a sane size. Tap to enlarge.
    @ViewBuilder
    private func imageView(url: URL, width: ImageWidth) -> some View {
        let image = AsyncImage(url: url) { phase in
            if let image = phase.image {
                image.resizable().scaledToFit()
                    .contentShape(Rectangle())
                    .onTapGesture { imageZoom?.show(url) }
                    .pointingHandCursor()
                    .help("Click to enlarge")
            } else {
                EmptyView()
            }
        }
        switch width {
        case .points(let points):
            image.frame(maxWidth: points, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .fill:
            image.frame(maxWidth: .infinity, maxHeight: 420, alignment: .center)
        case .natural:
            image.frame(maxWidth: 460, maxHeight: 320, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func tableView(headers: [String], rows: [[String]]) -> some View {
        let columns = max(headers.count, 1)
        return ScrollView(.horizontal, showsIndicators: true) {
            Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
                GridRow {
                    ForEach(0..<columns, id: \.self) { column in
                        tableCell(column < headers.count ? headers[column] : "",
                                  header: true, lastColumn: column == columns - 1, lastRow: rows.isEmpty)
                    }
                }
                ForEach(rows.indices, id: \.self) { row in
                    GridRow {
                        ForEach(0..<columns, id: \.self) { column in
                            tableCell(column < rows[row].count ? rows[row][column] : "",
                                      header: false, lastColumn: column == columns - 1, lastRow: row == rows.count - 1)
                        }
                    }
                }
            }
            // Size columns to content (no mid-word wrapping); scroll if too wide.
            .fixedSize(horizontal: true, vertical: false)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(Color.gray.opacity(0.35), lineWidth: 1))
            .padding(.bottom, 4)
        }
    }

    private func tableCell(_ text: String, header: Bool, lastColumn: Bool, lastRow: Bool) -> some View {
        let attributed = Self.inline(text)
        let hasLink = attributed.runs.contains { $0.link != nil }
        return Text(attributed)
            .scaledFont(.callout)
            .fontWeight(header ? .semibold : .regular)
            .lineLimit(1)
            .padding(.horizontal, 10).padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .pointingHandCursor(hasLink)
            .background(header ? Color.gray.opacity(0.12) : Color.clear)
            .overlay(alignment: .trailing) {
                if !lastColumn { Rectangle().fill(Color.gray.opacity(0.35)).frame(width: 1) }
            }
            .overlay(alignment: .bottom) {
                if !lastRow { Rectangle().fill(Color.gray.opacity(0.35)).frame(height: 1) }
            }
    }

    static func inline(_ string: String) -> AttributedString {
        let cleaned = stripHTMLTags(string)
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace,
            failurePolicy: .returnPartiallyParsedIfPossible
        )
        return (try? AttributedString(markdown: cleaned, options: options)) ?? AttributedString(cleaned)
    }

    /// Removes leftover inline HTML tags (`<a href=…>`, `</a>`, `<sup>`, `<br>`, …)
    /// so they don't render as literal text. Matches only known tag names, leaving
    /// things like `Vec<T>` or `<https://…>` autolinks intact.
    private static let htmlTagRegex = try? NSRegularExpression(
        pattern: #"</?(?:a|abbr|b|br|center|details|div|em|figure|font|g|h[1-6]|hr|i|img|kbd|li|mark|ol|p|path|picture|pre|s|small|source|span|strong|sub|summary|sup|svg|table|tbody|td|th|thead|tr|u|ul|video)\b[^>]*/?>"#,
        options: [.caseInsensitive]
    )

    static func stripHTMLTags(_ string: String) -> String {
        guard let regex = htmlTagRegex else { return string }
        let range = NSRange(string.startIndex..., in: string)
        let stripped = regex.stringByReplacingMatches(in: string, range: range, withTemplate: "")
        return stripped.trimmingCharacters(in: .whitespaces)
    }
}

/// Holds the image currently shown enlarged. Hosted once at the window root
/// (`RootView`) so the lightbox can fill the existing window without resizing it.
@MainActor @Observable
final class ImageZoomModel {
    var url: URL?
    func show(_ url: URL) { self.url = url }
    func dismiss() { url = nil }
}

/// A lightbox that fills its container (the whole window) and fits the image to its
/// aspect ratio. Dismissed by Esc, the ✕ button, or a click anywhere.
struct ImageLightbox: View {
    let url: URL
    let onClose: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.62).ignoresSafeArea()

            VStack(spacing: 4) {
                // ✕ lives in its own top bar so it never sits on top of the image.
                HStack {
                    Spacer()
                    Button(action: onClose) {
                        Image(systemName: "xmark.circle.fill")
                            .scaledFont(.title2)
                            .symbolRenderingMode(.hierarchical)
                            .foregroundStyle(.white, .white.opacity(0.18))
                    }
                    .buttonStyle(.plain)
                    .pointingHandCursor()
                    .keyboardShortcut(.cancelAction) // Esc
                    .help("Close")
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)

                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().scaledToFit()
                    case .failure:
                        Label("Couldn't load image", systemImage: "photo.badge.exclamationmark")
                            .foregroundStyle(.white.opacity(0.85))
                    default:
                        ProgressView().controlSize(.large)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding([.horizontal, .bottom], 28)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Click anywhere (backdrop or image) dismisses.
        .contentShape(Rectangle())
        .onTapGesture { onClose() }
    }
}

struct CodeBlock: View {
    let language: String?
    let code: String
    @State private var copied = false
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(language ?? "code").scaledFont(.caption2).foregroundStyle(.secondary)
                Spacer()
                Button {
                    Pasteboard.copy(code)
                    copied = true
                    Task { try? await Task.sleep(for: .seconds(1.2)); copied = false }
                } label: {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc").scaledFont(.caption2)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10).padding(.vertical, 5)

            Divider()

            ScrollView(.horizontal, showsIndicators: false) {
                Text(CodeHighlighter.highlight(code))
                    .scaledFont(.callout, design: .monospaced)
                    .textSelection(.enabled)
                    .padding(10)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.black.opacity(colorScheme == .dark ? 0.28 : 0.045))
        )
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(.quaternary, lineWidth: 1))
    }
}

/// Lightweight, language-agnostic syntax highlighting via regex. Colors strings,
/// comments, numbers, and common keywords — enough to make code blocks colorful.
enum CodeHighlighter {
    private static let keywords: Set<String> = [
        "def", "class", "return", "if", "elif", "else", "for", "while", "import", "from",
        "as", "func", "let", "var", "const", "function", "public", "private", "static",
        "void", "true", "false", "none", "null", "nil", "self", "this", "new", "try",
        "catch", "except", "finally", "with", "in", "is", "and", "or", "not", "async",
        "await", "yield", "lambda", "struct", "enum", "extends", "implements", "switch",
        "case", "break", "continue", "do", "export", "default", "throw", "guard",
    ]

    static func highlight(_ code: String) -> AttributedString {
        let attributed = NSMutableAttributedString(
            string: code,
            attributes: [.foregroundColor: NSColor.labelColor]
        )
        let full = NSRange(location: 0, length: attributed.length)

        func apply(_ pattern: String, _ color: NSColor, options: NSRegularExpression.Options = []) {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else { return }
            regex.enumerateMatches(in: code, range: full) { match, _, _ in
                if let range = match?.range {
                    attributed.addAttribute(.foregroundColor, value: color, range: range)
                }
            }
        }

        apply(#"\b\d+(\.\d+)?\b"#, .systemPurple)
        let keywordPattern = "\\b(" + keywords.joined(separator: "|") + ")\\b"
        apply(keywordPattern, .systemTeal)
        // Strings and comments last so they override keyword/number coloring inside them.
        apply(#""([^"\\]|\\.)*""#, .systemOrange)
        apply(#"'([^'\\]|\\.)*'"#, .systemOrange)
        apply(#"//[^\n]*"#, .systemGreen)
        apply(#"#[^\n]*"#, .systemGreen)
        apply(#"/\*[\s\S]*?\*/"#, .systemGreen)

        return AttributedString(attributed)
    }
}

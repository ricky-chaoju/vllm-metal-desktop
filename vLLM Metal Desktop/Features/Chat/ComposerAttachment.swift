import AppKit
import PDFKit
import UniformTypeIdentifiers
import VMDCore

/// One file staged in the composer (or persisted on a sent message).
///
/// Handling per kind:
/// - **image** → downscaled, JPEG-encoded, sent as an OpenAI `image_url`
///   content part (base64 data URI). Only offered when the served model's
///   config says it accepts images.
/// - **text** (plain text, source code, JSON/CSV/YAML, …) → contents inlined
///   into the prompt inside a fenced block. Works with any model.
/// - **pdf** → text extracted with PDFKit, inlined the same way.
struct ComposerAttachment: Identifiable, Equatable {
    enum Kind: String {
        case image, text, pdf
    }

    let id = UUID()
    /// Our own copy under Application Support (survives the original moving).
    let url: URL
    let kind: Kind

    var displayName: String { url.lastPathComponent }

    /// Caps to keep prompts sane: ~60k chars of file text, 2048px images.
    static let maxInlineCharacters = 60_000
    static let maxImageDimension: CGFloat = 2048

    // MARK: Classification

    static func kind(of url: URL) -> Kind? {
        guard let type = UTType(filenameExtension: url.pathExtension.lowercased()) else { return nil }
        if type.conforms(to: .image) { return .image }
        if type.conforms(to: .pdf) { return .pdf }
        if type.conforms(to: .text) { return .text }  // covers source code, JSON, CSV, YAML…
        return nil
    }

    /// Stages a file: classifies it and copies it into the attachments library.
    static func stage(_ source: URL, bundleID: String) -> ComposerAttachment? {
        guard let kind = kind(of: source) else { return nil }
        let library = EnginePaths.standard.appSupport(bundleID: bundleID)
            .appending(path: "Attachments", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
        let copy = library.appending(
            path: "\(UUID().uuidString.prefix(8))-\(source.lastPathComponent)",
            directoryHint: .notDirectory
        )
        do {
            try FileManager.default.copyItem(at: source, to: copy)
        } catch {
            return nil
        }
        return ComposerAttachment(url: copy, kind: kind)
    }

    /// Rehydrates a persisted path (for history payloads and bubble display).
    static func fromPath(_ path: String) -> ComposerAttachment? {
        let url = URL(fileURLWithPath: path)
        guard let kind = kind(of: url) else { return nil }
        return ComposerAttachment(url: url, kind: kind)
    }

    // MARK: Payload building

    /// The `data:` URI for an image attachment, downscaled and re-encoded so a
    /// 48MP photo doesn't become a 60MB request.
    var imageDataURI: String? {
        guard kind == .image, let image = NSImage(contentsOf: url) else { return nil }
        let size = image.size
        let scale = min(1, Self.maxImageDimension / max(size.width, size.height, 1))
        let target = NSSize(width: size.width * scale, height: size.height * scale)

        let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(target.width), pixelsHigh: Int(target.height),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        )
        guard let bitmap else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        image.draw(in: NSRect(origin: .zero, size: target))
        NSGraphicsContext.restoreGraphicsState()
        guard let jpeg = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.85]) else {
            return nil
        }
        return "data:image/jpeg;base64,\(jpeg.base64EncodedString())"
    }

    /// The inline-prompt block for text/PDF attachments, or `nil` for images.
    var inlineText: String? {
        let raw: String?
        switch kind {
        case .image:
            return nil
        case .text:
            raw = try? String(contentsOf: url, encoding: .utf8)
        case .pdf:
            raw = PDFDocument(url: url)?.string
        }
        guard var text = raw else { return nil }
        if text.count > Self.maxInlineCharacters {
            text = String(text.prefix(Self.maxInlineCharacters)) + "\n… [truncated]"
        }
        return "[Attached file: \(displayName)]\n```\n\(text)\n```"
    }

    /// Builds the message content for a prompt plus attachments: file text is
    /// inlined; images become content parts (only sensible on vision models).
    static func buildContent(text: String, attachments: [ComposerAttachment]) -> ChatContent {
        var combined = text
        for inline in attachments.compactMap(\.inlineText) {
            combined += (combined.isEmpty ? "" : "\n\n") + inline
        }
        let imageParts = attachments.compactMap(\.imageDataURI).map(ChatContentPart.imageURL)
        if imageParts.isEmpty {
            return .text(combined)
        }
        return .parts([.text(combined)] + imageParts)
    }
}

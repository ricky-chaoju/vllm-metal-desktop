import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The actual product image macOS ships for a Mac model ("Mac14,8" → the Mac
/// Pro render), resolved through the device-model-code UTType. Falls back to a
/// generic laptop symbol for unknown/foreign identifiers.
struct MacModelIcon: View {
    let modelIdentifier: String?
    var size: CGFloat = 28

    var body: some View {
        if let modelIdentifier, let image = Self.image(for: modelIdentifier) {
            Image(nsImage: image)
                .resizable()
                .scaledToFit()
                .frame(width: size, height: size)
        } else {
            Image(systemName: "macbook")
                .scaledFont(.title3)
                .foregroundStyle(Color.accentColor)
                .frame(width: size, height: size)
        }
    }

    static func image(for identifier: String) -> NSImage? {
        guard let type = UTType(
            tag: identifier,
            tagClass: UTTagClass(rawValue: "com.apple.device-model-code"),
            conformingTo: nil
        ) else { return nil }
        return NSWorkspace.shared.icon(for: type)
    }
}

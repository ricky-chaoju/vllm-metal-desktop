import AppKit
import SwiftUI

extension View {
    /// Shows the pointing-hand cursor while the pointer is over this view — for
    /// links and tappable `.plain` buttons that AppKit otherwise leaves as an arrow.
    ///
    /// `onContinuousHover` re-asserts the cursor on every move, so SwiftUI/AppKit
    /// can't reset it back mid-hover (which is why `onHover` + `push/pop` and
    /// `pointerStyle` both flickered out). Pass `active: false` to opt out inline.
    func pointingHandCursor(_ active: Bool = true) -> some View {
        onContinuousHover { phase in
            guard active else { return }
            switch phase {
            case .active: NSCursor.pointingHand.set()
            case .ended: NSCursor.arrow.set()
            }
        }
    }
}

/// A compact pill/badge. Glass-backed on macOS 26, tinted material otherwise.
struct Tag: View {
    var text: String
    var systemImage: String?
    var tint: Color

    init(_ text: String, systemImage: String? = nil, tint: Color = .secondary) {
        self.text = text
        self.systemImage = systemImage
        self.tint = tint
    }

    var body: some View {
        HStack(spacing: 4) {
            if let systemImage { Image(systemName: systemImage) }
            Text(text)
        }
        .scaledFont(.caption, weight: .medium)
        .foregroundStyle(tint)
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .glassCapsule(tint: tint.opacity(0.10))
    }
}

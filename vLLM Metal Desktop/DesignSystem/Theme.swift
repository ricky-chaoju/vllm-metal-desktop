import SwiftUI

/// Lightweight design tokens. The full design system grows alongside the UI
/// milestones (docs/PLAN.md §5/§7); for now this centralizes the brand accent
/// and spacing so views don't hardcode values.
enum Theme {
    static let accent = Color.accentColor

    /// vLLM brand colors (from the logo: azure blue + amber).
    enum Brand {
        static let blue = Color(red: 0.290, green: 0.565, blue: 0.886)
        static let amber = Color(red: 0.945, green: 0.663, blue: 0.231)
    }

    enum Spacing {
        static let xs: CGFloat = 4
        static let s: CGFloat = 8
        static let m: CGFloat = 16
        static let l: CGFloat = 24
        static let xl: CGFloat = 32
    }

    enum Radius {
        static let s: CGFloat = 8
        static let m: CGFloat = 12
        static let l: CGFloat = 16
        static let xl: CGFloat = 22
    }
}

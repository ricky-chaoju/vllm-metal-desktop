import SwiftUI

// Liquid Glass helpers. On macOS 26+ these use the real `.glassEffect`; on older
// systems they fall back to a system material so the app still looks right.
// (Deployment target stays macOS 14; glass is an enhancement on Tahoe.)

extension View {
    @ViewBuilder
    func glassCapsule(tint: Color? = nil, interactive: Bool = false) -> some View {
        if #available(macOS 26.0, *) {
            let base = Glass.regular
            let glass = tint.map { base.tint($0) } ?? base
            self.glassEffect(glass.interactive(interactive), in: Capsule())
        } else {
            self.background(.regularMaterial, in: Capsule())
        }
    }

    @ViewBuilder
    func glassCard(cornerRadius: CGFloat = Theme.Radius.l, tint: Color? = nil) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        if #available(macOS 26.0, *) {
            let base = Glass.regular
            let glass = tint.map { base.tint($0) } ?? base
            self.glassEffect(glass, in: shape)
        } else {
            self.background(.regularMaterial, in: shape)
        }
    }
}

extension View {
    /// A floating glass pane for sidebars/rails (Apple Music style): real Liquid
    /// Glass on macOS 26; a material slab with a reflective rim highlight on older
    /// systems so the "catching the light" feel survives the fallback.
    @ViewBuilder
    func glassSidebar(cornerRadius: CGFloat = 18) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        if #available(macOS 26.0, *) {
            self
                // A whisper of white tint lifts the pane off dark backdrops
                // (plain glass is nearly invisible over uniform darkness), and a
                // gradient rim catches the light along the top-leading edge.
                .glassEffect(.regular.tint(.white.opacity(0.05)), in: shape)
                .overlay(
                    shape.strokeBorder(
                        LinearGradient(
                            colors: [.white.opacity(0.22), .white.opacity(0.03), .white.opacity(0.08)],
                            startPoint: .topLeading, endPoint: .bottomTrailing
                        ),
                        lineWidth: 1
                    )
                )
                .shadow(color: .black.opacity(0.22), radius: 12, y: 4)
        } else {
            self
                .background(.ultraThinMaterial, in: shape)
                .overlay(
                    shape.strokeBorder(
                        LinearGradient(
                            colors: [.white.opacity(0.28), .white.opacity(0.04), .white.opacity(0.10)],
                            startPoint: .topLeading, endPoint: .bottomTrailing
                        ),
                        lineWidth: 1
                    )
                )
                .shadow(color: .black.opacity(0.18), radius: 14, y: 6)
        }
    }
}

extension View {
    /// A prominent glass button on macOS 26, falling back to bordered-prominent.
    @ViewBuilder
    func glassProminentButton() -> some View {
        if #available(macOS 26.0, *) {
            self.buttonStyle(.glassProminent)
        } else {
            self.buttonStyle(.borderedProminent)
        }
    }
}

/// Groups glass shapes so they blend/morph together on macOS 26. A transparent
/// passthrough on older systems.
struct GlassGroup<Content: View>: View {
    var spacing: CGFloat
    @ViewBuilder var content: () -> Content

    init(spacing: CGFloat = Theme.Spacing.s, @ViewBuilder content: @escaping () -> Content) {
        self.spacing = spacing
        self.content = content
    }

    var body: some View {
        if #available(macOS 26.0, *) {
            GlassEffectContainer(spacing: spacing, content: content)
        } else {
            content()
        }
    }
}

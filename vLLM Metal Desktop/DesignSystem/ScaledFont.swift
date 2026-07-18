import SwiftUI

/// App-wide text sizing. macOS ignores Dynamic Type, so the Text size setting
/// is applied as a multiplier over each style's macOS base size: views opt in
/// with `.scaledFont(...)` instead of `.font(...)`, and `RootView` installs the
/// user's multiplier once via `.appTextScale(_:)`.
private struct AppTextScaleKey: EnvironmentKey {
    static let defaultValue: CGFloat = 1
}

extension EnvironmentValues {
    var appTextScale: CGFloat {
        get { self[AppTextScaleKey.self] }
        set { self[AppTextScaleKey.self] = newValue }
    }
}

extension View {
    /// Installs the user's text-size multiplier for every `scaledFont` below.
    func appTextScale(_ scale: CGFloat) -> some View {
        environment(\.appTextScale, scale)
    }

    /// A text-style font that follows the Text size setting.
    func scaledFont(
        _ style: Font.TextStyle,
        weight: Font.Weight? = nil,
        design: Font.Design = .default,
        monospacedDigit: Bool = false
    ) -> some View {
        modifier(ScaledFontModifier(
            size: ScaledFontModifier.baseSize(style),
            weight: weight ?? ScaledFontModifier.baseWeight(style),
            design: design,
            monospacedDigit: monospacedDigit
        ))
    }

    /// A fixed-point font that still follows the Text size setting.
    func scaledFont(size: CGFloat, weight: Font.Weight = .regular, design: Font.Design = .default) -> some View {
        modifier(ScaledFontModifier(size: size, weight: weight, design: design, monospacedDigit: false))
    }
}

private struct ScaledFontModifier: ViewModifier {
    @Environment(\.appTextScale) private var scale

    let size: CGFloat
    let weight: Font.Weight
    let design: Font.Design
    let monospacedDigit: Bool

    func body(content: Content) -> some View {
        let font = Font.system(size: size * scale, weight: weight, design: design)
        content.font(monospacedDigit ? font.monospacedDigit() : font)
    }

    /// macOS text-style metrics (HIG: body 13, callout 12, caption 10, …).
    static func baseSize(_ style: Font.TextStyle) -> CGFloat {
        switch style {
        case .largeTitle: 26
        case .title: 22
        case .title2: 17
        case .title3: 15
        case .headline: 13
        case .body: 13
        case .callout: 12
        case .subheadline: 11
        case .footnote: 10
        case .caption: 10
        case .caption2: 10
        @unknown default: 13
        }
    }

    static func baseWeight(_ style: Font.TextStyle) -> Font.Weight {
        style == .headline ? .semibold : .regular
    }
}

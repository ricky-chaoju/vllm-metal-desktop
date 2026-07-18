import AppKit
import SwiftUI

/// A soft, premium background: the system base with brand-colored glows. Its real
/// job is to give Liquid Glass something colorful to refract — glass is nearly
/// invisible over a flat background, but reads beautifully over this.
/// Follows the system appearance: bolder glows in dark, a pastel wash in light.
struct AppBackground: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            if colorScheme == .dark {
                // Whisper-level brand warmth (amber top-leading, blue bottom-
                // trailing) so the dark window isn't dead-flat and the glass rail
                // has something to refract. Corner-anchored for any window size.
                LinearGradient(
                    colors: [
                        Color(nsColor: .windowBackgroundColor),
                        Color(nsColor: .underPageBackgroundColor),
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
                Circle()
                    .fill(Theme.Brand.amber)
                    .frame(width: 560, height: 560)
                    .blur(radius: 140)
                    .opacity(0.07)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .offset(x: -180, y: -180)
                Circle()
                    .fill(Theme.Brand.blue)
                    .frame(width: 640, height: 640)
                    .blur(radius: 150)
                    .opacity(0.09)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                    .offset(x: 200, y: 220)
            } else {
                // Light mode: the same corner glows over the plain system base —
                // but no gray gradient underneath (that's what read as smudges).
                Color(nsColor: .windowBackgroundColor)
                Circle()
                    .fill(Theme.Brand.amber)
                    .frame(width: 560, height: 560)
                    .blur(radius: 140)
                    .opacity(0.05)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .offset(x: -180, y: -180)
                Circle()
                    .fill(Theme.Brand.blue)
                    .frame(width: 640, height: 640)
                    .blur(radius: 150)
                    .opacity(0.07)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                    .offset(x: 200, y: 220)
            }
        }
        .ignoresSafeArea()
    }
}

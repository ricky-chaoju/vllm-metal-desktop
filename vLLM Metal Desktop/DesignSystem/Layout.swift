import SwiftUI

extension View {
    /// Caps content width on wide windows so pages stay readable, centering
    /// the spare space. Chat uses a tight cap (bubbles shouldn't drift apart);
    /// reference/settings pages use the roomier default.
    func pageWidth(max: CGFloat = 1200) -> some View {
        frame(maxWidth: max)
            .frame(maxWidth: .infinity)
    }
}

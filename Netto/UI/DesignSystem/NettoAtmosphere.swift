import SwiftUI

/// The dashboard's atmosphere: a static, low-contrast wash painted behind the scroll content
/// so the gaps between cards read as depth instead of as flat background.
///
/// Gradients only — no materials, no blur, no animation. Reduce Transparency therefore has
/// nothing to change, Increase Contrast still meets an opaque background, and the wash never
/// sits under text (every card is opaque), so contrast is unaffected. The glow is designed
/// per appearance: brand in dark, the deeper brand in light.
private struct NettoAtmosphereModifier: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        content.background {
            ZStack {
                NettoColor.background

                // Soft top glow, quiet enough to be felt rather than seen.
                RadialGradient(
                    colors: [
                        NettoColor.atmosphereGlow.opacity(colorScheme == .dark ? 0.09 : 0.06),
                        NettoColor.atmosphereGlow.opacity(0)
                    ],
                    center: UnitPoint(x: 0.5, y: -0.04),
                    startRadius: 0,
                    endRadius: 460
                )

                // A veil that settles the top of the screen into the page.
                LinearGradient(
                    colors: [
                        NettoColor.surfaceSecondary.opacity(colorScheme == .dark ? 0.55 : 0.7),
                        NettoColor.surfaceSecondary.opacity(0)
                    ],
                    startPoint: .top,
                    endPoint: UnitPoint(x: 0.5, y: 0.34)
                )
            }
            .ignoresSafeArea()
        }
    }
}

extension View {
    /// The dashboard's background atmosphere. Applied once, behind the scrolling content.
    func nettoAtmosphere() -> some View {
        modifier(NettoAtmosphereModifier())
    }
}

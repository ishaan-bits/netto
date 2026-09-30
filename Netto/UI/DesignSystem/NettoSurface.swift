import SwiftUI

enum NettoSurfaceKind {
    case base
    case elevated
    case secondary
    case highlighted
    case translucent
    case photo
}

extension View {
    func nettoSurface(
        _ kind: NettoSurfaceKind = .elevated,
        cornerRadius: CGFloat = NettoLayout.Radius.card
    ) -> some View {
        background {
            switch kind {
            case .base:
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(NettoColor.background)
            case .elevated:
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(NettoColor.surface)
            case .secondary:
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(NettoColor.surfaceSecondary)
            case .highlighted:
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(NettoColor.surfaceHighlight)
                    .overlay {
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .strokeBorder(NettoColor.separator, lineWidth: 1)
                    }
            case .translucent:
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .overlay {
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .strokeBorder(NettoColor.separator, lineWidth: 1)
                    }
            case .photo:
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(NettoColor.photoBackdrop)
            }
        }
    }
}

/// The layered surfaces: a tonal fill, one gradient hairline, and — for the hero only — a
/// single ambient shadow. Everything is opaque, so neither Reduce Transparency nor what
/// scrolls underneath can change how these read.
enum NettoSurfaceLayer {
    /// The one hero surface (the storage core): base, brand wash, and a static core glow.
    case hero
    /// Dense informational surfaces (the scan card): base wash, no glow, no shadow.
    case panel
    /// Grid tiles (the cleanup cards): base only, no glow, no shadow.
    case tile
}

private struct NettoLayeredSurfaceModifier: ViewModifier {
    let layer: NettoSurfaceLayer
    let cornerRadius: CGFloat
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
    }

    func body(content: Content) -> some View {
        content
            .background { surfaceFill }
            .clipShape(shape)
            .overlay { surfaceBorder }
            .shadow(
                color: layer == .hero ? NettoColor.ambientShadow : .clear,
                radius: layer == .hero ? 18 : 0,
                x: 0,
                y: layer == .hero ? 10 : 0
            )
    }

    @ViewBuilder
    private var surfaceFill: some View {
        ZStack {
            NettoColor.surface

            if layer == .hero {
                LinearGradient(
                    colors: [
                        NettoColor.brand.opacity(0.14),
                        NettoColor.brand.opacity(0.04),
                        NettoColor.brand.opacity(0)
                    ],
                    startPoint: .top,
                    endPoint: .center
                )

                // The storage core's illumination: a static radial centred where the ring
                // sits. Gradient only — no material, no blur, nothing continuous.
                RadialGradient(
                    colors: [
                        NettoColor.atmosphereGlow.opacity(colorScheme == .dark ? 0.17 : 0.11),
                        NettoColor.atmosphereGlow.opacity(0)
                    ],
                    center: UnitPoint(x: 0.5, y: 0.42),
                    startRadius: 0,
                    endRadius: 210
                )
            }
        }
    }

    @ViewBuilder
    private var surfaceBorder: some View {
        if contrast == .increased {
            // Increase Contrast: a single solid, legible edge instead of a gradient.
            shape.strokeBorder(NettoColor.textTertiary.opacity(0.75), lineWidth: 1.5)
        } else {
            shape.strokeBorder(
                LinearGradient(
                    colors: [
                        NettoColor.hairlineLift,
                        NettoColor.hairlineLift.opacity(0),
                        NettoColor.hairlineShade
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                lineWidth: 1
            )
        }
    }
}

extension View {
    /// A layered surface — fill, hairline, and (for `.hero`) one ambient shadow — applied
    /// behind this view. Only ever added to; no existing surface token is changed.
    func nettoLayeredSurface(
        _ layer: NettoSurfaceLayer = .panel,
        cornerRadius: CGFloat = NettoLayout.Radius.card
    ) -> some View {
        modifier(NettoLayeredSurfaceModifier(layer: layer, cornerRadius: cornerRadius))
    }
}

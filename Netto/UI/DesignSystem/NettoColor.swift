import SwiftUI
import UIKit

private extension UIColor {
    convenience init(nettoHex: UInt32) {
        self.init(
            red: CGFloat((nettoHex >> 16) & 0xFF) / 255,
            green: CGFloat((nettoHex >> 8) & 0xFF) / 255,
            blue: CGFloat(nettoHex & 0xFF) / 255,
            alpha: 1
        )
    }
}

private func nettoDynamic(_ dark: UInt32, _ light: UInt32) -> Color {
    Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(nettoHex: dark)
            : UIColor(nettoHex: light)
    })
}

private func nettoHairline() -> Color {
    Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(white: 1, alpha: 0.10)
            : UIColor(white: 0, alpha: 0.10)
    })
}

private func nettoHex(_ hex: UInt32, alpha: CGFloat) -> UIColor {
    UIColor(
        red: CGFloat((hex >> 16) & 0xFF) / 255,
        green: CGFloat((hex >> 8) & 0xFF) / 255,
        blue: CGFloat(hex & 0xFF) / 255,
        alpha: alpha
    )
}

/// A color whose *hex* and *alpha* are both chosen per appearance, so the dark and light
/// readings are designed rather than one being an inversion of the other.
private func nettoAlphaDynamic(
    _ dark: UInt32,
    _ light: UInt32,
    _ darkAlpha: CGFloat,
    _ lightAlpha: CGFloat
) -> Color {
    Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? nettoHex(dark, alpha: darkAlpha)
            : nettoHex(light, alpha: lightAlpha)
    })
}

enum NettoColor {
    static let background = nettoDynamic(0x0D0B12, 0xF5F6F8)
    static let surface = nettoDynamic(0x16141C, 0xFFFFFF)
    static let surfaceSecondary = nettoDynamic(0x1E1B25, 0xEFEFF4)
    static let surfaceHighlight = nettoDynamic(0x282432, 0xE7E8EE)

    static let textPrimary = nettoDynamic(0xF4F2F7, 0x0B000F)
    static let textSecondary = nettoDynamic(0xA5A1B0, 0x56535E)
    static let textTertiary = nettoDynamic(0x837F91, 0x8A8794)

    static let brand = nettoDynamic(0xA6F04C, 0xA6F04C)
    static let brandDeep = nettoDynamic(0x4F9D33, 0x3F7D24)
    static let onBrand = nettoDynamic(0x0C1A0F, 0x0C1A0F)

    static let success = nettoDynamic(0x30D158, 0x248A3D)
    static let warning = nettoDynamic(0xFF9F0A, 0xB25000)
    static let destructive = nettoDynamic(0xFF453A, 0xD70015)

    static let separator = nettoHairline()
    static let photoBackdrop = nettoDynamic(0x08070B, 0x1A191F)

    // MARK: Atmosphere and lift (additive — existing tokens above are unchanged)

    /// The dashboard's ambient glow: brand in dark, the deeper brand in light, so the wash
    /// reads at the same weight in both appearances instead of glowing out of one of them.
    static let atmosphereGlow = nettoDynamic(0xA6F04C, 0x4F9D33)

    /// One ambient shadow for the hero surface — no blur stack, one radius, one offset.
    static let ambientShadow = nettoAlphaDynamic(0x000000, 0x1B1A22, 0.50, 0.16)

    /// Gradient hairline: a lift at the top-leading edge falling to a shade at the
    /// bottom-trailing edge, so a card reads as a layer without an opaque border.
    static let hairlineLift = nettoAlphaDynamic(0xFFFFFF, 0xFFFFFF, 0.16, 1.00)
    static let hairlineShade = nettoAlphaDynamic(0x000000, 0x000000, 0.40, 0.10)
}

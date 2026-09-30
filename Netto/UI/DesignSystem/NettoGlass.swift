import SwiftUI

/// Liquid Glass as an *accent*, not a skin.
///
/// Only floating, transient surfaces get this: the review/selection bars, control clusters,
/// and other things that hover above content. Cards, rows, and sections stay opaque so their
/// text contrast never depends on what scrolls underneath.
///
/// iOS 26+ uses the system glass; anything older (deployment target is iOS 17) falls back to
/// a semantic material with the same silhouette, so the layout is identical either way.
enum NettoGlass {
    static func shape(cornerRadius: CGFloat) -> RoundedRectangle {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
    }
}

extension View {
    /// A translucent glass surface behind the view.
    @ViewBuilder
    func nettoGlass(cornerRadius: CGFloat = NettoLayout.Radius.feature) -> some View {
        let shape = NettoGlass.shape(cornerRadius: cornerRadius)
        if #available(iOS 26.0, *) {
            glassEffect(.regular, in: shape)
        } else {
            background(shape.fill(.ultraThinMaterial))
                .overlay { shape.strokeBorder(NettoColor.separator, lineWidth: 1) }
        }
    }

    /// The app's signature floating bar: glass capsule that hovers over scrolling content,
    /// with the same metrics everywhere it appears.
    func nettoFloatingBar(cornerRadius: CGFloat = NettoLayout.Radius.feature) -> some View {
        self
            .padding(NettoLayout.Spacing.md)
            .nettoGlass(cornerRadius: cornerRadius)
            .padding(.horizontal, NettoLayout.Spacing.md)
            .padding(.bottom, NettoLayout.Spacing.xs)
    }
}

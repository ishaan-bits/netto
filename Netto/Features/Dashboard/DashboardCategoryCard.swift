import SwiftUI

/// One category of the dashboard's "Clean up" grid.
///
/// Layout is a fixed vertical stack — media banner, title, status — with every line allowed
/// to wrap, so nothing can collide at any text size or device width. The banner always fills
/// the card's width: the category glyph panel expands behind a real thumbnail when there is
/// one (a PhotoKit thumbnail at banner height, never full-resolution pixels), an initials
/// block for contacts, or on its own when neither exists.
struct DashboardCategoryCard: View {
    let title: String
    let icon: String
    let status: String
    /// A real library asset to preview, `nil` when this category has no results yet.
    let assetID: String?
    /// Initials for a contact group — contacts have no image thumbnails, so they show the
    /// real identity of the group instead of a stock placeholder.
    let initials: String?
    let store: ThumbnailStore

    /// Banner height and the card's resting height. `restingHeight` matches the tallest of
    /// the four cards' resting content (two-line title + status), so the whole grid uses one
    /// card size instead of rows that differ by a line of text.
    private static let bannerSide: CGFloat = 72
    private static let restingHeight: CGFloat = 209

    var body: some View {
        VStack(alignment: .leading, spacing: NettoLayout.Spacing.md) {
            banner

            HStack(alignment: .center, spacing: NettoLayout.Spacing.sm) {
                Text(title)
                    .font(NettoType.cardTitle)
                    .foregroundStyle(NettoColor.textPrimary)
                    .lineLimit(2)
                Spacer(minLength: NettoLayout.Spacing.xs)
                chevronChip
            }

            // Pushes the status to the card's baseline so two neighbouring cards still line
            // up when one title wraps to a second line; it collapses to its minimum once the
            // content itself fills the card at accessibility text sizes.
            Spacer(minLength: NettoLayout.Spacing.md)

            Text(status)
                .font(NettoType.caption)
                .foregroundStyle(NettoColor.textSecondary)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(NettoLayout.Spacing.md)
        .frame(
            maxWidth: .infinity,
            minHeight: Self.restingHeight,
            alignment: .topLeading
        )
        .nettoLayeredSurface(.tile, cornerRadius: NettoLayout.Radius.card)
        .contentShape(RoundedRectangle(cornerRadius: NettoLayout.Radius.card, style: .continuous))
    }

    /// The affordance itself: a quiet chip rather than a bare glyph, so the card reads as
    /// tappable in both appearances and stays legible under Increase Contrast.
    private var chevronChip: some View {
        ZStack {
            Circle()
                .fill(NettoColor.surfaceSecondary)
            NettoIcon(
                name: "chevron.right",
                size: NettoIconSize.control,
                weight: .semibold,
                tint: NettoColor.textTertiary
            )
        }
        .frame(width: 24, height: 24)
        .overlay {
            Circle().strokeBorder(NettoColor.separator, lineWidth: 1)
        }
        .accessibilityHidden(true)
    }

    // MARK: Media banner

    private var banner: some View {
        HStack(spacing: 0) {
            glyphPanel
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            if let assetID {
                PhotoThumbnailView(assetID: assetID, pointSize: Self.bannerSide, store: store)
                    .frame(width: Self.bannerSide, height: Self.bannerSide)
            } else if let initials {
                initialsBlock(initials)
                    .frame(width: Self.bannerSide, height: Self.bannerSide)
            }
        }
        .frame(height: Self.bannerSide)
        .frame(maxWidth: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: NettoLayout.Radius.control, style: .continuous))
        .overlay {
            // One inner hairline so the banner sits *in* the card instead of on top of it.
            RoundedRectangle(cornerRadius: NettoLayout.Radius.control, style: .continuous)
                .strokeBorder(
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
        .accessibilityHidden(true)
    }

    /// Opaque first, brand wash second: the panel keeps real contrast in both appearances and
    /// under Increase Contrast instead of relying on a translucent effect.
    private var glyphPanel: some View {
        ZStack {
            NettoColor.surfaceSecondary
            LinearGradient(
                colors: [
                    NettoColor.brand.opacity(0.16),
                    NettoColor.brand.opacity(0.03)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            NettoIcon(
                name: icon,
                size: NettoIconSize.feature,
                weight: .semibold,
                tint: NettoColor.brandDeep
            )
        }
    }

    /// Contacts have no photo, so the group's real identity is shown instead — on the one
    /// brand-gradient surface in the grid, with `onBrand` text so contrast holds in both
    /// appearances.
    private func initialsBlock(_ text: String) -> some View {
        ZStack {
            LinearGradient(
                colors: [NettoColor.brand, NettoColor.brandDeep],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            Text(text)
                .font(.system(.title3, design: .rounded).weight(.bold))
                .foregroundStyle(NettoColor.onBrand)
                .lineLimit(1)
                .minimumScaleFactor(0.5)
        }
    }
}

/// The dashboard tile's own press response: lighter than the shared row/tile press (0.985
/// against 0.975), so a card presses without feeling like it collapses. Scoped to these
/// cards — the shared `nettoPress()` that other screens use is untouched.
struct DashboardCardPressStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.985 : 1)
            .opacity(configuration.isPressed ? 0.92 : 1)
            .animation(
                NettoMotion.animation(for: .selection, reduceMotion: reduceMotion),
                value: configuration.isPressed
            )
    }
}

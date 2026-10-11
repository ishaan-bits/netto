import SwiftUI
import WidgetKit
#if NETTO_WIDGET_TESTS
@testable import Netto
#endif

/// Renders one `WidgetDisplayModel` in the small and medium families. Everything it
/// draws comes from the model — no dates, no formatting decisions, no raw bytes logic
/// beyond formatting the model's figure for display. Light and dark both come from the
/// shared `NettoColor` palette, so the widget keeps the app's green-on-dark identity.
struct NettoWidgetEntryView: View {
    @Environment(\.widgetFamily) private var family

    // MARK: Type metrics (U8 — text follows the user's Dynamic Type setting instead of
    // pinning every line to a fixed point size; the existing line limits and minimum
    // scale factors contain the growth inside the widget's frame).
    @ScaledMetric(relativeTo: .largeTitle) private var figureSize: CGFloat = 28
    @ScaledMetric(relativeTo: .title) private var mediumFigureSize: CGFloat = 32
    @ScaledMetric(relativeTo: .headline) private var headlineSize: CGFloat = 16
    @ScaledMetric(relativeTo: .subheadline) private var secondarySize: CGFloat = 11
    @ScaledMetric(relativeTo: .caption2) private var detailSize: CGFloat = 9

    let entry: NettoWidgetEntry

    var body: some View {
        content(for: family)
    }

    /// The family-resolved layout. Extracted from `body` so the unit tests can render a
    /// specific family's pixels directly — the `widgetFamily` environment value is
    /// read-only in the SDK, so it cannot be injected into the view from a test.
    @ViewBuilder
    func content(for family: WidgetFamily) -> some View {
        switch family {
        case .systemMedium:
            medium
        default:
            small
        }
    }

    // MARK: - Small

    /// Small: logo, then either the estimate or the status, plus its label — the tap
    /// target is the whole widget (a single `widgetURL` on the container).
    private var small: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            NettoLogo()
                .frame(height: 15)
            Spacer(minLength: Theme.Spacing.xs)
            switch entry.model.figure {
            case .bytes(let bytes):
                Text(bytesText(bytes))
                    .font(.system(size: figureSize, weight: .semibold, design: .rounded))
                    .foregroundStyle(figureColor)
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                Text(entry.model.caption)
                    .font(.system(size: secondarySize, weight: .medium))
                    .foregroundStyle(NettoColor.textSecondary)
                    .lineLimit(2)
                    .minimumScaleFactor(0.7)
                Text(entry.model.detail)
                    .font(.system(size: detailSize))
                    .foregroundStyle(NettoColor.textTertiary)
                    .lineLimit(2)
                    .minimumScaleFactor(0.7)
            case .none:
                Text(entry.model.headline)
                    .font(.system(size: headlineSize, weight: .semibold))
                    .foregroundStyle(headlineColor)
                    .lineLimit(2)
                    .minimumScaleFactor(0.7)
                Text(entry.model.detail)
                    .font(.system(size: secondarySize))
                    .foregroundStyle(NettoColor.textSecondary)
                    .lineLimit(3)
                    .minimumScaleFactor(0.8)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    // MARK: - Medium

    /// Medium: status block on the left, estimate on the right when one exists; the
    /// headline/detail pair spans the full width when there is no figure to show.
    @ViewBuilder
    private var medium: some View {
        if case .bytes(let bytes) = entry.model.figure {
            HStack(alignment: .center, spacing: Theme.Spacing.lg) {
                statusBlock
                Spacer(minLength: Theme.Spacing.md)
                VStack(alignment: .trailing, spacing: 2) {
                    Text(bytesText(bytes))
                        .font(.system(size: mediumFigureSize, weight: .semibold, design: .rounded))
                        .foregroundStyle(figureColor)
                        .lineLimit(1)
                        .minimumScaleFactor(0.5)
                    Text(entry.model.caption)
                        .font(.system(size: secondarySize, weight: .medium))
                        .foregroundStyle(NettoColor.textSecondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        } else {
            statusBlock
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        }
    }

    private var statusBlock: some View {
        VStack(alignment: .leading, spacing: 3) {
            NettoLogo()
                .frame(height: 16)
            Text(entry.model.headline)
                .font(.system(size: headlineSize, weight: .semibold))
                .foregroundStyle(headlineColor)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(entry.model.detail)
                .font(.system(size: secondarySize))
                .foregroundStyle(NettoColor.textSecondary)
                .lineLimit(2)
                .minimumScaleFactor(0.8)
        }
    }

    // MARK: - Model-derived styling

    /// Stale content is muted rather than branded green, so an old figure never reads as
    /// current.
    private var figureColor: Color {
        entry.model.isStale ? NettoColor.textSecondary : NettoColor.brandIndicator
    }

    /// "No recent estimate" / "Old cleanup estimate" carry the warning tone; everything
    /// else keeps the app's primary text color.
    private var headlineColor: Color {
        entry.model.isStale ? NettoColor.warning : NettoColor.textPrimary
    }

    private func bytesText(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = [.useKB, .useMB, .useGB, .useTB]
        return formatter.string(fromByteCount: bytes)
    }
}

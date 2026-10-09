import SwiftUI

/// The Space Freed Summary: a dedicated top-level screen shown after a deletion outcome with
/// at least one confirmed removal.
///
/// Pure presentation. It receives the immutable summary and a single `onDone` action, holds
/// no `AppEnvironment`, and does **no** work on appear — recreating this screen can never
/// repeat a deletion, re-fire the success, start a scan, or write a snapshot. Every figure
/// comes from `SpaceFreedSummary` (plan × verified outcome) through
/// `SpaceFreedSummaryPresentation`; the Done button is the only control.
///
/// Motion is restrained: the standard screen entrance plus a single success pop on the seal,
/// both Reduce Motion aware through the design system's motion helpers. The layout is a
/// `ScrollView` so Dynamic Type (including accessibility sizes) never clips, all colors and
/// type come from the design tokens, and the primary action is a full-width 44pt-minimum
/// button.
struct SpaceFreedSummaryView: View {
    let summary: SpaceFreedSummary
    var onDone: () -> Void = {}

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var sealShown = false

    var body: some View {
        ScrollView {
            VStack(spacing: NettoLayout.Spacing.xl) {
                seal

                VStack(spacing: NettoLayout.Spacing.sm) {
                    Text(SpaceFreedSummaryPresentation.headline)
                        .font(NettoType.sectionTitle)
                        .foregroundStyle(NettoColor.textPrimary)
                        .multilineTextAlignment(.center)
                    Text(SpaceFreedSummaryPresentation.movedToRecentlyDeleted)
                        .font(NettoType.secondaryBody)
                        .foregroundStyle(NettoColor.textSecondary)
                        .multilineTextAlignment(.center)
                }

                metricCard

                if summary.breakdown.count > 1 {
                    breakdownCard
                }

                if let failure = SpaceFreedSummaryPresentation.failureDisclosure(summary) {
                    failureNotice(failure)
                }

                doneButton
            }
            .padding(.top, NettoLayout.Spacing.xxxl)
            .padding(.bottom, NettoLayout.Spacing.xl)
            .padding(.horizontal, NettoLayout.Spacing.xl)
            .frame(maxWidth: .infinity)
        }
        .background(NettoColor.background.ignoresSafeArea())
        .nettoAppear()
        .accessibilityIdentifier(SpaceFreedSummaryPresentation.screenAccessibilityID)
    }

    // MARK: Pieces

    /// The one success animation: a single scale-and-fade pop when the screen appears.
    /// Under Reduce Motion the success curve degrades to its short, non-scaling variant.
    private var seal: some View {
        ZStack {
            Circle()
                .fill(NettoColor.success.opacity(0.16))
                .frame(width: 96, height: 96)
            Image(systemName: "checkmark.seal")
                .font(.system(size: 38, weight: .semibold))
                .foregroundStyle(NettoColor.success)
        }
        .opacity(sealShown ? 1 : 0)
        .scaleEffect(sealShown ? 1 : 0.55)
        .animation(NettoMotion.animation(for: .success, reduceMotion: reduceMotion), value: sealShown)
        .onAppear { sealShown = true }
        .accessibilityHidden(true)
    }

    /// The figure card: space freed (honestly labeled), total confirmed items, what could not
    /// be measured, and the existing Recently-Deleted caveat — announced as one element.
    private var metricCard: some View {
        VStack(spacing: NettoLayout.Spacing.sm) {
            Text(SpaceFreedSummaryPresentation.metricValue(summary))
                .font(NettoType.heroTitle.monospacedDigit())
                .foregroundStyle(NettoColor.textPrimary)

            Text(SpaceFreedSummaryPresentation.metricLabel(summary))
                .font(NettoType.metricLabel)
                .foregroundStyle(NettoColor.textSecondary)

            if let items = SpaceFreedSummaryPresentation.itemsRemovedLine(summary) {
                Text(items)
                    .font(NettoType.body.weight(.medium))
                    .monospacedDigit()
                    .foregroundStyle(NettoColor.textPrimary)
            }

            if let note = SpaceFreedSummaryPresentation.sizeNote(summary) {
                Text(note)
                    .font(NettoType.caption)
                    .foregroundStyle(NettoColor.textTertiary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text(SpaceFreedSummaryPresentation.storageCaveat)
                .font(NettoType.caption)
                .foregroundStyle(NettoColor.textTertiary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(NettoLayout.Spacing.xl)
        .frame(maxWidth: .infinity)
        .nettoSurface(.elevated)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(SpaceFreedSummaryPresentation.metricAccessibilityLabel(summary))
        .accessibilityIdentifier(SpaceFreedSummaryPresentation.metricAccessibilityID)
    }

    /// Category breakdown — only rendered when the confirmed items split into more than one
    /// bucket (a single uniform bucket would only repeat the total). Each row's count comes
    /// from the same exclusive tally, so the parts always add up to the confirmed count.
    private var breakdownCard: some View {
        VStack(spacing: NettoLayout.Spacing.md) {
            ForEach(summary.breakdown) { row in
                HStack(spacing: NettoLayout.Spacing.md) {
                    Text(SpaceFreedSummaryPresentation.breakdownLabel(row.category))
                        .font(NettoType.secondaryBody)
                        .foregroundStyle(NettoColor.textSecondary)
                    Spacer(minLength: NettoLayout.Spacing.sm)
                    Text("\(row.count)")
                        .font(NettoType.secondaryBody.weight(.semibold))
                        .monospacedDigit()
                        .foregroundStyle(NettoColor.brandDeep)
                }
            }
        }
        .padding(NettoLayout.Spacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .nettoSurface(.secondary)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(SpaceFreedSummaryPresentation.breakdownAccessibilityID)
    }

    /// Partial-success disclosure: what verification found still present, beside the success.
    private func failureNotice(_ text: String) -> some View {
        HStack(alignment: .top, spacing: NettoLayout.Spacing.sm) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(NettoColor.warning)
                .accessibilityHidden(true)
            Text(text)
                .font(NettoType.secondaryBody)
                .foregroundStyle(NettoColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(NettoLayout.Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .nettoSurface(.secondary)
        .accessibilityIdentifier(SpaceFreedSummaryPresentation.failureAccessibilityID)
    }

    private var doneButton: some View {
        Button(SpaceFreedSummaryPresentation.doneTitle, action: onDone)
            .buttonStyle(NettoPrimaryButtonStyle())
            .frame(maxWidth: .infinity)
            .accessibilityIdentifier(SpaceFreedSummaryPresentation.doneAccessibilityID)
    }
}

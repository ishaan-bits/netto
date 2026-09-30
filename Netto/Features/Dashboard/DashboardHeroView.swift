import SwiftUI

/// The storage hero: one square ring over the device's real storage snapshot — Netto's
/// storage core.
///
/// Every layer inside the ring is inset to the square's own bounds — the track uses
/// `strokeBorder` (inset by half its width) and the value arc carries a matching positive
/// padding — so no stroke can ever cross the square's edge and reach the row below it.
///
/// The surface is a layered hero: base, brand wash, and one static radial that illuminates
/// the core. On first appearance the arc and the used figure settle onto the measurement —
/// the same numbers, revealed rather than invented — and under Reduce Motion they simply are
/// there. After that the ring changes only when the measurement changes.
struct DashboardHeroView: View {
    let snapshot: StorageSnapshot?

    /// Largest the ring is allowed to grow at standard text sizes. Content, not screen: the
    /// card stays readable on every device width instead of scaling with the viewport.
    private static let maxRingSide: CGFloat = 208
    private static let ringStroke: CGFloat = 14

    /// The center column keeps the standard ring's measure (the 208 ring minus its xl
    /// padding) even when the ring steps up for accessibility text sizes — a wider column
    /// would let the bottom caption run past the arc on both sides.
    private static let labelMeasure: CGFloat = 160

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    /// At accessibility text sizes the ring takes one step up so the center labels keep
    /// their full size and still land inside the arc — the ring scales with the content it
    /// holds, never with the viewport. Standard sizes are unchanged.
    private var ringSide: CGFloat {
        dynamicTypeSize.isAccessibilitySize ? 264 : Self.maxRingSide
    }

    /// What the ring and the used figure currently show. Driven *from* the snapshot: it starts
    /// at zero and settles on the measured values (or lands on them immediately when Reduce
    /// Motion is on). It is never a different number than what was measured.
    @State private var displayedFraction: Double = 0
    @State private var displayedUsed: Int64 = 0
    @State private var statsShown = false
    @State private var woke = false

    var body: some View {
        content
            .padding(NettoLayout.Spacing.xl)
            .frame(maxWidth: .infinity, alignment: .leading)
            .nettoLayeredSurface(.hero, cornerRadius: NettoLayout.Radius.card)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("storageHeroCard")
    }

    // MARK: States

    @ViewBuilder
    private var content: some View {
        if let snapshot, let fraction = DashboardPresentation.heroFraction(snapshot) {
            measured(snapshot, fraction: fraction)
        } else if snapshot == nil {
            loading
        } else {
            unavailable
        }
    }

    private func measured(_ snapshot: StorageSnapshot, fraction: Double) -> some View {
        VStack(alignment: .leading, spacing: NettoLayout.Spacing.lg) {
            ring(snapshot, fraction: displayedFraction)
            stats(snapshot)
                .opacity(statsShown ? 1 : 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear { wake(fraction: fraction, used: snapshot.usedCapacity) }
        .onChange(of: fraction) { _, newValue in
            settle(to: newValue, using: .progress)
        }
        .onChange(of: snapshot.usedCapacity) { _, newValue in
            settleUsed(to: newValue, using: .progress)
        }
    }

    /// First appearance: the arc draws itself in and the used figure rolls to the
    /// measurement. One shot — never a loop.
    private func wake(fraction: Double, used: Int64) {
        guard !woke else { return }
        woke = true

        guard !reduceMotion else {
            displayedFraction = fraction
            displayedUsed = used
            statsShown = true
            return
        }

        withAnimation(NettoMotion.slow.animation.delay(0.06)) {
            displayedFraction = fraction
        }
        withAnimation(NettoMotion.slow.animation.delay(0.14)) {
            displayedUsed = used
        }
        withAnimation(NettoMotion.animation(for: .hierarchy, reduceMotion: false).delay(0.36)) {
            statsShown = true
        }
    }

    /// A later measurement (pull-to-refresh) retargets the same values — a real change,
    /// animated once.
    private func settle(to fraction: Double, using purpose: NettoMotion.Purpose) {
        guard woke else { return }
        withAnimation(NettoMotion.animation(for: purpose, reduceMotion: reduceMotion)) {
            displayedFraction = fraction
        }
    }

    private func settleUsed(to used: Int64, using purpose: NettoMotion.Purpose) {
        guard woke else { return }
        withAnimation(NettoMotion.animation(for: purpose, reduceMotion: reduceMotion)) {
            displayedUsed = used
        }
    }

    private func ring(_ snapshot: StorageSnapshot, fraction: Double) -> some View {
        ZStack {
            Circle()
                .strokeBorder(NettoColor.surfaceSecondary, lineWidth: Self.ringStroke)

            Circle()
                .trim(from: 0, to: fraction)
                .stroke(
                    LinearGradient(
                        colors: [NettoColor.brand, NettoColor.brandDeep],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    style: StrokeStyle(lineWidth: Self.ringStroke, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
                // A centered stroke reaches `lineWidth / 2` past its path; inset by exactly
                // that much so the arc ends flush with the square instead of overhanging it.
                .padding(Self.ringStroke / 2)

            ringLabels(snapshot)
                .padding(.horizontal, NettoLayout.Spacing.xl)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .aspectRatio(1, contentMode: .fit)
        .frame(maxWidth: ringSide)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Storage used")
        .accessibilityValue(ringValue)
        .accessibilityIdentifier("storageRing")
        .frame(maxWidth: .infinity)
    }

    private func ringLabels(_ snapshot: StorageSnapshot) -> some View {
        VStack(spacing: NettoLayout.Spacing.xs) {
            Text("Used")
                .font(NettoType.metricLabel)
                .foregroundStyle(NettoColor.textSecondary)
                .lineLimit(1)
            Text(ByteFormat.string(displayedUsed))
                .font(NettoType.metricNumber)
                .monospacedDigit()
                .contentTransition(.numericText(value: Double(displayedUsed)))
                .foregroundStyle(NettoColor.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.5)
            Text("of \(snapshot.formattedTotal())")
                .font(NettoType.caption)
                .foregroundStyle(NettoColor.textSecondary)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: Self.labelMeasure)
        .accessibilityHidden(true)
    }

    private func stats(_ snapshot: StorageSnapshot) -> some View {
        HStack(spacing: 0) {
            stat(label: "Free", value: snapshot.formattedFree(), color: NettoColor.success)
            Rectangle()
                .fill(NettoColor.separator)
                .frame(width: 1, height: 36)
            stat(label: "Used", value: usedPercent(snapshot), color: NettoColor.textPrimary)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Free and used")
        .accessibilityValue("\(snapshot.formattedFree()) free, \(usedPercent(snapshot)) used")
        .accessibilityIdentifier("storageStats")
    }

    private func stat(label: String, value: String, color: Color) -> some View {
        VStack(spacing: NettoLayout.Spacing.xxs) {
            Text(label)
                .font(NettoType.metricLabel)
                .foregroundStyle(NettoColor.textSecondary)
            Text(value)
                .font(NettoType.cardTitle)
                .monospacedDigit()
                .foregroundStyle(color)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
    }

    private var loading: some View {
        HStack(spacing: NettoLayout.Spacing.md) {
            ProgressView()
            Text("Reading device storage…")
                .font(NettoType.secondaryBody)
                .foregroundStyle(NettoColor.textSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, NettoLayout.Spacing.sm)
    }

    private var unavailable: some View {
        VStack(alignment: .leading, spacing: NettoLayout.Spacing.xs) {
            Text("Storage size unavailable")
                .font(NettoType.cardTitle)
                .foregroundStyle(NettoColor.textPrimary)
            Text("Your iPhone didn't report a capacity, so there is nothing to show here.")
                .font(NettoType.secondaryBody)
                .foregroundStyle(NettoColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, NettoLayout.Spacing.sm)
    }

    // MARK: Derived values

    private var ringValue: String {
        guard let snapshot else { return "Reading device storage" }
        guard DashboardPresentation.heroFraction(snapshot) != nil else {
            return "Storage size unavailable"
        }
        return "\(snapshot.formattedUsed()) used of \(snapshot.formattedTotal()), "
            + "\(snapshot.formattedFree()) free"
    }

    private func usedPercent(_ snapshot: StorageSnapshot) -> String {
        "\(Int((snapshot.usedFraction * 100).rounded()))%"
    }
}

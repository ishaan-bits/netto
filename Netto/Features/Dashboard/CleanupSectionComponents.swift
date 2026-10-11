import SwiftUI

/// The two reusable building blocks of the M11 dashboard and its hub screens.
///
/// `CleanupSectionCard` is one primary dashboard section (the four). `CleanupDestinationRow`
/// is one destination inside a hub (Image Cleanup's four, Video Cleanup's two). Both are
/// status-driven: they render whatever honest `CleanupDestinationStatus` the presentation
/// layer computed, never a fabricated count.
struct CleanupSectionCard<Destination: View>: View {
    let title: String
    let subtitle: String
    let icon: String
    let status: CleanupDestinationStatus
    let accessibilityIdentifier: String
    @ViewBuilder let destination: () -> Destination

    @Namespace private var namespace

    var body: some View {
        NavigationLink {
            destination()
        } label: {
            card
        }
        .buttonStyle(DashboardCardPressStyle())
        .nettoZoomSource(title, in: namespace)
        .accessibilityIdentifier(accessibilityIdentifier)
    }

    private var card: some View {
        HStack(spacing: NettoLayout.Spacing.md) {
            NettoIconBubble(name: icon, tint: NettoColor.brand)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: NettoLayout.Spacing.xs) {
                Text(title)
                    .font(NettoType.cardTitle)
                    .foregroundStyle(NettoColor.textPrimary)
                    .lineLimit(1)
                Text(subtitle)
                    .font(NettoType.secondaryBody)
                    .foregroundStyle(NettoColor.textSecondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                statusLine
                    .padding(.top, NettoLayout.Spacing.xxs)
            }

            Spacer(minLength: NettoLayout.Spacing.md)

            NettoIcon(name: "chevron.right", size: NettoIconSize.control, weight: .semibold, tint: NettoColor.textTertiary)
                .accessibilityHidden(true)
        }
        .padding(NettoLayout.Spacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .nettoSurface(.elevated, cornerRadius: NettoLayout.Radius.card)
        .contentShape(RoundedRectangle(cornerRadius: NettoLayout.Radius.card, style: .continuous))
    }

    @ViewBuilder
    private var statusLine: some View {
        switch status {
        case .count(let n):
            Text(n == 1 ? "1 item" : "\(n) items")
                .font(NettoType.caption.weight(.semibold))
                .foregroundStyle(NettoColor.brand)
        case .measurement(let text):
            Text(text)
                .font(NettoType.caption)
                .foregroundStyle(NettoColor.textSecondary)
        case .progress(let message, let fraction):
            VStack(alignment: .leading, spacing: NettoLayout.Spacing.xxs) {
                Text(message)
                    .font(NettoType.caption)
                    .foregroundStyle(NettoColor.textSecondary)
                    .lineLimit(1)
                if let fraction {
                    ProgressView(value: fraction)
                        .progressViewStyle(.linear)
                        .tint(NettoColor.brandIndicator)
                }
            }
        case .unknownCount(let text), .empty(let text), .queued(let text), .paused(let text):
            Text(text)
                .font(NettoType.caption)
                .foregroundStyle(NettoColor.textSecondary)
                .lineLimit(2)
        case .unavailable(let reason), .failed(let reason):
            Label(reason, systemImage: "exclamationmark.circle")
                .font(NettoType.caption)
                .foregroundStyle(NettoColor.warning)
                .lineLimit(2)
        }
    }
}

/// One destination inside a hub screen — same visual language as the section card, one
/// level down. Drives the Image Cleanup and Video Cleanup hubs.
struct CleanupDestinationRow<Destination: View>: View {
    let title: String
    let subtitle: String
    let icon: String
    let status: CleanupDestinationStatus
    let accessibilityIdentifier: String
    @ViewBuilder let destination: () -> Destination

    var body: some View {
        NavigationLink {
            destination()
        } label: {
            row
        }
        .buttonStyle(DashboardCardPressStyle())
        .accessibilityIdentifier(accessibilityIdentifier)
    }

    private var row: some View {
        HStack(spacing: NettoLayout.Spacing.md) {
            NettoIconBubble(name: icon, tint: NettoColor.brand)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: NettoLayout.Spacing.xxs) {
                Text(title)
                    .font(NettoType.cardTitle)
                    .foregroundStyle(NettoColor.textPrimary)
                    .lineLimit(1)
                Text(subtitle)
                    .font(NettoType.caption)
                    .foregroundStyle(NettoColor.textSecondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                statusText
                    .padding(.top, NettoLayout.Spacing.xxs)
            }

            Spacer(minLength: NettoLayout.Spacing.md)

            NettoIcon(name: "chevron.right", size: NettoIconSize.control, weight: .semibold, tint: NettoColor.textTertiary)
                .accessibilityHidden(true)
        }
        .padding(NettoLayout.Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .nettoSurface(.elevated, cornerRadius: NettoLayout.Radius.card)
        .contentShape(RoundedRectangle(cornerRadius: NettoLayout.Radius.card, style: .continuous))
    }

    @ViewBuilder
    private var statusText: some View {
        switch status {
        case .count(let n):
            Text(n == 1 ? "1 item" : "\(n) items")
                .font(NettoType.caption.weight(.semibold))
                .foregroundStyle(NettoColor.brand)
        case .unavailable(let reason), .failed(let reason):
            Label(reason, systemImage: "exclamationmark.circle")
                .font(NettoType.caption)
                .foregroundStyle(NettoColor.warning)
                .lineLimit(2)
        case .measurement(let text), .progress(let text, _),
             .unknownCount(let text), .empty(let text), .queued(let text), .paused(let text):
            Text(text)
                .font(NettoType.caption)
                .foregroundStyle(NettoColor.textSecondary)
                .lineLimit(2)
        }
    }
}

/// A hub screen's shared chrome: title, an honest one-line intro, and the destination rows.
/// Used identically by Image Cleanup and Video Cleanup so the two hubs cannot drift.
struct CleanupHubScreen<Rows: View>: View {
    let title: String
    let intro: String
    @ViewBuilder let rows: () -> Rows

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: NettoLayout.Spacing.lg) {
                Text(intro)
                    .font(NettoType.secondaryBody)
                    .foregroundStyle(NettoColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)

                VStack(spacing: NettoLayout.Spacing.md) {
                    rows()
                }
            }
            .padding(NettoLayout.Spacing.lg)
        }
        .background(NettoColor.background.ignoresSafeArea())
        .navigationTitle(title)
        .nettoAppear()
    }
}

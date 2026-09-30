import SwiftUI

struct NettoCard: View {
    var title: String? = nil
    var subtitle: String? = nil
    var metric: String? = nil
    var systemImage: String? = nil
    var iconTint: Color = NettoColor.brand
    var trailing: String? = nil
    var progress: Double? = nil
    var action: (() -> Void)? = nil

    var body: some View {
        content
            .nettoSurface(.elevated, cornerRadius: NettoLayout.Radius.card)
    }

    @ViewBuilder
    private var content: some View {
        if let action {
            Button(action: action) {
                row
            }
            .buttonStyle(NettoTertiaryButtonStyle())
            .padding(NettoLayout.Spacing.lg)
        } else {
            row
                .padding(NettoLayout.Spacing.lg)
        }
    }

    private var row: some View {
        HStack(spacing: NettoLayout.Spacing.md) {
            if let systemImage {
                NettoIconBubble(name: systemImage, tint: iconTint)
            }

            VStack(alignment: .leading, spacing: NettoLayout.Spacing.xs) {
                if let title {
                    Text(title)
                        .font(NettoType.cardTitle)
                        .foregroundStyle(NettoColor.textPrimary)
                }
                if let subtitle {
                    Text(subtitle)
                        .font(NettoType.secondaryBody)
                        .foregroundStyle(NettoColor.textSecondary)
                }
            }

            Spacer(minLength: NettoLayout.Spacing.md)

            VStack(alignment: .trailing, spacing: NettoLayout.Spacing.xs) {
                if let metric {
                    Text(metric)
                        .font(NettoType.metricNumber)
                        .foregroundStyle(NettoColor.textPrimary)
                }
                if let trailing {
                    Text(trailing)
                        .font(NettoType.metricLabel)
                        .foregroundStyle(NettoColor.textSecondary)
                }
                if action != nil {
                    NettoIcon(name: "chevron.right", size: NettoIconSize.control, weight: .semibold, tint: NettoColor.textTertiary)
                }
            }

            if let progress {
                ProgressView(value: progress)
                    .progressViewStyle(.linear)
                    .tint(NettoColor.brand)
                    .frame(width: 64)
            }
        }
    }
}

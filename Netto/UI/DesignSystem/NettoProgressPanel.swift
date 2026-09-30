import SwiftUI

/// The one indeterminate/determinate progress state: used while a catalog is read, similarity
/// runs, or video sizes are measured.
///
/// The fraction is always the caller's real value — this view never invents progress, and
/// shows no percentage until there is one.
struct NettoProgressPanel: View {
    let message: String
    var fraction: Double?
    var cancel: (() -> Void)?

    private var percent: Int? {
        fraction.map { Int(($0 * 100).rounded()) }
    }

    var body: some View {
        VStack(spacing: NettoLayout.Spacing.lg) {
            Spacer(minLength: NettoLayout.Spacing.xxl)

            if let fraction {
                VStack(spacing: NettoLayout.Spacing.sm) {
                    ProgressView(value: fraction)
                        .progressViewStyle(.linear)
                        .tint(NettoColor.brand)
                    if let percent {
                        Text("\(percent)%")
                            .font(NettoType.metricLabel)
                            .monospacedDigit()
                            .foregroundStyle(NettoColor.textSecondary)
                            .nettoCount(percent)
                    }
                }
                .frame(maxWidth: 260)
                .nettoAnimate(.progress, value: fraction)
            } else {
                ProgressView()
                    .tint(NettoColor.brand)
            }

            Text(message)
                .font(NettoType.secondaryBody)
                .monospacedDigit()
                .multilineTextAlignment(.center)
                .foregroundStyle(NettoColor.textPrimary)

            if let cancel {
                Button("Cancel", action: cancel)
                    .buttonStyle(NettoTertiaryButtonStyle())
            }

            Spacer(minLength: NettoLayout.Spacing.xxl)
        }
        .padding(.horizontal, NettoLayout.Spacing.xl)
        .frame(maxWidth: .infinity)
        .nettoAppear()
    }
}

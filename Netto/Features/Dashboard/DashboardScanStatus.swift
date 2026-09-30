import SwiftUI

/// The dashboard's single scan surface: permission, scanning, ready, finished, cancelled,
/// empty, and failed all render here as one card instead of as a growing stack of blocks.
///
/// It is a pure read of `DashboardPresentation.ScanStatus` — every button reports intent
/// through a closure, and the state-specific accessibility identifiers (`allowPhotosButton`,
/// `openSettingsButton`, `analyzeLibraryButton`, `cancelAnalysisButton`, `retryAnalysisButton`)
/// stay exactly where the dashboard's tests and QA harness expect them.
struct DashboardScanStatusCard: View {
    let status: DashboardPresentation.ScanStatus
    let onAllowPhotos: () -> Void
    let onOpenSettings: () -> Void
    let onAnalyze: () -> Void
    let onCancel: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Drives the indicator's breathing while a scan runs. It is always the *same* indicator
    /// and the same colour — only its emphasis moves, and only for as long as the scan does.
    @State private var pulsing = false

    private var copy: DashboardPresentation.ScanCopy {
        DashboardPresentation.scanCopy(for: status)
    }

    private var isScanning: Bool {
        if case .scanning = status { return true }
        return false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: NettoLayout.Spacing.md) {
            header

            if case .scanning(_, let fraction) = status {
                progress(fraction: fraction)
            }

            if let buttonTitle = copy.buttonTitle {
                actionButton(buttonTitle)
            }
        }
        .padding(NettoLayout.Spacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .nettoLayeredSurface(.panel, cornerRadius: NettoLayout.Radius.card)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("scanStatusCard")
        .onAppear { syncPulse() }
        .onChange(of: status) { _, _ in syncPulse() }
        .onChange(of: reduceMotion) { _, _ in syncPulse() }
    }

    /// The pulse runs only while a scan is running and only when Reduce Motion is off; when
    /// either ends, the indicator settles back at full strength instead of being left dim.
    private func syncPulse() {
        let shouldPulse = isScanning && !reduceMotion
        guard shouldPulse != pulsing else { return }
        pulsing = shouldPulse
    }

    private var header: some View {
        HStack(alignment: .top, spacing: NettoLayout.Spacing.md) {
            ScanIndicator(icon: copy.icon, tint: toneColor)
                .opacity(pulsing ? 0.5 : 1)
                .animation(indicatorAnimation, value: pulsing)

            VStack(alignment: .leading, spacing: NettoLayout.Spacing.xs) {
                Text(copy.title)
                    .font(NettoType.sectionTitle)
                    .foregroundStyle(NettoColor.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(copy.body)
                    .font(NettoType.secondaryBody)
                    .foregroundStyle(NettoColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }

    /// Breathing while a scan runs; a short settle when it stops; nothing at all under
    /// Reduce Motion (the value simply never changes).
    private var indicatorAnimation: Animation? {
        guard isScanning, !reduceMotion else {
            return NettoMotion.animation(for: .quick, reduceMotion: reduceMotion)
        }
        return .easeInOut(duration: 1.15).repeatForever(autoreverses: true)
    }

    /// Determinate when the stage reports a real fraction; indeterminate otherwise — a bar
    /// that only ever animates is honest, a fabricated percentage is not. Both run on the real
    /// value (or on an explicitly indeterminate pulse), never on a timer that pretends.
    private func progress(fraction: Double?) -> some View {
        ScanProgressBar(fraction: fraction)
            .accessibilityLabel("Scan progress")
            .accessibilityValue(
                fraction.map { "\(Int(($0 * 100).rounded())) percent" } ?? "In progress"
            )
            .accessibilityAddTraits(.updatesFrequently)
            .accessibilityIdentifier("scanProgressBar")
    }

    @ViewBuilder
    private func actionButton(_ title: String) -> some View {
        switch status {
        case .scanning:
            // Cancel is secondary: a compact trailing capsule, not a second primary bar.
            HStack {
                Spacer(minLength: NettoLayout.Spacing.sm)
                Button(action: primaryAction) {
                    Text(title)
                }
                .buttonStyle(ScanCancelStyle())
                .accessibilityIdentifier("cancelAnalysisButton")
            }
        case .permissionRequired:
            Button(action: primaryAction) {
                Text(title)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(NettoPrimaryButtonStyle())
            .accessibilityIdentifier("allowPhotosButton")
        case .permissionDenied:
            Button(action: primaryAction) {
                Text(title)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(NettoSecondaryButtonStyle())
            .accessibilityIdentifier("openSettingsButton")
        case .failed:
            Button(action: primaryAction) {
                Text(title)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(NettoPrimaryButtonStyle())
            .accessibilityIdentifier("retryAnalysisButton")
        case .idle, .finished, .cancelled, .emptyLibrary:
            Button(action: primaryAction) {
                Text(title)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(NettoPrimaryButtonStyle())
            .accessibilityIdentifier("analyzeLibraryButton")
        }
    }

    private var primaryAction: () -> Void {
        switch status {
        case .permissionRequired:
            return onAllowPhotos
        case .permissionDenied:
            return onOpenSettings
        case .scanning:
            return onCancel
        case .idle, .finished, .cancelled, .emptyLibrary, .failed:
            return onAnalyze
        }
    }

    private var toneColor: Color {
        switch copy.tone {
        case .brand:
            return NettoColor.brand
        case .success:
            return NettoColor.success
        case .warning:
            return NettoColor.warning
        case .failure:
            return NettoColor.destructive
        case .muted:
            return NettoColor.textTertiary
        }
    }
}

/// The scan card's indicator: one rounded tile carrying the state's own icon in the state's
/// own tone. Shared surfaces keep their circular bubble — this is the dashboard's own.
private struct ScanIndicator: View {
    let icon: String
    let tint: Color

    private var cornerRadius: CGFloat { NettoLayout.Radius.button }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [tint.opacity(0.24), tint.opacity(0.10)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .overlay {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .strokeBorder(
                            LinearGradient(
                                colors: [tint.opacity(0.45), tint.opacity(0.10)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: 1
                        )
                }
            NettoIcon(name: icon, size: NettoIconSize.feature, weight: .semibold, tint: tint)
        }
        .frame(width: 44, height: 44)
        .accessibilityHidden(true)
    }
}

/// The scan card's progress: a proportioned bar on the real fraction, or an explicitly
/// indeterminate pulse when there is no measured fraction yet. The track is measured, not
/// positioned — no fake percentage ever drives it.
private struct ScanProgressBar: View {
    let fraction: Double?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulse = false

    private var clamped: Double? {
        fraction.map { min(max($0, 0), 1) }
    }

    private var barGradient: LinearGradient {
        LinearGradient(
            colors: [NettoColor.brand, NettoColor.brandDeep],
            startPoint: .leading,
            endPoint: .trailing
        )
    }

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(NettoColor.surfaceSecondary)

                if let value = clamped {
                    Capsule()
                        .fill(barGradient)
                        .frame(width: value > 0 ? max(6, width * value) : 0)
                        .animation(
                            NettoMotion.animation(for: .progress, reduceMotion: reduceMotion),
                            value: value
                        )
                } else {
                    Capsule()
                        .fill(barGradient)
                        .frame(width: width * 0.36)
                        .opacity(indeterminateOpacity)
                        .animation(pulseAnimation, value: pulse)
                }
            }
        }
        .frame(height: 6)
        .onAppear { syncPulse() }
        .onChange(of: fraction) { _, _ in syncPulse() }
        .onChange(of: reduceMotion) { _, _ in syncPulse() }
    }

    private var indeterminateOpacity: Double {
        guard clamped == nil else { return 1 }
        if reduceMotion { return 0.75 }
        return pulse ? 0.45 : 1
    }

    private var pulseAnimation: Animation? {
        guard clamped == nil, !reduceMotion else {
            return NettoMotion.animation(for: .quick, reduceMotion: reduceMotion)
        }
        return .easeInOut(duration: 1.0).repeatForever(autoreverses: true)
    }

    private func syncPulse() {
        let shouldPulse = clamped == nil && !reduceMotion
        guard shouldPulse != pulse else { return }
        pulse = shouldPulse
    }
}

/// Cancel during a scan: a compact glass capsule. It is the dashboard's only glass surface —
/// a transient, floating control — and it falls back to a material below iOS 26.
private struct ScanCancelStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(NettoType.buttonLabel)
            .foregroundStyle(NettoColor.textPrimary)
            .padding(.horizontal, NettoLayout.Spacing.lg)
            .padding(.vertical, NettoLayout.Spacing.md)
            .frame(minHeight: 44)
            .nettoGlass(cornerRadius: NettoLayout.Radius.pill)
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.98 : 1)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .animation(
                NettoMotion.animation(for: .selection, reduceMotion: reduceMotion),
                value: configuration.isPressed
            )
            .contentShape(Rectangle())
    }
}

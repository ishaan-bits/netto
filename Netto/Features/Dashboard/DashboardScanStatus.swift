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
    /// Continues an interrupted run from its saved checkpoint (the paused state's own
    /// action — never a fresh start, which would discard the saved progress instead).
    var onResume: () -> Void = {}
    /// Whether the empty-library state is a *limited* permission state — only then does
    /// its copy get the "Open Settings" action its body asks for (U2); a genuinely empty
    /// authorized library has no Settings action to offer.
    var isLimitedAccess: Bool = false

    private var copy: DashboardPresentation.ScanCopy {
        DashboardPresentation.scanCopy(for: status, limitedAccess: isLimitedAccess)
    }

    /// The scan core's phase, derived once from the real status so the animation and the copy
    /// can never disagree about what the app is actually doing.
    private var corePhase: ScanCorePresentation.Phase {
        ScanCorePresentation.phase(for: status)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: NettoLayout.Spacing.md) {
            header

            if case .scanning(_, let fraction, let eta) = status {
                progress(fraction: fraction, eta: eta)
            } else if case .paused(_, let fraction?) = status {
                // The saved position as a static bar — only when the run had a measured
                // one (no indeterminate pulse: nothing is moving) and never an ETA (the
                // estimator was reset with the pause; a countdown would be fiction).
                pausedProgress(fraction: fraction)
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
    }

    private var header: some View {
        HStack(alignment: .top, spacing: NettoLayout.Spacing.md) {
            // The scan core: luminous centre, concentric rings, and a slow sweep — it animates
            // only while a run is in flight and settles the moment that ends (see
            // `ScanCoreView`). Under Reduce Motion it is a static mark.
            ScanCoreView(phase: corePhase, tint: toneColor)

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

    /// Determinate when the stage reports a real fraction; indeterminate otherwise — a bar
    /// that only ever animates is honest, a fabricated percentage is not. Both run on the real
    /// value (or on an explicitly indeterminate pulse), never on a timer that pretends.
    ///
    /// The accessibility value carries the full picture — percent (or "In progress"), plus the
    /// time-remaining line when one exists — so VoiceOver gets stage, counts (in the combined
    /// header), and ETA without a second element announcing every tick; `.updatesFrequently`
    /// keeps that throttled exactly as before.
    private func progress(fraction: Double?, eta: ScanETA) -> some View {
        var value = fraction.map { "\(Int(($0 * 100).rounded())) percent" } ?? "In progress"
        if let etaLine = ScanETAEstimator.etaLine(for: eta) {
            value += ", \(etaLine)"
        }
        return ScanProgressBar(fraction: fraction)
            .accessibilityLabel("Scan progress")
            .accessibilityValue(value)
            .accessibilityAddTraits(.updatesFrequently)
            .accessibilityIdentifier("scanProgressBar")
    }

    /// The paused bar: same measured track, but quiet — no pulse, no `updatesFrequently`
    /// (VoiceOver should not re-announce a state that is not changing).
    private func pausedProgress(fraction: Double) -> some View {
        ScanProgressBar(fraction: fraction)
            .accessibilityLabel("Scan progress")
            .accessibilityValue("\(Int((fraction * 100).rounded())) percent, paused")
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
        case .paused:
            // Resume is the paused state's primary action: it continues the saved run,
            // it does not start a new one.
            Button(action: primaryAction) {
                Text(title)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(NettoPrimaryButtonStyle())
            .accessibilityIdentifier("resumeAnalysisButton")
        case .emptyLibrary where isLimitedAccess:
            // The settings action, in the same secondary treatment the denied state uses.
            Button(action: primaryAction) {
                Text(title)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(NettoSecondaryButtonStyle())
            .accessibilityIdentifier("openSettingsButton")
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
        case .paused:
            return onResume
        case .emptyLibrary where isLimitedAccess:
            return onOpenSettings
        case .idle, .finished, .cancelled, .emptyLibrary, .failed:
            return onAnalyze
        }
    }

    private var toneColor: Color {
        switch copy.tone {
        case .brand:
            return NettoColor.brandIndicator
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
            colors: [NettoColor.brandIndicator, NettoColor.brandDeep],
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

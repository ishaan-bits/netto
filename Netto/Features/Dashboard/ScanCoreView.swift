import SwiftUI

/// The dashboard's scan core: a luminous centre, a couple of concentric rings, and a slow
/// sweep — the app's "scanning" made visible without inventing a single number.
///
/// Every moving part is a pure function of `ScanCorePresentation.phase`, so the core cannot
/// outlive or out-say the state that drives it:
/// - The sweep turns **only** while a run is in flight (`.running`); a paused, terminal, or
///   resting core is still.
/// - The progress ring shows the stage's **real** fraction, or nothing at all when the stage
///   reports no denominator — never a fabricated ring.
/// - Under Reduce Motion the sweep never spins and the rings never pulse; the core settles to
///   a static, legible mark instead.
/// - The animation is stopped on disappear (and by its `isActive` gate) so no repeating
///   animation outlives the card. There are no timers, no per-asset tasks, and nothing is
///   published into app-wide state — only local `@State`.
struct ScanCoreView: View {
    /// The core's phase, derived by `ScanCorePresentation.phase(for:)` from real status.
    let phase: ScanCorePresentation.Phase
    /// The state's own colour, so the core always matches the card's tone.
    let tint: Color

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase

    /// Drives the sweep's continuous rotation. Only ever `true` while a run is in flight and
    /// Reduce Motion is off; flipping it back to `false` settles the sweep immediately.
    @State private var sweeping = false
    /// Drives the rings' slow breathing. Same gate as the sweep.
    @State private var breathing = false

    private var isSweepingAllowed: Bool {
        ScanCorePresentation.isSweeping(phase) && !reduceMotion && scenePhase == .active
    }

    var body: some View {
        ZStack {
            glow
            rings
            sweep
            progressRing
            core
        }
        .frame(width: ScanCoreMetrics.size, height: ScanCoreMetrics.size)
        .accessibilityHidden(true)
        .onAppear { syncMotion() }
        .onChange(of: phase) { _, _ in syncMotion() }
        .onChange(of: reduceMotion) { _, _ in syncMotion() }
        .onChange(of: scenePhase) { _, _ in syncMotion() }
        .onDisappear { stopMotion() }
    }

    // MARK: - Layers

    /// A soft radial bloom behind the core. Brightens only while a run is in flight.
    private var glow: some View {
        let active = ScanCorePresentation.isSweeping(phase)
        return Circle()
            .fill(
                RadialGradient(
                    colors: [
                        tint.opacity(active ? 0.34 : 0.16),
                        tint.opacity(0)
                    ],
                    center: .center,
                    startRadius: 0,
                    endRadius: ScanCoreMetrics.size / 2
                )
            )
            .frame(width: ScanCoreMetrics.size, height: ScanCoreMetrics.size)
            .opacity(breathing && !reduceMotion ? 0.85 : 1)
            .animation(
                breathing && !reduceMotion
                    ? .easeInOut(duration: 2.2).repeatForever(autoreverses: true)
                    : nil,
                value: breathing
            )
    }

    /// Two concentric rings, thin and quiet. They breathe only while a run is in flight and
    /// Reduce Motion is off.
    private var rings: some View {
        let active = ScanCorePresentation.isSweeping(phase)
        return ZStack {
            ring(diameter: ScanCoreMetrics.outerRing, opacity: active ? 0.42 : 0.24)
            ring(diameter: ScanCoreMetrics.innerRing, opacity: active ? 0.6 : 0.34)
        }
    }

    private func ring(diameter: CGFloat, opacity: Double) -> some View {
        Circle()
            .strokeBorder(tint.opacity(opacity), lineWidth: ScanCoreMetrics.ringWidth)
            .frame(width: diameter, height: diameter)
    }

    /// A single sweeping arc, rotating once every few seconds — the "scanning" tell. It exists
    /// only while a run is in flight and Reduce Motion is off; otherwise it is simply absent.
    private var sweep: some View {
        Group {
            if isSweepingAllowed {
                Circle()
                    .trim(from: 0, to: 0.28)
                    .stroke(
                        AngularGradient(
                            colors: [.clear, tint.opacity(0.9), .clear],
                            center: .center
                        ),
                        style: StrokeStyle(lineWidth: ScanCoreMetrics.sweepWidth, lineCap: .round)
                    )
                    .frame(width: ScanCoreMetrics.sweepDiameter, height: ScanCoreMetrics.sweepDiameter)
                    .rotationEffect(.degrees(sweeping ? 360 : 0))
                    .animation(
                        .linear(duration: ScanCoreMetrics.sweepDuration).repeatForever(autoreverses: false),
                        value: sweeping
                    )
            }
        }
    }

    /// The progress ring — the stage's real fraction, drawn only when one is measured. An
    /// indeterminate stage (`.running(progress: nil)`) draws no ring at all.
    private var progressRing: some View {
        let fraction = ScanCorePresentation.progressFraction(phase)
        return Group {
            if let fraction {
                Circle()
                    .trim(from: 0, to: fraction)
                    .stroke(
                        AngularGradient(colors: [tint, tint.opacity(0.55)], center: .center),
                        style: StrokeStyle(lineWidth: ScanCoreMetrics.progressWidth, lineCap: .round)
                    )
                    .frame(width: ScanCoreMetrics.progressDiameter, height: ScanCoreMetrics.progressDiameter)
                    .rotationEffect(.degrees(-90))
                    .animation(
                        NettoMotion.animation(for: .progress, reduceMotion: reduceMotion),
                        value: fraction
                    )
            }
        }
    }

    /// The luminous centre.
    private var core: some View {
        Circle()
            .fill(
                RadialGradient(
                    colors: [tint.opacity(0.95), tint.opacity(0.55)],
                    center: .center,
                    startRadius: 0,
                    endRadius: ScanCoreMetrics.coreRadius
                )
            )
            .frame(width: ScanCoreMetrics.coreSize, height: ScanCoreMetrics.coreSize)
    }

    // MARK: - Motion lifecycle

    /// Starts the sweep and the rings' breathing only when a run is in flight, Reduce Motion
    /// is off, and the scene is active; settles them the moment any of those ends.
    private func syncMotion() {
        let shouldMove = isSweepingAllowed
        guard shouldMove != sweeping else { return }
        sweeping = shouldMove
        breathing = shouldMove
    }

    /// Stops all repeating motion without animating back to a start value — the sweep simply
    /// halts where it is, which is what a cancelled/paused/backgrounded scan should look like.
    private func stopMotion() {
        sweeping = false
        breathing = false
    }
}

/// The scan core's dimensions — one place so the rings, sweep, and progress stay in step.
enum ScanCoreMetrics {
    static let size: CGFloat = 48
    static let coreSize: CGFloat = 14
    static let coreRadius: CGFloat = 7
    static let outerRing: CGFloat = 44
    static let innerRing: CGFloat = 32
    static let sweepDiameter: CGFloat = 44
    static let progressDiameter: CGFloat = 40
    static let ringWidth: CGFloat = 1
    static let sweepWidth: CGFloat = 2.5
    static let progressWidth: CGFloat = 3
    static let sweepDuration: Double = 2.8
}

import Foundation

/// The scan core's visual state — a pure, testable read of `DashboardPresentation.ScanStatus`.
///
/// The core is the dashboard's scan animation: a luminous centre with concentric rings and a
/// slow sweep. Everything it draws is a decision made here, from real state, so the animation
/// can never invent progress, a stage, or a completion that the app has not actually reached.
///
/// No timers, no clocks, no side effects — the view supplies `reduceMotion` and the current
/// `ScanStatus`, and this type answers what should be drawn and what should still be moving.
enum ScanCorePresentation {
    /// What the core is doing right now.
    enum Phase: Equatable, Sendable {
        /// Nothing is running: ready, permission-blocked, or an empty library. A quiet,
        /// settled core — no sweep, no pulse, no fabricated motion.
        case resting
        /// A run is in flight. `progress` is the stage's *real* fraction, or `nil` when the
        /// stage reports no denominator (catalog enumeration, measuring). The sweep turns
        /// either way; the progress ring only ever shows a measured value.
        case running(progress: Double?)
        /// A paused run, frozen at its saved position. `progress` is that saved fraction —
        /// never `nil` (a pause with no measured position presents as `.resting`), and the
        /// core is still: nothing is moving while a run is paused.
        case paused(progress: Double)
        /// A successful run finished. Settled, no motion.
        case finished
        /// A run was cancelled. Settled, no motion.
        case cancelled
        /// A run failed. Settled, no motion.
        case failed
    }

    /// The single mapping from the scan card's status to the core's phase.
    ///
    /// A cancelled or failed *catalog* build and a cancelled or failed *analysis* land on the
    /// same settled phase — the core never claims motion the app does not have.
    static func phase(for status: DashboardPresentation.ScanStatus) -> Phase {
        switch status {
        case .scanning(_, let fraction, _):
            // Pass the fraction through exactly as reported: `nil` stays `nil` (an
            // indeterminate stage is drawn as an indeterminate sweep, never a fake ring).
            return .running(progress: fraction)
        case .paused(_, let fraction):
            // A pause with a saved position freezes there; one without presents as resting.
            return fraction.map { .paused(progress: $0) } ?? .resting
        case .finished:
            return .finished
        case .cancelled:
            return .cancelled
        case .failed:
            return .failed
        case .idle, .permissionRequired, .permissionDenied, .emptyLibrary:
            return .resting
        }
    }

    /// Whether the sweep should be turning. Only an in-flight run sweeps; a paused, terminal,
    /// or resting core is still.
    static func isSweeping(_ phase: Phase) -> Bool {
        if case .running = phase { return true }
        return false
    }

    /// Whether the core should show a progress ring, and at what fraction. `nil` means "draw
    /// no ring" — an indeterminate stage and a resting/terminal core both get no ring rather
    /// than a ring at a made-up position.
    static func progressFraction(_ phase: Phase) -> Double? {
        switch phase {
        case .running(let progress):
            return progress.map { min(max($0, 0), 1) }
        case .paused(let progress):
            return min(max(progress, 0), 1)
        case .resting, .finished, .cancelled, .failed:
            return nil
        }
    }
}

import Foundation

/// What the active scan card should say about time remaining.
///
/// Deliberately a small closed set so the view never does arithmetic: each case is already a
/// decision the estimator can defend with samples.
enum ScanETA: Sendable, Equatable {
    /// Not enough throughput samples yet — say "Calculating time remaining…", never a guess.
    case calculating
    /// The current stage reports no denominator (e.g. counting assets) — stage and an
    /// indeterminate bar only; no percentage, no countdown.
    case indeterminate
    /// A trustworthy estimate, in seconds (always > 0 — negatives cannot be represented).
    case remaining(seconds: Int)
    /// The stage is within a whisker of finishing, where any countdown would be noise —
    /// prefer "Finishing analysis…" over a fake "0 seconds remaining".
    case finishing
}

/// Rolling-throughput estimator for the active scan's *current stage*.
///
/// Pure value type: no SwiftUI, no MainActor, no timers, no wall clock. Callers hand in
/// progress samples with a **monotonic** elapsed time (`ScanETAEstimator.monotonicNow()`,
/// which is `ProcessInfo.systemUptime`), and ask for the current estimate — all arithmetic
/// stays here, out of the views.
///
/// Behaviour that makes the number trustworthy:
/// - Samples closer than `minSampleInterval` do not create throughput observations, so the
///   estimate reacts to a rolling window rather than to every progress tick.
/// - Observations are smoothed with an exponential moving average (`smoothing`), so one
///   stalled batch cannot swing the countdown.
/// - A stage change resets everything: each stage is estimated from its own throughput only.
/// - Fewer than `minimumRateSamples` observations → `.calculating`. A single sample is a
///   guess, not an estimate.
/// - Totals ≤ 0 → `.indeterminate`; near-complete or non-positive remainders → `.finishing`.
struct ScanETAEstimator: Sendable, Equatable {
    /// Minimum spacing between throughput observations (seconds of monotonic time).
    static let minSampleInterval: TimeInterval = 1.0
    /// Exponential moving average weight for the newest observation.
    static let smoothing = 0.35
    /// Observations required before any countdown is shown.
    static let minimumRateSamples = 2
    /// Below this many remaining seconds the countdown is noise — show "Finishing analysis…" .
    static let finishingThresholdSeconds: TimeInterval = 5

    /// Current stage key (opaque string: analysis stage raw value, or `"catalog"`).
    private(set) var stage: String?
    /// Latest completed/total seen for the stage (updated on every record).
    private var currentCompleted = 0
    private var currentTotal = 0
    /// Anchor for the next throughput observation (monotonic elapsed + completed at that time).
    private var anchorElapsed: TimeInterval?
    private var anchorCompleted = 0
    /// Smoothed units-per-second throughput of the current stage.
    private var rate: Double?
    private var rateSamples = 0

    /// Monotonic clock for performance measurement — safe across wall-clock changes.
    static func monotonicNow() -> TimeInterval {
        ProcessInfo.processInfo.systemUptime
    }

    /// Drops all accumulated state — call when a new scan (or a new stage owner, such as a
    /// standalone catalog build) starts.
    mutating func reset() {
        stage = nil
        currentCompleted = 0
        currentTotal = 0
        anchorElapsed = nil
        anchorCompleted = 0
        rate = nil
        rateSamples = 0
    }

    /// One progress sample. A different `stage` (or time moving backwards) resets the
    /// stage-specific state first, so stage transitions can never inherit the old stage's
    /// throughput.
    mutating func record(stage: String, completed: Int, total: Int, at elapsed: TimeInterval) {
        guard elapsed >= 0 else { return }
        if stage != self.stage {
            reset()
            self.stage = stage
            currentCompleted = completed
            currentTotal = total
            anchorElapsed = elapsed
            anchorCompleted = completed
            return
        }
        currentCompleted = completed
        currentTotal = total
        guard let anchor = anchorElapsed, elapsed - anchor >= Self.minSampleInterval else {
            return
        }
        let deltaT = elapsed - anchor
        let deltaU = completed - anchorCompleted
        if deltaT > 0, deltaU >= 0 {
            let observation = Double(deltaU) / deltaT
            rate = rate.map { Self.smoothing * observation + (1 - Self.smoothing) * $0 }
                ?? observation
            rateSamples += 1
        }
        anchorElapsed = elapsed
        anchorCompleted = completed
    }

    /// The current stage's estimate. Pure — no clock, no side effects.
    func estimate() -> ScanETA {
        guard stage != nil else { return .calculating }
        guard currentTotal > 0 else { return .indeterminate }
        guard let rate, rate > 0, rateSamples >= Self.minimumRateSamples else {
            return .calculating
        }
        let remainingUnits = Double(currentTotal - currentCompleted)
        guard remainingUnits > 0 else { return .finishing }
        let seconds = remainingUnits / rate
        guard seconds.isFinite, seconds >= 0 else { return .finishing }
        guard seconds >= Self.finishingThresholdSeconds else { return .finishing }
        return .remaining(seconds: Int(seconds.rounded()))
    }

    /// Smoothed units per second for the current stage — the number the estimate is built on.
    var observedThroughput: Double? { rate }

    // MARK: Display strings (pure, testable)

    /// The card's ETA line, or `nil` when there is no honest line to show.
    static func etaLine(for eta: ScanETA) -> String? {
        switch eta {
        case .calculating: return "Calculating time remaining…"
        case .finishing: return "Finishing analysis…"
        case .indeterminate: return nil
        case .remaining(let seconds): return remainingText(seconds: seconds)
        }
    }

    /// `~45 sec remaining` / `~3 min remaining` / `~1 hr 12 min remaining`.
    /// Rounded to seconds under a minute and to minutes beyond, so the number does not jump
    /// on every tick. Never emits a negative or zero countdown.
    static func remainingText(seconds: Int) -> String {
        let seconds = max(0, seconds)
        if seconds < 60 {
            return "~\(max(1, seconds)) sec remaining"
        }
        let roundedMinutes = Int((Double(seconds) / 60).rounded())
        if seconds < 3_600 {
            if roundedMinutes >= 60 {
                return "~1 hr remaining"
            }
            return "~\(max(1, roundedMinutes)) min remaining"
        }
        var hours = seconds / 3_600
        var minutes = Int((Double(seconds - hours * 3_600) / 60).rounded())
        if minutes >= 60 {
            hours += 1
            minutes = 0
        }
        if minutes == 0 {
            return "~\(hours) hr remaining"
        }
        return "~\(hours) hr \(minutes) min remaining"
    }
}

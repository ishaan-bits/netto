import Testing
@testable import Netto

/// The scan core must never animate something the app is not actually doing: a paused or
/// terminal run is still, an indeterminate stage draws no progress ring, and a measured
/// fraction is passed through exactly as reported. These pin the pure mapping that
/// `ScanCoreView` renders from, so the animation's *meaning* is tested without a renderer.
struct ScanCorePresentationTests {
    // MARK: - Idle / ready / blocked

    @Test func idleIsRestingWithNoSweepAndNoRing() {
        let phase = ScanCorePresentation.phase(for: .idle)
        #expect(phase == .resting)
        #expect(ScanCorePresentation.isSweeping(phase) == false)
        #expect(ScanCorePresentation.progressFraction(phase) == nil)
    }

    @Test func permissionBlockedStatesAreRestingNotAnimated() {
        for status in [DashboardPresentation.ScanStatus.permissionRequired,
                       .permissionDenied,
                       .emptyLibrary] {
            let phase = ScanCorePresentation.phase(for: status)
            #expect(phase == .resting)
            #expect(ScanCorePresentation.isSweeping(phase) == false)
        }
    }

    // MARK: - Starting / catalog enumeration (indeterminate)

    @Test func scanningWithoutAFractionSweepsButDrawsNoProgressRing() {
        // Catalog enumeration reports no denominator: the core must sweep (work is
        // happening) but must not draw a progress ring at a made-up position.
        let phase = ScanCorePresentation.phase(for: .scanning(stage: "Reading library…", fraction: nil, eta: .indeterminate))
        #expect(phase == .running(progress: nil))
        #expect(ScanCorePresentation.isSweeping(phase) == true)
        #expect(ScanCorePresentation.progressFraction(phase) == nil)
    }

    // MARK: - Active analysis with real progress

    @Test func scanningWithAFractionSweepsAndDrawsTheRealFraction() {
        let phase = ScanCorePresentation.phase(for: .scanning(stage: "Comparing", fraction: 0.42, eta: .calculating))
        #expect(phase == .running(progress: 0.42))
        #expect(ScanCorePresentation.isSweeping(phase) == true)
        #expect(ScanCorePresentation.progressFraction(phase) == 0.42)
    }

    @Test func theProgressFractionIsClampedAndNeverInvented() {
        // Out-of-range values (a racing progress tick) are clamped, not drawn as-is.
        #expect(ScanCorePresentation.progressFraction(.running(progress: -3)) == 0)
        #expect(ScanCorePresentation.progressFraction(.running(progress: 7)) == 1)
        #expect(ScanCorePresentation.progressFraction(.paused(progress: -1)) == 0)
        #expect(ScanCorePresentation.progressFraction(.paused(progress: 2)) == 1)
    }

    // MARK: - Paused / queued behind another pass

    @Test func pausedWithASavedPositionFreezesThereWithoutSweeping() {
        // A paused run keeps its saved fraction but is still — nothing is moving, so the
        // sweep must not turn and the ring must show the saved position.
        let phase = ScanCorePresentation.phase(for: .paused(stage: "Comparing", fraction: 0.6))
        #expect(phase == .paused(progress: 0.6))
        #expect(ScanCorePresentation.isSweeping(phase) == false)
        #expect(ScanCorePresentation.progressFraction(phase) == 0.6)
    }

    @Test func pausedWithoutAMeasuredPositionPresentsAsResting() {
        // No saved fraction → nothing to freeze at, and no ring at a made-up zero.
        let phase = ScanCorePresentation.phase(for: .paused(stage: "Reading library…", fraction: nil))
        #expect(phase == .resting)
        #expect(ScanCorePresentation.isSweeping(phase) == false)
        #expect(ScanCorePresentation.progressFraction(phase) == nil)
    }

    // MARK: - Cancellation / failure / successful completion (terminal states)

    @Test func terminalStatesAreSettledWithNoSweepAndNoRing() {
        let terminal: [DashboardPresentation.ScanStatus] = [
            .finished(analyzed: 10, total: 10, groups: 2, lastScannedAt: nil),
            .cancelled,
            .failed("boom")
        ]
        for status in terminal {
            let phase = ScanCorePresentation.phase(for: status)
            #expect(ScanCorePresentation.isSweeping(phase) == false)
            #expect(ScanCorePresentation.progressFraction(phase) == nil)
        }
    }

    @Test func eachTerminalStateMapsToItsOwnPhase() {
        #expect(ScanCorePresentation.phase(for: .finished(analyzed: 1, total: 1, groups: 0, lastScannedAt: nil)) == .finished)
        #expect(ScanCorePresentation.phase(for: .cancelled) == .cancelled)
        #expect(ScanCorePresentation.phase(for: .failed("boom")) == .failed)
    }

    // MARK: - Reduce Motion is a view concern, but the phase must not require motion

    @Test func onlyAnInFlightRunEverSweeps() {
        // The one gate the view uses to decide whether motion is warranted at all.
        let sweeping: [ScanCorePresentation.Phase] = [
            .running(progress: nil), .running(progress: 0.5)
        ]
        let still: [ScanCorePresentation.Phase] = [
            .resting, .paused(progress: 0.5), .finished, .cancelled, .failed
        ]
        for phase in sweeping { #expect(ScanCorePresentation.isSweeping(phase) == true) }
        for phase in still { #expect(ScanCorePresentation.isSweeping(phase) == false) }
    }
}

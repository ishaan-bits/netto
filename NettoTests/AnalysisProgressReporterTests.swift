import Foundation
import Testing
@testable import Netto

// MARK: - Test doubles

/// `@unchecked Sendable`: every access goes through `lock`.
private final class ReporterEventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [PhotoAnalysisProgress] = []

    func append(_ value: PhotoAnalysisProgress) {
        lock.lock()
        values.append(value)
        lock.unlock()
    }

    var snapshot: [PhotoAnalysisProgress] {
        lock.lock()
        defer { lock.unlock() }
        return values
    }
}

// MARK: - Throttled emission

/// The reporter is the single funnel between worker-pool counters and the main actor. These
/// tests pin the throttle contract: intermediate ticks coalesce, but stage transitions, total
/// changes, and terminal counts always publish — so progress can be quiet without ever being
/// wrong or looking stuck.
struct AnalysisProgressReporterTests {
    @Test func rapidAdvancesCoalesceButTheTerminalCountAlwaysEmits() throws {
        let log = ReporterEventLog()
        let reporter = AnalysisProgressReporter(
            observer: NoopStageObserver(),
            report: { log.append($0) },
            minEmitIntervalNanos: 50_000_000
        )

        try reporter.enter(.fingerprinting, total: 10_000)
        for _ in 0..<10_000 {
            try reporter.advance(.fingerprinting, total: 10_000)
        }

        let events = log.snapshot
        #expect(events.first?.stage == .fingerprinting)
        #expect(events.first?.completedUnits == 0, "the stage entry must publish immediately")
        #expect(events.count < 50, "advances must coalesce; got \(events.count) events")
        #expect(events.last?.completedUnits == 10_000)
        #expect(events.last?.totalUnits == 10_000)

        var lastCompleted = -1
        for event in events {
            #expect(event.completedUnits >= lastCompleted, "emission went backwards")
            lastCompleted = event.completedUnits
        }
    }

    @Test func stageTransitionsAlwaysEmitInsideTheInterval() throws {
        let log = ReporterEventLog()
        // An interval longer than the test guarantees only the forced cases publish.
        let reporter = AnalysisProgressReporter(
            observer: NoopStageObserver(),
            report: { log.append($0) },
            minEmitIntervalNanos: 60_000_000_000
        )

        try reporter.enter(.preparing, total: 1)
        try reporter.complete(.preparing, total: 1)
        try reporter.enter(.fingerprinting, total: 4)
        try reporter.advance(.fingerprinting, total: 4) // intermediate → coalesced
        try reporter.setCount(.fingerprinting, completed: 4, total: 6) // total change → forced

        let events = log.snapshot
        #expect(events.map(\.stage) == [.preparing, .preparing, .fingerprinting, .fingerprinting])
        #expect(events[0].completedUnits == 0)
        #expect(events[1].completedUnits == 1)
        #expect(events[3].completedUnits == 4)
        #expect(events[3].totalUnits == 6, "a changed total must publish, or the stage can never complete")
    }

    @Test func completionOfATotallyIndeterminateStageStillPublishes() throws {
        let log = ReporterEventLog()
        let reporter = AnalysisProgressReporter(
            observer: NoopStageObserver(),
            report: { log.append($0) },
            minEmitIntervalNanos: 60_000_000_000
        )

        try reporter.enter(.generatingCandidates, total: 0)
        try reporter.complete(.generatingCandidates, total: 0)

        let events = log.snapshot
        #expect(events.count == 2)
        #expect(events.last?.completedUnits == 0)
        #expect(events.last?.totalUnits == 0)
    }
}

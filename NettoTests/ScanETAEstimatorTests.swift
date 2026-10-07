import Foundation
import Testing
@testable import Netto

struct ScanETAEstimatorTests {
    // MARK: Insufficient samples

    @Test func noRecordsMeansNoFabricatedETA() {
        #expect(ScanETAEstimator().estimate() == .calculating)
        #expect(ScanETAEstimator.etaLine(for: .calculating) == "Calculating time remaining…")
    }

    @Test func aSingleThroughputSampleIsStillJustAGuess() {
        var estimator = ScanETAEstimator()
        estimator.record(stage: "extractingFeatures", completed: 0, total: 10_000, at: 0)
        estimator.record(stage: "extractingFeatures", completed: 1_000, total: 10_000, at: 1)
        // One observation: a countdown now would be a single-sample guess.
        #expect(estimator.estimate() == .calculating)

        estimator.record(stage: "extractingFeatures", completed: 2_000, total: 10_000, at: 2)
        // Two observations at a steady 1000 units/s with 8000 left → ~8 seconds.
        #expect(estimator.estimate() == .remaining(seconds: 8))
    }

    @Test func samplesCloserThanTheMinimumIntervalRollUpInsteadOfCounting() {
        var estimator = ScanETAEstimator()
        // 31 records at 0.1 s cadence — only the ≥1 s spacing can create observations.
        for index in 0...30 {
            estimator.record(
                stage: "fingerprinting",
                completed: index * 10,
                total: 10_000,
                at: Double(index) * 0.1
            )
        }
        #expect(abs((estimator.observedThroughput ?? 0) - 100) < 0.001)
        #expect(estimator.estimate() == .remaining(seconds: 97))
    }

    // MARK: Smoothing

    @Test func rollingThroughputSmoothsNoisySamples() {
        var estimator = ScanETAEstimator()
        estimator.record(stage: "comparing", completed: 0, total: 10_000, at: 0)
        estimator.record(stage: "comparing", completed: 100, total: 10_000, at: 1)
        estimator.record(stage: "comparing", completed: 200, total: 10_000, at: 2)
        // Steady 100/s so far; then one 900/s batch — a raw reaction would jump to 900.
        estimator.record(stage: "comparing", completed: 1_100, total: 10_000, at: 3)

        // EMA(α=0.35): 0.35·900 + 0.65·100 = 380 units/s — pulled, not yanked.
        #expect(abs((estimator.observedThroughput ?? 0) - 380) < 0.001)
        // 8900 units left ÷ 380 ≈ 23.4 s → 23 s.
        #expect(estimator.estimate() == .remaining(seconds: 23))
    }

    // MARK: Never negative, never fake

    @Test func etaIsNeverNegativeEvenWhenProgressOvershoots() {
        var estimator = ScanETAEstimator()
        estimator.record(stage: "grouping", completed: 0, total: 1_000, at: 0)
        estimator.record(stage: "grouping", completed: 500, total: 1_000, at: 1)
        estimator.record(stage: "grouping", completed: 1_200, total: 1_000, at: 2)
        #expect(estimator.estimate() == .finishing)

        // The formatter itself never emits a negative or zero countdown either.
        let text = ScanETAEstimator.remainingText(seconds: -30)
        #expect(!text.contains("-"))
        #expect(text.hasPrefix("~"))
    }

    @Test func unknownTotalIsIndeterminateNotAFakePercentage() {
        var estimator = ScanETAEstimator()
        estimator.record(stage: "catalog", completed: 0, total: 0, at: 0)
        estimator.record(stage: "catalog", completed: 0, total: 0, at: 1)
        estimator.record(stage: "catalog", completed: 0, total: 0, at: 2)
        #expect(estimator.estimate() == .indeterminate)
        // No denominator → no line at all; the stage name and indeterminate bar carry it.
        #expect(ScanETAEstimator.etaLine(for: .indeterminate) == nil)
    }

    // MARK: Stage transitions

    @Test func stageTransitionResetsThroughputAndRecalculates() {
        var estimator = ScanETAEstimator()
        estimator.record(stage: "fingerprinting", completed: 0, total: 10_000, at: 0)
        estimator.record(stage: "fingerprinting", completed: 1_000, total: 10_000, at: 1)
        estimator.record(stage: "fingerprinting", completed: 2_000, total: 10_000, at: 2)
        #expect(estimator.estimate() == .remaining(seconds: 8))

        // New stage: no inherited throughput, no inherited countdown.
        estimator.record(stage: "grouping", completed: 0, total: 10_000, at: 3)
        #expect(estimator.observedThroughput == nil)
        #expect(estimator.estimate() == .calculating)

        // …and the new stage earns its estimate only from its own samples.
        estimator.record(stage: "grouping", completed: 1_000, total: 10_000, at: 4)
        #expect(estimator.estimate() == .calculating)
        estimator.record(stage: "grouping", completed: 2_000, total: 10_000, at: 5)
        #expect(estimator.estimate() == .remaining(seconds: 8))
    }

    @Test func nearCompletionPrefersFinishingOverAFakeCountdown() {
        var estimator = ScanETAEstimator()
        estimator.record(stage: "finalizing", completed: 0, total: 10_000, at: 0)
        estimator.record(stage: "finalizing", completed: 1_000, total: 10_000, at: 1)
        estimator.record(stage: "finalizing", completed: 2_000, total: 10_000, at: 2)
        // A steady 1000/s with 8000 left → a real 8-second countdown.
        #expect(estimator.estimate() == .remaining(seconds: 8))

        // Then a batch lands everything but two units — a countdown now would be noise.
        estimator.record(stage: "finalizing", completed: 9_998, total: 10_000, at: 3)
        #expect(estimator.estimate() == .finishing)
        #expect(ScanETAEstimator.etaLine(for: .finishing) == "Finishing analysis…")
    }

    // MARK: Formatting

    @Test func formattingFollowsSecondsMinutesAndHoursRules() {
        #expect(ScanETAEstimator.remainingText(seconds: 45) == "~45 sec remaining")
        #expect(ScanETAEstimator.remainingText(seconds: 1) == "~1 sec remaining")
        #expect(ScanETAEstimator.remainingText(seconds: 90) == "~2 min remaining")
        #expect(ScanETAEstimator.remainingText(seconds: 200) == "~3 min remaining")
        #expect(ScanETAEstimator.remainingText(seconds: 3_599) == "~1 hr remaining")
        #expect(ScanETAEstimator.remainingText(seconds: 3_600) == "~1 hr remaining")
        #expect(ScanETAEstimator.remainingText(seconds: 4_320) == "~1 hr 12 min remaining")
        #expect(ScanETAEstimator.remainingText(seconds: 7_200) == "~2 hr remaining")
    }

    @Test func etaLinesMapEachStateToItsWording() {
        #expect(ScanETAEstimator.etaLine(for: .calculating) == "Calculating time remaining…")
        #expect(ScanETAEstimator.etaLine(for: .finishing) == "Finishing analysis…")
        #expect(ScanETAEstimator.etaLine(for: .remaining(seconds: 120)) == "~2 min remaining")
        #expect(ScanETAEstimator.etaLine(for: .indeterminate) == nil)
    }

    // MARK: Concurrency

    @Test func estimatorDoesNotRequireTheMainActor() async {
        // Constructed, mutated, and read entirely off the main actor — if the type needed
        // MainActor isolation this would not compile under Swift 6 strict concurrency.
        let estimate = await Task.detached { () -> ScanETA in
            var estimator = ScanETAEstimator()
            estimator.record(stage: "extractingFeatures", completed: 0, total: 10_000, at: 0)
            estimator.record(stage: "extractingFeatures", completed: 1_000, total: 10_000, at: 1)
            estimator.record(stage: "extractingFeatures", completed: 2_000, total: 10_000, at: 2)
            return estimator.estimate()
        }.value
        #expect(estimate == .remaining(seconds: 8))
    }
}

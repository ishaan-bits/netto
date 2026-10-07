import Foundation
import Testing
@testable import Netto

// MARK: Dashboard presentation derivations
//
// The dashboard's hero values and primary action are derived from real state — never
// measured or invented in the view. These tests pin the derivations, especially the
// all-zeros failed storage read, which must never surface as a real measurement.

struct DashboardFlowTests {
    private let runningProgress = PhotoAnalysisProgress(
        stage: .fingerprinting,
        completedUnits: 12,
        totalUnits: 48
    )

    @Test func notDeterminedPermissionAsksFirst() {
        let action = DashboardPresentation.libraryAction(
            permission: .notDetermined,
            catalog: .notStarted,
            analysis: .notStarted
        )
        #expect(action == .requestAccess)
    }

    @Test func deniedAndRestrictedPointAtSettings() {
        for permission in [PermissionState.denied, .restricted] {
            let action = DashboardPresentation.libraryAction(
                permission: permission,
                catalog: .notStarted,
                analysis: .notStarted
            )
            #expect(action == .openSettings)
        }
    }

    @Test func usablePermissionOffersAnalysis() {
        for permission in [PermissionState.authorized, .limited] {
            let action = DashboardPresentation.libraryAction(
                permission: permission,
                catalog: .notStarted,
                analysis: .notStarted
            )
            #expect(action == .analyze)
        }
    }

    @Test func runningAnalysisShowsStageAndFraction() {
        let action = DashboardPresentation.libraryAction(
            permission: .authorized,
            catalog: .notStarted,
            analysis: .running(runningProgress)
        )
        #expect(
            action == .analyzing(
                stage: SimilarPhotosPresentation.stageMessage(for: runningProgress),
                fraction: 0.25
            )
        )
    }

    @Test func failedAnalysisOffersRetryWithItsMessage() {
        let failure = PhotoAnalysisFailure.underlying("Could not read your library.")
        let action = DashboardPresentation.libraryAction(
            permission: .authorized,
            catalog: .notStarted,
            analysis: .failed(failure)
        )
        #expect(action == .retry(message: failure.userMessage))
    }

    @Test func completedOrCancelledRunOffersAnalysisAgain() {
        let completed = DashboardPresentation.libraryAction(
            permission: .authorized,
            catalog: .notStarted,
            analysis: .completed(Self.sampleResult)
        )
        #expect(completed == .analyze)

        let cancelled = DashboardPresentation.libraryAction(
            permission: .authorized,
            catalog: .notStarted,
            analysis: .cancelled
        )
        #expect(cancelled == .analyze)
    }

    @Test func leftoverCatalogStateStillOffersAnalysis() {
        let catalogStates: [CatalogScanState] = [
            .completed(CatalogScanResult(records: [], libraryAssetCount: 0, accessLevel: .authorized)),
            .cancelled
        ]
        for catalog in catalogStates {
            let action = DashboardPresentation.libraryAction(
                permission: .authorized,
                catalog: catalog,
                analysis: .notStarted
            )
            #expect(action == .analyze)
        }
    }

    @Test func heroFractionIsNilBeforeTheRead() {
        #expect(DashboardPresentation.heroFraction(nil) == nil)
    }

    @Test func heroFractionIsNilForAFailedRead() {
        let failedRead = StorageSnapshot(totalCapacity: 0, availableCapacity: 0)
        #expect(DashboardPresentation.heroFraction(failedRead) == nil)
    }

    @Test func heroFractionMatchesTheRealMeasurement() {
        let snapshot = StorageSnapshot(
            totalCapacity: 128_000_000_000,
            availableCapacity: 32_000_000_000
        )
        #expect(DashboardPresentation.heroFraction(snapshot) == 0.75)
    }

    // MARK: - Scan ETA presentation

    @Test func scanStatusForwardsTheETAIntoTheScanningState() {
        let status = DashboardPresentation.scanStatus(
            permission: .authorized,
            catalog: .notStarted,
            analysis: .running(PhotoAnalysisProgress(
                stage: .extractingFeatures,
                completedUnits: 5_397,
                totalUnits: 41_036
            )),
            eta: .remaining(seconds: 120)
        )
        guard case .scanning(_, let fraction, let eta) = status else {
            Issue.record("expected scanning, got \(status)")
            return
        }
        #expect(eta == .remaining(seconds: 120))
        #expect(fraction != nil)
    }

    @Test func scanningCopyShowsStageCountsThenTimeRemaining() {
        let stage = "Analyzing 5397 of 41036 images…"
        let copy = DashboardPresentation.scanCopy(for: .scanning(
            stage: stage,
            fraction: 0.13,
            eta: .remaining(seconds: 120)
        ))
        #expect(copy.title == "Scanning your library")
        #expect(copy.body == stage + "\n~2 min remaining")
        #expect(copy.buttonTitle == "Cancel")
    }

    @Test func calculatingLineShowsBeforeEnoughThroughputSamples() {
        let stage = "Fingerprinting…"
        let copy = DashboardPresentation.scanCopy(for: .scanning(
            stage: stage,
            fraction: nil,
            eta: .calculating
        ))
        #expect(copy.body == stage + "\nCalculating time remaining…")
    }

    @Test func finishingLineWinsOverAUntrustworthyCountdown() {
        let copy = DashboardPresentation.scanCopy(for: .scanning(
            stage: "Comparing 40 of 41 groups…",
            fraction: 0.98,
            eta: .finishing
        ))
        #expect(copy.body.contains("Finishing analysis…"))
        #expect(!copy.body.contains("sec remaining"))
        #expect(!copy.body.contains("min remaining"))
        #expect(!copy.body.contains("Calculating"))
    }

    @Test func indeterminateStageAddsNoTimeLine() {
        let stage = "Counting assets…"
        let copy = DashboardPresentation.scanCopy(for: .scanning(
            stage: stage,
            fraction: nil,
            eta: .indeterminate
        ))
        #expect(copy.body == stage)
    }

    @Test func completedAndCancelledStatesCarryNoETA() {
        let completed = DashboardPresentation.scanStatus(
            permission: .authorized,
            catalog: .notStarted,
            analysis: .completed(Self.sampleResult),
            eta: .remaining(seconds: 120)
        )
        #expect(completed == .finished(analyzed: 4, total: 4, groups: 0, lastScannedAt: nil))

        let cancelled = DashboardPresentation.scanStatus(
            permission: .authorized,
            catalog: .notStarted,
            analysis: .cancelled,
            eta: .calculating
        )
        #expect(cancelled == .cancelled)
    }

    private static let sampleResult = PhotoAnalysisResult(
        exactGroups: [],
        similarGroups: [],
        unavailableAssets: [],
        descriptorKind: nil,
        visionAvailable: false,
        similarityThreshold: nil,
        totalRecordCount: 4,
        candidateBucketCount: 0,
        candidatePairCount: 0
    )
}

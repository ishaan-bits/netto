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

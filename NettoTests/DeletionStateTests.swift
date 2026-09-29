import Foundation
import Testing
@testable import Netto

// MARK: - State machine

struct DeletionStateTests {
    private let plan = DeletionPlan(
        schemaVersion: DeletionPlan.currentVersion,
        items: [
            DeletionPlanItem(localIdentifier: "a", mediaType: .image, sizeInBytes: 10, category: nil),
            DeletionPlanItem(localIdentifier: "b", mediaType: .image, sizeInBytes: nil, category: nil)
        ],
        authorization: .authorized,
        sessionToken: "s",
        analysisSignature: "sig"
    )

    @Test func happyPathTransitionsAreAllLegal() {
        #expect(DeletionState.canTransition(from: .noSelection, to: .preparingPlan))
        #expect(DeletionState.canTransition(from: .preparingPlan, to: .resolvingSizes))
        #expect(DeletionState.canTransition(from: .resolvingSizes, to: .readyForReview(plan)))
        #expect(DeletionState.canTransition(from: .readyForReview(plan), to: .awaitingConfirmation(plan)))
        #expect(DeletionState.canTransition(from: .awaitingConfirmation(plan), to: .deleting(plan)))
        #expect(DeletionState.canTransition(
            from: .deleting(plan),
            to: .succeeded(DeletionSuccess(plannedCount: 2, verifiedRemovedCount: 2, remainingIDs: []))
        ))
    }

    @Test func deletionCanNeverBeReachedWithoutConfirmation() {
        #expect(!DeletionState.canTransition(from: .noSelection, to: .deleting(plan)))
        #expect(!DeletionState.canTransition(from: .preparingPlan, to: .deleting(plan)))
        #expect(!DeletionState.canTransition(from: .resolvingSizes, to: .deleting(plan)))
        #expect(!DeletionState.canTransition(from: .readyForReview(plan), to: .deleting(plan)))
        #expect(!DeletionState.canTransition(from: .planStale(plan, []), to: .deleting(plan)))
        #expect(!DeletionState.canTransition(from: .failed("x"), to: .deleting(plan)))
        #expect(!DeletionState.canTransition(from: .permissionRequired(.denied), to: .deleting(plan)))
    }

    @Test func resultsRequireExecutionFirst() {
        let success = DeletionSuccess(plannedCount: 1, verifiedRemovedCount: 1, remainingIDs: [])
        #expect(!DeletionState.canTransition(from: .awaitingConfirmation(plan), to: .succeeded(success)))
        #expect(!DeletionState.canTransition(from: .awaitingConfirmation(plan), to: .needsReview(success)))
        #expect(!DeletionState.canTransition(from: .readyForReview(plan), to: .failed("x")))
        #expect(!DeletionState.canTransition(from: .deleting(plan), to: .awaitingConfirmation(plan)))
    }

    @Test func aFinishedPlanCanNeverBeReused() {
        let success = DeletionSuccess(plannedCount: 1, verifiedRemovedCount: 1, remainingIDs: [])
        #expect(!DeletionState.canTransition(from: .succeeded(success), to: .deleting(plan)))
        #expect(!DeletionState.canTransition(from: .succeeded(success), to: .readyForReview(plan)))
        #expect(!DeletionState.canTransition(from: .needsReview(success), to: .deleting(plan)))
    }

    @Test func everyStateCanResetToNoSelection() {
        let states: [DeletionState] = [
            .noSelection, .preparingPlan, .resolvingSizes, .readyForReview(plan),
            .planStale(plan, [.selectionChanged]), .awaitingConfirmation(plan), .deleting(plan),
            .succeeded(DeletionSuccess(plannedCount: 1, verifiedRemovedCount: 1, remainingIDs: [])),
            .needsReview(DeletionSuccess(plannedCount: 2, verifiedRemovedCount: 1, remainingIDs: ["b"])),
            .failed("x"),
            .permissionRequired(.denied)
        ]
        for state in states {
            #expect(DeletionState.canTransition(from: state, to: .noSelection))
        }
    }

    @Test func confirmationIsReversibleButOnlyUntilExecution() {
        #expect(DeletionState.canTransition(from: .awaitingConfirmation(plan), to: .readyForReview(plan)))
        #expect(DeletionState.canTransition(from: .readyForReview(plan), to: .planStale(plan, [.selectionChanged])))
        // A cancelled execution may return to review; a stale plan may not resurrect into
        // confirmation directly, and deleting never jumps back to confirmation.
        #expect(!DeletionState.canTransition(from: .planStale(plan, []), to: .awaitingConfirmation(plan)))
        #expect(!DeletionState.canTransition(from: .deleting(plan), to: .awaitingConfirmation(plan)))
    }

    @Test func stateCarriesItsPlanOnlyWhileAPlanIsLive() {
        #expect(DeletionState.readyForReview(plan).plan == plan)
        #expect(DeletionState.awaitingConfirmation(plan).plan == plan)
        #expect(DeletionState.deleting(plan).plan == plan)
        #expect(DeletionState.planStale(plan, [.selectionChanged]).plan == plan)
        #expect(DeletionState.noSelection.plan == nil)
        #expect(DeletionState.resolvingSizes.plan == nil)
        #expect(DeletionState.succeeded(
            DeletionSuccess(plannedCount: 1, verifiedRemovedCount: 1, remainingIDs: [])
        ).plan == nil)
    }

    @Test func onlyDeletingMarksTheMachineAsDeleting() {
        #expect(DeletionState.deleting(plan).isDeleting)
        #expect(!DeletionState.awaitingConfirmation(plan).isDeleting)
        #expect(!DeletionState.succeeded(
            DeletionSuccess(plannedCount: 1, verifiedRemovedCount: 1, remainingIDs: [])
        ).isDeleting)
    }
}

// MARK: - Review-screen presentation (pure)

struct DeletionPresentationTests {
    private let exactPlan = DeletionPlan(
        schemaVersion: DeletionPlan.currentVersion,
        items: [
            DeletionPlanItem(
                localIdentifier: "a",
                mediaType: .image,
                sizeInBytes: 1_073_741_824,
                category: .exactDuplicates
            ),
            DeletionPlanItem(
                localIdentifier: "b",
                mediaType: .image,
                sizeInBytes: 1_073_741_824,
                category: .exactDuplicates
            )
        ],
        authorization: .authorized,
        sessionToken: "s",
        analysisSignature: "sig"
    )

    private let partialPlan = DeletionPlan(
        schemaVersion: DeletionPlan.currentVersion,
        items: [
            DeletionPlanItem(
                localIdentifier: "a",
                mediaType: .image,
                sizeInBytes: 1_000_000,
                category: .exactDuplicates
            ),
            DeletionPlanItem(localIdentifier: "b", mediaType: .image, sizeInBytes: nil, category: nil),
            DeletionPlanItem(localIdentifier: "c", mediaType: .video, sizeInBytes: nil, category: nil)
        ],
        authorization: .authorized,
        sessionToken: "s",
        analysisSignature: "sig"
    )

    @Test func phaseMappingCoversEveryState() {
        let success = DeletionSuccess(plannedCount: 2, verifiedRemovedCount: 2, remainingIDs: [])
        let partial = DeletionSuccess(plannedCount: 3, verifiedRemovedCount: 2, remainingIDs: ["c"])

        #expect(DeletionPresentation.phase(for: .noSelection) == .empty)
        #expect(DeletionPresentation.phase(for: .preparingPlan) == .building)
        #expect(DeletionPresentation.phase(for: .resolvingSizes) == .building)
        #expect(DeletionPresentation.phase(for: .readyForReview(exactPlan)) == .ready(exactPlan))
        #expect(DeletionPresentation.phase(for: .awaitingConfirmation(exactPlan)) == .ready(exactPlan))
        #expect(DeletionPresentation.phase(for: .planStale(exactPlan, [.selectionChanged]))
            == .stale([.selectionChanged]))
        #expect(DeletionPresentation.phase(for: .deleting(exactPlan)) == .deleting)
        #expect(DeletionPresentation.phase(for: .succeeded(success)) == .succeeded(success))
        #expect(DeletionPresentation.phase(for: .needsReview(partial)) == .needsReview(partial))
        #expect(DeletionPresentation.phase(for: .failed("boom")) == .failed("boom"))
        #expect(DeletionPresentation.phase(for: .permissionRequired(.denied))
            == .permissionRequired(.denied))
    }

    @Test func destructiveTitleNamesTheExactActionAndCount() {
        #expect(DeletionPresentation.destructiveTitle(for: exactPlan) == "Delete 2 Photos")

        let single = DeletionPlan(
            schemaVersion: DeletionPlan.currentVersion,
            items: exactPlan.items.prefix(1).map { $0 },
            authorization: .authorized,
            sessionToken: "s",
            analysisSignature: "sig"
        )
        #expect(DeletionPresentation.destructiveTitle(for: single) == "Delete 1 Photo")
    }

    @Test func exactSizeWordingStatesTheMeasuredTotal() {
        let message = DeletionPresentation.sizeMessage(for: exactPlan)
        #expect(message.contains("measured total"))
        #expect(!message.contains("At least"))
        #expect(!message.contains("unavailable"))
    }

    @Test func partialSizeWordingIsALowerBoundNeverAPromise() {
        let message = DeletionPresentation.sizeMessage(for: partialPlan)
        #expect(message.hasPrefix("At least "))
        #expect(message.contains("2 sizes unavailable"))
        #expect(!message.contains("measured total"))
    }

    @Test func fullyUnresolvedSizeNeverDisplaysAsZero() {
        let unresolved = DeletionPlan(
            schemaVersion: DeletionPlan.currentVersion,
            items: [
                DeletionPlanItem(localIdentifier: "a", mediaType: .image, sizeInBytes: nil, category: nil),
                DeletionPlanItem(localIdentifier: "b", mediaType: .image, sizeInBytes: nil, category: nil)
            ],
            authorization: .authorized,
            sessionToken: "s",
            analysisSignature: "sig"
        )
        let message = DeletionPresentation.sizeMessage(for: unresolved)
        #expect(message.contains("unavailable"))
        #expect(!message.contains("0 GB"))
        #expect(!message.hasPrefix("At least"))
    }

    @Test func categorySummaryAddsUpToThePlanCount() {
        let summary = DeletionPresentation.categorySummary(for: partialPlan)
        #expect(summary.contains("1 exact duplicate"))
        #expect(summary.contains("1 video"))

        let all = DeletionPresentation.categorySummary(for: exactPlan)
        #expect(all == "2 exact duplicates")
    }

    @Test func staleMessageCallsOutMissingAssets() {
        let plain = DeletionPresentation.staleMessage([.selectionChanged])
        #expect(!plain.isEmpty)
        #expect(!plain.contains("no longer available"))

        let missing = DeletionPresentation.staleMessage([.assetsMissing(["a"])])
        #expect(missing.contains("no longer available"))
    }

    @Test func successWordingPointsAtRecentlyDeletedAndNeverPromisesSpace() {
        let success = DeletionSuccess(plannedCount: 3, verifiedRemovedCount: 3, remainingIDs: [])
        #expect(DeletionPresentation.successMessage(for: success) == "3 photos were moved to Recently Deleted.")

        let one = DeletionSuccess(plannedCount: 1, verifiedRemovedCount: 1, remainingIDs: [])
        #expect(DeletionPresentation.successMessage(for: one) == "1 photo was moved to Recently Deleted.")

        #expect(DeletionPresentation.storageCaveat.contains("may not change right away"))
        #expect(!DeletionPresentation.storageCaveat.contains("will be freed"))
    }

    @Test func partialSuccessWordingNamesWhatRemains() {
        let partial = DeletionSuccess(plannedCount: 5, verifiedRemovedCount: 3, remainingIDs: ["a", "b"])
        let message = DeletionPresentation.partialMessage(for: partial)
        #expect(message.contains("3 of 5"))
        #expect(message.contains("2 photos are still in your library"))
    }

    @Test func permissionMessagesCoverEveryStateWithNoRawErrorText() {
        for state in [PermissionState.notDetermined, .authorized, .limited, .denied, .restricted] {
            let message = DeletionPresentation.permissionMessage(for: state)
            #expect(!message.isEmpty)
            #expect(!message.contains("NSError"))
            #expect(!message.contains("Error("))
        }
    }

    @Test func mutationFailureTextNeverReachesTheUser() {
        let outcome = DeletionOutcome.mutationFailed("PHPhotosErrorDomain Code=-1 raw dump")
        let message = DeletionPresentation.userFacingFailure(for: outcome)
        #expect(!message.contains("PHPhotosErrorDomain"))
        #expect(!message.contains("raw dump"))
        #expect(!message.isEmpty)

        let verification = DeletionOutcome.verificationFailed("could not verify")
        #expect(DeletionPresentation.userFacingFailure(for: verification) == "could not verify")
    }
}

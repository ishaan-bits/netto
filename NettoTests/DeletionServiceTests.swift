import Foundation
import Testing
@testable import Netto

// MARK: - Service: validation → mutation → verification

struct DeletionServiceTests {
    // MARK: Happy path

    @Test func executesExactlyThePlanIdentifiersInDeterministicOrder() async {
        let backing = FakeBacking(present: ["a", "b", "c", "other"])
        let service = PhotoDeletionService(backing: backing)
        let plan = makePlan(ids: ["b", "a", "c"])

        let outcome = await service.execute(
            try! plan.confirmed(),
            in: context(selectionIDs: ["a", "b", "c"])
        )

        guard case .succeeded(let success) = outcome else {
            Issue.record("expected succeeded, got \(outcome)")
            return
        }
        #expect(success.plannedCount == 3)
        #expect(success.verifiedRemovedCount == 3)
        #expect(success.remainingIDs.isEmpty)
        #expect(backing.deleteCalls == [["a", "b", "c"]])
        #expect(backing.deleteCalls.first?.contains("other") != true)
    }

    @Test func freshAuthorizationIsReadOnEveryExecution() async {
        let backing = FakeBacking(present: ["a"])
        let service = PhotoDeletionService(backing: backing)

        _ = await service.execute(try! makePlan(ids: ["a"]).confirmed(), in: context(selectionIDs: ["a"]))
        _ = await service.execute(try! makePlan(ids: ["a"]).confirmed(), in: context(selectionIDs: ["a"]))

        #expect(backing.authReadCount == 2)
    }

    // MARK: Refusals with zero mutation

    @Test func emptyPlanIsRejectedWithoutTouchingPhotos() async {
        let backing = FakeBacking(present: ["a"])
        let service = PhotoDeletionService(backing: backing)
        let empty = DeletionPlan(
            schemaVersion: DeletionPlan.currentVersion,
            items: [],
            authorization: .authorized,
            sessionToken: "session-1",
            analysisSignature: "sig-1"
        )

        let outcome = await service.execute(
            ConfirmedDeletionPlan(plan: empty),
            in: context(selectionIDs: [])
        )

        #expect(outcome == .rejected(.emptyPlan))
        #expect(backing.deleteCalls.isEmpty)
        #expect(backing.fetchCount == 0)
    }

    @Test func freshDeniedAuthorizationStopsBeforeAnythingElse() async {
        let backing = FakeBacking(present: ["a"], authorization: .denied)
        let service = PhotoDeletionService(backing: backing)

        let outcome = await service.execute(
            try! makePlan(ids: ["a"]).confirmed(),
            in: context(selectionIDs: ["a"])
        )

        #expect(outcome == .permissionDenied(.denied))
        #expect(backing.deleteCalls.isEmpty)
        #expect(backing.fetchCount == 0)
        #expect(backing.authReadCount == 1)
    }

    @Test func planFromAnotherAuthorizationStateCannotExecuteEvenWhenStillUsable() async {
        // Plan created under .authorized; fresh status is .limited (usable) — not the same
        // authorization, so the plan is stale and nothing is mutated.
        let backing = FakeBacking(present: ["a"], authorization: .limited)
        let service = PhotoDeletionService(backing: backing)
        let plan = makePlan(ids: ["a"], authorization: .authorized)

        let outcome = await service.execute(try! plan.confirmed(), in: context(selectionIDs: ["a"]))

        guard case .stale(let reasons) = outcome else {
            Issue.record("expected stale, got \(outcome)")
            return
        }
        #expect(reasons == [.authorizationChanged(from: .authorized, to: .limited)])
        #expect(backing.deleteCalls.isEmpty)
    }

    @Test func degradedAuthorizationCannotExecuteThePlan() async {
        let backing = FakeBacking(present: ["a"], authorization: .notDetermined)
        let service = PhotoDeletionService(backing: backing)
        let plan = makePlan(ids: ["a"], authorization: .authorized)

        let outcome = await service.execute(try! plan.confirmed(), in: context(selectionIDs: ["a"]))

        #expect(outcome == .permissionDenied(.notDetermined))
        #expect(backing.deleteCalls.isEmpty)
    }

    @Test func selectionDriftBlocksExecution() async {
        let backing = FakeBacking(present: ["a", "b"])
        let service = PhotoDeletionService(backing: backing)

        let outcome = await service.execute(
            try! makePlan(ids: ["a"]).confirmed(),
            in: context(selectionIDs: ["a", "b"])
        )

        #expect(outcome == .stale([.selectionChanged]))
        #expect(backing.deleteCalls.isEmpty)
        #expect(backing.fetchCount == 0)
    }

    @Test func differentSessionBlocksExecution() async {
        let backing = FakeBacking(present: ["a"])
        let service = PhotoDeletionService(backing: backing)

        let outcome = await service.execute(
            try! makePlan(ids: ["a"]).confirmed(),
            in: PlanExecutionContext(
                selectionIDs: ["a"],
                sessionToken: "another-session",
                analysisSignature: "sig-1"
            )
        )

        #expect(outcome == .stale([.sessionChanged]))
        #expect(backing.deleteCalls.isEmpty)
    }

    @Test func vanishedAssetInvalidatesTheWholePlanNeverASubset() async {
        // "b" was deleted externally between review and execution.
        let backing = FakeBacking(present: ["a"])
        let service = PhotoDeletionService(backing: backing)

        let outcome = await service.execute(
            try! makePlan(ids: ["a", "b"]).confirmed(),
            in: context(selectionIDs: ["a", "b"])
        )

        guard case .stale(let reasons) = outcome else {
            Issue.record("expected stale, got \(outcome)")
            return
        }
        #expect(reasons == [.assetsMissing(["b"])])
        #expect(backing.deleteCalls.isEmpty)
    }

    @Test func preMutationRevalidationFailureMutatesNothing() async {
        let backing = FakeBacking(present: ["a"], fetchError: FakeError.boom)
        let service = PhotoDeletionService(backing: backing)

        let outcome = await service.execute(try! makePlan(ids: ["a"]).confirmed(), in: context(selectionIDs: ["a"]))

        guard case .revalidationFailed = outcome else {
            Issue.record("expected revalidationFailed, got \(outcome)")
            return
        }
        #expect(backing.deleteCalls.isEmpty)
    }

    // MARK: Mutation outcomes

    @Test func mutationErrorPropagatesWithItsLocalizedDescription() async {
        let backing = FakeBacking(
            present: ["a"],
            deleteError: NSError(
                domain: "PHPhotosErrorDomain",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "kaboom"]
            )
        )
        let service = PhotoDeletionService(backing: backing)

        let outcome = await service.execute(try! makePlan(ids: ["a"]).confirmed(), in: context(selectionIDs: ["a"]))

        #expect(outcome == .mutationFailed("kaboom"))
        #expect(backing.deleteCalls.count == 1)
    }

    @Test func cancellationDuringMutationReportsCancelledNotFailure() async {
        let backing = FakeBacking(present: ["a"], deleteError: CancellationError())
        let service = PhotoDeletionService(backing: backing)

        let outcome = await service.execute(try! makePlan(ids: ["a"]).confirmed(), in: context(selectionIDs: ["a"]))

        #expect(outcome == .cancelled)
    }

    @Test func allRemovedVerifiesAsFullSuccess() async {
        let backing = FakeBacking(present: ["a", "b"])
        let service = PhotoDeletionService(backing: backing)

        let outcome = await service.execute(
            try! makePlan(ids: ["a", "b"]).confirmed(),
            in: context(selectionIDs: ["a", "b"])
        )

        guard case .succeeded(let success) = outcome else {
            Issue.record("expected succeeded, got \(outcome)")
            return
        }
        #expect(success.isFullyRemoved)
        #expect(!success.isPartial)
        #expect(success.verifiedRemovedCount == 2)
    }

    @Test func partiallyRemovedAssetsReportPartialSuccessNeverFull() async {
        // Deletion removes only "a" — "b" survives (e.g., an external change mid-flight).
        let backing = FakeBacking(present: ["a", "b"], deleting: ["a"])
        let service = PhotoDeletionService(backing: backing)

        let outcome = await service.execute(
            try! makePlan(ids: ["a", "b"]).confirmed(),
            in: context(selectionIDs: ["a", "b"])
        )

        guard case .succeeded(let success) = outcome else {
            Issue.record("expected succeeded, got \(outcome)")
            return
        }
        #expect(success.isPartial)
        #expect(success.verifiedRemovedCount == 1)
        #expect(success.remainingIDs == ["b"])
    }

    @Test func postMutationVerificationFailureNeverClaimsSuccess() async {
        let backing = FakeBacking(
            present: ["a"],
            fetchErrorAfterMutation: FakeError.boom
        )
        let service = PhotoDeletionService(backing: backing)

        let outcome = await service.execute(try! makePlan(ids: ["a"]).confirmed(), in: context(selectionIDs: ["a"]))

        guard case .verificationFailed(let message) = outcome else {
            Issue.record("expected verificationFailed, got \(outcome)")
            return
        }
        #expect(!message.isEmpty)
        #expect(message.contains("could not be verified"))
        if case .succeeded = outcome {
            Issue.record("verification failure must never be reported as success")
        }
    }

    // MARK: Fixtures

    private func makePlan(
        ids: [String],
        authorization: PermissionState = .authorized
    ) -> DeletionPlan {
        DeletionPlan(
            schemaVersion: DeletionPlan.currentVersion,
            items: ids.sorted().map {
                DeletionPlanItem(localIdentifier: $0, mediaType: .image, sizeInBytes: 1, category: nil)
            },
            authorization: authorization,
            sessionToken: "session-1",
            analysisSignature: "sig-1"
        )
    }

    private func context(
        selectionIDs: Set<String>
    ) -> PlanExecutionContext {
        PlanExecutionContext(
            selectionIDs: selectionIDs,
            sessionToken: "session-1",
            analysisSignature: "sig-1"
        )
    }
}

// MARK: - Recording fake backing

private enum FakeError: Error {
    case boom
}

/// Lock-guarded: the service calls it from async contexts, tests read it from theirs.
/// Never touches a real photo library — unit tests must not mutate Photos.
private final class FakeBacking: PhotoMutationBacking, @unchecked Sendable {
    private let lock = NSLock()
    private var authorization: PermissionState
    private var present: Set<String>
    private let deletingSubset: Set<String>?
    private let fetchError: Error?
    private let fetchErrorAfterMutation: Error?
    private let deleteError: Error?

    private var authReads = 0
    private var fetches = 0
    private var deletions: [[String]] = []

    init(
        present: Set<String>,
        authorization: PermissionState = .authorized,
        deleting subset: Set<String>? = nil,
        fetchError: Error? = nil,
        fetchErrorAfterMutation: Error? = nil,
        deleteError: Error? = nil
    ) {
        self.present = present
        self.authorization = authorization
        self.deletingSubset = subset
        self.fetchError = fetchError
        self.fetchErrorAfterMutation = fetchErrorAfterMutation
        self.deleteError = deleteError
    }

    func currentAuthorization() -> PermissionState {
        lock.lock()
        defer { lock.unlock() }
        authReads += 1
        return authorization
    }

    func existingIdentifiers(_ localIdentifiers: [String]) async throws -> Set<String> {
        try fetchIdentifiers(localIdentifiers)
    }

    func deleteAssets(localIdentifiers: [String]) async throws {
        try performDelete(localIdentifiers)
    }

    // Synchronous halves: `NSLock` is unavailable in async contexts, so all locking happens
    // here and the async protocol methods are thin await-free adapters.
    private func fetchIdentifiers(_ localIdentifiers: [String]) throws -> Set<String> {
        lock.lock()
        fetches += 1
        let isFirstFetch = fetches == 1
        let preError = fetchError
        let postError = fetchErrorAfterMutation
        let snapshot = present
        lock.unlock()

        if isFirstFetch, let preError { throw preError }
        if !isFirstFetch, let postError { throw postError }
        return snapshot.intersection(localIdentifiers)
    }

    private func performDelete(_ localIdentifiers: [String]) throws {
        lock.lock()
        deletions.append(localIdentifiers)
        let error = deleteError
        let subset = deletingSubset
        if error == nil {
            if let subset {
                present.subtract(subset)
            } else {
                present.subtract(localIdentifiers)
            }
        }
        lock.unlock()

        if let error { throw error }
    }

    var authReadCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return authReads
    }

    var fetchCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return fetches
    }

    var deleteCalls: [[String]] {
        lock.lock()
        defer { lock.unlock() }
        return deletions
    }
}

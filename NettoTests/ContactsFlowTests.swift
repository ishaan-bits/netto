import Foundation
import Testing
@testable import Netto

// MARK: Orchestration: scan → selection → plan → confirmation → outcome → reset

@MainActor
struct ContactsFlowTests {
    // MARK: Scan

    @Test func scanReadsTheFixtureSetAndComputesItsFourGroups() async {
        let (env, _) = makeEnv()

        env.startContactScan()
        let state = await waitForScan(env)

        guard case .completed(let dataset) = state else {
            Issue.record("expected completed, got \(state)")
            return
        }
        #expect(dataset.records.count == ContactFixture.records.count)
        #expect(dataset.groups.count == ContactFixture.expectedGroupCount)

        let phase = ContactsPresentation.phase(permission: .authorized, scan: state)
        guard case .results(let groups) = phase else {
            Issue.record("expected results phase, got \(phase)")
            return
        }
        #expect(groups.count == ContactFixture.expectedGroupCount)
    }

    @Test func cancelledScanStaysCancelledAndNeverFlipsBackToCompleted() async {
        let (env, _) = makeEnv()

        env.startContactScan()
        env.cancelContactScan()
        #expect(env.contactScanState == .cancelled)

        // A late completion from the cancelled run must be discarded by the generation guard.
        try? await Task.sleep(for: .milliseconds(150))
        #expect(env.contactScanState == .cancelled)
    }

    @Test func startIfNeededRunsOnceAndNeedsAFreshScanAfterCancellation() async {
        let (env, _) = makeEnv()

        env.startContactScanIfNeeded()
        env.startContactScanIfNeeded() // running → no second scan, no state churn
        let first = await waitForScan(env)
        guard case .completed = first else {
            Issue.record("expected completed, got \(first)")
            return
        }

        env.startContactScanIfNeeded() // completed → untouched
        #expect(env.contactScanState == first)

        // Explicit rescan restarts a finished scan.
        env.startContactScan()
        #expect(env.contactScanState == .running)
        _ = await waitForScan(env)

        // After a cancellation mid-scan, the next "if needed" starts a fresh one.
        env.startContactScan()
        env.cancelContactScan()
        #expect(env.contactScanState == .cancelled)
        env.startContactScanIfNeeded()
        let restarted = await waitForScan(env)
        guard case .completed = restarted else {
            Issue.record("expected completed after restart, got \(restarted)")
            return
        }
    }

    @Test func scanIsRefusedWithoutUsablePermissionAndThePhaseSaysSo() {
        let (env, _) = makeEnv()
        env.contactsPermissionState = .denied

        env.startContactScan()
        #expect(env.contactScanState == .notStarted)

        let phase = ContactsPresentation.phase(
            permission: env.contactsPermissionState,
            scan: env.contactScanState
        )
        #expect(phase == .permissionDenied)
    }

    @Test func aFreshScanDropsTheOldSelectionAndAnyPreparedPlan() async {
        let (env, _) = makeEnv()
        await prepareDelete(in: env)
        guard case .readyForReview = env.contactActionState else {
            Issue.record("expected readyForReview, got \(env.contactActionState)")
            return
        }

        env.startContactScan()

        #expect(env.contactSelection.isEmpty)
        #expect(env.contactActionState == .noSelection)
        #expect(env.contactScanState == .running)
        _ = await waitForScan(env)
    }

    // MARK: Selection → plan

    @Test func openingAGroupBindsAnEmptySelectionAndPlanPreparationSnapshotsIt() async {
        let (env, _) = makeEnv()
        let group = await waitForFirstGroup(env)

        env.openContactGroup(group)
        #expect(env.contactSelection.isEmpty) // nothing pre-checked, no auto master
        #expect(env.contactSelection.groupID == group.id)
        #expect(env.contactSelection.datasetCount == group.memberCount)

        env.mutateContactSelection { selection in
            for member in group.memberIDs { selection.toggle(member) }
            selection.setDestination(group.memberIDs[0])
        }
        env.prepareContactAction(.merge)

        guard case .readyForReview(let plan) = env.contactActionState else {
            Issue.record("expected readyForReview, got \(env.contactActionState)")
            return
        }
        #expect(plan.selectionSnapshot == Set(group.memberIDs))
        #expect(plan.sessionToken == "session-1")
        #expect(!plan.datasetSignature.isEmpty)
        #expect(plan.datasetSignature == ContactDataset.signature(in: completedDataset(env)))
        if case .merge(let merge) = plan.kind {
            #expect(merge.destinationID == group.memberIDs[0])
            #expect(
                Set(merge.sourceIDs)
                    == Set(group.memberIDs).subtracting([group.memberIDs[0]])
            )
        } else {
            Issue.record("expected merge kind, got \(plan.kind)")
        }
    }

    @Test func mergePreparationRefusesOneContactOrMissingDestination() async {
        let (env, _) = makeEnv()
        let group = await waitForFirstGroup(env)

        env.openContactGroup(group)
        env.mutateContactSelection { $0.toggle(group.memberIDs[0]) }
        env.prepareContactAction(.merge)
        guard case .failed = env.contactActionState else {
            Issue.record("expected failed for a one-contact merge, got \(env.contactActionState)")
            return
        }

        // Two selected but no destination chosen.
        env.mutateContactSelection { $0.toggle(group.memberIDs[1]) }
        env.prepareContactAction(.merge)
        #expect(isFailed(env.contactActionState))
    }

    @Test func reviewingAForeignChoiceRebuildsThePlanNeverReusesTheOldOne() async {
        let (env, _) = makeEnv()
        await prepareDelete(in: env)
        #expect(isReadyForReview(env.contactActionState))

        // Make the selection merge-ready, then appear under the *merge* review.
        env.mutateContactSelection { selection in
            if let first = selection.selectedIDs.sorted().first {
                selection.setDestination(first)
            }
        }
        env.contactReviewDidAppear(.merge)

        guard case .readyForReview(let plan) = env.contactActionState else {
            Issue.record("expected a freshly prepared plan, got \(env.contactActionState)")
            return
        }
        // The prepared *delete* plan can never be presented under a merge review.
        guard case .merge = plan.kind else {
            Issue.record("delete plan reused under merge review: \(plan.kind)")
            return
        }
        #expect(plan.selectionSnapshot == env.contactSelection.selectedIDs)
    }

    @Test func aStaleSelectionPlanIsDroppedWhenTheSelectionChanges() async {
        let (env, _) = makeEnv()
        await prepareDelete(in: env)

        env.mutateContactSelection { selection in
            if let first = selection.selectedIDs.sorted().first { selection.toggle(first) }
        }

        guard case .planStale(let plan, let reasons) = env.contactActionState else {
            Issue.record("expected planStale, got \(env.contactActionState)")
            return
        }
        #expect(reasons == [.selectionChanged])
        #expect(!plan.isEmpty)
    }

    // MARK: Confirmation → mutation

    @Test func confirmingWithoutConfirmationNeverReachesTheMutationService() async {
        let (env, recorder) = makeEnv()
        await prepareDelete(in: env)

        await env.confirmContactAction() // no begin → guard refuses

        #expect(isReadyForReview(env.contactActionState))
        #expect(recorder.callCount == 0)
    }

    @Test func cancellingTheConfirmationLeavesThePlanAndSkipsMutation() async {
        let (env, recorder) = makeEnv()
        await prepareDelete(in: env)

        env.beginContactConfirmation()
        #expect(isAwaitingConfirmation(env.contactActionState))
        env.cancelContactConfirmation()
        #expect(isReadyForReview(env.contactActionState))

        await env.confirmContactAction() // no longer awaiting → refused

        #expect(isReadyForReview(env.contactActionState))
        #expect(recorder.callCount == 0)
    }

    @Test func aStalePlanNeverExecutesEvenIfConfirmationIsAttempted() async {
        let (env, recorder) = makeEnv()
        await prepareDelete(in: env)
        env.mutateContactSelection { selection in
            if let first = selection.selectedIDs.sorted().first { selection.toggle(first) }
        }
        guard case .planStale = env.contactActionState else {
            Issue.record("expected planStale, got \(env.contactActionState)")
            return
        }

        env.beginContactConfirmation() // refused outside readyForReview
        await env.confirmContactAction() // refused outside awaitingConfirmation

        #expect(recorder.callCount == 0)
    }

    @Test func confirmedDeleteRunsToVerifiedSuccessAndResetsContactsState() async {
        let (env, recorder) = makeEnv(outcome: .succeeded(ContactMutationSuccess(
            plannedCount: 2,
            verifiedRemovedCount: 2,
            remainingIDs: [],
            isMerge: false,
            destinationID: nil
        )))
        await prepareDelete(in: env)

        env.beginContactConfirmation()
        await env.confirmContactAction()

        guard case .succeeded = env.contactActionState else {
            Issue.record("expected succeeded, got \(env.contactActionState)")
            return
        }
        #expect(recorder.callCount == 1)
        // Contacts changed: selection gone, dataset dropped, a fresh scan is due.
        #expect(env.contactSelection.isEmpty)
        #expect(env.contactScanState == .notStarted)

        // And the new scan is allowed immediately (nothing is stuck in executing).
        env.startContactScanIfNeeded()
        #expect(env.contactScanState == .running)
        _ = await waitForScan(env)
    }

    @Test func partialRemovalIsReportedAsNeedsReviewNotSuccess() async {
        let (env, _) = makeEnv(outcome: .succeeded(ContactMutationSuccess(
            plannedCount: 2,
            verifiedRemovedCount: 1,
            remainingIDs: ["fixture-contact-02"],
            isMerge: false,
            destinationID: nil
        )))
        await prepareDelete(in: env)

        env.beginContactConfirmation()
        await env.confirmContactAction()

        guard case .needsReview(let success) = env.contactActionState else {
            Issue.record("expected needsReview, got \(env.contactActionState)")
            return
        }
        #expect(success.remainingIDs == ["fixture-contact-02"])
    }

    @Test func staleOutcomeKeepsThePlanStale() async {
        let (env, recorder) = makeEnv(outcome: .stale([.contactsChanged(["fixture-contact-01"])]))
        await prepareDelete(in: env)

        env.beginContactConfirmation()
        await env.confirmContactAction()

        guard case .planStale(let plan, let reasons) = env.contactActionState else {
            Issue.record("expected planStale, got \(env.contactActionState)")
            return
        }
        #expect(reasons == [.contactsChanged(["fixture-contact-01"])])
        #expect(!plan.isEmpty)
        #expect(recorder.callCount == 1) // reached the service; refused inside it
    }

    @Test func permissionDeniedOutcomeLandsInPermissionRequired() async {
        let (env, _) = makeEnv(outcome: .permissionDenied(.denied))
        await prepareDelete(in: env)

        env.beginContactConfirmation()
        await env.confirmContactAction()

        #expect(env.contactActionState == .permissionRequired(.denied))
    }

    @Test func storeFailureLandsInFailedWithActionableCopy() async {
        let (env, _) = makeEnv(outcome: .mutationFailed("underlying store error"))
        await prepareDelete(in: env)

        env.beginContactConfirmation()
        await env.confirmContactAction()

        guard case .failed(let message) = env.contactActionState else {
            Issue.record("expected failed, got \(env.contactActionState)")
            return
        }
        // The raw store error is never shown — only the structural message.
        #expect(message.contains("could not complete"))
        #expect(!message.contains("underlying store error"))
    }

    @Test func verificationFailureLandsInFailedWithItsOwnMessage() async {
        let (env, _) = makeEnv(outcome: .verificationFailed("The change was requested, but not confirmed."))
        await prepareDelete(in: env)

        env.beginContactConfirmation()
        await env.confirmContactAction()

        guard case .failed(let message) = env.contactActionState else {
            Issue.record("expected failed, got \(env.contactActionState)")
            return
        }
        #expect(message == "The change was requested, but not confirmed.")
    }

    @Test func dismissedResultsReturnToTheUniversalReset() {
        let states: [ContactActionState] = [
            .succeeded(ContactMutationSuccess(
                plannedCount: 1, verifiedRemovedCount: 1, remainingIDs: [],
                isMerge: false, destinationID: nil
            )),
            .needsReview(ContactMutationSuccess(
                plannedCount: 1, verifiedRemovedCount: 0, remainingIDs: ["x"],
                isMerge: false, destinationID: nil
            )),
            .failed("x"),
            .permissionRequired(.denied),
        ]
        for state in states {
            let (env, _) = makeEnv()
            env.contactActionState = state
            env.dismissContactActionResult()
            #expect(env.contactActionState == .noSelection)
        }
    }

    // MARK: Helpers

    private func makeEnv(
        records: [ContactRecord] = ContactFixture.records,
        outcome: ContactActionOutcome = .succeeded(ContactMutationSuccess(
            plannedCount: 2,
            verifiedRemovedCount: 2,
            remainingIDs: [],
            isMerge: false,
            destinationID: nil
        ))
    ) -> (env: AppEnvironment, recorder: RecordingContactMutationService) {
        let recorder = RecordingContactMutationService(outcome: outcome)
        let env = AppEnvironment(
            contactsPermission: FakeContactsPermission(.authorized),
            makeContactReader: { ArrayContactReader(records: records) },
            contactMutationService: recorder,
            sessionToken: "session-1"
        )
        env.contactsPermissionState = .authorized
        return (env, recorder)
    }

    private func waitForScan(
        _ env: AppEnvironment,
        timeoutMilliseconds: Int = 5_000
    ) async -> ContactScanState {
        let deadline = ContinuousClock.now.advanced(by: .milliseconds(timeoutMilliseconds))
        while env.contactScanState.isRunning, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        return env.contactScanState
    }

    private func waitForFirstGroup(_ env: AppEnvironment) async -> ContactDuplicateGroup {
        env.startContactScanIfNeeded()
        let state = await waitForScan(env)
        guard case .completed(let dataset) = state, let group = dataset.groups.first else {
            Issue.record("expected a completed dataset with groups, got \(state)")
            // Two placeholder members keep downstream indexing safe; the issue above fails the test.
            return ContactDuplicateGroup(
                id: "none", memberIDs: ["ghost-a", "ghost-b"], reasons: [.sharedPhone]
            )
        }
        return group
    }

    private func completedDataset(_ env: AppEnvironment) -> ContactDataset {
        guard case .completed(let dataset) = env.contactScanState else { return .empty }
        return dataset
    }

    /// Scan → open the first group → select every member → prepare a delete plan.
    private func prepareDelete(in env: AppEnvironment) async {
        let group = await waitForFirstGroup(env)
        env.openContactGroup(group)
        env.mutateContactSelection { selection in
            for member in group.memberIDs { selection.toggle(member) }
        }
        env.contactReviewDidAppear(.delete)
    }

    private func isReadyForReview(_ state: ContactActionState) -> Bool {
        if case .readyForReview = state { return true }
        return false
    }

    private func isAwaitingConfirmation(_ state: ContactActionState) -> Bool {
        if case .awaitingConfirmation = state { return true }
        return false
    }

    private func isFailed(_ state: ContactActionState) -> Bool {
        if case .failed = state { return true }
        return false
    }
}

// MARK: - Test doubles

private struct ArrayContactReader: ContactReading {
    let records: [ContactRecord]
    func readContacts() async throws -> [ContactRecord] { records }
}

private struct FakeContactsPermission: ContactsPermissionServicing {
    let state: PermissionState
    init(_ state: PermissionState) { self.state = state }
    func currentStatus() -> PermissionState { state }
    func requestAccess() async -> PermissionState { state }
}

final class RecordingContactMutationService: ContactMutating, @unchecked Sendable {
    private let lock = NSLock()
    private let outcome: ContactActionOutcome
    private var plans: [ContactActionPlan] = []

    init(outcome: ContactActionOutcome) {
        self.outcome = outcome
    }

    var callCount: Int {
        lock.lock(); defer { lock.unlock() }
        return plans.count
    }

    func execute(
        _ confirmed: ConfirmedContactActionPlan,
        in context: ContactPlanExecutionContext
    ) async -> ContactActionOutcome {
        record(confirmed.plan)
    }

    // Synchronous so `NSLock` (unavailable in async contexts) can be used safely.
    private func record(_ plan: ContactActionPlan) -> ContactActionOutcome {
        lock.lock()
        defer { lock.unlock() }
        plans.append(plan)
        return outcome
    }
}

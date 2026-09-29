import Foundation
import Testing
@testable import Netto

// MARK: Service: structural guard → fresh auth → staleness → revalidation → mutation → verify

struct ContactMutationServiceTests {
    // MARK: Happy paths

    @Test func deleteExecutesExactlyThePlanIdentifiersAndVerifiesThemGone() async {
        let backing = FakeContactBacking(records: [
            makeRecord("a"), makeRecord("b"), makeRecord("other"),
        ])
        let service = ContactMutationService(backing: backing)

        let outcome = await service.execute(
            try! makeDeletePlan(ids: ["a", "b"]).confirmed(),
            in: context(selectionIDs: ["a", "b"])
        )

        guard case .succeeded(let success) = outcome else {
            Issue.record("expected succeeded, got \(outcome)")
            return
        }
        #expect(success.plannedCount == 2)
        #expect(success.verifiedRemovedCount == 2)
        #expect(success.remainingIDs.isEmpty)
        #expect(!success.isMerge)
        #expect(backing.applyCount == 1)
        #expect(backing.storedIDs == ["other"])
    }

    @Test func mergeUpdatesTheDestinationWithTheReviewedDecisionsThenRemovesSources() async {
        let destination = ContactRecord(
            identifier: "dest",
            givenName: "Mara",
            familyName: "Voss",
            phoneNumbers: [.phone(label: "mobile", value: "+1 555 010 1234")]
        )
        let source = ContactRecord(
            identifier: "src",
            givenName: "Mara",
            familyName: "Voss",
            phoneNumbers: [.phone(label: "work", value: "+1 555 010 9999")],
            emailAddresses: [.email(label: "w", value: "mara@example.com")]
        )
        let backing = FakeContactBacking(records: [destination, source, makeRecord("other")])
        let service = ContactMutationService(backing: backing)
        let merge = ContactMergePlanner.decisions(destination: destination, sources: [source])

        let outcome = await service.execute(
            try! makeMergePlan(destination: destination, sources: [source], merge: merge).confirmed(),
            in: context(selectionIDs: ["dest", "src"])
        )

        guard case .succeeded(let success) = outcome else {
            Issue.record("expected succeeded, got \(outcome)")
            return
        }
        #expect(success.isMerge)
        #expect(success.destinationID == "dest")
        #expect(success.verifiedRemovedCount == 1)
        #expect(Set(backing.storedIDs) == ["dest", "other"])

        guard let stored = backing.record("dest") else {
            Issue.record("destination contact missing from the fake store")
            return
        }
        #expect(stored.phoneNumbers.map(\.value) == ["+1 555 010 1234", "+1 555 010 9999"])
        #expect(stored.emailAddresses.map(\.value) == ["mara@example.com"])
        #expect(stored.givenName == "Mara")
    }

    @Test func freshAuthorizationIsReadOnEveryExecution() async {
        let backing = FakeContactBacking(records: [makeRecord("a")])
        let service = ContactMutationService(backing: backing)

        _ = await service.execute(
            try! makeDeletePlan(ids: ["a"]).confirmed(),
            in: context(selectionIDs: ["a"])
        )
        // The record is gone now; the second run still reads authorization first, then
        // reports the contacts as missing — never a mutation over ghosts.
        let second = await service.execute(
            try! makeDeletePlan(ids: ["a"]).confirmed(),
            in: context(selectionIDs: ["a"])
        )

        #expect(backing.authReadCount == 2)
        guard case .stale(let reasons) = second else {
            Issue.record("expected stale, got \(second)")
            return
        }
        #expect(reasons == [.contactsMissing(["a"])])
    }

    // MARK: Refusals with zero mutation

    @Test func emptyPlanIsRejectedWithoutTouchingContacts() async {
        let backing = FakeContactBacking(records: [makeRecord("a")])
        let service = ContactMutationService(backing: backing)
        let empty = ContactActionPlan(
            schemaVersion: ContactActionPlan.currentVersion,
            items: [],
            kind: .delete,
            authorization: .authorized,
            sessionToken: "session-1",
            datasetSignature: "sig-1"
        )

        let outcome = await service.execute(
            ConfirmedContactActionPlan(plan: empty),
            in: context(selectionIDs: [])
        )

        #expect(outcome == .rejected(.emptyPlan))
        #expect(backing.applyCount == 0)
        #expect(backing.validationReadCount == 0)
    }

    @Test func structurallyInvalidMergeIsRejectedWithoutTouchingContacts() async {
        let backing = FakeContactBacking(records: [makeRecord("a")])
        let service = ContactMutationService(backing: backing)
        let plan = ContactActionPlan(
            schemaVersion: ContactActionPlan.currentVersion,
            items: [ContactPlanItem(record: makeRecord("a"))],
            kind: .merge(ContactMergePlan(
                destinationID: "a",
                sourceIDs: ["a"],
                appendedPhones: [],
                appendedEmails: [],
                retainedGivenName: "",
                retainedFamilyName: "",
                retainedOrganizationName: "",
                conflicts: []
            )),
            authorization: .authorized,
            sessionToken: "session-1",
            datasetSignature: "sig-1"
        )

        let outcome = await service.execute(
            ConfirmedContactActionPlan(plan: plan),
            in: context(selectionIDs: ["a"])
        )

        #expect(outcome == .rejected(.invalidMerge))
        #expect(backing.applyCount == 0)
        #expect(backing.validationReadCount == 0)
    }

    @Test func freshDeniedAuthorizationStopsBeforeAnythingElse() async {
        let backing = FakeContactBacking(records: [makeRecord("a")], authorization: .denied)
        let service = ContactMutationService(backing: backing)

        let outcome = await service.execute(
            try! makeDeletePlan(ids: ["a"]).confirmed(),
            in: context(selectionIDs: ["a"])
        )

        #expect(outcome == .permissionDenied(.denied))
        #expect(backing.applyCount == 0)
        #expect(backing.validationReadCount == 0)
        #expect(backing.authReadCount == 1)
    }

    @Test func planFromAnotherAuthorizationStateCannotExecuteEvenWhenStillUsable() async {
        // Plan created under .authorized; fresh status is .limited (usable) — not the same,
        // so the plan is stale rather than silently reinterpreted.
        let backing = FakeContactBacking(records: [makeRecord("a")], authorization: .limited)
        let service = ContactMutationService(backing: backing)

        let outcome = await service.execute(
            try! makeDeletePlan(ids: ["a"]).confirmed(),
            in: context(selectionIDs: ["a"])
        )

        guard case .stale(let reasons) = outcome else {
            Issue.record("expected stale, got \(outcome)")
            return
        }
        #expect(reasons == [.authorizationChanged(from: .authorized, to: .limited)])
        #expect(backing.applyCount == 0)
        #expect(backing.validationReadCount == 0)
    }

    @Test func contextDriftIsStaleBeforeAnyStoreRead() async {
        let backing = FakeContactBacking(records: [makeRecord("a")])
        let service = ContactMutationService(backing: backing)
        let plan = makeDeletePlan(ids: ["a"])

        let wrongSelection = await service.execute(
            try! plan.confirmed(),
            in: context(selectionIDs: ["b"])
        )
        let wrongSession = await service.execute(
            try! plan.confirmed(),
            in: ContactPlanExecutionContext(
                selectionIDs: ["a"], sessionToken: "other", datasetSignature: plan.datasetSignature
            )
        )
        let wrongDataset = await service.execute(
            try! plan.confirmed(),
            in: ContactPlanExecutionContext(
                selectionIDs: ["a"], sessionToken: plan.sessionToken, datasetSignature: "other"
            )
        )

        guard case .stale(let a) = wrongSelection, case .stale(let b) = wrongSession,
              case .stale(let c) = wrongDataset else {
            Issue.record("expected three stale outcomes")
            return
        }
        #expect(a == [.selectionChanged])
        #expect(b == [.sessionChanged])
        #expect(c == [.datasetChanged])
        #expect(backing.applyCount == 0)
        #expect(backing.validationReadCount == 0)
    }

    @Test func missingOrDriftedLiveContactsAreStaleNeverShrunk() async {
        // "a" is missing entirely; "b" exists but its fields drifted from the snapshot.
        let backing = FakeContactBacking(records: [
            ContactRecord(identifier: "b", givenName: "Benjamin"),
        ])
        let service = ContactMutationService(backing: backing)

        let outcome = await service.execute(
            try! makeDeletePlan(ids: ["a", "b"]).confirmed(),
            in: context(selectionIDs: ["a", "b"])
        )

        guard case .stale(let reasons) = outcome else {
            Issue.record("expected stale, got \(outcome)")
            return
        }
        #expect(reasons == [
            .contactsMissing(["a"]),
            .contactsChanged(["b"]),
        ])
        #expect(backing.applyCount == 0)
        #expect(backing.validationReadCount == 1)
    }

    @Test func failedRevalidationReportsNothingWasChanged() async {
        let backing = FakeContactBacking(records: [makeRecord("a")])
        backing.revalidationError = ContactReadError.failed("boom")
        let service = ContactMutationService(backing: backing)

        let outcome = await service.execute(
            try! makeDeletePlan(ids: ["a"]).confirmed(),
            in: context(selectionIDs: ["a"])
        )

        guard case .revalidationFailed = outcome else {
            Issue.record("expected revalidationFailed, got \(outcome)")
            return
        }
        #expect(backing.applyCount == 0)
        #expect(backing.storedIDs == ["a"])
    }

    @Test func storeFailureIsReportedAsMutationFailedWithZeroChange() async {
        let backing = FakeContactBacking(records: [makeRecord("a")])
        backing.applyError = ContactMutationError.destinationMissing
        let service = ContactMutationService(backing: backing)

        let outcome = await service.execute(
            try! makeDeletePlan(ids: ["a"]).confirmed(),
            in: context(selectionIDs: ["a"])
        )

        guard case .mutationFailed = outcome else {
            Issue.record("expected mutationFailed, got \(outcome)")
            return
        }
        #expect(backing.applyCount == 1)
        #expect(backing.storedIDs == ["a"]) // the failed save changed nothing
    }

    // MARK: Post-mutation verification (never trusting the request alone)

    @Test func aSilentlyUnappliedDeleteIsReportedPartialNotSuccess() async {
        let backing = FakeContactBacking(records: [makeRecord("a"), makeRecord("b")])
        backing.skipApply = true // save "succeeds" but the store is untouched
        let service = ContactMutationService(backing: backing)

        let outcome = await service.execute(
            try! makeDeletePlan(ids: ["a", "b"]).confirmed(),
            in: context(selectionIDs: ["a", "b"])
        )

        guard case .succeeded(let success) = outcome else {
            Issue.record("expected succeeded, got \(outcome)")
            return
        }
        #expect(success.verifiedRemovedCount == 0)
        #expect(success.remainingIDs.sorted() == ["a", "b"])
        #expect(success.isPartial)
    }

    @Test func mergeVerificationFailsWhenAnAppendedValueIsAbsent() async {
        let destination = ContactRecord(identifier: "dest", givenName: "D")
        let source = ContactRecord(
            identifier: "src",
            givenName: "S",
            phoneNumbers: [.phone(label: "w", value: "+1 555 010 9999")]
        )
        let backing = FakeContactBacking(records: [destination, source])
        backing.dropAppendedValues = true // apply removes sources but loses the merge copy
        let service = ContactMutationService(backing: backing)
        let merge = ContactMergePlanner.decisions(destination: destination, sources: [source])

        let outcome = await service.execute(
            try! makeMergePlan(destination: destination, sources: [source], merge: merge).confirmed(),
            in: context(selectionIDs: ["dest", "src"])
        )

        guard case .verificationFailed = outcome else {
            Issue.record("expected verificationFailed, got \(outcome)")
            return
        }
    }

    @Test func mergeVerificationFailsWhenTheDestinationVanishes() async {
        let destination = ContactRecord(identifier: "dest", givenName: "D")
        let source = ContactRecord(identifier: "src", givenName: "S")
        let backing = FakeContactBacking(records: [destination, source])
        backing.dropDestination = true
        let service = ContactMutationService(backing: backing)
        let merge = ContactMergePlanner.decisions(destination: destination, sources: [source])

        let outcome = await service.execute(
            try! makeMergePlan(destination: destination, sources: [source], merge: merge).confirmed(),
            in: context(selectionIDs: ["dest", "src"])
        )

        guard case .verificationFailed = outcome else {
            Issue.record("expected verificationFailed, got \(outcome)")
            return
        }
    }

    @Test func verificationReadFailureDoesNotClaimSuccess() async {
        let backing = FakeContactBacking(records: [makeRecord("a")])
        backing.revalidationError = nil
        backing.verificationError = ContactReadError.failed("boom")
        let service = ContactMutationService(backing: backing)

        let outcome = await service.execute(
            try! makeDeletePlan(ids: ["a"]).confirmed(),
            in: context(selectionIDs: ["a"])
        )

        guard case .verificationFailed = outcome else {
            Issue.record("expected verificationFailed, got \(outcome)")
            return
        }
        #expect(backing.storedIDs.isEmpty) // the delete itself did apply
    }

    // MARK: Helpers

    private func context(
        selectionIDs: Set<String>,
        plan: ContactActionPlan? = nil
    ) -> ContactPlanExecutionContext {
        ContactPlanExecutionContext(
            selectionIDs: selectionIDs,
            sessionToken: plan?.sessionToken ?? "session-1",
            datasetSignature: plan?.datasetSignature ?? "sig-1"
        )
    }

    private func makeRecord(_ id: String) -> ContactRecord {
        ContactRecord(identifier: id, givenName: "Name" + id)
    }

    private func makeDeletePlan(ids: [String]) -> ContactActionPlan {
        let records = ids.sorted().map { ContactRecord(identifier: $0, givenName: "Name" + $0) }
        return ContactActionPlan(
            schemaVersion: ContactActionPlan.currentVersion,
            items: records.map(ContactPlanItem.init(record:)),
            kind: .delete,
            authorization: .authorized,
            sessionToken: "session-1",
            datasetSignature: "sig-1"
        )
    }

    private func makeMergePlan(
        destination: ContactRecord,
        sources: [ContactRecord],
        merge: ContactMergePlan
    ) -> ContactActionPlan {
        let records = ([destination] + sources).sorted { $0.identifier < $1.identifier }
        return ContactActionPlan(
            schemaVersion: ContactActionPlan.currentVersion,
            items: records.map(ContactPlanItem.init(record:)),
            kind: .merge(merge),
            authorization: .authorized,
            sessionToken: "session-1",
            datasetSignature: "sig-1"
        )
    }
}

// MARK: - Fake backing

/// In-memory stand-in for `CNContactStore`. Implements realistic store semantics (delete
/// removes, merge updates + removes) so verification can be exercised honestly, with
/// fault-injection knobs for silent no-ops and lost merge values. Never touches real Contacts.
private final class FakeContactBacking: ContactMutationBacking, @unchecked Sendable {
    private let lock = NSLock()
    private var records: [String: ContactRecord]
    private var authorization: PermissionState

    private(set) var authReadCount = 0
    private(set) var validationReadCount = 0
    private(set) var applyCount = 0

    var applyError: Error?
    var revalidationError: Error?
    var verificationError: Error?
    var skipApply = false
    var dropAppendedValues = false
    var dropDestination = false

    init(records: [ContactRecord], authorization: PermissionState = .authorized) {
        self.records = Dictionary(
            records.map { ($0.identifier, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        self.authorization = authorization
    }

    var storedIDs: [String] {
        lock.lock(); defer { lock.unlock() }
        return records.keys.sorted()
    }

    func record(_ id: String) -> ContactRecord? {
        lock.lock(); defer { lock.unlock() }
        return records[id]
    }

    func currentAuthorization() -> PermissionState {
        lock.lock(); defer { lock.unlock() }
        authReadCount += 1
        return authorization
    }

    func existingRecords(_ identifiers: [String]) async throws -> [ContactRecord] {
        try readLocked(identifiers)
    }

    func apply(_ request: ContactMutationRequest) async throws {
        try applyLocked(request)
    }

    // Synchronous helpers so `NSLock` (unavailable in async contexts) can be used safely.
    private func readLocked(_ identifiers: [String]) throws -> [ContactRecord] {
        lock.lock(); defer { lock.unlock() }
        // Exactly one read happens before apply (revalidation) and one after (verification).
        if applyCount == 0 {
            if let error = revalidationError { throw error }
        } else if let error = verificationError {
            throw error
        }
        validationReadCount += 1
        return identifiers.compactMap { records[$0] }
    }

    private func applyLocked(_ request: ContactMutationRequest) throws {
        lock.lock(); defer { lock.unlock() }
        applyCount += 1
        if let error = applyError { throw error }
        if skipApply { return }

        switch request {
        case .delete(let identifiers):
            for id in identifiers { records.removeValue(forKey: id) }

        case .merge(let destinationID, let sources, let decisions):
            guard var destination = records[destinationID] else {
                throw ContactMutationError.destinationMissing
            }
            if dropDestination {
                records.removeValue(forKey: destinationID)
                for id in sources { records.removeValue(forKey: id) }
                return
            }
            if !dropAppendedValues {
                destination = ContactRecord(
                    identifier: destination.identifier,
                    givenName: decisions.retainedGivenName,
                    familyName: decisions.retainedFamilyName,
                    organizationName: decisions.retainedOrganizationName,
                    phoneNumbers: destination.phoneNumbers
                        + decisions.appendedPhones.map { .phone(label: $0.label, value: $0.value) },
                    emailAddresses: destination.emailAddresses
                        + decisions.appendedEmails.map { .email(label: $0.label, value: $0.value) }
                )
                records[destinationID] = destination
            } else {
                // Sources die, the copied values are lost.
                for id in sources { records.removeValue(forKey: id) }
                return
            }
            for id in sources { records.removeValue(forKey: id) }
        }
    }
}

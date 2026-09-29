import Foundation
import Testing
@testable import Netto

// MARK: Plan construction, merge decisions, staleness, transitions

struct ContactActionPlanTests {
    // MARK: Merge decisions

    @Test func mergeUnionsPhonesAndEmailsAndNeverDuplicatesNormalizedValues() {
        let destination = ContactRecord(
            identifier: "dest",
            givenName: "Mara",
            familyName: "Voss",
            phoneNumbers: [.phone(label: "mobile", value: "+1 555 010 1234")],
            emailAddresses: [.email(label: "home", value: "mara@example.com")]
        )
        let sources = [
            ContactRecord(
                identifier: "src-b",
                givenName: "Mara",
                familyName: "Voss",
                phoneNumbers: [
                    .phone(label: "home", value: "(555) 010-1234"),
                    .phone(label: "work", value: "+1 555 010 9999"),
                ],
                emailAddresses: [
                    .email(label: "work", value: "Mara@Example.com"),
                    .email(label: "other", value: "mara.work@example.com"),
                ]
            ),
            ContactRecord(
                identifier: "src-a",
                givenName: "M.",
                familyName: "Voss",
                phoneNumbers: [.phone(label: "mobile", value: "15550109999")],
                emailAddresses: [.email(label: "w", value: "mara.work@example.com")]
            ),
        ]

        let merge = ContactMergePlanner.decisions(destination: destination, sources: sources)

        #expect(merge.destinationID == "dest")
        #expect(merge.sourceIDs == ["src-a", "src-b"])
        // Formatting variants the detector pairs on (shared match key) are not appended as
        // extra entries; only genuinely new values come along.
        #expect(merge.appendedPhones.map(\.value) == ["15550109999"])
        #expect(merge.appendedEmails.map(\.value) == ["mara.work@example.com"])
    }

    @Test func destinationValuesWinConflictsAndEveryConflictIsRecorded() {
        let destination = ContactRecord(
            identifier: "dest",
            givenName: "Mara",
            familyName: "Voss",
            organizationName: "Brightlabs"
        )
        let sources = [
            ContactRecord(
                identifier: "src",
                givenName: "M.",
                familyName: "Voss",
                organizationName: "OtherCo"
            ),
        ]

        let merge = ContactMergePlanner.decisions(destination: destination, sources: sources)

        #expect(merge.retainedGivenName == "Mara")
        #expect(merge.retainedFamilyName == "Voss")
        #expect(merge.retainedOrganizationName == "Brightlabs")
        #expect(merge.conflicts.count == 2)
        #expect(merge.conflicts.contains {
            $0.field == .givenName && $0.kept == "Mara" && $0.notCopied == "M."
        })
        #expect(merge.conflicts.contains {
            $0.field == .organizationName && $0.kept == "Brightlabs" && $0.notCopied == "OtherCo"
        })
    }

    @Test func emptyDestinationFieldsAreFilledFromTheFirstSourceThatHasOne() {
        let destination = ContactRecord(identifier: "dest")
        let sources = [
            ContactRecord(identifier: "src-b", givenName: "Second", familyName: ""),
            ContactRecord(identifier: "src-a", givenName: "First", familyName: "Last"),
        ]

        let merge = ContactMergePlanner.decisions(destination: destination, sources: sources)

        // Deterministic order: src-a before src-b.
        #expect(merge.retainedGivenName == "First")
        #expect(merge.retainedFamilyName == "Last")
        #expect(merge.conflicts == [
            ContactMergeConflict(field: .givenName, kept: "First", notCopied: "Second"),
        ])
    }

    // MARK: Plan structure and identity

    @Test func planItemsSnapshotEveryGroupingRelevantField() {
        let record = ContactRecord(
            identifier: "c1",
            givenName: "Mara",
            familyName: "Voss",
            organizationName: "Brightlabs",
            phoneNumbers: [.phone(label: "m", value: "123")],
            emailAddresses: [.email(label: "h", value: "a@example.com")]
        )
        let item = ContactPlanItem(record: record)

        #expect(item.identifier == "c1")
        #expect(item.displayName == "Mara Voss")
        #expect(item.organizationName == "Brightlabs")
        #expect(item.phoneCount == 1)
        #expect(item.emailCount == 1)
        #expect(item.identitySignature == ContactDigest.hex(record.canonicalFields))

        let changed = ContactRecord(
            identifier: "c1",
            givenName: "Mara",
            familyName: "Voss",
            organizationName: "Brightlabs",
            phoneNumbers: [.phone(label: "m", value: "124")],
            emailAddresses: [.email(label: "h", value: "a@example.com")]
        )
        #expect(ContactDigest.hex(changed.canonicalFields) != item.identitySignature)
    }

    @Test func identicalInputsProduceIdenticalPlanIdentity() {
        let planA = makeDeletePlan(ids: ["b", "a"])
        let planB = makeDeletePlan(ids: ["a", "b"])
        #expect(planA == planB)
        #expect(planA.identity == planB.identity)
        #expect(makeDeletePlan(ids: ["a", "b", "c"]).identity != planA.identity)
    }

    @Test func confirmationBoundaryRejectsStructurallyInvalidPlans() throws {
        #expect(throws: ContactPlanRejection.self) {
            try makeDeletePlan(ids: []).confirmed()
        }

        let invalidMerge = ContactActionPlan(
            schemaVersion: ContactActionPlan.currentVersion,
            items: [ContactPlanItem(record: ContactRecord(identifier: "dest"))],
            kind: .merge(ContactMergePlan(
                destinationID: "dest",
                sourceIDs: ["dest"],
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
        #expect(throws: ContactPlanRejection.self) {
            try invalidMerge.confirmed()
        }

        let valid = makeDeletePlan(ids: ["a", "b"])
        let confirmed = try valid.confirmed()
        #expect(confirmed.plan == valid)
    }

    // MARK: Staleness

    @Test func stalenessReasonsAreOrderedSessionDatasetSelectionAuthorization() {
        let plan = makeDeletePlan(ids: ["a", "b"])

        let reasons = ContactPlanValidator.stalenessReasons(
            plan: plan,
            context: ContactPlanExecutionContext(
                selectionIDs: ["a", "c"],
                sessionToken: "other-session",
                datasetSignature: "other-signature"
            ),
            freshAuthorization: .denied
        )
        #expect(reasons == [
            .sessionChanged,
            .datasetChanged,
            .selectionChanged,
            .authorizationChanged(from: .authorized, to: .denied),
        ])
    }

    @Test func matchingContextProducesNoStalenessReasons() {
        let plan = makeDeletePlan(ids: ["a", "b"])
        let reasons = ContactPlanValidator.stalenessReasons(
            plan: plan,
            context: ContactPlanExecutionContext(
                selectionIDs: ["a", "b"],
                sessionToken: plan.sessionToken,
                datasetSignature: plan.datasetSignature
            ),
            freshAuthorization: plan.authorization
        )
        #expect(reasons.isEmpty)
    }

    @Test func contactDriftReportsMissingAndChangedDeterministically() {
        let a = ContactRecord(identifier: "a", givenName: "Ana")
        let b = ContactRecord(identifier: "b", givenName: "Ben")
        let plan = ContactActionPlan(
            schemaVersion: ContactActionPlan.currentVersion,
            items: [ContactPlanItem(record: a), ContactPlanItem(record: b)],
            kind: .delete,
            authorization: .authorized,
            sessionToken: "s",
            datasetSignature: "sig"
        )
        let drifted = ContactRecord(identifier: "b", givenName: "Benjamin")

        let reasons = ContactPlanValidator.contactDriftReasons(
            plan: plan,
            liveRecords: [drifted]
        )
        #expect(reasons == [
            .contactsMissing(["a"]),
            .contactsChanged(["b"]),
        ])

        #expect(ContactPlanValidator.contactDriftReasons(plan: plan, liveRecords: [a, b]).isEmpty)
    }

    // MARK: State machine transitions

    @Test func legalTransitionsFollowTheTableExactly() {
        let plan = makeDeletePlan(ids: ["a"])
        let stale = ContactActionState.planStale(plan, [.selectionChanged])
        let success = ContactMutationSuccess(
            plannedCount: 1,
            verifiedRemovedCount: 1,
            remainingIDs: [],
            isMerge: false,
            destinationID: nil
        )

        let pairs: [(ContactActionState, ContactActionState)] = [
            (.noSelection, .preparingPlan),
            (.preparingPlan, .readyForReview(plan)),
            (.preparingPlan, .failed("x")),
            (.preparingPlan, stale),
            (.readyForReview(plan), .awaitingConfirmation(plan)),
            (.readyForReview(plan), stale),
            (.readyForReview(plan), .preparingPlan),
            (stale, .preparingPlan),
            (.awaitingConfirmation(plan), .executing(plan)),
            (.awaitingConfirmation(plan), .readyForReview(plan)),
            (.awaitingConfirmation(plan), stale),
            (.executing(plan), .succeeded(success)),
            (.executing(plan), .needsReview(success)),
            (.executing(plan), .failed("x")),
            (.executing(plan), stale),
            (.executing(plan), .permissionRequired(.denied)),
            (.executing(plan), .readyForReview(plan)),
            (.needsReview(success), .preparingPlan),
            (.failed("x"), .preparingPlan),
            (.permissionRequired(.denied), .preparingPlan),
        ]
        for (from, to) in pairs {
            #expect(
                ContactActionState.canTransition(from: from, to: to),
                "expected allowed: \(from) -> \(to)"
            )
        }
    }

    @Test func illegalTransitionsAreRefusedEspeciallyAnythingBypassingConfirmation() {
        let plan = makeDeletePlan(ids: ["a"])
        let stale = ContactActionState.planStale(plan, [.selectionChanged])
        let success = ContactMutationSuccess(
            plannedCount: 1,
            verifiedRemovedCount: 1,
            remainingIDs: [],
            isMerge: false,
            destinationID: nil
        )

        let pairs: [(ContactActionState, ContactActionState)] = [
            (.noSelection, .executing(plan)),
            (.noSelection, .awaitingConfirmation(plan)),
            (.readyForReview(plan), .executing(plan)),
            (.readyForReview(plan), .succeeded(success)),
            (stale, .executing(plan)),
            (stale, .awaitingConfirmation(plan)),
            (.awaitingConfirmation(plan), .succeeded(success)),
            (.succeeded(success), .executing(plan)),
            (.executing(plan), .awaitingConfirmation(plan)),
            (.failed("x"), .executing(plan)),
            (.preparingPlan, .executing(plan)),
        ]
        for (from, to) in pairs {
            #expect(
                !ContactActionState.canTransition(from: from, to: to),
                "expected refused: \(from) -> \(to)"
            )
        }
    }

    @Test func noSelectionIsAResetAndNeverAForwardPath() {
        let plan = makeDeletePlan(ids: ["a"])
        let forward: [ContactActionState] = [
            .readyForReview(plan),
            .awaitingConfirmation(plan),
            .executing(plan),
            .succeeded(ContactMutationSuccess(
                plannedCount: 1, verifiedRemovedCount: 1, remainingIDs: [],
                isMerge: false, destinationID: nil
            )),
            .failed("x"),
        ]
        for target in forward {
            #expect(
                !ContactActionState.canTransition(from: .noSelection, to: target),
                "noSelection must not reach \(target)"
            )
        }
        #expect(ContactActionState.canTransition(from: .noSelection, to: .noSelection))
        // Reaching a safe reset is allowed from every state — it removes capability.
        for from in [ContactActionState.preparingPlan, .executing(plan), .succeeded(
            ContactMutationSuccess(plannedCount: 1, verifiedRemovedCount: 1, remainingIDs: [],
                                    isMerge: false, destinationID: nil)
        )] {
            #expect(ContactActionState.canTransition(from: from, to: .noSelection))
        }
    }

    // MARK: Helpers

    private func makeDeletePlan(ids: [String]) -> ContactActionPlan {
        let records = ids.sorted().map { ContactRecord(identifier: $0, givenName: $0.uppercased()) }
        return ContactActionPlan(
            schemaVersion: ContactActionPlan.currentVersion,
            items: records.map(ContactPlanItem.init(record:)),
            kind: .delete,
            authorization: .authorized,
            sessionToken: "session-1",
            datasetSignature: "sig-1"
        )
    }
}

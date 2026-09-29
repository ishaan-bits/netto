import Foundation
import Contacts

/// The single seam over Contacts' mutation surface plus the store facts that must be read
/// **fresh, immediately before mutating**: current authorization and current contact state.
///
/// The live implementation (`ContactStoreMutationBacking`) is the only place in the app that
/// calls Contacts write APIs. Tests inject fakes; unit tests never touch a real contact store.
protocol ContactMutationBacking: Sendable {
    /// Always a live system read — never a previously captured authorization result.
    func currentAuthorization() -> PermissionState
    /// Which of the given identifiers currently resolve, with fresh field values — used for
    /// pre-mutation revalidation and post-mutation verification.
    func existingRecords(_ identifiers: [String]) async throws -> [ContactRecord]
    /// Performs the Contacts change for exactly the given request.
    func apply(_ request: ContactMutationRequest) async throws
}

/// What the backing is asked to do. Exactly what the confirmed plan describes — the backing
/// never computes a different set.
enum ContactMutationRequest: Sendable, Equatable {
    /// Remove exactly these identifiers.
    case delete(identifiers: [String])
    /// Apply the precomputed merge decisions to the destination, then remove the sources —
    /// in one atomic save request.
    case merge(destination: String, sources: [String], decisions: ContactMergePlan)
}

/// What the app layer may ask of the contacts boundary. The only accepted payload is a
/// `ConfirmedContactActionPlan` — raw identifiers from UI code have no path to Contacts writes.
protocol ContactMutating: Sendable {
    func execute(
        _ confirmed: ConfirmedContactActionPlan,
        in context: ContactPlanExecutionContext
    ) async -> ContactActionOutcome
}

/// The contacts mutation service: the sole orchestrator of Contacts mutation.
///
/// Every run goes through **one final pre-mutation path**, in this order, with no mutation
/// possible before it completes:
/// 1. structural guard (non-empty plan; a merge must be internally valid),
/// 2. **fresh** authorization read (a stale/earlier result is never reused),
/// 3. authorization-must-permit check (otherwise: permission error, zero mutations),
/// 4. pure plan-vs-context staleness validation (session, dataset, selection, authorization),
/// 5. re-fetch every planned contact; missing or field-drifted contacts → stale, never shrunk,
/// 6. only then: apply exactly the plan's request,
/// 7. post-mutation verification against the live store (deletions gone; for merge, the
///    destination present with every appended value).
struct ContactMutationService: ContactMutating {
    private let backing: any ContactMutationBacking

    init(backing: any ContactMutationBacking = ContactStoreMutationBacking()) {
        self.backing = backing
    }

    func execute(
        _ confirmed: ConfirmedContactActionPlan,
        in context: ContactPlanExecutionContext
    ) async -> ContactActionOutcome {
        let plan = confirmed.plan
        guard !plan.isEmpty else { return .rejected(.emptyPlan) }
        if case .merge(let merge) = plan.kind {
            let structurallyValid = !merge.sourceIDs.isEmpty
                && !merge.destinationID.isEmpty
                && !merge.sourceIDs.contains(merge.destinationID)
                && Set(merge.sourceIDs).count == merge.sourceIDs.count
            guard structurallyValid else { return .rejected(.invalidMerge) }
        }

        // ── Final pre-mutation path (fresh authorization + validation, same path) ──────────
        let freshAuthorization = backing.currentAuthorization()
        guard freshAuthorization.isUsable else {
            return .permissionDenied(freshAuthorization)
        }

        let contextReasons = ContactPlanValidator.stalenessReasons(
            plan: plan,
            context: context,
            freshAuthorization: freshAuthorization
        )
        guard contextReasons.isEmpty else { return .stale(contextReasons) }

        let planIdentifiers = plan.items.map(\.identifier)
        let liveBefore: [ContactRecord]
        do {
            liveBefore = try await backing.existingRecords(planIdentifiers)
        } catch {
            return .revalidationFailed(
                "Your contacts could not be rechecked, so nothing was changed."
            )
        }
        let driftReasons = ContactPlanValidator.contactDriftReasons(
            plan: plan,
            liveRecords: liveBefore
        )
        guard driftReasons.isEmpty else { return .stale(driftReasons) }
        // ── Validation complete: the live contacts are exactly the reviewed contacts. ──────

        let request: ContactMutationRequest
        switch plan.kind {
        case .delete:
            request = .delete(identifiers: planIdentifiers)
        case .merge(let merge):
            request = .merge(
                destination: merge.destinationID,
                sources: merge.sourceIDs,
                decisions: merge
            )
        }

        do {
            try await backing.apply(request)
        } catch is CancellationError {
            return .cancelled
        } catch {
            return .mutationFailed(error.localizedDescription)
        }

        // Verify against the store rather than trusting that the request "returning" means
        // the intended change actually happened.
        let liveAfter: [ContactRecord]
        do {
            liveAfter = try await backing.existingRecords(planIdentifiers)
        } catch {
            return .verificationFailed(
                "The change was requested, but the result could not be verified in Contacts. "
                    + "Check the Contacts app before trying again."
            )
        }
        return await Self.verify(
            plan: plan,
            liveAfter: liveAfter,
            verifyingWith: backing
        )
    }

    // MARK: Post-mutation verification

    /// Match keys for a phone value at verification time — identical to the merge planner's
    /// collapse keys, so "appended" means exactly what the plan meant.
    private static func phoneKeys(_ value: String) -> Set<String> {
        let keys = ContactNormalization.phoneMatchKeys(value)
        return keys.isEmpty ? ["raw:\(value)"] : keys
    }

    private static func emailKey(_ value: String) -> String {
        ContactNormalization.email(value) ?? "raw:\(value)"
    }

    private static func verify(
        plan: ContactActionPlan,
        liveAfter: [ContactRecord],
        verifyingWith backing: any ContactMutationBacking
    ) async -> ContactActionOutcome {
        let liveByID = Dictionary(
            liveAfter.map { ($0.identifier, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let removedIDs = plan.removedIdentifiers

        switch plan.kind {
        case .delete:
            let remaining = removedIDs.filter { liveByID[$0] != nil }
            return .succeeded(ContactMutationSuccess(
                plannedCount: removedIDs.count,
                verifiedRemovedCount: removedIDs.count - remaining.count,
                remainingIDs: remaining,
                isMerge: false,
                destinationID: nil
            ))

        case .merge(let merge):
            guard let destination = liveByID[merge.destinationID] else {
                return .verificationFailed(
                    "The merge was requested, but the destination contact could not be "
                        + "confirmed in Contacts. Check the Contacts app before trying again."
                )
            }
            var missingAppended: [String] = []
            for phone in merge.appendedPhones {
                let keys = Self.phoneKeys(phone.value)
                let present = destination.phoneNumbers.contains {
                    !keys.isDisjoint(with: Self.phoneKeys($0.value))
                }
                if !present { missingAppended.append(phone.value) }
            }
            for email in merge.appendedEmails {
                let key = Self.emailKey(email.value)
                let present = destination.emailAddresses.contains {
                    Self.emailKey($0.value) == key
                }
                if !present { missingAppended.append(email.value) }
            }
            guard missingAppended.isEmpty else {
                return .verificationFailed(
                    "The merge was requested, but some values could not be confirmed on the "
                        + "destination contact. Check the Contacts app before trying again."
                )
            }
            let remaining = merge.sourceIDs.filter { liveByID[$0] != nil }
            return .succeeded(ContactMutationSuccess(
                plannedCount: merge.sourceIDs.count,
                verifiedRemovedCount: merge.sourceIDs.count - remaining.count,
                remainingIDs: remaining,
                isMerge: true,
                destinationID: merge.destinationID
            ))
        }
    }
}

// MARK: - Live Contacts backing (the only Contacts mutation code in the app)

/// iOS 17 Contacts implementation.
///
/// - Authorization is read live on every call (`CNContactStore` status for `.contacts`).
/// - Existence/field revalidation fetches by exact identifier; an identifier that no longer
///   resolves is simply absent — never substituted — and a resolved contact whose fields no
///   longer match the plan's snapshot is caught by the service's identity-signature check.
/// - `execute(saveRequest:)` is atomic: either every add/update/delete in the request applies
///   or none does (a save request that fails leaves the store unchanged).
/// - Merge = update destination (appended phones/emails + retained name fields) **and**
///   delete the sources in one save request. There is no public iOS API for linking contacts
///   into one unified card, so Netto does not claim one: it reports exactly what it does —
///   combine unique values into the chosen contact, remove the duplicates.
///
/// This struct (plus DEBUG fixture seeding, which is simulator-only and documented in
/// `FixtureContacts`) is the only production code that executes `CNSaveRequest`.
struct ContactStoreMutationBacking: ContactMutationBacking {
    private let permission: any ContactsPermissionServicing

    init(permission: any ContactsPermissionServicing = ContactsPermissionService()) {
        self.permission = permission
    }

    func currentAuthorization() -> PermissionState {
        permission.currentStatus()
    }

    func existingRecords(_ identifiers: [String]) async throws -> [ContactRecord] {
        guard !identifiers.isEmpty else { return [] }
        let store = CNContactStore()
        let predicate = CNContact.predicateForContacts(withIdentifiers: identifiers)
        let contacts = try store.unifiedContacts(
            matching: predicate,
            keysToFetch: Self.readKeys()
        )
        return contacts.map(ContactStoreReader.record(from:))
    }

    func apply(_ request: ContactMutationRequest) async throws {
        let store = CNContactStore()
        let saveRequest = CNSaveRequest()

        switch request {
        case .delete(let identifiers):
            let targets = try fetchMutableContacts(identifiers: identifiers, from: store)
            for contact in targets {
                saveRequest.delete(contact)
            }

        case .merge(let destinationID, let sources, let decisions):
            let destination = try fetchMutableContacts(
                identifiers: [destinationID],
                from: store
            ).first
            guard let destination else {
                throw ContactMutationError.destinationMissing
            }
            let sourceContacts = try fetchMutableContacts(identifiers: sources, from: store)

            // Apply the precomputed decisions exactly as reviewed.
            for phone in decisions.appendedPhones {
                destination.phoneNumbers.append(CNLabeledValue(
                    label: phone.label.isEmpty ? nil : phone.label,
                    value: CNPhoneNumber(stringValue: phone.value)
                ))
            }
            for email in decisions.appendedEmails {
                destination.emailAddresses.append(CNLabeledValue(
                    label: email.label.isEmpty ? nil : email.label,
                    value: email.value as NSString
                ))
            }
            destination.givenName = decisions.retainedGivenName
            destination.familyName = decisions.retainedFamilyName
            destination.organizationName = decisions.retainedOrganizationName

            saveRequest.update(destination)
            for source in sourceContacts {
                saveRequest.delete(source)
            }
        }

        try store.execute(saveRequest)
    }

    /// Fetches the contacts for `identifiers` as mutable copies (required by `CNSaveRequest`).
    /// Missing identifiers are simply absent — the service's revalidation has already run, and
    /// a race is reported by the save request itself rather than by inventing a target.
    private func fetchMutableContacts(
        identifiers: [String],
        from store: CNContactStore
    ) throws -> [CNMutableContact] {
        guard !identifiers.isEmpty else { return [] }
        let predicate = CNContact.predicateForContacts(withIdentifiers: identifiers)
        let contacts = try store.unifiedContacts(matching: predicate, keysToFetch: Self.readKeys())
        return contacts.compactMap { $0.mutableCopy() as? CNMutableContact }
    }

    private static func readKeys() -> [CNKeyDescriptor] {
        [
            CNContactIdentifierKey,
            CNContactGivenNameKey,
            CNContactFamilyNameKey,
            CNContactOrganizationNameKey,
            CNContactPhoneNumbersKey,
            CNContactEmailAddressesKey,
        ] as [CNKeyDescriptor]
    }
}

/// Structural failure inside the live backing (mapped to an outcome, never shown raw).
enum ContactMutationError: Error, Sendable {
    case destinationMissing
}

import Foundation

// MARK: - Review items

/// One contact exactly as the final review shows it. Immutable; carries a field digest so the
/// mutation service can detect out-of-band changes to the very fields the plan was built on.
struct ContactPlanItem: Sendable, Hashable, Identifiable {
    let identifier: String
    let displayName: String
    let organizationName: String
    let phoneCount: Int
    let emailCount: Int
    /// Digest of this contact's grouping-relevant fields at plan time. If the live record no
    /// longer digests to this, the plan is stale — zero mutation, fresh review.
    let identitySignature: String

    var id: String { identifier }

    init(record: ContactRecord) {
        identifier = record.identifier
        displayName = record.displayName
        organizationName = record.organizationName
        phoneCount = record.phoneNumbers.count
        emailCount = record.emailAddresses.count
        identitySignature = ContactDigest.hex(record.canonicalFields)
    }
}

// MARK: - Merge semantics

/// One field value that will be copied from a source contact into the destination.
struct ContactMergeAppend: Sendable, Hashable, Identifiable {
    let label: String
    let value: String
    /// Normalization used to dedupe against the destination and other sources; `nil` for a
    /// value that cannot be normalized (still copied — never silently dropped).
    let normalized: String?

    var id: String { "\(label)|\(value)" }

    init(_ contactValue: ContactLabeledValue) {
        label = contactValue.label
        value = contactValue.value
        normalized = contactValue.normalized
    }
}

/// A name/organization value that exists (differently) on both sides and will **not** be
/// copied — recorded so the review screen can state exactly what is kept and what is not.
/// Nothing is ever discarded silently: every conflict is shown before confirmation.
struct ContactMergeConflict: Sendable, Hashable, Identifiable {
    enum Field: String, Sendable, CaseIterable {
        case givenName = "First name"
        case familyName = "Last name"
        case organizationName = "Organization"
    }

    let field: Field
    /// The destination's value, which is retained.
    let kept: String
    /// The source's differing value, which is not copied.
    let notCopied: String

    var id: String { "\(field.rawValue)|\(kept)|\(notCopied)" }
}

/// The exact, deterministic field decisions a merge applies. Computed once at plan time from
/// the reviewed snapshot; the mutation service refuses to run them if any involved contact's
/// fields have changed since (identity-signature check), so the decisions can never be applied
/// against drifted data.
struct ContactMergePlan: Sendable, Equatable {
    let destinationID: String
    /// Sorted source identifiers — the contacts that will be removed after their unique
    /// values are copied into the destination.
    let sourceIDs: [String]
    /// Phone values from sources not already present in the destination (deduped by
    /// normalized value, stable order: source id, then value order).
    let appendedPhones: [ContactMergeAppend]
    let appendedEmails: [ContactMergeAppend]
    /// The destination's post-merge name/organization. Destination values win conflicts;
    /// an empty destination field is filled from the first source that has one.
    let retainedGivenName: String
    let retainedFamilyName: String
    let retainedOrganizationName: String
    /// Every differing non-empty source value that is *not* copied (shown in review).
    let conflicts: [ContactMergeConflict]

    var removedCount: Int { sourceIDs.count }
}

/// Pure merge-decision computation — no I/O, fully testable.
///
/// Policy (documented, never silent):
/// - **Phones / emails**: union. Destination keeps every value it has; source values whose
///   match key is not already present are appended with their original labels. Collapse uses
///   the *same* keys detection groups on (for phones: any shared match key, so a
///   national-format variant the detector paired does not come back as a second entry on the
///   kept contact). Exact duplicates are dropped — that is the point of merging.
/// - **Names / organization**: the destination's non-empty value is *kept*; a differing
///   non-empty source value is recorded as a conflict and not copied (the review states this
///   before anything happens). An empty destination field is filled from the first source —
///   in sorted source order — that has one; further differing values become conflicts.
enum ContactMergePlanner {
    static func decisions(
        destination: ContactRecord,
        sources: [ContactRecord]
    ) -> ContactMergePlan {
        let orderedSources = sources.sorted { $0.identifier < $1.identifier }

        var seenPhoneKeys = Set<String>()
        for phone in destination.phoneNumbers {
            seenPhoneKeys.formUnion(phoneKeys(for: phone))
        }
        var appendedPhones: [ContactMergeAppend] = []

        var seenEmailKeys = Set<String>()
        for email in destination.emailAddresses {
            seenEmailKeys.insert(emailKey(for: email))
        }
        var appendedEmails: [ContactMergeAppend] = []

        for source in orderedSources {
            for phone in source.phoneNumbers {
                let keys = phoneKeys(for: phone)
                guard keys.isDisjoint(with: seenPhoneKeys) else { continue }
                seenPhoneKeys.formUnion(keys)
                appendedPhones.append(ContactMergeAppend(phone))
            }
            for email in source.emailAddresses {
                let key = emailKey(for: email)
                guard !seenEmailKeys.contains(key) else { continue }
                seenEmailKeys.insert(key)
                appendedEmails.append(ContactMergeAppend(email))
            }
        }

        var conflicts: [ContactMergeConflict] = []
        let given = resolveField(
            destinationValue: destination.givenName,
            sources: orderedSources.map(\.givenName),
            field: .givenName,
            into: &conflicts
        )
        let family = resolveField(
            destinationValue: destination.familyName,
            sources: orderedSources.map(\.familyName),
            field: .familyName,
            into: &conflicts
        )
        let organization = resolveField(
            destinationValue: destination.organizationName,
            sources: orderedSources.map(\.organizationName),
            field: .organizationName,
            into: &conflicts
        )

        return ContactMergePlan(
            destinationID: destination.identifier,
            sourceIDs: orderedSources.map(\.identifier),
            appendedPhones: appendedPhones,
            appendedEmails: appendedEmails,
            retainedGivenName: given,
            retainedFamilyName: family,
            retainedOrganizationName: organization,
            conflicts: conflicts
        )
    }

    /// Every match key for a phone value — the same keys detection grouped on, so merge
    /// collapse and detection agree. A value with no usable digits degenerates to its exact
    /// raw form (never invented into a digit key).
    private static func phoneKeys(for phone: ContactLabeledValue) -> Set<String> {
        let keys = ContactNormalization.phoneMatchKeys(phone.value)
        return keys.isEmpty ? ["raw:\(phone.value)"] : keys
    }

    private static func emailKey(for email: ContactLabeledValue) -> String {
        ContactNormalization.email(email.value) ?? "raw:\(email.value)"
    }

    private static func resolveField(
        destinationValue: String,
        sources: [String],
        field: ContactMergeConflict.Field,
        into conflicts: inout [ContactMergeConflict]
    ) -> String {
        let kept = destinationValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if kept.isEmpty {
            // Fill from the first source that has a value; later differing values conflict.
            var adopted = ""
            for raw in sources {
                let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !value.isEmpty else { continue }
                if adopted.isEmpty {
                    adopted = value
                } else if value != adopted {
                    conflicts.append(
                        ContactMergeConflict(field: field, kept: adopted, notCopied: value)
                    )
                }
            }
            return adopted
        }
        for raw in sources {
            let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty, value != kept else { continue }
            conflicts.append(ContactMergeConflict(field: field, kept: kept, notCopied: value))
        }
        return kept
    }
}

// MARK: - Plan

/// What a confirmed plan will do. Carries every decision so the mutation service executes
/// exactly this — never a recomputed set.
enum ContactActionKind: Sendable, Equatable {
    /// Remove exactly the plan's contacts.
    case delete
    /// Copy the merge decisions into the destination, then remove the sources — one atomic
    /// save request (see `ContactMutationService`).
    case merge(ContactMergePlan)
}

/// Why the mutation boundary structurally refused a plan (nothing mutated).
enum ContactPlanRejection: Error, Sendable, Equatable {
    case emptyPlan
    case invalidMerge
}

/// Everything outside the plan that must still match at execution time. Captured fresh at
/// confirmation and compared inside the same pre-mutation path that reads authorization.
struct ContactPlanExecutionContext: Sendable, Equatable {
    /// The selection as it exists right now.
    let selectionIDs: Set<String>
    /// The app session that created the plan.
    let sessionToken: String
    /// Fingerprint of the contacts dataset the selection came from.
    let datasetSignature: String
}

/// Why a plan may not be executed. Ordered deterministically by the validator.
enum ContactPlanStalenessReason: Sendable, Equatable {
    /// The user changed the selection after the plan was created.
    case selectionChanged
    /// Contacts authorization differs from the authorization the plan was created under.
    case authorizationChanged(from: PermissionState, to: PermissionState)
    /// The contacts dataset changed (any contact added, removed, or edited).
    case datasetChanged
    /// The plan was created in a different app session.
    case sessionChanged
    /// Some planned contacts no longer resolve in the store.
    case contactsMissing([String])
    /// Some planned contacts still exist but their fields changed since the plan was made.
    case contactsChanged([String])
}

/// The immutable boundary between "user selection" and "actual contacts mutation".
///
/// A plan is a value snapshot: the exact reviewed contacts in deterministic order, the exact
/// action (delete set, or merge with all field decisions), and the creation context used to
/// detect staleness. The mutation service executes this plan or refuses it — it never
/// recomputes which contacts are affected.
struct ContactActionPlan: Sendable, Equatable {
    /// Bump only for incompatible plan-shape changes.
    static let currentVersion = 1

    let schemaVersion: Int
    /// Every contact involved, sorted by identifier — for merge this is destination + sources.
    let items: [ContactPlanItem]
    let kind: ContactActionKind
    /// Contacts authorization at plan creation; re-read fresh at execution.
    let authorization: PermissionState
    let sessionToken: String
    /// Fingerprint of the contacts dataset the plan was built from.
    let datasetSignature: String

    var count: Int { items.count }
    var isEmpty: Bool { items.isEmpty }
    var isDelete: Bool {
        if case .delete = kind { return true }
        return false
    }

    /// Reviewed identifiers (sorted, deduped by construction).
    var selectionSnapshot: Set<String> { Set(items.map(\.identifier)) }

    /// Contacts that will be removed: the whole set for delete; the sources for merge.
    var removedIdentifiers: [String] {
        switch kind {
        case .delete:
            return items.map(\.identifier)
        case .merge(let merge):
            return merge.sourceIDs
        }
    }

    /// Deterministic identity of *this exact plan* — kind, members, and (for merge) every
    /// field decision. Two builds over identical inputs produce identical identities.
    var identity: String {
        let kindDescription: String
        switch kind {
        case .delete:
            kindDescription = "delete"
        case .merge(let merge):
            let phones = merge.appendedPhones.map { "\($0.label):\($0.value)" }.joined(separator: ",")
            let emails = merge.appendedEmails.map { "\($0.label):\($0.value)" }.joined(separator: ",")
            let conflicts = merge.conflicts
                .map { "\($0.field.rawValue):\($0.kept)~\($0.notCopied)" }
                .joined(separator: ",")
            kindDescription = [
                "merge",
                merge.destinationID,
                merge.sourceIDs.joined(separator: ","),
                phones,
                emails,
                merge.retainedGivenName,
                merge.retainedFamilyName,
                merge.retainedOrganizationName,
                conflicts,
            ].joined(separator: "|")
        }
        return ContactDigest.hex([
            "v\(schemaVersion)",
            kindDescription,
            items.map(\.identifier).joined(separator: ","),
            authorization.displayName,
            sessionToken,
            datasetSignature,
        ].joined(separator: "|"))
    }

    /// The confirmation boundary: only through here can a plan reach mutation APIs.
    func confirmed() throws -> ConfirmedContactActionPlan {
        guard !isEmpty else { throw ContactPlanRejection.emptyPlan }
        if case .merge(let merge) = kind {
            guard !merge.sourceIDs.isEmpty,
                  !merge.destinationID.isEmpty,
                  !merge.sourceIDs.contains(merge.destinationID),
                  Set(merge.sourceIDs).count == merge.sourceIDs.count else {
                throw ContactPlanRejection.invalidMerge
            }
        }
        return ConfirmedContactActionPlan(plan: self)
    }
}

/// A plan that has passed the confirmation boundary. The mutation service accepts only this
/// type — raw identifiers from UI code have no path to Contacts writes.
struct ConfirmedContactActionPlan: Sendable, Equatable {
    let plan: ContactActionPlan

    init(plan: ContactActionPlan) {
        self.plan = plan
    }
}

/// Pure staleness rules: plan vs. the current context and a freshly-read authorization.
enum ContactPlanValidator {
    /// Deterministic order: session, dataset, selection, authorization.
    static func stalenessReasons(
        plan: ContactActionPlan,
        context: ContactPlanExecutionContext,
        freshAuthorization: PermissionState
    ) -> [ContactPlanStalenessReason] {
        var reasons: [ContactPlanStalenessReason] = []
        if context.sessionToken != plan.sessionToken {
            reasons.append(.sessionChanged)
        }
        if context.datasetSignature != plan.datasetSignature {
            reasons.append(.datasetChanged)
        }
        if context.selectionIDs != plan.selectionSnapshot {
            reasons.append(.selectionChanged)
        }
        if freshAuthorization != plan.authorization {
            reasons.append(
                .authorizationChanged(from: plan.authorization, to: freshAuthorization)
            )
        }
        return reasons
    }

    /// Live-record drift: identifiers that no longer resolve, and identifiers whose
    /// grouping-relevant fields no longer match the plan's snapshot. Deterministic order
    /// (items are sorted by identifier by construction).
    static func contactDriftReasons(
        plan: ContactActionPlan,
        liveRecords: [ContactRecord]
    ) -> [ContactPlanStalenessReason] {
        var reasons: [ContactPlanStalenessReason] = []
        let liveByID = Dictionary(
            liveRecords.map { ($0.identifier, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        var missing: [String] = []
        var changed: [String] = []
        for item in plan.items {
            guard let live = liveByID[item.identifier] else {
                missing.append(item.identifier)
                continue
            }
            if ContactDigest.hex(live.canonicalFields) != item.identitySignature {
                changed.append(item.identifier)
            }
        }
        if !missing.isEmpty { reasons.append(.contactsMissing(missing)) }
        if !changed.isEmpty { reasons.append(.contactsChanged(changed)) }
        return reasons
    }
}

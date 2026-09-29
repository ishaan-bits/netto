import Foundation

/// Everything the Duplicate Contacts screen can be showing, derived — never stored.
enum ContactsPhase: Sendable, Equatable {
    /// Contacts access has never been requested.
    case permissionRequired
    /// Contacts access is off (denied or restricted) — only Settings can fix it.
    case permissionDenied
    /// Permission is fine but no scan has been started (or the last one was cancelled).
    case scanRequired
    /// A scan (read + duplicate detection) is running.
    case scanning
    /// The scan failed; carries the user-facing message.
    case failed(String)
    /// Authorized and enumerated, but there are no contacts at all.
    case empty
    /// Contacts exist but the detector found no likely duplicates.
    case noDuplicates
    /// The likely-duplicate groups, ready for review.
    case results([ContactDuplicateGroup])
}

enum ContactsPresentation {
    /// The single permission → scan → phase mapping.
    static func phase(
        permission: PermissionState,
        scan: ContactScanState
    ) -> ContactsPhase {
        switch permission {
        case .notDetermined:
            return .permissionRequired
        case .denied, .restricted:
            return .permissionDenied
        case .authorized, .limited:
            break
        }

        switch scan {
        case .notStarted, .cancelled:
            return .scanRequired
        case .running:
            return .scanning
        case .failed(let message):
            return .failed(message)
        case .completed(let dataset):
            if dataset.records.isEmpty { return .empty }
            if dataset.groups.isEmpty { return .noDuplicates }
            return .results(dataset.groups)
        }
    }

    /// Dashboard status line: actual state only — no invented counts, no "space freed"
    /// (contacts have no reliable storage-savings value, so none is ever shown).
    static func statusText(
        permission: PermissionState,
        scan: ContactScanState
    ) -> String {
        switch phase(permission: permission, scan: scan) {
        case .permissionRequired:
            return "Contacts access needed"
        case .permissionDenied:
            return "Contacts access is off"
        case .scanRequired:
            return "Not scanned yet"
        case .scanning:
            return "Finding likely duplicates…"
        case .failed(let message):
            return message
        case .empty:
            return "No contacts found"
        case .noDuplicates:
            return "Scanned · no likely duplicates"
        case .results(let groups):
            let affected = Set(groups.flatMap(\.memberIDs)).count
            return "\(groups.count) \(groups.count == 1 ? "group" : "groups") · "
                + "\(affected) contacts ready to review"
        }
    }

    /// Limited access still shows usable results — but only the granted contacts count, so the
    /// screen must say that "no duplicates" means "none among the contacts Netto can see"
    /// (mirrors `SimilarPhotosPresentation.showsLimitedAccessNotice`).
    static func showsLimitedAccessNotice(permission: PermissionState) -> Bool {
        permission == .limited
    }

    /// "Same phone number · Same email address" — human-readable evidence, never a score.
    static func reasonsText(_ reasons: [ContactDuplicateReason]) -> String {
        guard !reasons.isEmpty else { return "Likely duplicates" }
        return reasons.map(\.rawValue).joined(separator: " · ")
    }

    /// Short reason labels for a group row's chips (one line each).
    static func reasonLines(_ reasons: [ContactDuplicateReason]) -> [String] {
        reasons.isEmpty ? [ContactDuplicateReason.sharedPhone.rawValue] : reasons.map(\.rawValue)
    }

    // MARK: Review copy

    /// The destructive button title names the actual action and the exact count.
    static func destructiveTitle(for plan: ContactActionPlan) -> String {
        switch plan.kind {
        case .delete:
            let count = plan.removedIdentifiers.count
            return "Delete \(count) \(count == 1 ? "Contact" : "Contacts")"
        case .merge(let merge):
            let count = merge.sourceIDs.count
            return "Merge \(count) \(count == 1 ? "Contact" : "Contacts") into 1"
        }
    }

    /// Confirmation dialog title.
    static func confirmationTitle(for plan: ContactActionPlan) -> String {
        switch plan.kind {
        case .delete:
            let count = plan.removedIdentifiers.count
            return "Delete \(count) \(count == 1 ? "contact" : "contacts")?"
        case .merge(let merge):
            let count = merge.sourceIDs.count
            return "Merge \(count) \(count == 1 ? "contact" : "contacts") into 1?"
        }
    }

    /// One-line summary of what the plan does.
    static func actionSummary(for plan: ContactActionPlan) -> String {
        switch plan.kind {
        case .delete:
            let count = plan.removedIdentifiers.count
            return "\(count) \(count == 1 ? "contact" : "contacts") will be deleted"
        case .merge(let merge):
            let name = plan.items.first { $0.identifier == merge.destinationID }?.displayName
                ?? "the kept contact"
            return "\(merge.sourceIDs.count) "
                + "\(merge.sourceIDs.count == 1 ? "contact" : "contacts") will be merged into "
                + "“\(name)”"
        }
    }

    /// What happens in Contacts after a successful mutation (honest, no space claims).
    static func successMessage(for success: ContactMutationSuccess) -> String {
        if success.isMerge {
            let remaining = success.remainingIDs.count
            if remaining > 0 {
                return "\(success.verifiedRemovedCount) of \(success.plannedCount) duplicates "
                    + "were merged away. \(remaining) "
                    + "\(remaining == 1 ? "contact remains" : "contacts remain") — review the "
                    + "changed state again."
            }
            return "\(success.verifiedRemovedCount) "
                + "\(success.verifiedRemovedCount == 1 ? "contact was" : "contacts were") merged "
                + "into the contact you kept."
        }
        if success.isPartial {
            let remaining = success.remainingIDs.count
            return "\(success.verifiedRemovedCount) of \(success.plannedCount) were deleted. "
                + "\(remaining) \(remaining == 1 ? "contact is" : "contacts are") still in "
                + "Contacts — review the changed state again."
        }
        return "\(success.verifiedRemovedCount) "
            + "\(success.verifiedRemovedCount == 1 ? "contact was" : "contacts were") deleted "
            + "from Contacts."
    }

    static func staleMessage(_ reasons: [ContactPlanStalenessReason]) -> String {
        var message = "This review no longer matches your selection or your contacts. "
            + "Review again before changing anything."
        if reasons.contains(where: { reason in
            if case .contactsMissing = reason { return true }
            return false
        }) {
            message += " Some reviewed contacts are no longer available."
        }
        if reasons.contains(where: { reason in
            if case .contactsChanged = reason { return true }
            return false
        }) {
            message += " Some reviewed contacts have changed since you approved this."
        }
        return message
    }

    static func permissionMessage(for state: PermissionState) -> String {
        switch state {
        case .denied, .restricted:
            return "Contacts access is off, so Netto cannot change anything. Enable access in "
                + "Settings, then review again."
        case .notDetermined:
            return "Contacts access has not been granted. Allow Contacts access, then review again."
        case .authorized, .limited:
            return "Contacts access is required to make this change. Grant access in Settings, "
                + "then review again."
        }
    }

    /// Structural error text never leaks raw store errors.
    static func userFacingFailure(for outcome: ContactActionOutcome) -> String {
        switch outcome {
        case .mutationFailed:
            return "Contacts could not complete the change. Check the Contacts app before "
                + "trying again."
        case .verificationFailed(let message), .revalidationFailed(let message):
            return message
        case .succeeded, .stale, .permissionDenied, .rejected, .cancelled:
            return ""
        }
    }
}

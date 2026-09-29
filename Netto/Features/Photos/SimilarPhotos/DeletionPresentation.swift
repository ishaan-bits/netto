import Foundation

/// What the final review screen renders, derived from `DeletionState` — never stored.
///
/// One projection so every displayed fact (counts, size wording, destructive title) is pure and
/// unit-testable, mirroring `SimilarPhotosPresentation` for the analysis screen.
enum DeletionReviewPhase: Sendable, Equatable {
    case empty
    case building
    case ready(DeletionPlan)
    case stale([PlanStalenessReason])
    case deleting
    case succeeded(DeletionSuccess)
    case needsReview(DeletionSuccess)
    case failed(String)
    case permissionRequired(PermissionState)
}

enum DeletionPresentation {
    static func phase(for state: DeletionState) -> DeletionReviewPhase {
        switch state {
        case .noSelection:
            return .empty
        case .preparingPlan, .resolvingSizes:
            return .building
        case .readyForReview(let plan):
            return .ready(plan)
        case .planStale(_, let reasons):
            return .stale(reasons)
        case .awaitingConfirmation(let plan):
            return .ready(plan)
        case .deleting:
            return .deleting
        case .succeeded(let success):
            return .succeeded(success)
        case .needsReview(let success):
            return .needsReview(success)
        case .failed(let message):
            return .failed(message)
        case .permissionRequired(let state):
            return .permissionRequired(state)
        }
    }

    /// The destructive button title names the actual action and the exact count — never
    /// "Clean" or other ambiguous wording.
    static func destructiveTitle(for plan: DeletionPlan) -> String {
        "Delete \(plan.count) \(plural(plan.count, one: "Photo", many: "Photos"))"
    }

    /// Size wording that is honest about completeness:
    /// - exact → "1.2 GB measured total"
    /// - partial → "At least 900 MB measured · 3 sizes unavailable" (a lower bound, not a promise)
    /// - nothing measured → "Measured size unavailable…" (never "0 B")
    static func sizeMessage(for plan: DeletionPlan) -> String {
        let summary = plan.sizeSummary
        if summary.isFullyUnresolved {
            return "Measured size unavailable — Netto could not resolve sizes for these "
                + "\(summary.totalCount) \(plural(summary.totalCount, one: "item", many: "items"))."
        }
        if summary.isExact {
            return "\(ByteFormat.string(summary.measuredBytes)) measured total"
        }
        return "At least \(ByteFormat.string(summary.measuredBytes)) measured · "
            + "\(summary.unresolvedCount) \(plural(summary.unresolvedCount, one: "size", many: "sizes")) unavailable"
    }

    /// What categories are being removed (deduped plan items, so the parts add to `count`).
    static func categorySummary(for plan: DeletionPlan) -> String {
        let exact = plan.items.filter { $0.category == .exactDuplicates }.count
        let similar = plan.items.filter { $0.category == .nearDuplicates }.count
        let videos = plan.items.filter { $0.mediaType == .video }.count

        var parts: [String] = []
        if exact > 0 { parts.append("\(exact) exact \(plural(exact, one: "duplicate", many: "duplicates"))") }
        if similar > 0 { parts.append("\(similar) similar \(plural(similar, one: "photo", many: "photos"))") }
        if videos > 0 { parts.append("\(videos) \(plural(videos, one: "video", many: "videos"))") }
        if parts.isEmpty { return "\(plan.count) \(plural(plan.count, one: "item", many: "items"))" }
        return parts.joined(separator: " · ")
    }

    static func staleMessage(_ reasons: [PlanStalenessReason]) -> String {
        var message = "This review no longer matches your selection or your photo library. "
            + "Review the current selection again before deleting."
        if reasons.contains(where: { reason in
            if case .assetsMissing = reason { return true }
            return false
        }) {
            message += " Some planned photos are no longer available."
        }
        return message
    }

    static func successMessage(for success: DeletionSuccess) -> String {
        "\(success.verifiedRemovedCount) \(plural(success.verifiedRemovedCount, one: "photo was", many: "photos were")) moved to Recently Deleted."
    }

    static func partialMessage(for success: DeletionSuccess) -> String {
        let remaining = success.remainingIDs.count
        return "\(success.verifiedRemovedCount) of \(success.plannedCount) were removed. "
            + "\(remaining) \(plural(remaining, one: "photo is", many: "photos are")) still in your library — review the changed state again."
    }

    /// Honest storage wording: iOS reclaims space on its own schedule; the plan's byte count is
    /// not equated with device free space.
    static let storageCaveat =
        "Photos keeps deleted items in Recently Deleted until it cleans them up, so your device's "
        + "free space may not change right away."

    static func permissionMessage(for state: PermissionState) -> String {
        switch state {
        case .denied, .restricted:
            return "Photos access is off, so Netto cannot delete anything. Enable access in Settings, then review again."
        case .notDetermined:
            return "Photos access has not been granted. Allow Photos access, then review again."
        case .authorized, .limited:
            return "Photos access is required to delete. Grant access in Settings, then review again."
        }
    }

    static func failureMessage(_ message: String) -> String {
        message
    }

    /// Structural error text (PhotoKit's `localizedDescription`, etc.) never reaches the UI —
    /// every failure outcome is mapped to a friendly message here.
    static func userFacingFailure(for outcome: DeletionOutcome) -> String {
        switch outcome {
        case .mutationFailed:
            return "Photos could not complete the deletion. Check your library before trying again."
        case .verificationFailed(let message), .revalidationFailed(let message):
            return message
        case .succeeded, .stale, .permissionDenied, .rejected, .cancelled:
            return ""
        }
    }

    private static func plural(_ count: Int, one: String, many: String) -> String {
        count == 1 ? one : many
    }
}

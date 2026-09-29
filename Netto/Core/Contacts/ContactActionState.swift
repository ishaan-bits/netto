import Foundation

/// Verified result of a completed contacts mutation — checked against the store *after* the
/// save request, because `execute(saveRequest:)` returning is not proof that the intended
/// contacts actually changed.
struct ContactMutationSuccess: Sendable, Equatable {
    /// Contacts the plan intended to remove (delete: the set; merge: the sources).
    let plannedCount: Int
    /// Removed contacts verified gone from the store after the request.
    let verifiedRemovedCount: Int
    /// Planned removals still present after the request (external change or partial outcome).
    let remainingIDs: [String]
    let isMerge: Bool
    /// For merge: the destination that was updated (verified present with the appended values).
    let destinationID: String?

    var isFullyRemoved: Bool { remainingIDs.isEmpty }
    var isPartial: Bool { !remainingIDs.isEmpty }
}

/// Everything the contacts mutation service can report back. Distinguished outcomes — never a
/// bare success flag — so the UI can handle a partial result, a stale plan, and a permission
/// failure differently.
enum ContactActionOutcome: Sendable, Equatable {
    /// The save request completed and post-verification ran. Inspect `remainingIDs` for
    /// partiality; for merge the destination is also verified.
    case succeeded(ContactMutationSuccess)
    /// At least one staleness reason was detected pre-mutation — zero contacts touched.
    case stale([ContactPlanStalenessReason])
    /// Current authorization does not permit the operation — zero contacts touched.
    case permissionDenied(PermissionState)
    /// The plan was structurally unacceptable — zero contacts touched.
    case rejected(ContactPlanRejection)
    /// The store reported a save failure.
    case mutationFailed(String)
    /// Post-mutation verification could not confirm the result — success deliberately *not*
    /// claimed.
    case verificationFailed(String)
    /// Pre-mutation revalidation could not run — zero contacts touched.
    case revalidationFailed(String)
    /// Cancelled before or during the request.
    case cancelled
}

/// The contacts action state machine. One enum — no boolean soup — and every change goes
/// through `canTransition`, so illegal sequences (mutating without confirmation, re-running a
/// finished plan) are unrepresentable in practice. Mirrors the Photos `DeletionState` for the
/// same safety reasons, with contacts-specific outcomes.
enum ContactActionState: Sendable, Equatable {
    /// Nothing prepared for a contacts action (universal safe reset target).
    case noSelection
    /// A plan build is in flight (selection snapshot + merge decisions being computed).
    case preparingPlan
    /// Plan ready: awaiting the user's review and destructive action.
    case readyForReview(ContactActionPlan)
    /// The plan exists but must not run (selection/authorization/dataset changed).
    case planStale(ContactActionPlan, [ContactPlanStalenessReason])
    /// The confirmation dialog accepted the destructive action; execution has not begun.
    case awaitingConfirmation(ContactActionPlan)
    /// Inside the mutation service — the only state in which Contacts mutation can happen.
    case executing(ContactActionPlan)
    /// Request completed; every planned removal verified gone (and merge destination verified).
    case succeeded(ContactMutationSuccess)
    /// Request completed but some planned contacts remain — review the changed state again.
    case needsReview(ContactMutationSuccess)
    /// The operation failed; carries the user-facing message.
    case failed(String)
    /// Current authorization does not permit the action; recovery is Settings or back.
    case permissionRequired(PermissionState)

    enum Tag: Hashable {
        case noSelection, preparingPlan, readyForReview, planStale, awaitingConfirmation,
             executing, succeeded, needsReview, failed, permissionRequired
    }

    var tag: Tag {
        switch self {
        case .noSelection: return .noSelection
        case .preparingPlan: return .preparingPlan
        case .readyForReview: return .readyForReview
        case .planStale: return .planStale
        case .awaitingConfirmation: return .awaitingConfirmation
        case .executing: return .executing
        case .succeeded: return .succeeded
        case .needsReview: return .needsReview
        case .failed: return .failed
        case .permissionRequired: return .permissionRequired
        }
    }

    private struct Transition: Hashable {
        let from: Tag
        let to: Tag
    }

    /// Every legal non-reset transition. Notably illegal: `noSelection → executing`,
    /// `readyForReview → executing` (confirmation required), `planStale → executing`,
    /// `awaitingConfirmation → succeeded` (execution required), `succeeded → executing`
    /// (a finished plan is never reusable).
    private static let allowed: Set<Transition> = [
        Transition(from: .noSelection, to: .preparingPlan),
        Transition(from: .preparingPlan, to: .readyForReview),
        Transition(from: .preparingPlan, to: .failed),
        Transition(from: .preparingPlan, to: .planStale),
        Transition(from: .readyForReview, to: .awaitingConfirmation),
        Transition(from: .readyForReview, to: .planStale),
        Transition(from: .readyForReview, to: .preparingPlan),
        Transition(from: .planStale, to: .preparingPlan),
        Transition(from: .awaitingConfirmation, to: .executing),
        Transition(from: .awaitingConfirmation, to: .readyForReview),
        Transition(from: .awaitingConfirmation, to: .planStale),
        Transition(from: .executing, to: .succeeded),
        Transition(from: .executing, to: .needsReview),
        Transition(from: .executing, to: .failed),
        Transition(from: .executing, to: .planStale),
        Transition(from: .executing, to: .permissionRequired),
        Transition(from: .executing, to: .readyForReview),
        Transition(from: .needsReview, to: .preparingPlan),
        Transition(from: .failed, to: .preparingPlan),
        Transition(from: .permissionRequired, to: .preparingPlan),
    ]

    /// `noSelection` is a universal safe reset (it removes capability, never grants it);
    /// everything else must be in the explicit table.
    static func canTransition(from source: ContactActionState, to target: ContactActionState) -> Bool {
        if case .noSelection = target { return true }
        return allowed.contains(Transition(from: source.tag, to: target.tag))
    }

    /// The plan this state is holding, if any.
    var plan: ContactActionPlan? {
        switch self {
        case .readyForReview(let plan), .planStale(let plan, _), .awaitingConfirmation(let plan),
             .executing(let plan):
            return plan
        case .noSelection, .preparingPlan, .succeeded, .needsReview, .failed,
             .permissionRequired:
            return nil
        }
    }

    var isExecuting: Bool {
        if case .executing = self { return true }
        return false
    }

    /// While a plan build is in flight, does this count as "still building"?
    var isBuildingPlan: Bool {
        if case .preparingPlan = self { return true }
        return false
    }
}

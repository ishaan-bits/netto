import Foundation

/// Verified result of a completed mutation request — checked against the library *after* the
/// request, because `performChanges` returning is not proof that every intended asset vanished.
struct DeletionSuccess: Sendable, Equatable {
    let plannedCount: Int
    /// Planned assets no longer present in the active library after the request.
    let verifiedRemovedCount: Int
    /// Planned assets still present after the request (external change or partial outcome).
    let remainingIDs: [String]

    var isFullyRemoved: Bool { remainingIDs.isEmpty }
    var isPartial: Bool { !remainingIDs.isEmpty }
}

/// Structural refusal by the deletion boundary (nothing mutated).
enum DeletionRejection: Error, Sendable, Equatable {
    case emptyPlan
}

/// Everything the deletion service can report back. Distinguished outcomes, never a bare
/// success flag: a partial result, a stale plan, and a permission failure are different things
/// the UI must handle differently.
enum DeletionOutcome: Sendable, Equatable {
    /// The request completed and post-verification ran. Inspect `remainingIDs` for partiality.
    case succeeded(DeletionSuccess)
    /// At least one staleness reason was detected pre-mutation — zero assets touched.
    /// `.assetsMissing` inside the reasons distinguishes vanished assets from context drift.
    case stale([PlanStalenessReason])
    /// Current authorization does not permit the operation — zero assets touched.
    case permissionDenied(PermissionState)
    /// The plan was structurally unacceptable (empty) — zero assets touched.
    case rejected(DeletionRejection)
    /// PhotoKit reported a mutation failure.
    case mutationFailed(String)
    /// The mutation was requested but post-mutation verification could not run: success is
    /// deliberately *not* claimed.
    case verificationFailed(String)
    /// Pre-mutation library revalidation could not run — zero assets touched.
    case revalidationFailed(String)
    /// The operation was cancelled before or during the request.
    case cancelled
}

/// The explicit deletion state machine (§16). One enum — no boolean soup — and every change
/// goes through `canTransition`, which makes illegal sequences (deleting without a plan, a
/// result without execution, re-executing a finished plan) unrepresentable in practice.
enum DeletionState: Sendable, Equatable {
    /// Nothing selected for cleanup (also the universal safe reset target).
    case noSelection
    /// A plan build was started; inputs are being collected.
    case preparingPlan
    /// Real sizes are being resolved through `AssetSizeProviding`.
    case resolvingSizes
    /// Plan ready: sizes resolved, awaiting the user's review and destructive action.
    case readyForReview(DeletionPlan)
    /// The plan exists but must not run (selection/authorization/library context changed).
    case planStale(DeletionPlan, [PlanStalenessReason])
    /// The confirmation dialog accepted the destructive action; execution has not begun.
    case awaitingConfirmation(DeletionPlan)
    /// Inside the deletion service — the only state in which Photos mutation can happen.
    case deleting(DeletionPlan)
    /// Request completed; every planned asset verified gone from the active library.
    case succeeded(DeletionSuccess)
    /// Request completed but some planned assets remain — review the changed state again.
    case needsReview(DeletionSuccess)
    /// The operation failed; carries the user-facing message.
    case failed(String)
    /// Current authorization does not permit deletion; safe recovery is Settings or back.
    case permissionRequired(PermissionState)

    // MARK: Transition table

    enum Tag: Hashable {
        case noSelection, preparingPlan, resolvingSizes, readyForReview, planStale,
             awaitingConfirmation, deleting, succeeded, needsReview, failed, permissionRequired
    }

    var tag: Tag {
        switch self {
        case .noSelection: return .noSelection
        case .preparingPlan: return .preparingPlan
        case .resolvingSizes: return .resolvingSizes
        case .readyForReview: return .readyForReview
        case .planStale: return .planStale
        case .awaitingConfirmation: return .awaitingConfirmation
        case .deleting: return .deleting
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

    /// Every legal non-reset transition. Notably illegal: `noSelection → deleting`,
    /// `readyForReview → deleting` (confirmation required), `planStale → deleting`,
    /// `awaitingConfirmation → succeeded` (execution required), `succeeded → deleting`
    /// (a finished plan is never reusable).
    private static let allowed: Set<Transition> = [
        Transition(from: .noSelection, to: .preparingPlan),
        Transition(from: .preparingPlan, to: .resolvingSizes),
        Transition(from: .preparingPlan, to: .failed),
        Transition(from: .preparingPlan, to: .planStale),
        Transition(from: .resolvingSizes, to: .readyForReview),
        Transition(from: .resolvingSizes, to: .failed),
        Transition(from: .resolvingSizes, to: .planStale),
        Transition(from: .readyForReview, to: .awaitingConfirmation),
        Transition(from: .readyForReview, to: .planStale),
        Transition(from: .readyForReview, to: .preparingPlan),
        Transition(from: .planStale, to: .preparingPlan),
        Transition(from: .awaitingConfirmation, to: .deleting),
        Transition(from: .awaitingConfirmation, to: .readyForReview),
        Transition(from: .awaitingConfirmation, to: .planStale),
        Transition(from: .deleting, to: .succeeded),
        Transition(from: .deleting, to: .needsReview),
        Transition(from: .deleting, to: .failed),
        Transition(from: .deleting, to: .planStale),
        Transition(from: .deleting, to: .permissionRequired),
        Transition(from: .deleting, to: .readyForReview),
        Transition(from: .needsReview, to: .preparingPlan),
        Transition(from: .failed, to: .preparingPlan),
        Transition(from: .permissionRequired, to: .preparingPlan),
    ]

    /// `noSelection` is a universal safe reset (it removes capability, never grants it);
    /// everything else must be in the explicit table.
    static func canTransition(from source: DeletionState, to target: DeletionState) -> Bool {
        if case .noSelection = target { return true }
        return allowed.contains(Transition(from: source.tag, to: target.tag))
    }

    /// The plan this state is holding, if any.
    var plan: DeletionPlan? {
        switch self {
        case .readyForReview(let plan), .planStale(let plan, _), .awaitingConfirmation(let plan),
             .deleting(let plan):
            return plan
        case .noSelection, .preparingPlan, .resolvingSizes, .succeeded, .needsReview,
             .failed, .permissionRequired:
            return nil
        }
    }

    var isDeleting: Bool {
        if case .deleting = self { return true }
        return false
    }

    /// While a plan build is in flight, which states count as "still building".
    var isBuildingPlan: Bool {
        switch self {
        case .preparingPlan, .resolvingSizes: return true
        default: return false
        }
    }
}

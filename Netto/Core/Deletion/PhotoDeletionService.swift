import Foundation
import Photos

/// The single seam over PhotoKit's mutation surface plus the library facts that must be read
/// **fresh, immediately before mutating**: current authorization and current asset existence.
///
/// The live implementation (`PhotoKitMutationBacking`) is the only place in the app that calls
/// Photos write APIs. Tests inject fakes; unit tests never touch a real photo library.
protocol PhotoMutationBacking: Sendable {
    /// Always a live system read — never a previously captured authorization result.
    func currentAuthorization() -> PermissionState
    /// Which of the given identifiers currently resolve in the library (visible under the
    /// current authorization). Used for pre-mutation revalidation and post-mutation verification.
    func existingIdentifiers(_ localIdentifiers: [String]) async throws -> Set<String>
    /// Performs the Photos change for **exactly** the given identifiers. The returned
    /// submission names the identifiers the change block actually fetched and submitted:
    /// only those can be trusted to have moved to Recently Deleted (an empty or partial
    /// in-block fetch is reported, never papered over).
    func deleteAssets(localIdentifiers: [String]) async throws -> DeletedAssetSubmission
}

/// What a committed Photos change actually submitted: the planned identifiers the change
/// block fetched and handed to `deleteAssets`. Committed ⇒ every submitted asset moved to
/// Recently Deleted.
struct DeletedAssetSubmission: Equatable, Sendable {
    let submittedIDs: Set<String>
}

/// What the app layer may ask of the deletion boundary. The only accepted payload is a
/// `ConfirmedDeletionPlan` — raw local identifiers from UI code have no path to Photos writes.
protocol PhotoDeleting: Sendable {
    func execute(
        _ confirmed: ConfirmedDeletionPlan,
        in context: PlanExecutionContext
    ) async -> DeletionOutcome
}

/// The deletion service: the sole orchestrator of Photos mutation.
///
/// Every run goes through **one final pre-mutation path**, in this order, with no mutation
/// possible before it completes:
/// 1. structural guard (non-empty plan),
/// 2. **fresh** authorization read (a stale/earlier result is never reused),
/// 3. authorization-must-permit check (otherwise: permission error, zero mutations),
/// 4. pure plan-vs-context staleness validation (selection, session, analysis, authorization),
/// 5. resolve every planned identifier against the live library (missing → stale, never shrunk),
/// 6. only then: `deleteAssets` with exactly the plan's identifiers — the change block's own
///    fetch is the submission of record,
/// 7. post-mutation verification: a committed change moved exactly its submitted identifiers
///    to Recently Deleted; a follow-up library read must still succeed, but its per-asset
///    results are deliberately not used for counting (see `execute`).
struct PhotoDeletionService: PhotoDeleting {
    private let backing: any PhotoMutationBacking

    init(backing: any PhotoMutationBacking = PhotoKitMutationBacking()) {
        self.backing = backing
    }

    func execute(
        _ confirmed: ConfirmedDeletionPlan,
        in context: PlanExecutionContext
    ) async -> DeletionOutcome {
        let plan = confirmed.plan
        guard !plan.isEmpty else { return .rejected(.emptyPlan) }
        // Deterministic order (plan items are sorted by identifier) and unique by construction.
        let planIDs = plan.items.map(\.localIdentifier)

        // ── Final pre-mutation path (fresh authorization + validation, same path) ──────────
        let freshAuthorization = backing.currentAuthorization()
        guard freshAuthorization.isUsable else {
            return .permissionDenied(freshAuthorization)
        }

        let reasons = DeletionPlanValidator.stalenessReasons(
            plan: plan,
            context: context,
            freshAuthorization: freshAuthorization
        )
        guard reasons.isEmpty else { return .stale(reasons) }

        let presentBefore: Set<String>
        do {
            presentBefore = try await backing.existingIdentifiers(planIDs)
        } catch {
            return .revalidationFailed("Your library could not be rechecked, so nothing was deleted.")
        }
        let missing = planIDs.filter { !presentBefore.contains($0) }
        guard missing.isEmpty else { return .stale([.assetsMissing(missing)]) }
        // ── Validation complete: the live set is exactly the reviewed set. ─────────────────

        let submission: DeletedAssetSubmission
        do {
            submission = try await backing.deleteAssets(localIdentifiers: planIDs)
        } catch is CancellationError {
            return .cancelled
        } catch {
            return .mutationFailed(error.localizedDescription)
        }

        // Post-mutation verification. PhotoKit keeps a trashed asset (one in Recently
        // Deleted) fetchable by its local identifier, so re-fetching the planned IDs after
        // the commit cannot distinguish "moved to Recently Deleted" from "still in the
        // library" — counting that fetch would report every successful deletion as a
        // phantom partial failure with zero confirmed removals, which in turn would prune
        // nothing and suppress the Space Freed Summary. The committed change block's own
        // fetch is the submission of record: an identifier is confirmed removed exactly when
        // it entered the committed change. The follow-up library read below is a
        // corroboration that the library is still readable; its per-asset results are
        // deliberately ignored for counting.
        do {
            _ = try await backing.existingIdentifiers(planIDs)
        } catch {
            return .verificationFailed(
                "The deletion was requested, but the result could not be verified. Check Recently Deleted."
            )
        }
        let remaining = planIDs.filter { !submission.submittedIDs.contains($0) }
        return .succeeded(DeletionSuccess(
            plannedCount: plan.count,
            verifiedRemovedCount: plan.count - remaining.count,
            remainingIDs: remaining
        ))
    }
}

// MARK: - Live PhotoKit backing (the only Photos mutation code in the app)

/// iOS 17 PhotoKit implementation.
///
/// - Authorization is read live on every call (`PHPhotoLibrary` status for `.readWrite`).
/// - Existence revalidation fetches by exact identifier: an identifier that no longer resolves
///   (deleted externally, or outside limited access) is simply absent — never substituted.
/// - The change block re-fetches by the exact plan identifiers and deletes only those; no other
///   asset can enter the request. Async `performChanges` throws on failure (SDK:
///   `NS_SWIFT_ASYNC_THROWS_ON_FALSE`).
struct PhotoKitMutationBacking: PhotoMutationBacking {
    private let permission: any PhotoLibraryPermissionServicing

    init(permission: any PhotoLibraryPermissionServicing = PhotoLibraryPermissionService()) {
        self.permission = permission
    }

    func currentAuthorization() -> PermissionState {
        permission.currentStatus()
    }

    func existingIdentifiers(_ localIdentifiers: [String]) async throws -> Set<String> {
        guard !localIdentifiers.isEmpty else { return [] }
        let options = PHFetchOptions()
        options.fetchLimit = localIdentifiers.count
        let assets = PHAsset.fetchAssets(withLocalIdentifiers: localIdentifiers, options: options)
        var found = Set<String>()
        found.reserveCapacity(assets.count)
        for index in 0..<assets.count {
            found.insert(assets.object(at: index).localIdentifier)
        }
        return found
    }

    func deleteAssets(localIdentifiers: [String]) async throws -> DeletedAssetSubmission {
        guard !localIdentifiers.isEmpty else { return DeletedAssetSubmission(submittedIDs: []) }
        let ids = localIdentifiers
        let collector = SubmissionCollector()
        try await PHPhotoLibrary.shared().performChanges {
            let options = PHFetchOptions()
            options.fetchLimit = ids.count
            let assets = PHAsset.fetchAssets(withLocalIdentifiers: ids, options: options)
            guard assets.count > 0 else { return }
            var submitted = Set<String>()
            submitted.reserveCapacity(assets.count)
            for index in 0..<assets.count {
                submitted.insert(assets.object(at: index).localIdentifier)
            }
            collector.record(submitted)
            PHAssetChangeRequest.deleteAssets(assets)
        }
        return DeletedAssetSubmission(submittedIDs: collector.submitted)
    }
}

/// Crosses the `performChanges` boundary: the change block runs on a Photos-owned queue
/// and records exactly which identifiers it fetched and submitted; the awaiting caller
/// reads that submission after the commit. Lock-guarded for the cross-queue handoff.
private final class SubmissionCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var ids = Set<String>()

    func record(_ submitted: Set<String>) {
        lock.lock()
        defer { lock.unlock() }
        ids = submitted
    }

    var submitted: Set<String> {
        lock.lock()
        defer { lock.unlock() }
        return ids
    }
}

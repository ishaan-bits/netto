import Foundation

/// One asset exactly as the user reviewed it — the atomic unit of a deletion plan.
///
/// Immutable by construction: a plan is a value snapshot of a selection at a moment in time,
/// never a live view over the library. Sizes are `nil` when unresolved; `nil` is never coerced
/// to `0` anywhere in the pipeline.
struct DeletionPlanItem: Sendable, Hashable, Identifiable {
    let localIdentifier: String
    let mediaType: PhotoMediaType
    /// Exact measured bytes, or `nil` when resolution failed or was never possible.
    let sizeInBytes: Int64?
    /// Which review category surfaced this asset (exact vs similar), `nil` when unknown.
    let category: PhotoSimilarityGroupKind?

    var id: String { localIdentifier }
}

/// Measured-vs-unresolved size semantics for a plan.
///
/// Three states are explicit and distinguishable:
/// - **Exact** (`isExact`): every item measured — the total is the real byte total.
/// - **Partial**: some measured, some unresolved — `measuredBytes` is a *lower bound* only.
/// - **Fully unresolved**: nothing measured — any UI must say so instead of showing zero.
struct DeletionSizeSummary: Sendable, Equatable {
    /// Sum over measured items only. Unresolved items contribute nothing (a lower bound).
    let measuredBytes: Int64
    let measuredCount: Int
    let unresolvedCount: Int

    var totalCount: Int { measuredCount + unresolvedCount }

    /// The only state in which the displayed total may be called exact.
    var isExact: Bool { unresolvedCount == 0 }

    /// Nothing was measured — the total must never be displayed as "0 bytes".
    var isFullyUnresolved: Bool { measuredCount == 0 && unresolvedCount > 0 }

    init(items: [DeletionPlanItem]) {
        var bytes: Int64 = 0
        var measured = 0
        var unresolved = 0
        for item in items {
            if let size = item.sizeInBytes {
                bytes += size
                measured += 1
            } else {
                unresolved += 1
            }
        }
        measuredBytes = bytes
        measuredCount = measured
        unresolvedCount = unresolved
    }
}

/// Everything outside the plan that must still match at execution time.
///
/// Captured fresh by the environment at the moment of confirmation and compared against the
/// plan's creation context inside the same pre-mutation path that reads authorization.
struct PlanExecutionContext: Sendable, Equatable {
    /// The selection as it exists right now (not as it existed at plan creation).
    let selectionIDs: Set<String>
    /// Identifies the app session that created the plan — a reloaded app cannot prove currency.
    let sessionToken: String
    /// Stable fingerprint of the analysis dataset the selection came from.
    let analysisSignature: String
}

/// Why a plan may not be executed. Ordered deterministically by the validator.
enum PlanStalenessReason: Sendable, Equatable {
    /// The user changed the selection after the plan was created.
    case selectionChanged
    /// Photo authorization differs from the authorization the plan was created under.
    case authorizationChanged(from: PermissionState, to: PermissionState)
    /// The analysis dataset behind the selection changed (or is gone).
    case analysisChanged
    /// The plan was created in a different app session than the one about to execute it.
    case sessionChanged
    /// Some planned assets no longer resolve in the library (deleted or hidden externally).
    case assetsMissing([String])
}

/// The immutable boundary between "user selection" and "actual mutation".
///
/// A plan contains the *exact* asset set that was reviewed: stable local identifiers in
/// deterministic order, media classification, measured sizes where available, and the creation
/// context (authorization, session, analysis fingerprint) used to detect staleness. The deletion
/// service never recomputes a different set — it executes this one or refuses.
struct DeletionPlan: Sendable, Equatable {
    /// Bump only for incompatible plan-shape changes; stored so foreign plans can be recognized.
    static let currentVersion = 1

    let schemaVersion: Int
    /// Exactly the reviewed assets, sorted by localIdentifier — deduped and deterministic.
    let items: [DeletionPlanItem]
    /// Photo authorization at plan creation. Execution re-reads authorization fresh and
    /// invalidates the plan if it changed.
    let authorization: PermissionState
    /// App session that created the plan.
    let sessionToken: String
    /// Fingerprint of the analysis result the selection came from.
    let analysisSignature: String

    var count: Int { items.count }
    var isEmpty: Bool { items.isEmpty }

    /// The reviewed identifier set (equal to the items' identifiers by construction).
    var selectionSnapshot: Set<String> { Set(items.map(\.localIdentifier)) }

    var sizeSummary: DeletionSizeSummary { DeletionSizeSummary(items: items) }

    /// The confirmation boundary. Only a non-empty plan can ever become confirmed, and the
    /// confirmed wrapper is what the mutation service accepts — an unconfirmed plan cannot
    /// reach Photos write APIs by type.
    func confirmed() throws -> ConfirmedDeletionPlan {
        guard !isEmpty else { throw DeletionRejection.emptyPlan }
        return ConfirmedDeletionPlan(plan: self)
    }
}

/// A plan that has passed the confirmation boundary.
///
/// Constructed through `DeletionPlan.confirmed()` from the confirmation flow; the internal
/// initializer exists so tests can exercise the service's own defensive empty-plan guard.
/// Raw local identifiers are never accepted by the deletion service — only this type.
struct ConfirmedDeletionPlan: Sendable, Equatable {
    let plan: DeletionPlan

    init(plan: DeletionPlan) {
        self.plan = plan
    }
}

/// Pure staleness rules: plan vs. the current context and a freshly-read authorization.
///
/// No I/O, no timestamps — equality over the stored creation context is the proof.
enum DeletionPlanValidator {
    /// Deterministic order: session, analysis, selection, authorization.
    static func stalenessReasons(
        plan: DeletionPlan,
        context: PlanExecutionContext,
        freshAuthorization: PermissionState
    ) -> [PlanStalenessReason] {
        var reasons: [PlanStalenessReason] = []
        if context.sessionToken != plan.sessionToken {
            reasons.append(.sessionChanged)
        }
        if context.analysisSignature != plan.analysisSignature {
            reasons.append(.analysisChanged)
        }
        if context.selectionIDs != plan.selectionSnapshot {
            reasons.append(.selectionChanged)
        }
        if freshAuthorization != plan.authorization {
            reasons.append(.authorizationChanged(from: plan.authorization, to: freshAuthorization))
        }
        return reasons
    }
}

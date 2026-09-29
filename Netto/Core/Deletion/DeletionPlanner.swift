import Foundation

enum DeletionPlannerError: Error, Sendable, Equatable {
    /// An empty selection can never produce a plan (and therefore never a mutation).
    case emptySelection
    /// Selected identifiers with no catalog record: identity cannot be resolved, so no plan is
    /// built for a subset — the whole plan fails loudly rather than silently shrinking.
    case missingRecords([String])
}

/// Builds the immutable `DeletionPlan` from a reviewed selection.
///
/// The planner is the only place a selection becomes a plan. It resolves media classification
/// from catalog records, keeps unresolved sizes `nil` (never fabricates), and stamps the plan
/// with the creation context used later for staleness detection. Input identifiers arrive as a
/// `Set`, so duplicates can never inflate a count or produce duplicate plan items.
struct DeletionPlanner {
    /// Asset → the review category that surfaced it. Exact wins over similar when an asset
    /// belongs to both, so the label is deterministic.
    static func categories(from result: PhotoAnalysisResult) -> [String: PhotoSimilarityGroupKind] {
        var map: [String: PhotoSimilarityGroupKind] = [:]
        for group in result.exactGroups {
            for assetID in group.memberAssetIDs {
                map[assetID] = .exactDuplicates
            }
        }
        for group in result.similarGroups {
            for assetID in group.memberAssetIDs where map[assetID] == nil {
                map[assetID] = .nearDuplicates
            }
        }
        return map
    }

    /// Stable fingerprint of an analysis dataset: same groups → same signature; any membership
    /// or membership-count change → different signature (group ids alone are not enough — an
    /// exact group's id is its fingerprint, which can stay fixed while members change).
    /// Purely structural — no time, no randomness.
    static func analysisSignature(for result: PhotoAnalysisResult) -> String {
        func fingerprint(_ group: PhotoSimilarityGroup) -> String {
            "\(group.id)#\(group.memberAssetIDs.sorted().joined(separator: ","))"
        }
        let exact = result.exactGroups.map(fingerprint).sorted().joined(separator: ";")
        let near = result.similarGroups.map(fingerprint).sorted().joined(separator: ";")
        return "v1|e:\(exact)|n:\(near)|t:\(result.totalRecordCount)|u:\(result.unavailableAssets.count)"
    }

    /// - Parameters:
    ///   - selectedIDs: the reviewed selection (set semantics — duplicates impossible).
    ///   - recordsByID: catalog records for identity/media lookup; every selected ID must be
    ///     present or the whole build fails with `missingRecords`.
    ///   - resolvedSizes: measured bytes by identifier; **absent means unknown, never zero**.
    func makePlan(
        selectedIDs: Set<String>,
        recordsByID: [String: PhotoAssetRecord],
        result: PhotoAnalysisResult,
        resolvedSizes: [String: Int64],
        authorization: PermissionState,
        sessionToken: String
    ) throws -> DeletionPlan {
        guard !selectedIDs.isEmpty else { throw DeletionPlannerError.emptySelection }

        let missing = selectedIDs.filter { recordsByID[$0] == nil }.sorted()
        guard missing.isEmpty else { throw DeletionPlannerError.missingRecords(missing) }

        let categories = Self.categories(from: result)
        let items = selectedIDs.sorted().map { assetID in
            DeletionPlanItem(
                localIdentifier: assetID,
                mediaType: recordsByID[assetID]?.mediaType ?? .unknown,
                sizeInBytes: resolvedSizes[assetID],
                category: categories[assetID]
            )
        }

        return DeletionPlan(
            schemaVersion: DeletionPlan.currentVersion,
            items: items,
            authorization: authorization,
            sessionToken: sessionToken,
            analysisSignature: Self.analysisSignature(for: result)
        )
    }
}

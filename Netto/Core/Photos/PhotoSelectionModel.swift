import Foundation

/// How much of one group is currently marked for cleanup.
///
/// Deliberately richer than a `Bool`: the review UI needs "3 of 5 selected", and tests need to
/// distinguish "nothing" from "part" from "everything" without recounting.
enum GroupSelectionState: Sendable, Equatable {
    /// No member of the group is selected.
    case none
    /// Some — but not all — members are selected.
    case some(selected: Int, total: Int)
    /// Every member is selected (only reachable by explicitly overriding the recommendation).
    case all
}

/// The review layer's answer to *"which photos has the user marked for cleanup?"*
///
/// Deliberately separate from analysis: analysis says *"these photos belong together"*;
/// selection says *"the user wants this one considered for cleanup."* The two are never
/// conflated — `PhotoAnalysisResult` carries no selection, and this model carries no analysis.
///
/// Semantics that make the model safe to hand to a future cleanup layer:
/// - Selection is a **set of asset identifiers** (`selectedIDs`), so duplicate memberships can
///   never inflate a count and an empty selection is a valid, representable state.
/// - The default policy is deterministic: every group member starts selected **except** any
///   asset recommended as the "keep" in *at least one* group it belongs to
///   (`protectedRecommendedIDs`). The app never silently selects a recommended photo for
///   cleanup; only an explicit per-asset override can do that.
/// - Group-level actions implement exactly their labels and nothing more: they touch only the
///   members of the named group. Individual overrides always win afterwards.
/// - Nothing here touches the photo library. This is an in-memory value; the deletion pipeline
///   only reads it as plan input.
struct PhotoSelectionModel: Sendable, Equatable {
    /// Asset identifiers the user has marked for cleanup. Unique by construction.
    private(set) var selectedIDs: Set<String>

    /// Group id → members, in the group's declared order.
    private let membersByGroup: [String: [String]]
    /// Group id → that group's recommended "keep" asset.
    private let recommendedByGroup: [String: String]
    /// Asset id → the groups it belongs to (an asset can appear in more than one group).
    private let groupIDsByAsset: [String: Set<String>]
    /// Every asset recommended as a keep *somewhere*. Group-level defaults never select these.
    private let protectedRecommendedIDs: Set<String>

    /// An empty selection over no groups — a valid starting state (and a valid end state).
    init() {
        selectedIDs = []
        membersByGroup = [:]
        recommendedByGroup = [:]
        groupIDsByAsset = [:]
        protectedRecommendedIDs = []
    }

    /// Builds the deterministic default selection over the analysis result: every member of
    /// every group is selected except assets protected as a recommendation.
    init(result: PhotoAnalysisResult) {
        self.init(groups: result.exactGroups + result.similarGroups)
    }

    init(groups: [PhotoSimilarityGroup]) {
        var members: [String: [String]] = [:]
        var recommended: [String: String] = [:]
        var membership: [String: Set<String>] = [:]
        var protectedIDs: Set<String> = []

        for group in groups {
            members[group.id] = group.memberAssetIDs
            recommended[group.id] = group.recommendedBestAssetID
            protectedIDs.insert(group.recommendedBestAssetID)
            for assetID in group.memberAssetIDs {
                membership[assetID, default: []].insert(group.id)
            }
        }

        membersByGroup = members
        recommendedByGroup = recommended
        groupIDsByAsset = membership
        protectedRecommendedIDs = protectedIDs

        // Default: everything except the protected recommendations.
        var initial: Set<String> = []
        for (assetID, groupIDs) in membership where !protectedIDs.contains(assetID) {
            if !groupIDs.isEmpty { initial.insert(assetID) }
        }
        selectedIDs = initial
    }

    // MARK: Queries

    var selectedCount: Int { selectedIDs.count }

    func isSelected(_ assetID: String) -> Bool {
        selectedIDs.contains(assetID)
    }

    func memberIDs(inGroup groupID: String) -> [String] {
        membersByGroup[groupID] ?? []
    }

    func selectedCount(inGroup groupID: String) -> Int {
        membersByGroup[groupID]?.reduce(0) { $0 + (selectedIDs.contains($1) ? 1 : 0) } ?? 0
    }

    func selectionState(inGroup groupID: String) -> GroupSelectionState {
        let members = membersByGroup[groupID] ?? []
        guard !members.isEmpty else { return .none }
        let selected = members.reduce(0) { $0 + (selectedIDs.contains($1) ? 1 : 0) }
        if selected == 0 { return .none }
        if selected == members.count { return .all }
        return .some(selected: selected, total: members.count)
    }

    /// `true` when `assetID` belongs to at least one group this model was built from.
    func contains(_ assetID: String) -> Bool {
        groupIDsByAsset[assetID] != nil
    }

    /// The groups `assetID` belongs to; empty when it is not part of this model.
    func groupIDs(containing assetID: String) -> Set<String> {
        groupIDsByAsset[assetID] ?? []
    }

    // MARK: Mutations

    /// Explicit per-asset override. Unknown assets are ignored (the review UI only ever shows
    /// group members, and a stray identifier must not silently enter the cleanup set).
    mutating func setSelected(_ selected: Bool, forAsset assetID: String) {
        guard groupIDsByAsset[assetID] != nil else { return }
        if selected {
            selectedIDs.insert(assetID)
        } else {
            selectedIDs.remove(assetID)
        }
    }

    /// Flips one asset. Toggling twice restores the previous state exactly.
    mutating func toggle(_ assetID: String) {
        guard groupIDsByAsset[assetID] != nil else { return }
        if selectedIDs.contains(assetID) {
            selectedIDs.remove(assetID)
        } else {
            selectedIDs.insert(assetID)
        }
    }

    /// "Select all except recommended": after this action the group's members are selected
    /// exactly when they are not a protected recommendation — including deselecting a
    /// recommendation the user had explicitly overridden, so the action's outcome is
    /// deterministic and matches its label.
    mutating func selectAllExceptRecommended(inGroup groupID: String) {
        guard let members = membersByGroup[groupID] else { return }
        for assetID in members {
            if protectedRecommendedIDs.contains(assetID) {
                selectedIDs.remove(assetID)
            } else {
                selectedIDs.insert(assetID)
            }
        }
    }

    /// "Clear selection": deselects every member of the named group (and only those).
    mutating func clearGroup(_ groupID: String) {
        guard let members = membersByGroup[groupID] else { return }
        for assetID in members {
            selectedIDs.remove(assetID)
        }
    }

    /// "Keep recommended": deselects this group's recommended asset; everything else — including
    /// the user's other choices in the group — is left untouched.
    mutating func keepRecommended(inGroup groupID: String) {
        guard let assetID = recommendedByGroup[groupID] else { return }
        selectedIDs.remove(assetID)
    }
}

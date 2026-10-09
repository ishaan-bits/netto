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

    /// The selection exactly as it was when these groups were first presented — the
    /// recommended selection "Reset to Recommended" restores.
    ///
    /// Captured once at init from the same deterministic default the results opened with.
    /// User changes never touch it, and it is never recalculated: a rescan produces a new
    /// `PhotoAnalysisResult` and therefore a brand-new model with its own snapshot.
    private let originalSelectionIDs: Set<String>

    /// Group id → members, in the group's declared order.
    private let membersByGroup: [String: [String]]
    /// Group id → that group's recommended "keep" asset.
    private let recommendedByGroup: [String: String]
    /// Asset id → the groups it belongs to (an asset can appear in more than one group).
    private let groupIDsByAsset: [String: Set<String>]
    /// Every asset recommended as a keep *somewhere*. Group-level defaults never select these.
    private let protectedRecommendedIDs: Set<String>
    /// Library assets outside every group that a standalone, library-wide review (the
    /// dashboard's Swipe Review feature) has admitted for marking. Admission only widens
    /// *which* assets accept a decision; it never selects anything by itself, and it is
    /// deliberately not part of the group universe — the group APIs above stay group-only.
    private var admittedLibraryAssets: Set<String> = []

    /// An empty selection over no groups — a valid starting state (and a valid end state).
    init() {
        selectedIDs = []
        originalSelectionIDs = []
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

    /// Rebuilds over an updated result while keeping the user's exact choices for the
    /// members that still exist — used after a confirmed deletion removes assets from a
    /// completed result. Library-wide (non-group) marks survive too: they live in the
    /// admitted set, and only the confirmed removals leave it, so a deletion from any
    /// feature can no longer silently erase Swipe Review decisions for photos that were
    /// never part of a group. Choices for vanished assets (and for members of dissolved
    /// groups) drop out; the reset snapshot is the updated result's deterministic default,
    /// so "Reset to Recommended" stays meaningful over the new groups.
    init(
        result: PhotoAnalysisResult,
        preserving previous: PhotoSelectionModel,
        removing removed: Set<String> = []
    ) {
        self.init(result: result)
        admittedLibraryAssets = previous.admittedLibraryAssets.subtracting(removed)
        let accepted = Set(groupIDsByAsset.keys).union(admittedLibraryAssets)
        selectedIDs = previous.selectedIDs.subtracting(removed).intersection(accepted)
    }

    /// Confirmed removals leave both the marked set and the admitted set — the in-place
    /// update used when there is no completed analysis to rebuild over (a catalog-only
    /// library carrying Swipe Review marks). Never marks anything new.
    mutating func prune(removing removed: Set<String>) {
        guard !removed.isEmpty else { return }
        selectedIDs.subtract(removed)
        admittedLibraryAssets.subtract(removed)
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
        originalSelectionIDs = initial
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

    /// Whether a per-asset decision may touch this identifier: a group member, or an asset
    /// a library-wide review explicitly admitted. Everything else is still ignored.
    private func accepts(_ assetID: String) -> Bool {
        groupIDsByAsset[assetID] != nil || admittedLibraryAssets.contains(assetID)
    }

    // MARK: Mutations

    /// Admits general-library assets (outside every group) so a standalone library-wide
    /// review can mark them for cleanup. Idempotent; selecting is still always explicit —
    /// admission alone never changes `selectedIDs`.
    mutating func admitLibraryAssets(_ assetIDs: Set<String>) {
        admittedLibraryAssets.formUnion(assetIDs)
    }

    /// Explicit per-asset override. Assets that are neither group members nor admitted
    /// library assets are ignored (the review UI only ever shows one of those two sets,
    /// and a stray identifier must not silently enter the cleanup set).
    mutating func setSelected(_ selected: Bool, forAsset assetID: String) {
        guard accepts(assetID) else { return }
        if selected {
            selectedIDs.insert(assetID)
        } else {
            selectedIDs.remove(assetID)
        }
    }

    /// Flips one asset. Toggling twice restores the previous state exactly.
    mutating func toggle(_ assetID: String) {
        guard accepts(assetID) else { return }
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

    /// "Deselect all": clears every user-selected cleanup candidate at once.
    ///
    /// Touches only `selectedIDs` — the groups, membership, and protected recommendations are
    /// immutable by construction, so results, KEEP recommendations, and per-group state are
    /// exactly what they were. Empty selection is a first-class state (the model says so at
    /// the top), and individual selection works normally afterwards.
    mutating func deselectAll() {
        selectedIDs.removeAll()
    }

    /// "Select all": every member of every group — the full set of valid cleanup candidates.
    ///
    /// An explicit bulk action, so unlike the default it may include recommended photos (the
    /// user can already select them one by one). The groups' KEEP recommendations themselves
    /// are untouched; only the selection changes.
    mutating func selectAll() {
        selectedIDs = Set(membersByGroup.values.flatMap { $0 })
    }

    /// "Reset to Recommended": restore exactly the selection these results were presented
    /// with, whatever the user has done since (deselect-all, select-all, individual changes).
    ///
    /// Reads only the snapshot captured at init — no rescan, no recomputation, and the
    /// groups, membership, and KEEP recommendations are never touched.
    mutating func resetToRecommended() {
        selectedIDs = originalSelectionIDs
    }

    /// "Keep recommended": deselects this group's recommended asset; everything else — including
    /// the user's other choices in the group — is left untouched.
    mutating func keepRecommended(inGroup groupID: String) {
        guard let assetID = recommendedByGroup[groupID] else { return }
        selectedIDs.remove(assetID)
    }
}

import Foundation

/// The action a review was opened with. The plan is always built to match this choice —
/// a prepared delete plan can never be presented under a merge review or vice versa.
enum ContactActionChoice: Sendable, Equatable {
    case delete
    case merge
}

/// User selection over the duplicate group currently being reviewed.
///
/// Bound to one group at a time: `begin(group…)` adopts a group's members as the dataset, and
/// every mutation is validated against that dataset — an unknown identifier is ignored, so a
/// selection can never point outside the group it was made in. `destinationID` (the contact
/// kept by a merge) must always be one of the selected members.
///
/// Selection starts empty: Netto never pre-checks contacts for deletion, and never picks a
/// "master" contact on the user's behalf.
struct ContactGroupSelection: Sendable, Equatable {
    private(set) var groupID: String?
    /// Member identifiers of the group the selection is bound to.
    private(set) var datasetIDs: Set<String> = []
    /// Marked-for-action identifiers — always a subset of `datasetIDs`.
    private(set) var selectedIDs: Set<String> = []
    /// The contact a merge would keep. Always inside `selectedIDs`.
    private(set) var destinationID: String?

    var selectedCount: Int { selectedIDs.count }
    /// How many contacts the current group contains (the selection's universe).
    var datasetCount: Int { datasetIDs.count }
    var isEmpty: Bool { selectedIDs.isEmpty }
    var isAllSelected: Bool { !datasetIDs.isEmpty && selectedIDs == datasetIDs }

    func isSelected(_ id: String) -> Bool { selectedIDs.contains(id) }

    /// Adopts a group: empty selection, its members as the dataset.
    mutating func begin(groupID: String, memberIDs: [String]) {
        self.groupID = groupID
        datasetIDs = Set(memberIDs)
        selectedIDs = []
        destinationID = nil
    }

    /// Unknown identifiers are ignored — the selection never leaves its group.
    mutating func toggle(_ id: String) {
        guard datasetIDs.contains(id) else { return }
        if selectedIDs.contains(id) {
            selectedIDs.remove(id)
            if destinationID == id { destinationID = nil }
        } else {
            selectedIDs.insert(id)
        }
    }

    mutating func selectAll() {
        selectedIDs = datasetIDs
    }

    mutating func deselectAll() {
        selectedIDs = []
        destinationID = nil
    }

    /// Marks the contact a merge would keep. Only allowed for a *selected* member — the user
    /// must explicitly include the destination in the action.
    mutating func setDestination(_ id: String) {
        guard datasetIDs.contains(id), selectedIDs.contains(id) else { return }
        destinationID = id
    }

    /// Adopts a new group state (a rescan changed the group): selections of vanished members
    /// are dropped, never carried forward; a vanished group resets everything.
    mutating func reconcile(groupID: String?, memberIDs: Set<String>) {
        guard let groupID else {
            reset()
            return
        }
        self.groupID = groupID
        datasetIDs = memberIDs
        selectedIDs = selectedIDs.intersection(memberIDs)
        if let destination = destinationID, !selectedIDs.contains(destination) {
            destinationID = nil
        }
    }

    /// The group is gone — nothing remains known or selected.
    mutating func reset() {
        groupID = nil
        datasetIDs = []
        selectedIDs = []
        destinationID = nil
    }
}

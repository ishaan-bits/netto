import Foundation

/// User selection over a catalog *subset* dataset (screenshots, videos, …).
///
/// Unlike `PhotoSelectionModel` — which is bound to analysis groups — this model is bound to a
/// dataset filter over the catalog. Every mutation is validated against the dataset the
/// model was last reconciled with, so a selection can never drift outside its dataset, and
/// reconciling against a changed dataset drops vanished assets instead of silently carrying
/// them into a plan. One shape serves every subset source; each source only decides which
/// filter (and therefore which dataset) it reconciles against.
struct DatasetSelectionModel: Sendable, Equatable {
    /// Dataset identifiers the selection was last reconciled with.
    private(set) var datasetIDs: Set<String> = []
    /// Marked-for-deletion identifiers — always a subset of `datasetIDs`.
    private(set) var selectedIDs: Set<String> = []

    var selectedCount: Int { selectedIDs.count }
    var datasetCount: Int { datasetIDs.count }
    var isEmpty: Bool { selectedIDs.isEmpty }
    /// Every asset in the dataset is marked. An empty dataset is never "all selected".
    var isAllSelected: Bool { !datasetIDs.isEmpty && selectedIDs == datasetIDs }

    func isSelected(_ id: String) -> Bool { selectedIDs.contains(id) }

    /// Unknown identifiers are ignored — the selection never leaves its dataset.
    mutating func toggle(_ id: String) {
        guard datasetIDs.contains(id) else { return }
        if selectedIDs.contains(id) {
            selectedIDs.remove(id)
        } else {
            selectedIDs.insert(id)
        }
    }

    mutating func selectAll() {
        selectedIDs = datasetIDs
    }

    mutating func deselectAll() {
        selectedIDs = []
    }

    /// Adopts a new dataset (the catalog changed): selections of vanished assets are dropped,
    /// never carried forward.
    mutating func reconcile(with newDatasetIDs: Set<String>) {
        datasetIDs = newDatasetIDs
        selectedIDs = selectedIDs.intersection(newDatasetIDs)
    }

    /// The dataset is gone (library reset) — nothing remains known or selected.
    mutating func reset() {
        datasetIDs = []
        selectedIDs = []
    }
}

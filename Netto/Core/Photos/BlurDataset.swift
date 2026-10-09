import Foundation

/// Blur candidates as a *filter over a completed blur analysis* — the same shape
/// `ScreenshotDataset` is over the catalog: identity comes only from what the analysis
/// already recorded, never from a second library read or a re-measurement.
enum BlurDataset {
    /// The candidate identifiers — set semantics, so a duplicated id can never inflate
    /// the dataset.
    static func identifiers(in result: BlurAnalysisResult) -> Set<String> {
        Set(result.candidates.lazy.map(\.assetID))
    }

    /// Stable local identifiers of the candidate subset — order-independent, no time or
    /// randomness. A plan stamped with this signature is stale the moment the candidate
    /// set changes (a new analysis, a pruned result, a rebuilt catalog).
    static func signature(for identifiers: Set<String>) -> String {
        "v1-blur|\(identifiers.count)|\(identifiers.sorted().joined(separator: ","))"
    }

    static func signature(in result: BlurAnalysisResult) -> String {
        signature(for: identifiers(in: result))
    }

    /// The candidate records in catalog order (the enumeration's newest-first order) —
    /// candidates that no longer exist in the catalog are silently absent from the list;
    /// `synchronizeBlurDataset` is what keeps the selection from referencing them.
    static func records(in result: BlurAnalysisResult, catalog: CatalogScanResult) -> [PhotoAssetRecord] {
        let candidates = identifiers(in: result)
        return catalog.records.filter { candidates.contains($0.localIdentifier) }
    }
}

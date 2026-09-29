import Foundation

/// Screenshots as a *filter* over the existing catalog — never a second enumeration.
///
/// Screenshot identity comes only from the PhotoKit media subtype already bridged into
/// `PhotoAssetRecord.isScreenshot` during enumeration. No filename, OCR, Vision, EXIF, or
/// dimension heuristic exists anywhere in this type: the dataset is whatever the catalog
/// already recorded.
enum ScreenshotDataset {
    /// The screenshot records, in catalog order (the enumeration's newest-first order).
    static func records(in result: CatalogScanResult) -> [PhotoAssetRecord] {
        result.records.filter(\.isScreenshot)
    }

    /// Stable local identifiers of the screenshot subset — set semantics, so a duplicate id
    /// in the record list can never inflate the dataset.
    static func identifiers(in result: CatalogScanResult) -> Set<String> {
        Set(result.records.lazy.filter(\.isScreenshot).map(\.localIdentifier))
    }

    /// Structural fingerprint of a screenshot dataset: membership + count, order-independent,
    /// no time or randomness. A plan stamped with this signature is stale the moment the
    /// screenshot subset changes.
    static func signature(for identifiers: Set<String>) -> String {
        "v1-screenshots|\(identifiers.count)|\(identifiers.sorted().joined(separator: ","))"
    }

    static func signature(in result: CatalogScanResult) -> String {
        signature(for: identifiers(in: result))
    }
}

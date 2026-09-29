import Foundation

/// Videos as a *filter* over the existing catalog — never a second enumeration.
///
/// Video identity comes only from the media type already bridged into
/// `PhotoAssetRecord.mediaType` during enumeration. No filename, EXIF, codec, or dimension
/// heuristic exists anywhere in this type: the dataset is whatever the catalog already
/// recorded.
enum VideoDataset {
    /// The video records, in catalog order (the enumeration's newest-first order).
    static func records(in result: CatalogScanResult) -> [PhotoAssetRecord] {
        result.records.filter(\.isVideo)
    }

    /// Stable local identifiers of the video subset — set semantics, so a duplicate id
    /// in the record list can never inflate the dataset.
    static func identifiers(in result: CatalogScanResult) -> Set<String> {
        Set(result.records.lazy.filter(\.isVideo).map(\.localIdentifier))
    }

    /// Structural fingerprint of a video dataset: membership + count, order-independent,
    /// no time or randomness. A plan stamped with this signature is stale the moment the
    /// video subset changes.
    static func signature(for identifiers: Set<String>) -> String {
        "v1-videos|\(identifiers.count)|\(identifiers.sorted().joined(separator: ","))"
    }

    static func signature(in result: CatalogScanResult) -> String {
        signature(for: identifiers(in: result))
    }

    /// Embeds measured bytes into records (a record's id absent from `bytes` keeps whatever it
    /// had — the catalog's `nil`, i.e. unknown — so a missing measurement can never become 0).
    static func resolved(
        _ records: [PhotoAssetRecord],
        with bytes: [String: Int64]
    ) -> [PhotoAssetRecord] {
        records.map { record in
            record.resolvingSize(bytes[record.localIdentifier] ?? record.sizeInBytes)
        }
    }

    /// Largest first, with a fully deterministic tie-break chain.
    ///
    /// Size states at the record level are *measured* (`sizeInBytes != nil`) and *unknown*
    /// (`nil`); the dataset-level "partial" state is a settled measurement that measured only
    /// some of the videos. The ordering rules, in order:
    ///
    /// 1. A measured size always sorts before an unknown size. `nil` is never treated as
    ///    zero — an unmeasured video is not claimed to be the smallest, it is claimed to be
    ///    unknown, and it is listed after every measured video.
    /// 2. Among measured sizes: larger bytes first.
    /// 3. Ties (equal bytes, or both unknown): newer `creationDate` first — a dated record
    ///    always precedes an undated one, so `Date?` never has to be ordered directly.
    /// 4. Full ties: `localIdentifier` ascending — so the same input in any order always
    ///    produces the same output.
    ///
    /// The function is pure: records carry their embedded `sizeInBytes` (the caller embeds
    /// measured bytes with `resolvingSize` first), so sorting never reaches for PhotoKit.
    static func sorted(_ records: [PhotoAssetRecord]) -> [PhotoAssetRecord] {
        records.sorted { lhs, rhs in
            switch (lhs.sizeInBytes, rhs.sizeInBytes) {
            case let (lhsBytes?, rhsBytes?) where lhsBytes != rhsBytes:
                return lhsBytes > rhsBytes
            case (_?, nil):
                return true
            case (nil, _?):
                return false
            default:
                break
            }
            switch (lhs.creationDate, rhs.creationDate) {
            case let (lhsDate?, rhsDate?):
                if lhsDate != rhsDate {
                    return lhsDate > rhsDate
                }
            case (_?, nil):
                return true
            case (nil, _?):
                return false
            case (nil, nil):
                break
            }
            return lhs.localIdentifier < rhs.localIdentifier
        }
    }
}

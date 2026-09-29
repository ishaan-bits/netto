import Foundation

/// Deterministic "which member would we suggest keeping" logic.
///
/// This is a *recommendation* surfaced as a pre-selected default later in Review — never a
/// deletion decision, never a claim that one photo is universally better. Every tie is broken so
/// the same library always yields the same recommendation.
enum BestPhotoScoring {
    /// Ranking chain, most decisive first:
    /// 1. favorited beats not favorited (the user already marked it)
    /// 2. non-burst beats burst (a burst's representative frame is the intended shot)
    /// 3. higher pixel count beats lower (more resolution to keep)
    /// 4. edited beats unedited (the user's edit is the photo they actually want)
    /// 5. newer capture date beats older (`nil` date ranks as `distantPast`)
    /// 6. lexicographically smallest `localIdentifier` — last resort, but total
    ///
    /// `sizeInBytes` is deliberately absent: unknown at analysis time, and unknown must never be
    /// fabricated into a ranking. Sharpness (variance of Laplacian) is out of scope this milestone.
    static func score(for record: PhotoAssetRecord) -> PhotoAssetQualityScore {
        PhotoAssetQualityScore(
            localIdentifier: record.localIdentifier,
            isFavorite: record.isFavorite,
            representsBurst: record.representsBurst,
            pixelCount: record.pixelCount,
            hasAdjustments: record.hasAdjustments,
            creationDate: record.creationDate
        )
    }

    /// `true` when `lhs` outranks `rhs`. Total order: never returns true for a score against
    /// itself with an identical tie-break chain.
    static func outranks(_ lhs: PhotoAssetQualityScore, _ rhs: PhotoAssetQualityScore) -> Bool {
        if lhs.isFavorite != rhs.isFavorite { return lhs.isFavorite }
        if lhs.representsBurst != rhs.representsBurst { return !lhs.representsBurst }
        if lhs.pixelCount != rhs.pixelCount { return lhs.pixelCount > rhs.pixelCount }
        if lhs.hasAdjustments != rhs.hasAdjustments { return lhs.hasAdjustments }

        let lhsDate = lhs.creationDate ?? .distantPast
        let rhsDate = rhs.creationDate ?? .distantPast
        if lhsDate != rhsDate { return lhsDate > rhsDate }

        return lhs.localIdentifier < rhs.localIdentifier
    }

    /// Deterministic recommendation for a set of records (group members).
    static func recommendedBestID(in records: [PhotoAssetRecord]) -> String? {
        guard let first = records.first else { return nil }
        var best = score(for: first)
        for record in records.dropFirst() {
            let candidate = score(for: record)
            if outranks(candidate, best) { best = candidate }
        }
        return best.localIdentifier
    }
}

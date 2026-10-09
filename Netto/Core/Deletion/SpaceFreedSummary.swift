import Foundation

/// The post-deletion facts the Space Freed Summary displays — projected from the executed
/// `DeletionPlan` and the service's post-verification `DeletionSuccess`, never from
/// presentation state and never by re-running anything.
///
/// Integrity rules baked into the initializer:
/// - **Only confirmed removals are counted.** An item is confirmed exactly when verification
///   says it is no longer in the library (its identifier is absent from
///   `success.remainingIDs`); failed, remaining, or unverified items contribute nothing to
///   any count or byte figure. `confirmedCount` and `success.verifiedRemovedCount` describe
///   the same verification from two sides — the identifier-derived set is used here because
///   it is also what sizes and categories are looked up from.
/// - **Each identifier counts once.** Plan items are walked once and de-duplicated by
///   identifier, so a malformed plan with repeated entries can never inflate a total, and a
///   repeated identifier in `remainingIDs` can never subtract twice.
/// - **Bytes are measured or absent.** Sizes come from the plan's measured values (resolved
///   through `AssetSizeProviding` before confirmation); an item without a measured size
///   contributes nothing to `measuredBytes` and is reported through `unresolvedCount`.
///   `hasSpaceFigure` is false when nothing was measured — the signal for the UI to show the
///   verified item count instead of a fabricated amount.
/// - **`nil` means "do not show a success summary."** When nothing was confirmed removed the
///   initializer fails, so no caller can present a success state for a failed or empty run.
///
/// The summary deliberately retains no asset identifiers and no photo content — counts,
/// bytes, and category tallies only — so it can never leak what was deleted or be mistaken
/// for a live selection.
struct SpaceFreedSummary: Sendable, Equatable {
    /// One exclusive tally bucket. Every confirmed item falls in exactly one category:
    /// videos by media type first, then the review category the item was surfaced under,
    /// then the photo fallback — so the counts always sum to `confirmedCount`.
    enum Category: Sendable, Equatable, Hashable {
        case videos
        case exactDuplicates
        case similarPhotos
        case photos
    }

    /// A category and its confirmed count. `Identifiable` for ordered `ForEach` rendering.
    struct CategoryCount: Sendable, Equatable, Identifiable {
        let category: Category
        let count: Int
        var id: Category { category }
    }

    /// Items verified gone from the active library — derived from the outcome's surviving
    /// identifiers against the plan's identifiers, de-duplicated. Never the requested count.
    let confirmedCount: Int
    /// Sum of measured bytes over confirmed items only. A lower bound while
    /// `unresolvedCount > 0`; meaningless — and never rendered — while `measuredCount == 0`.
    let measuredBytes: Int64
    /// Confirmed items whose size was measured.
    let measuredCount: Int
    /// Confirmed items with no size information — excluded from `measuredBytes`, disclosed
    /// rather than counted as zero.
    let unresolvedCount: Int
    /// Planned items verification found still present — the partial-failure disclosure.
    /// Never counted as removed and never included in any byte figure.
    let notRemovedCount: Int
    /// Exclusive tallies over the confirmed items, in deterministic order (videos, exact
    /// duplicates, similar photos, photos).
    let breakdown: [CategoryCount]

    /// A space figure may be shown only when at least one confirmed item was measured.
    var hasSpaceFigure: Bool { measuredCount > 0 }

    /// The figure covers every confirmed item (still an *estimate* of reclaimed space, but
    /// not a partial sum of it).
    var isByteFigureComplete: Bool { measuredCount > 0 && unresolvedCount == 0 }

    /// Some planned items were not removed: the success must be disclosed beside them.
    var isPartial: Bool { notRemovedCount > 0 }

    /// Builds the summary for a completed execution, or `nil` when nothing was confirmed
    /// removed — the single "no success summary" gate.
    init?(plan: DeletionPlan, success: DeletionSuccess) {
        let plannedIDs = Set(plan.items.map(\.localIdentifier))
        let surviving = Set(success.remainingIDs).intersection(plannedIDs)

        var countedIDs = Set<String>()
        var confirmed = 0
        var bytes: Int64 = 0
        var measured = 0
        var unresolved = 0
        var videos = 0
        var exact = 0
        var similar = 0
        var photos = 0

        for item in plan.items {
            // Surviving items were not removed; a repeated identifier counts exactly once.
            guard !surviving.contains(item.localIdentifier) else { continue }
            guard countedIDs.insert(item.localIdentifier).inserted else { continue }

            confirmed += 1
            if let size = item.sizeInBytes {
                bytes += size
                measured += 1
            } else {
                unresolved += 1
            }
            if item.mediaType == .video {
                videos += 1
            } else {
                switch item.category {
                case .exactDuplicates: exact += 1
                case .nearDuplicates: similar += 1
                case nil: photos += 1
                }
            }
        }

        guard confirmed > 0 else { return nil }

        self.confirmedCount = confirmed
        self.measuredBytes = bytes
        self.measuredCount = measured
        self.unresolvedCount = unresolved
        self.notRemovedCount = surviving.count

        var rows: [CategoryCount] = []
        if videos > 0 { rows.append(CategoryCount(category: .videos, count: videos)) }
        if exact > 0 { rows.append(CategoryCount(category: .exactDuplicates, count: exact)) }
        if similar > 0 { rows.append(CategoryCount(category: .similarPhotos, count: similar)) }
        if photos > 0 { rows.append(CategoryCount(category: .photos, count: photos)) }
        self.breakdown = rows
    }
}

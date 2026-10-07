import Foundation

/// One photo in a swipe session: the asset plus the little bit of context the swipe screen
/// shows under the counter. Built from the scanned catalog (the general library) — never
/// from a fresh library read or a re-analysis — so the session presents exactly the photos
/// the app has already read on this iPhone.
struct SwipeReviewItem: Sendable, Equatable, Identifiable {
    let assetID: String
    let groupKind: PhotoSimilarityGroupKind
    /// 1-based position of the item's group among the groups presented this session, so the
    /// context line can say "group 3" without re-deriving ordering at render time. Ignored
    /// for library items (see `isLibraryItem`).
    let groupOrdinal: Int
    /// Whether this asset is the group's recommended KEEP — the same fact the grid's Best
    /// badge shows, surfaced so a swipe toward Delete is an informed, deliberate override.
    /// Library items are never recommendations.
    let isRecommended: Bool
    /// `true` when the item came from the general photo library deck (the standalone Swipe
    /// Review feature) rather than an analysis group; drives the context line under the
    /// counter and keeps group fields out of the library presentation path.
    var isLibraryItem: Bool = false

    var id: String { assetID }
}

/// Everything the swipe-review screen renders, as data: the session's item order and every
/// user-facing string. Kept out of the view so ordering, counts, and copy are unit-testable
/// without rendering, and so the view contains layout rather than logic.
enum SwipeReviewPresentation {
    // MARK: Entry point

    /// The top-level Swipe Review entry: the dashboard card that opens this feature
    /// directly, independent of Similar Photos.
    static let entryLabel = "Swipe Review"
    static let entryAccessibilityID = "swipeReviewButton"

    // MARK: Screen chrome

    static let title = "Swipe Review"

    /// Accessibility identifiers (stable for UI tests).
    static let cardAccessibilityID = "swipeReviewCard"
    static let keepAccessibilityID = "swipeKeepButton"
    static let deleteAccessibilityID = "swipeDeleteButton"
    static let undoAccessibilityID = "swipeUndoButton"
    static let reviewCleanupAccessibilityID = "swipeReviewCleanupButton"
    static let doneAccessibilityID = "swipeDoneButton"

    // MARK: Decisions

    /// Visible decision buttons — the arrows mirror the gesture direction they stand for, so
    /// the buttons read as an equivalent of swiping rather than a separate control.
    static let deleteButtonTitle = "← Delete"
    static let keepButtonTitle = "Keep →"
    static let deleteAccessibilityLabel = "Delete"
    static let keepAccessibilityLabel = "Keep"

    static let undoButtonTitle = "Undo"

    /// In-card labels shown while a finger is dragging: right = keep, left = delete.
    static let keepIndicatorLabel = "KEEP"
    static let deleteIndicatorLabel = "DELETE"

    /// Horizontal drag (points) required to commit a decision. Deliberately below half a
    /// card-width flick and above the accidental-jitter band.
    static let commitThreshold: CGFloat = 80
    /// Drag distance over which the KEEP/DELETE indicator ramps to full opacity.
    static let indicatorRampWidth: CGFloat = 140

    // MARK: Counts and context copy

    /// "12 of 47" — the visible position counter.
    static func positionText(current: Int, total: Int) -> String {
        "\(current) of \(total)"
    }

    /// "Photo 12 of 47" — the VoiceOver reading of the counter.
    static func positionAccessibilityLabel(current: Int, total: Int) -> String {
        "Photo \(current) of \(total)"
    }

    /// "47 photos reviewed" / "1 photo reviewed".
    static func reviewedCountText(_ count: Int) -> String {
        count == 1 ? "1 photo reviewed" : "\(count) photos reviewed"
    }

    /// "5 photos selected for cleanup" / "1 photo selected for cleanup".
    static func selectedForCleanupText(_ count: Int) -> String {
        count == 1
            ? "1 photo selected for cleanup"
            : "\(count) photos selected for cleanup"
    }

    /// Context under the counter — the kind label the sections already use plus the group's
    /// ordinal for grouped items; "Your photo library" for the standalone library deck.
    static func groupContext(for item: SwipeReviewItem) -> String {
        guard !item.isLibraryItem else { return libraryContext }
        return "\(kindLabel(item.groupKind)) · group \(item.groupOrdinal)"
    }

    static let libraryContext = "Your photo library"

    static func kindLabel(_ kind: PhotoSimilarityGroupKind) -> String {
        switch kind {
        case .exactDuplicates: return "Exact duplicate"
        case .nearDuplicates: return "Similar photo"
        }
    }

    static let recommendedLabel = "Recommended keep"

    // MARK: Completion

    static let completionTitle = "You're all caught up."
    static let completionPrimaryTitle = "Review Cleanup"
    static let completionSecondaryTitle = "Done"

    /// The completion state's primary action target: the *existing* Review flow
    /// (`ReviewSelectionView`, which enters through `reviewDidAppear(from: .similarPhotos)`).
    /// Swipe Review never builds its own deletion surface — it only hands the (already
    /// existing) selection to the same review screen the bottom Review button pushes.
    enum CompletionDestination: Equatable {
        case existingReviewFlow
        case dismissToSimilarPhotos
    }

    static let completionPrimaryDestination: CompletionDestination = .existingReviewFlow
    static let completionSecondaryDestination: CompletionDestination = .dismissToSimilarPhotos

    // MARK: Session order

    /// The standalone feature's deck: every image in the scanned catalog, in catalog order —
    /// the general photo library exactly as Netto has read it. No analysis, no similarity
    /// groups, no per-session filtering: Swipe Review runs directly off the existing catalog
    /// data source, so it is available whenever a scan exists, regardless of analysis.
    static func items(from catalog: CatalogScanResult) -> [SwipeReviewItem] {
        catalog.records.lazy.filter(\.isImage).map { record in
            SwipeReviewItem(
                assetID: record.localIdentifier,
                groupKind: .nearDuplicates,
                groupOrdinal: 0,
                isRecommended: false,
                isLibraryItem: true
            )
        }
    }

    /// The analysis-group deck: exact groups first, then similar groups (the order the
    /// results list renders), each group's members in their declared order, and an asset
    /// that appears in more than one group presented only once (first group wins) so a
    /// session can never show the same photo twice.
    ///
    /// This is the group-based order the tests and the SwiftUI preview exercise; the
    /// standalone feature's runtime deck is the catalog builder above.
    static func items(from result: PhotoAnalysisResult) -> [SwipeReviewItem] {
        var items: [SwipeReviewItem] = []
        var presented = Set<String>()
        var ordinal = 0

        for group in result.exactGroups + result.similarGroups {
            ordinal += 1
            for assetID in group.memberAssetIDs {
                guard presented.insert(assetID).inserted else { continue }
                items.append(
                    SwipeReviewItem(
                        assetID: assetID,
                        groupKind: group.kind,
                        groupOrdinal: ordinal,
                        isRecommended: group.recommendedBestAssetID == assetID
                    )
                )
            }
        }
        return items
    }
}

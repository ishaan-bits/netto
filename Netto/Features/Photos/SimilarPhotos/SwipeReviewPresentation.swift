import Foundation

/// One photo in a swipe session: the asset plus the little bit of context the swipe screen
/// shows under the counter. Built from the scanned catalog (the general library) — never
/// from a fresh library read or a re-analysis — so the session presents exactly the photos
/// the app has already read on this iPhone.
struct SwipeReviewItem: Sendable, Equatable, Identifiable, Codable {
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

    // MARK: Shuffle and new pass

    static let shuffleButtonTitle = "Shuffle"
    static let shuffleAccessibilityID = "swipeShuffleButton"
    static let shuffleAccessibilityLabel = "Shuffle the photos you have not reviewed yet"

    /// "Start New Pass" on the completion screen: reshuffle the whole deck (picking up newly
    /// scanned photos for a library session) and review again. Decisions are never touched —
    /// a new pass re-orders the deck and resets the cursor and undo stack, nothing else.
    static let newPassButtonTitle = "Start New Pass"
    static let newPassAccessibilityID = "swipeNewPassButton"

    /// Shuffle is only meaningful when at least two unreviewed photos remain — with one (or
    /// none) there is nothing to re-order, so the button sits visibly disabled instead of
    /// pretending to do something.
    static func shuffleEnabled(remaining: Int) -> Bool {
        remaining > 1
    }

    /// Unreviewed photos still to decide — the Shuffle button's gate and the honest
    /// denominator behind it. O(1); never a deck filter.
    static func remainingCount(cursor: Int, total: Int) -> Int {
        max(0, total - cursor)
    }

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

    // MARK: Persistent review bar (while swiping)

    /// The live count line in the persistent bottom area — the same copy the completion
    /// screen shows, so "N photos selected for cleanup" reads identically everywhere.
    static let selectedCountAccessibilityID = "swipeSelectedCountLabel"

    /// Whether the "Review Cleanup" affordance is actionable. It gates *both* the persistent
    /// bar's button and the completion screen's primary button: with nothing marked for
    /// cleanup there is nothing to review, so the control is present but clearly unavailable
    /// instead of opening an empty review.
    static func reviewCleanupEnabled(selectedCount: Int) -> Bool {
        selectedCount > 0
    }

    /// The completion state's primary action target: the *editable* cleanup flow. Swipe
    /// Review never deletes on its own — it hands the session's Delete marks to
    /// `SwipeCleanupSelectionView`, which scoping-checks them and then enters the same
    /// `ReviewSelectionView` → plan → confirmation → PhotoKit pipeline every other feature
    /// uses.
    enum CompletionDestination: Equatable {
        case editableCleanup
        case dismissToSimilarPhotos
    }

    static let completionPrimaryDestination: CompletionDestination = .editableCleanup
    static let completionSecondaryDestination: CompletionDestination = .dismissToSimilarPhotos

    // MARK: Editable Review Cleanup (session-scoped)

    /// The cleanup screen: every photo this session marked Delete, selectable before the
    /// existing review pipeline is entered.
    static let cleanupTitle = "Review Cleanup"
    static let cleanupScreenAccessibilityID = "swipeCleanupScreen"
    static let cleanupSelectedCountAccessibilityID = "swipeCleanupSelectedCount"
    static let selectAllTitle = "Select All"
    static let deselectAllTitle = "Deselect All"
    static let selectAllAccessibilityID = "swipeCleanupSelectAllButton"
    static let deselectAllAccessibilityID = "swipeCleanupDeselectAllButton"
    static let cleanupReviewAccessibilityID = "swipeCleanupReviewButton"

    /// Per-row identifier — stable for tests and UI automation without embedding a count.
    static func cleanupRowAccessibilityID(_ assetID: String) -> String {
        "swipeCleanupRow-\(assetID)"
    }

    static let cleanupEmptyMessage =
        "Photos you mark Delete show up here. Swipe left on a photo to mark it for cleanup."
    static let keepExclusionNote = "Photos you kept are never shown here."
    static let confirmNote =
        "Nothing is deleted until you confirm the deletion on the next screen."

    /// "7 of 12 selected" — the live count over the cleanup screen's candidates.
    static func selectedOfTotalText(selected: Int, total: Int) -> String {
        "\(selected) of \(total) selected"
    }

    /// "Review 12 Photos" / "Review 1 Photo" — the handoff button into the existing review.
    static func reviewButtonTitle(_ count: Int) -> String {
        "Review \(count) \(count == 1 ? "Photo" : "Photos")"
    }

    /// The cleanup screen's candidate list, in deck order: exactly the photos this session
    /// decided "Delete" that are *still* marked in the shared selection and still present in
    /// the catalog. Photos decided "Keep" are excluded by the decision check; photos never
    /// reviewed (e.g. group members merely carrying the default selection) are excluded the
    /// same way; `availableAssetIDs` drops assets deleted or unavailable since the deck was
    /// built. `nil` availability means "no catalog to reconcile against" — no filtering.
    static func cleanupCandidates(
        items: [SwipeReviewItem],
        decisions: [String: SwipeReviewDecision],
        selection: PhotoSelectionModel,
        availableAssetIDs: Set<String>? = nil
    ) -> [SwipeReviewItem] {
        items.filter { item in
            guard decisions[item.assetID] == .delete, selection.isSelected(item.assetID) else {
                return false
            }
            return availableAssetIDs?.contains(item.assetID) ?? true
        }
    }

    /// Whether a deck should be constructed right now: only when no explicit deck was
    /// supplied *and* the session has none. Called from the screen's appear and catalog-change
    /// paths — once those checks say no (the normal state for an in-flight or finished
    /// session), no work runs, so repeated renders of a 30,000-photo library never rebuild,
    /// re-sort, or re-filter the deck.
    static func shouldInstallDeck(presetItemsSupplied: Bool, sessionIsEmpty: Bool) -> Bool {
        !presetItemsSupplied && sessionIsEmpty
    }

    /// Reconciles a persisted snapshot against the catalog as it is *now* before the session
    /// adopts it: photos deleted or no longer visible since the deck was built leave the deck
    /// (with the cursor keeping its position *relative to the photos that remain*), their
    /// stale history entries and decisions drop with them, and a session whose deck vanished
    /// entirely reads as no session. `nil` availability means no completed catalog to
    /// reconcile against — the snapshot is adopted untouched.
    ///
    /// Newly added photos never sneak into an in-flight deck (they join on Start New Pass,
    /// which rebuilds a library deck from the current catalog).
    static func reconciled(
        _ snapshot: SwipeReviewSessionSnapshot,
        availableAssetIDs: Set<String>?
    ) -> SwipeReviewSessionSnapshot? {
        guard let availableAssetIDs else {
            return snapshot.items.isEmpty ? nil : snapshot
        }
        var kept: [SwipeReviewItem] = []
        kept.reserveCapacity(snapshot.items.count)
        var keptCursor = 0
        for (index, item) in snapshot.items.enumerated() {
            guard availableAssetIDs.contains(item.assetID) else { continue }
            if index < snapshot.cursor { keptCursor += 1 }
            kept.append(item)
        }
        guard !kept.isEmpty else { return nil }
        var reconciled = snapshot
        reconciled.items = kept
        reconciled.cursor = keptCursor
        reconciled.history = snapshot.history.filter { availableAssetIDs.contains($0.assetID) }
        reconciled.decisions = snapshot.decisions.filter {
            availableAssetIDs.contains($0.key)
        }
        return reconciled
    }

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

    // MARK: Thumbnail prefetch (M14/M15)

    /// The swipe card's **final** frame: the screen-sized local thumbnail (M15). The card
    /// box is 340 pt tall and a screen-width box is ~353 pt wide, so 1 080 px on the
    /// longest side covers the rendered size at 3x — the photo on screen is this
    /// rendition, never an upscale of something smaller, and never the full-resolution
    /// original (never a network fetch either: local rendition or an honest unavailable).
    static let swipeThumbnailPixelSize = 1_080

    /// The temporary, low-resolution frame (M15): shown only while the screen-sized
    /// thumbnail for the same photo is still being prepared, and replaced by it the moment
    /// it lands. Never treated as the final sharp image. Prefetched ahead for the whole
    /// window because it is small (~0.9 MB) and arrives fastest.
    static let swipeThumbnailLowResPixelSize = 480

    /// How many upcoming photos get their **screen-sized** thumbnail warmed ahead of the
    /// cursor — "the current image and the next few images" — on top of the low-resolution
    /// tier that covers the whole window. Five at ~3.5–4.5 MB keeps the two tiers together
    /// inside the shared `ThumbnailStore`'s byte budget (48 MB) alongside the strip's
    /// entries; farther cards show their (warm) low-resolution frame while their
    /// screen-sized thumbnail loads on demand, still local-only.
    static let swipeSharpPrefetchCount = 5

    /// How many upcoming photos to warm at all: the current one plus this forward window.
    /// The low-resolution tier covers every one of them; the screen-sized tier covers the
    /// first `swipeSharpPrefetchCount`. Bounds the request count per window re-walk.
    static let swipePrefetchWindowCount = 20

    /// The warm-up order for a swipe at `index`: the current photo first (it is on screen
    /// now), then the forward window. Never backward — reviewed photos sit behind the
    /// cursor and only Undo returns there, and the store's LRU keeps recently shown frames
    /// anyway. Clamps at both ends; an empty deck is an empty order.
    static func prefetchOrder(around index: Int, in assetIDs: [String]) -> [String] {
        guard !assetIDs.isEmpty, index >= 0 else { return [] }
        let start = min(index, assetIDs.count - 1)
        let end = min(start + swipePrefetchWindowCount, assetIDs.count)
        return Array(assetIDs[start..<end])
    }
}

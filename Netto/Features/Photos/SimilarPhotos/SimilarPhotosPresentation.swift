import CoreGraphics
import Foundation

/// Everything the review screen can be showing, derived — never stored.
///
/// One pure function maps (permission, catalog, analysis) to a phase, so every state the UI
/// renders is testable without a view and cannot drift from the underlying state machines.
enum SimilarPhotosPhase: Sendable, Equatable {
    /// Photos access has never been requested.
    case permissionRequired
    /// Photos access is off (denied or restricted) — only Settings can fix it.
    case permissionDenied
    /// A standalone catalog build is running (started from the dashboard).
    case buildingCatalog(CatalogScanProgress)
    /// Similarity analysis is running, including its internal catalog read (reported as the
    /// `preparing` stage).
    case analyzing(PhotoAnalysisProgress)
    /// An interrupted run (analysis or its catalog stage) saved its progress and can be
    /// continued. `stage` is the saved stage line, `fraction` the bar at the pause — shown
    /// as paused, never as a live scan, and never with an ETA.
    case paused(stage: String, fraction: Double?)
    /// Analysis finished; groups are available (possibly none).
    case results(PhotoAnalysisResult)
    /// Permission is fine, nothing has been run yet.
    case idle
    /// The library visible to Netto is empty.
    case emptyLibrary
    /// The last run was cancelled.
    case cancelled
    /// The last run failed; carries the user-facing message.
    case failed(String)
}

/// The in-screen group-kind filter on the unified Duplicate & Similar Photos result (M14).
/// One result set, one selection model — the filter only narrows which sections are listed,
/// never re-runs, re-selects, or fabricates groups.
enum SimilarPhotosGroupFilter: String, CaseIterable, Sendable, Equatable, Identifiable {
    case all
    case exact
    case similar

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: return "All"
        case .exact: return "Exact"
        case .similar: return "Similar"
        }
    }

    var showsExact: Bool {
        switch self {
        case .all, .exact: return true
        case .similar: return false
        }
    }

    var showsSimilar: Bool {
        switch self {
        case .all, .similar: return true
        case .exact: return false
        }
    }
}

enum SimilarPhotosPresentation {
    /// The single permission → catalog → analysis → phase mapping.
    ///
    /// Ordering rules:
    /// 1. Permission gates everything — a completed result from an earlier grant must not
    ///    render if access has since been revoked.
    /// 2. A running analysis wins over everything else: it is what the user is waiting on.
    /// 3. Then a running catalog build (it is a prerequisite step in progress).
    /// 4. Then analysis outcomes, then catalog outcomes, then the resting states.
    static func phase(
        permission: PermissionState,
        catalog: CatalogScanState,
        analysis: PhotoAnalysisState
    ) -> SimilarPhotosPhase {
        switch permission {
        case .notDetermined:
            return .permissionRequired
        case .denied, .restricted:
            return .permissionDenied
        case .authorized, .limited:
            break
        }

        if case .running(let progress) = analysis {
            return .analyzing(progress)
        }
        if case .running(let progress) = catalog {
            return .buildingCatalog(progress)
        }

        switch analysis {
        case .completed(let result):
            // A run over a zero-record catalog means nothing was visible, not "no duplicates".
            return result.totalRecordCount == 0 ? .emptyLibrary : .results(result)
        case .cancelled:
            return .cancelled
        case .failed(let failure):
            return .failed(failure.userMessage)
        case .paused(let progress):
            return .paused(
                stage: stageMessage(for: progress),
                fraction: barFraction(for: progress)
            )
        case .notStarted, .running:
            break
        }

        switch catalog {
        case .failed(let failure):
            return .failed(failure.userMessage)
        case .cancelled:
            return .cancelled
        case .paused(let progress):
            return .paused(
                stage: DashboardPresentation.catalogStage(progress),
                fraction: DashboardPresentation.catalogFraction(progress)
            )
        case .completed(let result):
            return result.isEmpty ? .emptyLibrary : .idle
        case .notStarted, .running:
            return .idle
        }
    }

    /// Limited access still shows usable results — but the UI must say that only the photos the
    /// user granted are considered, so "nothing found" is never read as "nothing exists".
    static func showsLimitedAccessNotice(permission: PermissionState) -> Bool {
        permission == .limited
    }

    /// The "nothing to review" message. Only items the analysis actually ran over are counted:
    /// unavailable assets could not be analyzed (the notice naming them shows alongside) and
    /// skipped assets had no candidate partner, so folding either into an "Analyzed N" claim
    /// would overstate coverage.
    static func noDuplicatesMessage(result: PhotoAnalysisResult) -> String {
        let analyzed = result.effectiveAnalyzedCount
        guard analyzed > 0 else {
            if result.unavailableAssets.isEmpty, result.skippedNoCandidateCount > 0 {
                return "Every item was the only candidate in its group, so there is nothing marked for cleanup."
            }
            return "None of the items in this scan could be analyzed, so there is nothing marked for cleanup."
        }
        let skippedNote = result.skippedNoCandidateCount > 0
            ? " \(result.skippedNoCandidateCount) more had no similar candidates to compare."
            : ""
        return "Analyzed \(analyzed) items — every one is distinct, so there is nothing marked for cleanup.\(skippedNote)"
    }

    /// Honest, clamped progress for the determinate bar. `nil` for stages without a meaningful
    /// total — the UI then shows an indeterminate indicator instead of a fabricated percentage.
    static func barFraction(for progress: PhotoAnalysisProgress) -> Double? {
        progress.fraction.map { min(max($0, 0), 1) }
    }

    /// Whether the global "Deselect All" control should be on screen.
    ///
    /// Shown only while at least one photo is selected: a zero selection has nothing to
    /// clear, so the action would just be a confusing control that does nothing.
    static func showsDeselectAll(selectedCount: Int) -> Bool {
        selectedCount > 0
    }

    /// The actions the top selection toolbar exposes, in menu order, with their exact
    /// user-facing labels.
    ///
    /// Deliberately **not** including "Select All": Netto's cleanup workflow never bulk-marks
    /// photos for deletion, so the toolbar offers only clearing and restoring. The view
    /// builds its menu from this list, so what is tested here is what ships.
    enum SelectionToolbarAction: String, CaseIterable, Sendable, Equatable {
        case deselectAll = "Deselect All"
        case resetToRecommended = "Reset to Recommended"
    }

    static let selectionToolbarActions: [SelectionToolbarAction] = [.deselectAll, .resetToRecommended]

    /// Visibility per toolbar action: "Deselect All" only while there is something to clear;
    /// "Reset to Recommended" stays available whenever a recommended selection exists (a
    /// no-op when the selection already equals it).
    static func shows(_ action: SelectionToolbarAction, selectedCount: Int) -> Bool {
        switch action {
        case .deselectAll:
            return showsDeselectAll(selectedCount: selectedCount)
        case .resetToRecommended:
            return true
        }
    }

    /// Stable accessibility identifier per toolbar action (for UI tests).
    static func selectionActionIdentifier(_ action: SelectionToolbarAction) -> String {
        switch action {
        case .deselectAll:
            return "deselectAllButton"
        case .resetToRecommended:
            return "resetToRecommendedButton"
        }
    }

    /// The top toolbar's menu label — selection-specific by design.
    ///
    /// "Actions" was rejected: this screen's primary action is Review (cleanup/deletion
    /// review), so a generic "Actions" menu would collide with that hierarchy. "Selection"
    /// reads as secondary management of the current selection, which is exactly what it is.
    static let selectionToolbarMenuLabel = "Selection"

    /// VoiceOver value for the selection menu: "Selection, 234 photos selected".
    static func selectionToolbarAccessibilityValue(selectedCount: Int) -> String {
        selectedCount == 1 ? "1 photo selected" : "\(selectedCount) photos selected"
    }

    /// The bottom bar's primary action — the screen's dominant call-to-action, kept
    /// distinct from the selection menu so the hierarchy stays explicit: Review is primary;
    /// Selection → Deselect All / Reset to Recommended is secondary.
    static let primaryReviewActionLabel = "Review"

    /// User-facing copy per analysis stage. Kept here so the same wording is used everywhere the
    /// stage is shown and is unit-testable.
    static func stageMessage(for progress: PhotoAnalysisProgress) -> String {
        switch progress.stage {
        case .preparing:
            return progress.totalUnits > 0
                ? "Reading \(progress.completedUnits) of \(progress.totalUnits) assets…"
                : "Preparing…"
        case .generatingCandidates:
            return "Finding candidate groups…"
        case .fingerprinting:
            return progress.totalUnits > 0
                ? "Fingerprinting \(progress.completedUnits) of \(progress.totalUnits)…"
                : "Fingerprinting…"
        case .extractingFeatures:
            return progress.totalUnits > 0
                ? "Analyzing \(progress.completedUnits) of \(progress.totalUnits) images…"
                : "Analyzing image features…"
        case .comparing:
            return progress.totalUnits > 0
                ? "Comparing \(progress.completedUnits) of \(progress.totalUnits) groups…"
                : "Comparing…"
        case .grouping:
            return "Grouping matches…"
        case .finalizing:
            return "Finalizing…"
        }
    }

    // MARK: Photo Details preview

    /// Pixel budget for the large Photo Details preview and its full-screen viewer: one
    /// rendition of ~1000–1500 px on the long side, device-scale independent. Enough to
    /// inspect detail without ever decoding full-resolution pixels into memory.
    static let previewTargetPixelSize = 1_400

    /// Height of the preview box on the detail sheet. The *image* inside is aspect-fit
    /// (never cropped) and letterboxes against the box's dark background, so the box adapts
    /// to the asset's aspect ratio instead of forcing a square crop.
    static let previewBoxHeight: CGFloat = 340

    /// Loading headline for the preview skeleton.
    static let previewLoadingMessage = "Loading photo…"

    /// Failure headline shown in place of the preview.
    static let previewUnavailableTitle = "Photo unavailable"

    /// User-facing preview failure copy. PhotoKit's vocabulary stays distinct — "only in
    /// iCloud", "no longer in the library", and "Photos access is off" are different problems
    /// for the user — and every state is retryable: the preview request is uncached, so
    /// "Try Again" issues a fresh load instead of replaying a poisoned cache entry.
    static func previewUnavailableMessage(for error: PhotoContentError) -> String {
        switch error {
        case .onlyInICloud:
            return "This photo is only in iCloud and couldn't be downloaded right now. Check your connection and tap Try Again."
        case .assetNotFound:
            return "This photo is no longer in your library, so Netto can't show it."
        case .permissionDenied:
            return "Photos access is off. Enable it in Settings to view this photo."
        case .unavailable:
            return "Netto couldn't load this photo on this iPhone. Tap Try Again."
        }
    }

    /// Failure symbol per preview error — the same distinction the copy makes, in icon form.
    static func previewFailureSymbol(for error: PhotoContentError) -> String {
        switch error {
        case .onlyInICloud: return "icloud.and.arrow.down"
        case .assetNotFound: return "photo.badge.exclamationmark"
        case .permissionDenied: return "lock.shield"
        case .unavailable: return "exclamationmark.triangle"
        }
    }
}

/// Countable facts about a finished run, computed once from the result.
struct SimilarPhotosSummary: Sendable, Equatable {
    /// Kept only so `groupedAssetCount` can stay lazy: the dashboard card never reads it, and
    /// `totalGroupedAssetCount` allocates Sets over every grouped member — O(library) work
    /// that must not run inside an unrelated card's render.
    let result: PhotoAnalysisResult

    let exactGroupCount: Int
    let similarGroupCount: Int
    let unavailableCount: Int
    /// Assets never requested because no candidate partner could exist — honest "not analyzed"
    /// without pretending anything failed.
    let skippedCount: Int
    let totalRecords: Int
    /// Items with evidence this run (or, for legacy results, everything not unavailable).
    let analyzedCount: Int

    init(result: PhotoAnalysisResult) {
        self.result = result
        exactGroupCount = result.exactGroups.count
        similarGroupCount = result.similarGroups.count
        unavailableCount = result.unavailableAssets.count
        skippedCount = result.skippedNoCandidateCount
        totalRecords = result.totalRecordCount
        analyzedCount = result.effectiveAnalyzedCount
    }

    /// Assets involved in any group. Computed on read (not in `init`) so constructing a
    /// summary — which the dashboard does every render — never walks the grouped members.
    var groupedAssetCount: Int { result.totalGroupedAssetCount }

    /// No groups at all — the "nothing to review" result state.
    var hasNoGroups: Bool { exactGroupCount == 0 && similarGroupCount == 0 }

    /// Items the analysis did not produce evidence for — unavailable (failed, reported) plus
    /// skipped (no partner, reported): never folded into an "Analyzed N" claim.
    var notAnalyzedCount: Int { unavailableCount + skippedCount }
}

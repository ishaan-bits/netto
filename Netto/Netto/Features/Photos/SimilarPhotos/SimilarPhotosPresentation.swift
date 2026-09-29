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
        case .notStarted, .running:
            break
        }

        switch catalog {
        case .failed(let failure):
            return .failed(failure.userMessage)
        case .cancelled:
            return .cancelled
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

    /// Honest, clamped progress for the determinate bar. `nil` for stages without a meaningful
    /// total — the UI then shows an indeterminate indicator instead of a fabricated percentage.
    static func barFraction(for progress: PhotoAnalysisProgress) -> Double? {
        progress.fraction.map { min(max($0, 0), 1) }
    }

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
}

/// Countable facts about a finished run, computed once from the result.
struct SimilarPhotosSummary: Sendable, Equatable {
    let exactGroupCount: Int
    let similarGroupCount: Int
    let groupedAssetCount: Int
    let unavailableCount: Int

    init(result: PhotoAnalysisResult) {
        exactGroupCount = result.exactGroups.count
        similarGroupCount = result.similarGroups.count
        groupedAssetCount = result.totalGroupedAssetCount
        unavailableCount = result.unavailableAssets.count
    }

    /// No groups at all — the "nothing to review" result state.
    var hasNoGroups: Bool { exactGroupCount == 0 && similarGroupCount == 0 }
}

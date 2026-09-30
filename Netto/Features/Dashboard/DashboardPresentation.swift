import Foundation

/// Every value the dashboard renders, derived — never stored and never invented in the view.
///
/// The dashboard is a read surface: permission, catalog, analysis, contact, and storage state
/// are mapped here to exactly what each block shows, so the whole screen is testable without
/// rendering it.
enum DashboardPresentation {
    /// What the primary library button should do right now.
    ///
    /// Kept separate from `ScanStatus` (below): this is the *action* derivation, pinned by
    /// `DashboardFlowTests`; `ScanStatus` is the *copy* derivation the scan card renders.
    enum LibraryAction: Equatable {
        case requestAccess
        case openSettings
        case analyze
        case analyzing(stage: String, fraction: Double?)
        /// A standalone catalog build started from the dashboard is running.
        case catalogRunning(stage: String, fraction: Double?)
        case retry(message: String)
    }

    static func libraryAction(
        permission: PermissionState,
        catalog: CatalogScanState,
        analysis: PhotoAnalysisState
    ) -> LibraryAction {
        switch permission {
        case .notDetermined:
            return .requestAccess
        case .denied, .restricted:
            return .openSettings
        case .authorized, .limited:
            break
        }

        if case .running(let progress) = analysis {
            return .analyzing(
                stage: SimilarPhotosPresentation.stageMessage(for: progress),
                fraction: progress.fraction
            )
        }

        if case .failed(let failure) = analysis {
            return .retry(message: failure.userMessage)
        }

        if case .running(let progress) = catalog {
            return .catalogRunning(
                stage: catalogStage(progress),
                fraction: catalogFraction(progress)
            )
        }

        return .analyze
    }

    // MARK: Storage hero

    static func heroFraction(_ snapshot: StorageSnapshot?) -> Double? {
        guard let snapshot, snapshot.isAvailable else { return nil }
        return snapshot.usedFraction
    }

    // MARK: Catalog stage copy

    static func catalogStage(_ progress: CatalogScanProgress) -> String {
        progress.totalCount > 0
            ? "Reading \(progress.enumeratedCount) of \(progress.totalCount) assets…"
            : "Counting assets…"
    }

    /// `nil` while the asset total is unknown, so the bar runs indeterminate instead of
    /// displaying a percentage that was never measured.
    static func catalogFraction(_ progress: CatalogScanProgress) -> Double? {
        guard progress.totalCount > 0 else { return nil }
        return min(max(progress.fraction, 0), 1)
    }

    // MARK: Scan status card

    /// What the unified scan card is showing. Cases are *states*, not copy — the copy lives in
    /// `scanCopy(for:)` so it can be read and tested without a view.
    enum ScanStatus: Equatable, Sendable {
        case permissionRequired
        case permissionDenied
        case scanning(stage: String, fraction: Double?)
        case idle
        case finished(analyzed: Int, total: Int, groups: Int)
        case cancelled
        case emptyLibrary
        case failed(String)
    }

    enum ScanTone: Equatable, Sendable {
        case brand
        case success
        case warning
        case failure
        case muted
    }

    struct ScanCopy: Equatable, Sendable {
        let icon: String
        let title: String
        let body: String
        let buttonTitle: String?
        let tone: ScanTone
    }

    static func scanStatus(
        permission: PermissionState,
        catalog: CatalogScanState,
        analysis: PhotoAnalysisState
    ) -> ScanStatus {
        switch libraryAction(permission: permission, catalog: catalog, analysis: analysis) {
        case .requestAccess:
            return .permissionRequired
        case .openSettings:
            return .permissionDenied
        case .analyzing(let stage, let fraction):
            return .scanning(stage: stage, fraction: fraction)
        case .catalogRunning(let stage, let fraction):
            return .scanning(stage: stage, fraction: fraction)
        case .retry(let message):
            return .failed(message)
        case .analyze:
            break
        }

        switch analysis {
        case .completed(let result):
            guard result.totalRecordCount > 0 else { return .emptyLibrary }
            let analyzed = max(0, result.totalRecordCount - result.unavailableAssets.count)
            let groups = result.exactGroups.count + result.similarGroups.count
            return .finished(analyzed: analyzed, total: result.totalRecordCount, groups: groups)
        case .cancelled:
            return .cancelled
        case .notStarted, .running, .failed:
            break
        }

        switch catalog {
        case .completed(let result):
            return result.isEmpty ? .emptyLibrary : .idle
        case .failed(let failure):
            return .failed(failure.userMessage)
        case .notStarted, .cancelled, .running:
            return .idle
        }
    }

    static func scanCopy(for status: ScanStatus) -> ScanCopy {
        switch status {
        case .permissionRequired:
            return ScanCopy(
                icon: "photo.on.rectangle.angled",
                title: "Photos access needed",
                body: "Netto reads your photo library on this iPhone to find duplicates, "
                    + "similar shots, screenshots, and large videos. Images never leave "
                    + "your device.",
                buttonTitle: "Allow Photos access",
                tone: .brand
            )

        case .permissionDenied:
            return ScanCopy(
                icon: "lock.shield",
                title: "Photos access is off",
                body: "Grant Photos access in Settings to analyze your library. Netto only "
                    + "reads on this iPhone — images never leave your device.",
                buttonTitle: "Open Settings",
                tone: .warning
            )

        case .scanning(let stage, _):
            return ScanCopy(
                icon: "arrow.triangle.2.circlepath",
                title: "Scanning your library",
                body: stage,
                buttonTitle: "Cancel",
                tone: .brand
            )

        case .idle:
            return ScanCopy(
                icon: "play.circle",
                title: "Ready when you are",
                body: "Runs entirely on this iPhone. You review every group before anything "
                    + "changes — nothing is deleted without your confirmation.",
                buttonTitle: "Analyze my library",
                tone: .brand
            )

        case .finished(let analyzed, let total, let groups):
            let outcome = groups > 0
                ? "Results are ready to review."
                : "There is nothing marked for cleanup."
            return ScanCopy(
                icon: "checkmark.circle",
                title: "Last scan finished",
                body: "\(analyzed) of \(total) items analyzed. \(outcome)",
                buttonTitle: "Analyze again",
                tone: .success
            )

        case .cancelled:
            return ScanCopy(
                icon: "arrow.counterclockwise",
                title: "Scan cancelled",
                body: "Nothing was changed. Start again whenever you're ready.",
                buttonTitle: "Start again",
                tone: .muted
            )

        case .emptyLibrary:
            return ScanCopy(
                icon: "photo.badge.exclamationmark",
                title: "No photos visible to Netto",
                body: "There is nothing to analyze. If you granted limited access, choose the "
                    + "photos Netto can see in Settings.",
                buttonTitle: nil,
                tone: .warning
            )

        case .failed(let message):
            return ScanCopy(
                icon: "exclamationmark.triangle",
                title: "Scan couldn't finish",
                body: message,
                buttonTitle: "Try again",
                tone: .failure
            )
        }
    }
}

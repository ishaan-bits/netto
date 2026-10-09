import Foundation

/// Everything the Potentially Blurry screen can be showing — derived, never stored.
///
/// This feature needs a completed *catalog* (to know which records exist) plus its own
/// sharpness pass over that catalog's images. It never waits on similarity analysis: the
/// two passes are independent reads of the same completed catalog.
enum PotentiallyBlurryPhase: Sendable, Equatable {
    /// Photos access has never been requested.
    case permissionRequired
    /// Photos access is off (denied or restricted) — only Settings can fix it.
    case permissionDenied
    /// A catalog build is running.
    case buildingCatalog(CatalogScanProgress)
    /// Permission is fine but no catalog exists yet (or the last build was cancelled).
    case scanRequired
    /// The last catalog build failed; carries the user-facing message.
    case catalogFailed(String)
    /// The catalog is complete but the sharpness pass has never run (or was superseded
    /// by a rebuild).
    case notStarted
    /// The sharpness pass is running.
    case analyzing(BlurAnalysisProgress)
    /// The last sharpness pass was cancelled.
    case cancelled
    /// The last sharpness pass failed; carries the user-facing message.
    case failed(String)
    /// The catalog is complete and contains no images at all.
    case emptyLibrary
    /// The sharpness pass ran over an image library and produced no candidates.
    case noCandidates(BlurAnalysisResult)
    /// The candidate grid — every photo that scored below the sharp threshold.
    case results(BlurAnalysisResult)
}

/// The review tabs over a completed result's candidates. Counts are derived from the
/// result on every render — never stored — so a re-run's new totals replace the old.
enum BlurReviewTab: String, CaseIterable, Sendable, Equatable {
    case all
    case likelyBlurry
    case borderline

    var title: String {
        switch self {
        case .all: return "All Flagged"
        case .likelyBlurry: return "Likely Blurry"
        case .borderline: return "Borderline"
        }
    }

    /// The candidates this tab shows, in the result's own order.
    func candidates(in result: BlurAnalysisResult) -> [BlurCandidate] {
        switch self {
        case .all:
            return result.candidates
        case .likelyBlurry:
            return result.candidates.filter { $0.verdict == .likelyBlurry }
        case .borderline:
            return result.candidates.filter { $0.verdict == .borderline }
        }
    }
}

enum PotentiallyBlurryPresentation {
    /// The single permission → catalog → blur-analysis phase mapping. Similarity analysis
    /// state never participates: a duplicate scan running or failed in the background
    /// changes nothing here.
    static func phase(
        permission: PermissionState,
        catalog: CatalogScanState,
        blur: BlurAnalysisState
    ) -> PotentiallyBlurryPhase {
        switch permission {
        case .notDetermined:
            return .permissionRequired
        case .denied, .restricted:
            return .permissionDenied
        case .authorized, .limited:
            break
        }

        switch catalog {
        case .running(let progress):
            return .buildingCatalog(progress)
        case .failed(let failure):
            return .catalogFailed(failure.userMessage)
        case .notStarted, .cancelled:
            return .scanRequired
        case .completed(let result):
            guard result.imageCount > 0 else { return .emptyLibrary }
            switch blur {
            case .notStarted:
                return .notStarted
            case .running(let progress):
                return .analyzing(progress)
            case .cancelled:
                return .cancelled
            case .failed(let failure):
                return .failed(failure.userMessage)
            case .completed(let blurResult):
                return blurResult.candidates.isEmpty ? .noCandidates(blurResult) : .results(blurResult)
            }
        }
    }

    /// Limited access still shows usable results — but only the granted photos count, so
    /// the UI must say that "no candidates" means "none among the photos Netto can see".
    static func showsLimitedAccessNotice(permission: PermissionState) -> Bool {
        permission == .limited
    }

    /// Whether the screen's primary action starts the sharpness pass itself (as opposed
    /// to permission prompts and catalog builds, which have their own buttons).
    static func showsAnalyzeButton(_ phase: PotentiallyBlurryPhase) -> Bool {
        switch phase {
        case .notStarted, .cancelled, .failed:
            return true
        default:
            return false
        }
    }

    /// Dashboard status line for the Potentially Blurry section — same states as the
    /// screen, in one short sentence.
    static func statusText(
        permission: PermissionState,
        catalog: CatalogScanState,
        blur: BlurAnalysisState
    ) -> String {
        switch phase(permission: permission, catalog: catalog, blur: blur) {
        case .permissionRequired:
            return "Photos access needed"
        case .permissionDenied:
            return "Photos access is off"
        case .scanRequired:
            return "Not scanned yet"
        case .buildingCatalog(let progress):
            return progress.totalCount > 0
                ? "Reading \(progress.enumeratedCount) of \(progress.totalCount) assets…"
                : "Counting assets…"
        case .catalogFailed(let message):
            return message
        case .notStarted:
            return "Not analyzed yet"
        case .analyzing(let progress):
            return analyzingMessage(progress)
        case .cancelled:
            return "Last run cancelled"
        case .failed(let message):
            return message
        case .emptyLibrary:
            return "No photos visible to Netto"
        case .noCandidates:
            return "Analyzed · none look blurry"
        case .results(let result):
            return "\(result.candidates.count) \(result.candidates.count == 1 ? "photo" : "photos") to review"
        }
    }

    /// Progress copy for the running pass — a real, counted statement, never an estimate.
    static func analyzingMessage(_ progress: BlurAnalysisProgress) -> String {
        progress.totalUnits > 0
            ? "Checking sharpness: \(progress.completedUnits) of \(progress.totalUnits) photos…"
            : "Checking sharpness…"
    }

    /// Live count for one tab — derived from the result, never stored.
    static func tabCount(_ tab: BlurReviewTab, result: BlurAnalysisResult) -> Int {
        tab.candidates(in: result).count
    }

    /// One honest counts line under the results header: the split candidates, plus how
    /// many images were not judged at all. `nil` when there is nothing extra to say.
    static func countsMessage(for result: BlurAnalysisResult) -> String? {
        var parts: [String] = []
        parts.append("\(result.likelyBlurryCount) likely blurry")
        parts.append("\(result.borderlineCount) borderline")
        if result.notJudgedCount > 0 {
            parts.append("\(result.notJudgedCount) not judged")
        }
        return parts.joined(separator: " · ")
    }
}

/// Deterministic, personal-data-free blur fixtures for previews and tests.
enum BlurFixture {
    /// A candidate list matching the shape a completed run leaves behind: three likely
    /// blurry, two borderline, plus the judged/unavailable counts of a 10-image catalog.
    static let result = BlurAnalysisResult(
        candidates: [
            BlurCandidate(assetID: "blur-01", verdict: .likelyBlurry, laplacianVariance: 0.000_012),
            BlurCandidate(assetID: "blur-02", verdict: .likelyBlurry, laplacianVariance: 0.000_084),
            BlurCandidate(assetID: "blur-03", verdict: .likelyBlurry, laplacianVariance: 0.000_410),
            BlurCandidate(assetID: "blur-04", verdict: .borderline, laplacianVariance: 0.004_800),
            BlurCandidate(assetID: "blur-05", verdict: .borderline, laplacianVariance: 0.001_200)
        ],
        unavailableAssets: [
            PhotoAnalysisUnavailable(assetID: "cloud-01", reason: .contentOnlyInICloud),
            PhotoAnalysisUnavailable(assetID: "gone-01", reason: .assetNotFound)
        ],
        sharpCount: 2,
        insufficientInformationCount: 1,
        totalRecordCount: 10,
        thresholdsUsed: .corpusCalibrated,
        scannedAt: Date(timeIntervalSince1970: 1_760_000_000)
    )

    /// A completed run over a library with no candidates (the `.noCandidates` phase).
    static let emptyResult = BlurAnalysisResult(
        candidates: [],
        unavailableAssets: [],
        sharpCount: 4,
        insufficientInformationCount: 1,
        totalRecordCount: 5,
        thresholdsUsed: .corpusCalibrated,
        scannedAt: Date(timeIntervalSince1970: 1_760_000_000)
    )

    /// The catalog exactly as a completed enumeration would leave it for `result`:
    /// the five candidates (newest first), two sharp photos, and the three records that
    /// ended up unavailable — ten images total, matching `totalRecordCount`.
    static let completedCatalog = CatalogScanResult(
        records: ["blur-01", "blur-02", "blur-03", "blur-04", "blur-05", "sharp-01", "sharp-02", "cloud-01", "gone-01", "dark-01"]
            .enumerated()
            .map { index, id in record(id: id, daysAgo: Double(index) + 1) },
        libraryAssetCount: 10,
        accessLevel: .authorized
    )

    private static let baseDate = Date(timeIntervalSince1970: 1_760_000_000)

    private static func record(id: String, daysAgo: Double) -> PhotoAssetRecord {
        PhotoAssetRecord(
            localIdentifier: id,
            mediaType: .image,
            mediaSubtypes: [],
            pixelWidth: 1290,
            pixelHeight: 2796,
            creationDate: baseDate.addingTimeInterval(-daysAgo * 86_400),
            modificationDate: nil,
            duration: 0,
            isFavorite: false,
            isHidden: false,
            sourceType: .library,
            hasAdjustments: false,
            representsBurst: false,
            burstIdentifier: nil
        )
    }
}

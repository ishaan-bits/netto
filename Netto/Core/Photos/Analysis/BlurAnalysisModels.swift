import Foundation

/// Progress of one blur-analysis run — how many images have been judged out of how many
/// were queued. Single-dimension by design: unlike similarity analysis, sharpness scoring
/// has exactly one bounded pass, so there are no stages to coordinate.
struct BlurAnalysisProgress: Sendable, Equatable {
    let completedUnits: Int
    let totalUnits: Int

    var fraction: Double? {
        guard totalUnits > 0 else { return nil }
        return Double(completedUnits) / Double(totalUnits)
    }

    var isComplete: Bool { totalUnits > 0 && completedUnits >= totalUnits }
}

/// One image that scored below the sharp threshold — either confidently blurry or in the
/// uncertain band. Carries the measured number so the UI (and tests) can explain *why*
/// this photo is here without re-measuring it.
///
/// `verdict` is always `.likelyBlurry` or `.borderline`: `.sharp` and `.insufficientInformation`
/// images are counted in the result but never become candidates.
struct BlurCandidate: Sendable, Equatable, Identifiable {
    let assetID: String
    let verdict: BlurVerdict
    let laplacianVariance: Float

    var id: String { assetID }
}

/// Outcome of a completed blur run — in-memory only, deliberately *not* persisted: a
/// sharpness verdict is a suggestion for human review, not a durable fact about the
/// library like the similarity snapshot, so it is recomputed rather than restored and
/// can never outlive the catalog it was computed over.
struct BlurAnalysisResult: Sendable, Equatable {
    /// Candidates in the input record order (the catalog's enumeration order), so the
    /// grid is stable across runs over an unchanged library regardless of worker timing.
    let candidates: [BlurCandidate]
    /// Every image that could not be measured, with an honest reason — reported, never
    /// silently dropped and never counted as sharp or blurry.
    let unavailableAssets: [PhotoAnalysisUnavailable]
    /// Images measured confidently above the sharp threshold — never cleanup candidates.
    let sharpCount: Int
    /// Images measured but refused for lack of light or texture — analyzed honestly as
    /// "not judged", never folded into sharp or blurry counts.
    let insufficientInformationCount: Int
    /// Every record the run was handed (including non-image records, which are refused
    /// as `.notAnalyzable`).
    let totalRecordCount: Int
    /// The thresholds this run classified with — recorded so a result can always say
    /// which calibration produced it.
    let thresholdsUsed: BlurThresholds
    /// When this run finished — from the engine's injected clock, so tests pin it and
    /// the UI can say "Last checked …" honestly. `.distantPast` means "no real run
    /// stamped this result" (fixtures, `empty`); the UI hides the line there. In-memory
    /// only, like the result itself: a relaunch recomputes rather than restoring.
    var scannedAt: Date = .distantPast

    var candidateIDs: Set<String> { Set(candidates.lazy.map(\.assetID)) }

    /// `.likelyBlurry` verdicts — the confidently low-detail candidates.
    var likelyBlurryCount: Int { candidates.lazy.filter { $0.verdict == .likelyBlurry }.count }
    /// `.borderline` verdicts — below the sharp threshold but not confidently blurry.
    var borderlineCount: Int { candidates.lazy.filter { $0.verdict == .borderline }.count }

    /// Images that produced a verdict of any kind (sharp, blurry, uncertain, or refused
    /// as unjudgeable after being measured).
    var judgedCount: Int { sharpCount + insufficientInformationCount + candidates.count }

    /// Images that were queued and could not be measured at all.
    var notJudgedCount: Int { unavailableAssets.count }

    /// This result with the given identifiers removed — the in-place update a confirmed
    /// deletion applies, never a rescan. The deletion can originate from any feature: an
    /// identifier in `candidates` or `unavailableAssets` leaves that list, while one that
    /// was in neither (a sharp or refused photo deleted elsewhere) is already absent and
    /// changes nothing. `sharpCount`, `insufficientInformationCount` and
    /// `totalRecordCount` describe images this update cannot re-bucket — the verdict for
    /// a deleted sharp photo was never recorded per asset — so they stand as measured by
    /// the original run and are never guessed at.
    func removingAssets(_ assetIDs: Set<String>) -> BlurAnalysisResult {
        guard !assetIDs.isEmpty else { return self }
        return BlurAnalysisResult(
            candidates: candidates.filter { !assetIDs.contains($0.assetID) },
            unavailableAssets: unavailableAssets.filter { !assetIDs.contains($0.assetID) },
            sharpCount: sharpCount,
            insufficientInformationCount: insufficientInformationCount,
            totalRecordCount: totalRecordCount,
            thresholdsUsed: thresholdsUsed,
            scannedAt: scannedAt
        )
    }

    static let empty = BlurAnalysisResult(
        candidates: [],
        unavailableAssets: [],
        sharpCount: 0,
        insufficientInformationCount: 0,
        totalRecordCount: 0,
        thresholdsUsed: .corpusCalibrated
    )
}

/// Events streamed out of `BlurAnalysisEngine`. `.completed` is always last on success.
enum BlurAnalysisEvent: Sendable, Equatable {
    case progress(BlurAnalysisProgress)
    case completed(BlurAnalysisResult)
}

enum BlurAnalysisFailure: Error, Sendable, Equatable {
    case cancelled
    case underlying(String)

    var userMessage: String {
        switch self {
        case .cancelled:
            return "Sharpness analysis cancelled."
        case .underlying(let detail):
            return detail
        }
    }
}

/// Explicit state machine for the sharpness pass, mirroring `PhotoAnalysisState` so the
/// UI treats this category exactly like every other analysis-backed category.
enum BlurAnalysisState: Sendable, Equatable {
    case notStarted
    case running(BlurAnalysisProgress)
    case completed(BlurAnalysisResult)
    case cancelled
    case failed(BlurAnalysisFailure)

    var isRunning: Bool {
        if case .running = self { return true }
        return false
    }

    var result: BlurAnalysisResult? {
        if case .completed(let result) = self { return result }
        return nil
    }
}

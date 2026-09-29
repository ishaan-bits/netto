import Foundation

/// Ordered stages of one similarity-analysis run.
///
/// The stage sequence is the progress contract shown in the UI:
/// `preparing → generatingCandidates → fingerprinting → (extractingFeatures ↔ comparing)* →
/// grouping → finalizing`. The parenthesised pair is interleaved per bucket by design: each
/// bucket's prints are extracted, compared, and released before the next bucket starts, which is
/// what keeps feature prints for at most `maxConcurrentWorkers` buckets alive at once (see
/// `PhotoSimilarityEngine`). Every stage is reported through `PhotoAnalysisProgress`.
enum PhotoAnalysisStage: String, Sendable, Equatable, CaseIterable {
    case preparing
    case generatingCandidates
    case fingerprinting
    case extractingFeatures
    case comparing
    case grouping
    case finalizing

    /// Static label for signposts (`OSSignposter` messages are `StaticString`, so dynamic
    /// interpolation is not available here — and a per-stage literal keeps Instruments search
    /// friendly).
    var signpostName: StaticString {
        switch self {
        case .preparing: return "preparing"
        case .generatingCandidates: return "generating-candidates"
        case .fingerprinting: return "fingerprinting"
        case .extractingFeatures: return "extracting-features"
        case .comparing: return "comparing"
        case .grouping: return "grouping"
        case .finalizing: return "finalizing"
        }
    }
}

/// Progress of one analysis stage.
///
/// `totalUnits == 0` means *indeterminate* and `fraction` is then `nil` — used for
/// `generatingCandidates`, whose work (bucketing) is a single synchronous pass with no
/// meaningful sub-unit tick. Tests observe raw values; clamping happens in the UI.
struct PhotoAnalysisProgress: Sendable, Equatable {
    let stage: PhotoAnalysisStage
    let completedUnits: Int
    let totalUnits: Int

    var fraction: Double? {
        guard totalUnits > 0 else { return nil }
        return Double(completedUnits) / Double(totalUnits)
    }

    var isComplete: Bool { totalUnits > 0 && completedUnits >= totalUnits }
}

/// Why a specific asset could not be analyzed.
///
/// Unavailable assets are reported, never silently treated as duplicates and never silently
/// dropped: each reason maps to something honest the UI can tell the user later. The set is
/// deliberately granular — "could not read" is a different thing from "did not match" — and the
/// engine never collapses these into a single failure or, worse, into "not a duplicate".
enum PhotoAnalysisUnavailableReason: String, Sendable, Equatable, Error {
    /// Photos access was not granted when the request ran (denied, restricted, or not yet
    /// determined). Distinct from a missing asset so the UI can point at Settings.
    case permissionUnavailable
    /// The identifier no longer resolves to an asset — deleted, or not visible under limited
    /// access. Distinct from a cloud-only asset, which exists but is not local.
    case assetNotFound
    /// Content lives only in iCloud and network access is disabled for this pass.
    case contentOnlyInICloud
    /// PhotoKit returned no readable content locally (I/O failure, unsupported asset, missing
    /// paired resource) — the asset exists but its bytes were not available without downloading.
    case contentUnreadable
    /// A thumbnail could not be produced for an image that is part of a candidate bucket.
    case imageUnavailable
    /// Metadata reports zero or negative pixel dimensions.
    case invalidDimensions
    /// The Vision descriptor backend failed for this asset even though the run latched Vision.
    case visionFailed
    /// The run fell back to the CPU descriptor and even that failed for this asset (for example
    /// an undrawable image). Kept separate from `visionFailed` so a device-validation log can
    /// tell "Vision broke" apart from "the thumbnail itself was unusable".
    case cpuDescriptorFailed
    /// Not an analyzable media type (for example audio-only records).
    case notAnalyzable
}

struct PhotoAnalysisUnavailable: Sendable, Equatable {
    let assetID: String
    let reason: PhotoAnalysisUnavailableReason
}

/// Evidence backing a group. Carries the numbers that made the group, so the UI (and tests) can
/// explain a match without re-running analysis.
enum PhotoAnalysisEvidence: Sendable, Equatable {
    /// Byte-identical content: same SHA-256 over the same content lengths.
    case exactContent(fingerprint: String, byteLength: Int64)
    /// Visual near-duplicate: every pair in the group is within `threshold` L2 distance.
    case visualSimilarity(minDistance: Float, maxDistance: Float, threshold: Float)
}

enum PhotoSimilarityGroupKind: String, Sendable, Equatable {
    case exactDuplicates
    case nearDuplicates
}

/// Deterministic "which one would we suggest keeping" score for one member of a group.
///
/// This is a *recommendation input*, never a deletion decision. `sizeInBytes` is deliberately
/// absent — it is unknown at analysis time and must never be fabricated.
struct PhotoAssetQualityScore: Sendable, Equatable {
    let localIdentifier: String
    let isFavorite: Bool
    let representsBurst: Bool
    let pixelCount: Int
    let hasAdjustments: Bool
    let creationDate: Date?
}

/// One discovered group of duplicate or near-duplicate assets.
///
/// `memberAssetIDs` is always sorted so group identity and ordering are stable across runs;
/// `id` is derived from the kind plus that sorted membership (or the fingerprint for exact
/// groups), so re-running analysis over an unchanged library yields identical ids.
struct PhotoSimilarityGroup: Sendable, Equatable, Identifiable {
    let kind: PhotoSimilarityGroupKind
    let memberAssetIDs: [String]
    let evidence: PhotoAnalysisEvidence
    let recommendedBestAssetID: String
    /// Score backing each member's ranking; keys mirror `memberAssetIDs`.
    let memberScores: [String: PhotoAssetQualityScore]

    var id: String {
        switch kind {
        case .exactDuplicates:
            if case .exactContent(let fingerprint, _) = evidence {
                return "exact:\(fingerprint)"
            }
            return "exact:" + memberAssetIDs.joined(separator: ",")
        case .nearDuplicates:
            return "near:" + memberAssetIDs.joined(separator: ",")
        }
    }

    var count: Int { memberAssetIDs.count }
}

/// Outcome of a completed analysis run.
struct PhotoAnalysisResult: Sendable, Equatable {
    let exactGroups: [PhotoSimilarityGroup]
    let similarGroups: [PhotoSimilarityGroup]
    let unavailableAssets: [PhotoAnalysisUnavailable]
    /// Descriptor family actually used, `nil` when no image reached feature extraction
    /// (empty library or no image candidates).
    let descriptorKind: FeaturePrintKind?
    /// `true` when the Vision backend answered its warm-up probe and was used.
    let visionAvailable: Bool
    /// L2 threshold applied to near-duplicate comparisons, `nil` when nothing was compared.
    let similarityThreshold: Float?
    let totalRecordCount: Int
    /// Buckets formed from the metadata partition.
    let candidateBucketCount: Int
    /// Pairs actually considered (within buckets only) — always far below `n(n-1)/2`.
    let candidatePairCount: Int

    var totalGroupedAssetCount: Int {
        Set(exactGroups.flatMap(\.memberAssetIDs)).count
            + Set(similarGroups.flatMap(\.memberAssetIDs)).count
    }

    static let empty = PhotoAnalysisResult(
        exactGroups: [],
        similarGroups: [],
        unavailableAssets: [],
        descriptorKind: nil,
        visionAvailable: false,
        similarityThreshold: nil,
        totalRecordCount: 0,
        candidateBucketCount: 0,
        candidatePairCount: 0
    )
}

/// Events streamed out of `PhotoSimilarityEngine`. `.completed` is always last on success.
enum PhotoAnalysisEvent: Sendable, Equatable {
    case progress(PhotoAnalysisProgress)
    case completed(PhotoAnalysisResult)
}

enum PhotoAnalysisFailure: Error, Sendable, Equatable {
    case cancelled
    case underlying(String)

    var userMessage: String {
        switch self {
        case .cancelled:
            return "Analysis cancelled."
        case .underlying(let detail):
            return detail
        }
    }
}

/// Explicit state machine for the analysis stage, mirroring `CatalogScanState`.
enum PhotoAnalysisState: Sendable, Equatable {
    case notStarted
    case running(PhotoAnalysisProgress)
    case completed(PhotoAnalysisResult)
    case cancelled
    case failed(PhotoAnalysisFailure)

    var isRunning: Bool {
        if case .running = self { return true }
        return false
    }
}

/// Stage-transition hook. Fires just before a stage begins doing work (and, for the interleaved
/// extraction/comparison pair, on each transition between them inside bucket processing) —
/// specifically, whenever the *reported* stage changes.
///
/// Doubles as the signpost instrumentation seam and as the deterministic abort seam: throwing
/// from `analysisStageWillBegin` tears the run down at exactly that stage, which is how tests
/// exercise stage-by-stage interruption without racing a consumer-side cancel. Throwing
/// `CancellationError` is the idiomatic choice.
///
/// Must stay synchronous and side-effect-light (it is invoked while the reporter lock is held, so
/// it must never call back into progress reporting).
protocol PhotoAnalysisStageObserving: Sendable {
    func analysisStageWillBegin(_ stage: PhotoAnalysisStage) throws
    /// Called once when a run ends, successfully or not, so observers can close open intervals.
    func analysisDidFinish()
}

extension PhotoAnalysisStageObserving {
    func analysisDidFinish() {}
}

/// No-op observer used when instrumentation is not wired up.
struct NoopStageObserver: PhotoAnalysisStageObserving {
    func analysisStageWillBegin(_ stage: PhotoAnalysisStage) throws {}
}

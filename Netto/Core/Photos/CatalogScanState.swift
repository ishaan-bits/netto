import Foundation

/// Progress of a catalog build, in assets enumerated so far.
///
/// The catalog stage reports against the asset count the library reported at scan start, so the
/// bar reaches completion exactly when the enumeration loop ends. `fraction` is clamped for
/// display by the caller; it is not clamped here so tests can observe raw values.
struct CatalogScanProgress: Sendable, Equatable {
    let enumeratedCount: Int
    let totalCount: Int

    var fraction: Double {
        guard totalCount > 0 else { return 0 }
        return Double(enumeratedCount) / Double(totalCount)
    }

    var isComplete: Bool { totalCount > 0 && enumeratedCount >= totalCount }

    static let indeterminate = CatalogScanProgress(enumeratedCount: 0, totalCount: 0)
}

enum CatalogScanFailure: Error, Sendable, Equatable {
    case photoLibraryUnavailable
    case cancelled
    case underlying(String)

    var userMessage: String {
        switch self {
        case .photoLibraryUnavailable:
            return "Photos access is required to read your library."
        case .cancelled:
            return "Catalog build cancelled."
        case .underlying(let detail):
            return detail
        }
    }
}

/// The result of a completed metadata enumeration.
///
/// This is *not* a scan result: no analysis has happened yet. It is the ordered, metadata-only
/// record set that every later stage (bucketing, fingerprinting, grouping) consumes.
struct CatalogScanResult: Sendable, Equatable {
    let records: [PhotoAssetRecord]
    /// Asset count the library reported when the enumeration started. May differ from
    /// `scannedAssetCount` if the library changed mid-scan; that is not an error.
    let libraryAssetCount: Int
    /// `.authorized` or `.limited` — whichever the app was actually reading under.
    let accessLevel: PermissionState

    /// Derived facts, computed once in `init` from the record list so that dashboard cards,
    /// presentation status, and dataset views never re-filter the full library per render.
    /// Every field is a pure function of `records`, so `==` ignores them by construction.
    let imageCount: Int
    let videoCount: Int
    let screenshotCount: Int
    let livePhotoCount: Int
    let adjustedCount: Int
    /// The screenshot subset in catalog order — shared (CoW) rather than re-filtered.
    let screenshotRecords: [PhotoAssetRecord]
    /// The video subset in catalog order — shared (CoW) rather than re-filtered.
    let videoRecords: [PhotoAssetRecord]
    /// First image in catalog order (the swipe-review card's thumbnail), resolved once so the
    /// dashboard never scans the full record list per render. `nil` for a video-only library.
    let firstImageAssetID: String?

    init(
        records: [PhotoAssetRecord],
        libraryAssetCount: Int,
        accessLevel: PermissionState
    ) {
        self.records = records
        self.libraryAssetCount = libraryAssetCount
        self.accessLevel = accessLevel

        var imageCount = 0
        var videoCount = 0
        var screenshotCount = 0
        var livePhotoCount = 0
        var adjustedCount = 0
        var screenshotRecords: [PhotoAssetRecord] = []
        var videoRecords: [PhotoAssetRecord] = []
        var firstImageAssetID: String?

        for record in records {
            if record.isImage {
                imageCount += 1
                if firstImageAssetID == nil {
                    firstImageAssetID = record.localIdentifier
                }
            }
            if record.isVideo {
                videoCount += 1
                videoRecords.append(record)
            }
            if record.isScreenshot {
                screenshotCount += 1
                screenshotRecords.append(record)
            }
            if record.isLivePhoto { livePhotoCount += 1 }
            if record.hasAdjustments { adjustedCount += 1 }
        }

        self.imageCount = imageCount
        self.videoCount = videoCount
        self.screenshotCount = screenshotCount
        self.livePhotoCount = livePhotoCount
        self.adjustedCount = adjustedCount
        self.screenshotRecords = screenshotRecords
        self.videoRecords = videoRecords
        self.firstImageAssetID = firstImageAssetID
    }

    var scannedAssetCount: Int { records.count }
    var isEmpty: Bool { records.isEmpty }

    /// Known byte total across the catalog. Assets with unknown size contribute nothing, so this
    /// is a lower bound, not a claim about the library's real footprint. Off the render path
    /// (test/diagnostic use only), so it stays a computed fold.
    var knownSizeBytes: Int64 {
        records.reduce(Int64(0)) { total, record in
            total + (record.sizeInBytes ?? 0)
        }
    }

    /// Equality over the inputs only: the derived facts above are pure functions of `records`,
    /// so comparing them would add an O(records) walk without changing any outcome.
    static func == (lhs: CatalogScanResult, rhs: CatalogScanResult) -> Bool {
        lhs.libraryAssetCount == rhs.libraryAssetCount
            && lhs.accessLevel == rhs.accessLevel
            && lhs.records == rhs.records
    }

    /// The same completed catalog with the given asset identifiers removed — in-place pruning
    /// after a confirmed deletion, never a rebuild. `libraryAssetCount` stays the count the
    /// enumeration reported: the next build is what reports the library's new size.
    func removingAssetIDs(_ assetIDs: Set<String>) -> CatalogScanResult {
        guard !assetIDs.isEmpty else { return self }
        return CatalogScanResult(
            records: records.filter { !assetIDs.contains($0.localIdentifier) },
            libraryAssetCount: libraryAssetCount,
            accessLevel: accessLevel
        )
    }
}

/// Explicit state machine for the catalog stage. No booleans, no implicit transitions.
enum CatalogScanState: Sendable, Equatable {
    case notStarted
    case running(CatalogScanProgress)
    /// Interrupted with a checkpoint on disk — resumable, never presented as still running.
    case paused(CatalogScanProgress)
    case completed(CatalogScanResult)
    case cancelled
    case failed(CatalogScanFailure)

    var isRunning: Bool {
        if case .running = self { return true }
        return false
    }

    /// The progress this state is showing, for a paused state's saved snapshot.
    var pausedProgress: CatalogScanProgress? {
        if case .paused(let progress) = self { return progress }
        return nil
    }
}

/// Events streamed out of `PhotoCatalogBuilder`. Ordered: progress is yielded from the single
/// enumeration loop, and `completed` is always last.
enum CatalogScanEvent: Sendable, Equatable {
    case progress(CatalogScanProgress)
    case completed(CatalogScanResult)
}

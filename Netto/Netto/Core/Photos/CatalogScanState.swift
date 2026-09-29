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

    var scannedAssetCount: Int { records.count }
    var isEmpty: Bool { records.isEmpty }
    var imageCount: Int { records.lazy.filter(\.isImage).count }
    var videoCount: Int { records.lazy.filter(\.isVideo).count }
    var screenshotCount: Int { records.lazy.filter(\.isScreenshot).count }
    var livePhotoCount: Int { records.lazy.filter(\.isLivePhoto).count }
    var adjustedCount: Int { records.lazy.filter(\.hasAdjustments).count }

    /// Known byte total across the catalog. Assets with unknown size contribute nothing, so this
    /// is a lower bound, not a claim about the library's real footprint.
    var knownSizeBytes: Int64 {
        records.reduce(Int64(0)) { total, record in
            total + (record.sizeInBytes ?? 0)
        }
    }
}

/// Explicit state machine for the catalog stage. No booleans, no implicit transitions.
enum CatalogScanState: Sendable, Equatable {
    case notStarted
    case running(CatalogScanProgress)
    case completed(CatalogScanResult)
    case cancelled
    case failed(CatalogScanFailure)

    var isRunning: Bool {
        if case .running = self { return true }
        return false
    }
}

/// Events streamed out of `PhotoCatalogBuilder`. Ordered: progress is yielded from the single
/// enumeration loop, and `completed` is always last.
enum CatalogScanEvent: Sendable, Equatable {
    case progress(CatalogScanProgress)
    case completed(CatalogScanResult)
}

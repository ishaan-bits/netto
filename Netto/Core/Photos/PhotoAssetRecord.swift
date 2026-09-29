import Foundation

/// A metadata-only snapshot of a single photo-library asset.
///
/// Produced by `PhotoCatalogBuilder` from PhotoKit metadata alone: no image or video data is
/// decoded, no `PHAssetResource` payload is retrieved, and no network access occurs. Records are
/// deliberately free of any `PHAsset` reference so they can be stored, compared, and passed
/// across concurrency domains cheaply; the `localIdentifier` is the handle used to re-fetch an
/// asset for thumbnails or deletion.
///
/// `sizeInBytes` is `nil` at catalog time and must stay that way. iOS 17 exposes no public, cheap,
/// exact per-asset byte count through PhotoKit metadata (`PHAssetResource.dataSize` is iOS 27+),
/// so the catalog never guesses one. Sizes are resolved later, for an explicitly selected subset
/// only, through `AssetSizeProviding`.
struct PhotoAssetRecord: Sendable, Hashable, Identifiable {
    let localIdentifier: String
    let mediaType: PhotoMediaType
    let mediaSubtypes: PhotoMediaSubtypes
    let pixelWidth: Int
    let pixelHeight: Int
    let creationDate: Date?
    let modificationDate: Date?
    let duration: TimeInterval
    let isFavorite: Bool
    let isHidden: Bool
    let sourceType: PhotoSourceTypes
    let hasAdjustments: Bool
    let representsBurst: Bool
    let burstIdentifier: String?

    /// Exact size in bytes when it has been measured, `nil` when unknown.
    ///
    /// `nil` means *unknown*, never zero. Only `AssetSizeProviding` writes this field, and only
    /// for assets the user has moved toward review. Enumeration never writes it.
    var sizeInBytes: Int64?

    var id: String { localIdentifier }

    init(
        localIdentifier: String,
        mediaType: PhotoMediaType,
        mediaSubtypes: PhotoMediaSubtypes,
        pixelWidth: Int,
        pixelHeight: Int,
        creationDate: Date?,
        modificationDate: Date?,
        duration: TimeInterval,
        isFavorite: Bool,
        isHidden: Bool,
        sourceType: PhotoSourceTypes,
        hasAdjustments: Bool,
        representsBurst: Bool,
        burstIdentifier: String?,
        sizeInBytes: Int64? = nil
    ) {
        self.localIdentifier = localIdentifier
        self.mediaType = mediaType
        self.mediaSubtypes = mediaSubtypes
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.creationDate = creationDate
        self.modificationDate = modificationDate
        self.duration = duration
        self.isFavorite = isFavorite
        self.isHidden = isHidden
        self.sourceType = sourceType
        self.hasAdjustments = hasAdjustments
        self.representsBurst = representsBurst
        self.burstIdentifier = burstIdentifier
        self.sizeInBytes = sizeInBytes
    }

    var isImage: Bool { mediaType == .image }
    var isVideo: Bool { mediaType == .video }
    var isScreenshot: Bool { mediaSubtypes.contains(.screenshot) }
    var isLivePhoto: Bool { mediaSubtypes.contains(.livePhoto) }
    var pixelCount: Int { pixelWidth * pixelHeight }

    /// Byte for byte, an unknown size must never be treated as a known zero.
    var isSizeKnown: Bool { sizeInBytes != nil }

    func resolvingSize(_ bytes: Int64?) -> PhotoAssetRecord {
        var copy = self
        copy.sizeInBytes = bytes
        return copy
    }

    var cacheKey: CatalogCacheKey {
        CatalogCacheKey(localIdentifier: localIdentifier, modificationDate: modificationDate)
    }
}

/// Identity used to decide whether an already-analyzed asset can be reused on a rescan.
///
/// An asset is unchanged iff its `localIdentifier` and `modificationDate` are both identical;
/// any edit, favorite toggle, or replacement produces a different key.
struct CatalogCacheKey: Sendable, Hashable {
    let localIdentifier: String
    let modificationDate: Date?
}

enum PhotoMediaType: String, Sendable, Hashable, CaseIterable {
    case image
    case video
    case audio
    case unknown
}

/// Mirrors `PHAssetMediaSubtype` bit-for-bit, but is free of any PhotoKit type so catalog values
/// can be constructed and asserted without a photo library. The bridge lives in
/// `PhotoLibraryProvider`.
struct PhotoMediaSubtypes: OptionSet, Sendable, Hashable {
    let rawValue: UInt

    static let panorama = PhotoMediaSubtypes(rawValue: 1 << 0)
    static let hdr = PhotoMediaSubtypes(rawValue: 1 << 1)
    static let screenshot = PhotoMediaSubtypes(rawValue: 1 << 2)
    static let livePhoto = PhotoMediaSubtypes(rawValue: 1 << 3)
    static let depthEffect = PhotoMediaSubtypes(rawValue: 1 << 4)
    static let animation = PhotoMediaSubtypes(rawValue: 1 << 6)
    static let spatial = PhotoMediaSubtypes(rawValue: 1 << 10)
    static let videoStreamed = PhotoMediaSubtypes(rawValue: 1 << 16)
    static let videoHighFrameRate = PhotoMediaSubtypes(rawValue: 1 << 17)
    static let videoTimelapse = PhotoMediaSubtypes(rawValue: 1 << 18)
    static let videoScreenRecording = PhotoMediaSubtypes(rawValue: 1 << 19)
    static let videoCinematic = PhotoMediaSubtypes(rawValue: 1 << 21)
}

/// Mirrors `PHAssetSourceType`. `.library` is the only source Netto analyzes; assets synced from
/// iTunes or shared via iCloud Photos are reported but never silently dropped.
struct PhotoSourceTypes: OptionSet, Sendable, Hashable {
    let rawValue: UInt

    static let library = PhotoSourceTypes(rawValue: 1 << 0)
    static let cloudShared = PhotoSourceTypes(rawValue: 1 << 1)
    static let itunesSynced = PhotoSourceTypes(rawValue: 1 << 2)
}

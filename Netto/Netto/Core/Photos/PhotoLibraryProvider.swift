import Foundation
import Photos

enum PhotoLibraryReadError: Error, Sendable, Equatable {
    case accessDenied
    case underlying(String)

    var catalogFailure: CatalogScanFailure {
        switch self {
        case .accessDenied: return .photoLibraryUnavailable
        case .underlying(let detail): return .underlying(detail)
        }
    }
}

/// The single seam between the catalog and PhotoKit.
///
/// Reads are strictly metadata-only: implementations must never request image data, thumbnails,
/// `PHAssetResourceManager` payloads, or content editing inputs. Ranges are 0-based against the
/// total reported by `assetCount()`, ordered newest-first, and out-of-bounds bounds are clamped
/// rather than trapping so a library that shrinks mid-scan degrades to a shorter result instead
/// of crashing.
protocol PhotoLibraryReading: Sendable {
    /// Full or limited — whatever access the app is reading under right now.
    var accessLevel: PermissionState { get }
    func assetCount() throws -> Int
    func records(in range: Range<Int>) throws -> [PhotoAssetRecord]
}

/// Live PhotoKit reader. Holds an immutable `PHFetchResult` snapshot, which is `Sendable`, so the
/// catalog can enumerate it off the main actor without racing the photo library.
struct SystemPhotoLibrary: PhotoLibraryReading {
    let accessLevel: PermissionState
    private let assets: PHFetchResult<PHAsset>

    init() throws {
        let status = PhotoLibraryPermissionService.map(PHPhotoLibrary.authorizationStatus(for: .readWrite))
        guard status.isUsable else { throw PhotoLibraryReadError.accessDenied }

        let options = PHFetchOptions()
        options.includeHiddenAssets = false
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]

        self.accessLevel = status
        self.assets = PHAsset.fetchAssets(with: options)
    }

    func assetCount() throws -> Int {
        assets.count
    }

    func records(in range: Range<Int>) throws -> [PhotoAssetRecord] {
        let total = assets.count
        let lower = max(0, range.lowerBound)
        let upper = min(range.upperBound, total)
        guard lower < upper else { return [] }

        var chunk: [PhotoAssetRecord] = []
        chunk.reserveCapacity(upper - lower)
        for index in lower..<upper {
            chunk.append(PhotoAssetRecord(assets.object(at: index)))
        }
        return chunk
    }
}

// MARK: - PhotoKit bridging
//
// The only place a `PHAsset` is turned into a value. Everything downstream of this file works
// with `PhotoAssetRecord` alone.

extension PhotoMediaType {
    init(_ mediaType: PHAssetMediaType) {
        switch mediaType {
        case .image: self = .image
        case .video: self = .video
        case .audio: self = .audio
        case .unknown: self = .unknown
        @unknown default: self = .unknown
        }
    }
}

extension PhotoMediaSubtypes {
    init(_ subtypes: PHAssetMediaSubtype) {
        var value: PhotoMediaSubtypes = []
        if subtypes.contains(.photoPanorama) { value.insert(.panorama) }
        if subtypes.contains(.photoHDR) { value.insert(.hdr) }
        if subtypes.contains(.photoScreenshot) { value.insert(.screenshot) }
        if subtypes.contains(.photoLive) { value.insert(.livePhoto) }
        if subtypes.contains(.photoDepthEffect) { value.insert(.depthEffect) }
        if subtypes.contains(.photoAnimation) { value.insert(.animation) }
        if subtypes.contains(.spatialMedia) { value.insert(.spatial) }
        if subtypes.contains(.videoStreamed) { value.insert(.videoStreamed) }
        if subtypes.contains(.videoHighFrameRate) { value.insert(.videoHighFrameRate) }
        if subtypes.contains(.videoTimelapse) { value.insert(.videoTimelapse) }
        if subtypes.contains(.videoScreenRecording) { value.insert(.videoScreenRecording) }
        if subtypes.contains(.videoCinematic) { value.insert(.videoCinematic) }
        self = value
    }
}

extension PhotoSourceTypes {
    init(_ sourceType: PHAssetSourceType) {
        var value: PhotoSourceTypes = []
        if sourceType.contains(.typeUserLibrary) { value.insert(.library) }
        if sourceType.contains(.typeCloudShared) { value.insert(.cloudShared) }
        if sourceType.contains(.typeiTunesSynced) { value.insert(.itunesSynced) }
        self = value
    }
}

extension PhotoAssetRecord {
    /// Metadata extraction only. Nothing here touches image bytes, resource data, or the network.
    init(_ asset: PHAsset) {
        self.init(
            localIdentifier: asset.localIdentifier,
            mediaType: PhotoMediaType(asset.mediaType),
            mediaSubtypes: PhotoMediaSubtypes(asset.mediaSubtypes),
            pixelWidth: Int(asset.pixelWidth),
            pixelHeight: Int(asset.pixelHeight),
            creationDate: asset.creationDate,
            modificationDate: asset.modificationDate,
            duration: asset.duration,
            isFavorite: asset.isFavorite,
            isHidden: asset.isHidden,
            sourceType: PhotoSourceTypes(asset.sourceType),
            hasAdjustments: asset.hasAdjustments,
            representsBurst: asset.representsBurst,
            burstIdentifier: asset.burstIdentifier,
            sizeInBytes: nil
        )
    }
}

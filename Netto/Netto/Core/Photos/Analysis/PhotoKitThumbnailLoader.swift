import CoreGraphics
import Foundation
import Photos
import UIKit

enum PhotoContentError: Error, Sendable, Equatable {
    /// Photos access was not granted at request time (denied, restricted, or not determined).
    /// Checked as a *status read* before every fetch — the loader never requests permission.
    case permissionDenied
    /// The identifier does not resolve to a visible asset (deleted, or outside limited access).
    case assetNotFound
    /// Content exists only in iCloud and network access is disabled for this pass.
    case onlyInICloud
    /// PhotoKit returned nothing usable.
    case unavailable
}

/// Seam over thumbnail delivery. The engine must run against synthetic images in tests, without
/// a photo library or photo permissions.
protocol PhotoThumbnailLoading: Sendable {
    /// Returns an **upright** thumbnail of at most `targetPixelSize` on its longest side.
    /// Orientation is baked in by the loader so every downstream consumer (Vision and the CPU
    /// descriptor) sees pixels the same way, with no EXIF left to disagree about.
    func thumbnail(for assetID: String, targetPixelSize: Int) async throws -> CGImage
}

/// iOS 17-compatible thumbnail loading.
///
/// Choices and their reasons:
/// - `.aspectFit` within a `targetPixelSize × targetPixelSize` box → thumbnails sized for
///   analysis, never full-resolution decoding of the library.
/// - `.highQualityFormat` delivers exactly one result (no degraded-then-final double callback),
///   `.version = .current` so the thumbnail reflects the user's edits, matching the "visible
///   content" provenance rule shared with `PhotoKitAssetSizeProvider`.
/// - `isNetworkAccessAllowed = false` → never downloads; an iCloud-only asset surfaces as
///   `PhotoContentError.onlyInICloud` instead of silently fetching.
/// - Callbacks may never fire after cancellation, so the request runs through
///   `PendingPhotoRequest`, which resumes exactly once and cancels the PhotoKit request when the
///   surrounding task is cancelled.
struct PhotoKitThumbnailLoader: PhotoThumbnailLoading {
    /// The PhotoKit request itself, injectable so tests can exercise the loader's success,
    /// failure, and cancellation behaviour without a photo library. The default is the live
    /// request below; nothing about the protocol seam changes.
    typealias ImageRequest = @Sendable (_ assetID: String, _ targetPixelSize: Int) async throws
        -> CGImage

    private let request: ImageRequest

    init() {
        request = Self.liveRequest
    }

    init(request: @escaping ImageRequest) {
        self.request = request
    }

    func thumbnail(for assetID: String, targetPixelSize: Int) async throws -> CGImage {
        try await request(assetID, max(1, targetPixelSize))
    }

    /// The production path: exactly one bounded, local-only, orientation-baked thumbnail.
    ///
    /// Runs through `PendingPhotoRequest` so a cancelled task cancels the PhotoKit request and
    /// the continuation resumes exactly once even though `requestImage` may call back on the
    /// main thread, more than once (`.opportunistic`), or — when cancelled — not at all.
    private static func liveRequest(assetID: String, targetPixelSize: Int) async throws -> CGImage {
        try await PendingPhotoRequest.run { resolve in
            let asset = try fetchAsset(assetID)
            let options = makeImageRequestOptions()

            let side = CGFloat(max(1, targetPixelSize))
            let targetSize = CGSize(width: side, height: side)

            let requestID = PHImageManager.default().requestImage(
                for: asset,
                targetSize: targetSize,
                contentMode: .aspectFit,
                options: options
            ) { image, info in
                resolve(Self.result(image: image, info: info))
            }
            return { PHImageManager.default().cancelImageRequest(requestID) }
        }
    }

    /// Every knob that matters for the analysis pass, in one testable place:
    /// - `isNetworkAccessAllowed = false` → an iCloud-only asset reports `.onlyInICloud` instead
    ///   of silently downloading bytes during a scan.
    /// - `.highQualityFormat` → exactly one callback (no degraded-then-final double fire).
    /// - `.version = .current` → the thumbnail reflects the user's edits, matching the
    ///   visible-content provenance rule the fingerprinting path uses.
    /// - `.resizeMode = .exact` + `.aspectFit` request → the delivered bitmap respects the
    ///   requested bound; combined with `targetPixelSize` (256) full-resolution pixels are never
    ///   decoded into memory.
    /// - `isSynchronous = false` → callback off the calling thread; no main-thread blocking.
    static func makeImageRequestOptions() -> PHImageRequestOptions {
        let options = PHImageRequestOptions()
        options.isNetworkAccessAllowed = false
        options.version = .current
        options.deliveryMode = .highQualityFormat
        options.resizeMode = .exact
        options.isSynchronous = false
        return options
    }

    /// Status *read* only — never a permission request. With access missing, a fetch would
    /// silently come back empty and every asset would be misreported as "not found"; checking
    /// first keeps "Photos access is off" distinguishable from "this photo was deleted".
    static func fetchAsset(_ assetID: String) throws -> PHAsset {
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        switch status {
        case .authorized, .limited:
            break
        default:
            throw PhotoContentError.permissionDenied
        }
        let options = PHFetchOptions()
        options.fetchLimit = 1
        let result = PHAsset.fetchAssets(withLocalIdentifiers: [assetID], options: options)
        guard let asset = result.firstObject else { throw PhotoContentError.assetNotFound }
        return asset
    }

    static func result(image: UIImage?, info: [AnyHashable: Any]?) -> Result<CGImage, any Error> {
        if let cancelled = info?[PHImageCancelledKey] as? Bool, cancelled {
            return .failure(CancellationError())
        }
        if let error = info?[PHImageErrorKey] as? any Error {
            return .failure(mapError(error))
        }
        if let inCloud = info?[PHImageResultIsInCloudKey] as? Bool, inCloud {
            return .failure(PhotoContentError.onlyInICloud)
        }
        guard let image, let cgImage = normalizedCGImage(from: image) else {
            return .failure(PhotoContentError.unavailable)
        }
        return .success(cgImage)
    }

    /// `PHImageErrorKey` NSError → the loader vocabulary, using the documented `PHPhotosError`
    /// codes (iOS 15+, verified in the installed SDK headers) so downstream analysis can tell
    /// "Photos access is off" and "this photo is gone" apart from a generic failure.
    static func mapError(_ error: any Error) -> any Error {
        let nsError = error as NSError
        guard nsError.domain == PHPhotosErrorDomain else { return error }
        switch nsError.code {
        case PHPhotosError.Code.accessUserDenied.rawValue,
             PHPhotosError.Code.accessRestricted.rawValue:
            return PhotoContentError.permissionDenied
        case PHPhotosError.Code.identifierNotFound.rawValue:
            return PhotoContentError.assetNotFound
        case PHPhotosError.Code.networkAccessRequired.rawValue:
            return PhotoContentError.onlyInICloud
        default:
            return PhotoContentError.unavailable
        }
    }

    /// Bakes `imageOrientation` into the pixel data once, at the boundary. Without this, an
    /// EXIF-rotated still would be described by both descriptor families in their unrotated frame
    /// while appearing upright to the user — and a burst shot plus its rotation would stop
    /// matching each other.
    static func normalizedCGImage(from image: UIImage) -> CGImage? {
        if image.imageOrientation == .up, let direct = image.cgImage {
            return direct
        }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        let renderer = UIGraphicsImageRenderer(size: image.size, format: format)
        let rendered = renderer.image { _ in image.draw(at: .zero) }
        return rendered.cgImage
    }
}

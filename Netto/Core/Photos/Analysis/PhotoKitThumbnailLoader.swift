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

/// Which analysis pass is asking for the thumbnail — the quality/network policy for the request.
enum PhotoThumbnailRequestMode: Sendable, Equatable {
    /// Cheap-first gate: a small thumbnail for perceptual hashing (96 px). Delivered with the
    /// fast resize path; a sub-optimal rendition is fine because this pass only decides which
    /// pairs are worth a real comparison.
    case perceptual
    /// Descriptor input: the exact requested size (256 px). This pixel data *is* the evidence
    /// the near-duplicate decision rests on, so it must be the accurate rendition.
    case verification
}

/// Seam over thumbnail delivery. The engine must run against synthetic images in tests, without
/// a photo library or photo permissions.
protocol PhotoThumbnailLoading: Sendable {
    /// Returns an **upright** thumbnail of at most `targetPixelSize` on its longest side.
    /// Orientation is baked in by the loader so every downstream consumer (Vision and the CPU
    /// descriptor) sees pixels the same way, with no EXIF left to disagree about.
    func thumbnail(
        for assetID: String,
        targetPixelSize: Int,
        mode: PhotoThumbnailRequestMode
    ) async throws -> CGImage

    /// The large, **explicitly user-requested** preview rendition for Photo Details.
    ///
    /// Distinct from `thumbnail(for:targetPixelSize:mode:)` in two ways the analysis path
    /// must never inherit:
    /// - PhotoKit may use the network for this one request (an iCloud photo opened on purpose
    ///   should download); analysis passes stay local-only.
    /// - `.opportunistic` delivery means PhotoKit can call back with a degraded interim frame
    ///   before the final render. Interim frames are handed to `onInterim` (the caller may
    ///   surface them for progressive sharpening) and **never** settle the call: the returned
    ///   image is always the final frame, and a degraded frame is never a terminal failure.
    ///
    /// Cancellation and the request failsafe behave exactly like `thumbnail`.
    func previewImage(
        for assetID: String,
        targetPixelSize: Int,
        onInterim: @escaping @Sendable (CGImage) -> Void
    ) async throws -> CGImage
}

extension PhotoThumbnailLoading {
    /// Convenience for callers outside the analysis pipeline (thumbnail stores, previews) that
    /// want the accurate rendition and do not care about the cheap-first distinction.
    func thumbnail(for assetID: String, targetPixelSize: Int) async throws -> CGImage {
        try await thumbnail(for: assetID, targetPixelSize: targetPixelSize, mode: .verification)
    }

    /// Synthetic loaders (tests, previews) have no PhotoKit degradation step: serve the single
    /// frame and report no interim. The default keeps every existing conformer source-compatible.
    func previewImage(
        for assetID: String,
        targetPixelSize: Int,
        onInterim: @escaping @Sendable (CGImage) -> Void
    ) async throws -> CGImage {
        try await thumbnail(for: assetID, targetPixelSize: targetPixelSize, mode: .verification)
    }
}

/// iOS 17-compatible thumbnail loading.
///
/// Choices and their reasons:
/// - `.aspectFit` within a `targetPixelSize × targetPixelSize` box → thumbnails sized for
///   analysis, never full-resolution decoding of the library.
/// - `isNetworkAccessAllowed = false` with a **bounded failsafe**: local-only, the same
///   policy as the content-fingerprint path. Measured on a 41k library: with the network
///   allowed, every non-local asset enters Photos' make-available path at ~2.5 s per request,
///   serialized by the Photos backend — concurrent width does not lift the ceiling, so the
///   cheap stage alone would take hours. A cloud-only asset is recorded as unavailable with
///   `.contentOnlyInICloud` (reported, never hidden, never able to stall the scan);
///   `PendingPhotoRequest` still aborts a hung local request after `thumbnailTimeoutNanos`.
/// - `.highQualityFormat` delivers exactly one result (no degraded-then-final double callback),
///   `.version = .current` so the thumbnail reflects the user's edits, matching the "visible
///   content" provenance rule shared with `PhotoKitAssetSizeProvider`.
/// - `.resizeMode = .exact` for verification (the bitmap must respect the requested bound) and
///   `.fast` for the perceptual pass (cheapest scaling; only approximate size matters).
/// - Callbacks may never fire after cancellation, so the request runs through
///   `PendingPhotoRequest`, which resumes exactly once and cancels the PhotoKit request when the
///   surrounding task is cancelled.
/// - The **preview path is separate and explicit**: `previewImage` / `makePreviewRequestOptions`
///   (large box, network allowed, opportunistic frames) exist only for the Photo Details screen
///   the user just opened; nothing above — and no scanner call site — reaches them.
struct PhotoKitThumbnailLoader: PhotoThumbnailLoading {
    /// Failsafe for one analysis thumbnail request. Generous enough for a slow local decode to
    /// finish, finite enough that a stuck request costs one asset, not the scan.
    static let thumbnailTimeoutNanos: UInt64 = 15_000_000_000

    /// The PhotoKit request itself, injectable so tests can exercise the loader's success,
    /// failure, and cancellation behaviour without a photo library. The default is the live
    /// request below; nothing about the protocol seam changes.
    typealias ImageRequest = @Sendable (
        _ assetID: String,
        _ targetPixelSize: Int,
        _ mode: PhotoThumbnailRequestMode
    ) async throws -> CGImage

    /// The preview request, injectable for the same reason. Its contract includes the interim
    /// channel: `onInterim` may fire any number of times before the call returns or throws.
    typealias PreviewImageRequest = @Sendable (
        _ assetID: String,
        _ targetPixelSize: Int,
        _ onInterim: @escaping @Sendable (CGImage) -> Void
    ) async throws -> CGImage

    private let request: ImageRequest
    private let previewRequest: PreviewImageRequest

    init(
        request: @escaping ImageRequest = Self.liveRequest,
        previewRequest: @escaping PreviewImageRequest = Self.livePreviewRequest
    ) {
        self.request = request
        self.previewRequest = previewRequest
    }

    func thumbnail(
        for assetID: String,
        targetPixelSize: Int,
        mode: PhotoThumbnailRequestMode
    ) async throws -> CGImage {
        try await request(assetID, max(1, targetPixelSize), mode)
    }

    func previewImage(
        for assetID: String,
        targetPixelSize: Int,
        onInterim: @escaping @Sendable (CGImage) -> Void
    ) async throws -> CGImage {
        try await previewRequest(assetID, max(1, targetPixelSize), onInterim)
    }

    /// The production path: exactly one bounded, orientation-baked thumbnail.
    ///
    /// Runs through `PendingPhotoRequest` so a cancelled task cancels the PhotoKit request and
    /// the continuation resumes exactly once even though `requestImage` may call back on the
    /// main thread, more than once (`.opportunistic`), or — when cancelled — not at all.
    private static func liveRequest(
        assetID: String,
        targetPixelSize: Int,
        mode: PhotoThumbnailRequestMode
    ) async throws -> CGImage {
        try await PendingPhotoRequest.run(timeoutNanos: thumbnailTimeoutNanos) { resolve in
            let asset = try fetchAsset(assetID)
            let options = makeImageRequestOptions(mode: mode)

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

    /// The production preview path: one large, user-requested rendition that may use the
    /// network, with degraded frames surfaced as interim and only the final frame settling.
    ///
    /// Same `PendingPhotoRequest` bridge as the analysis path — cancellation still aborts the
    /// PhotoKit request and resumes exactly once — but the callback first asks
    /// `previewOutcome` whether this callback is intermediate: an interim frame is forwarded
    /// to `onInterim` and the continuation keeps waiting, so a degraded image is progress, not
    /// a result, and never a failure.
    private static func livePreviewRequest(
        assetID: String,
        targetPixelSize: Int,
        onInterim: @escaping @Sendable (CGImage) -> Void
    ) async throws -> CGImage {
        // 30 s: an iCloud download of one rendition can legitimately take longer than the
        // local-only analysis failsafe, and on timeout the user still gets Retry.
        try await PendingPhotoRequest.run(timeoutNanos: PendingPhotoRequest.defaultTimeoutNanos) { resolve in
            let asset = try fetchAsset(assetID)
            let options = makePreviewRequestOptions()

            let side = CGFloat(max(1, targetPixelSize))
            let targetSize = CGSize(width: side, height: side)

            let requestID = PHImageManager.default().requestImage(
                for: asset,
                targetSize: targetSize,
                contentMode: .aspectFit,
                options: options
            ) { image, info in
                switch previewOutcome(image: image, info: info) {
                case .interim:
                    if let image, let frame = normalizedCGImage(from: image) {
                        onInterim(frame)
                    }
                case .terminal(let result):
                    resolve(result)
                }
            }
            return { PHImageManager.default().cancelImageRequest(requestID) }
        }
    }

    /// What one PhotoKit callback means for a preview request. Extracted from the closure so
    /// the interim/terminal rule is testable without a photo library.
    enum PreviewOutcome {
        /// A degraded frame — progress toward the final render. The caller may surface its
        /// pixels (or ignore them) but must keep waiting; settling here is what would turn
        /// "still downloading" into a premature result or failure.
        case interim
        /// The request is over: settle the continuation with this result.
        case terminal(Result<CGImage, any Error>)
    }

    static func previewOutcome(image: UIImage?, info: [AnyHashable: Any]?) -> PreviewOutcome {
        // Cancellation and hard errors are terminal even on a degraded callback — they say
        // the request is dead, not that a better frame is coming.
        if let cancelled = info?[PHImageCancelledKey] as? Bool, cancelled {
            return .terminal(.failure(CancellationError()))
        }
        if let error = info?[PHImageErrorKey] as? any Error {
            return .terminal(.failure(mapError(error)))
        }
        if info?[PHImageResultIsDegradedKey] as? Bool == true {
            return .interim
        }
        return .terminal(result(image: image, info: info))
    }

    /// Every knob that matters for the explicit Photo Details preview, in one testable place:
    /// - `isNetworkAccessAllowed = true` — **the one exception in the app.** Opening a photo
    ///   in Photo Details is a deliberate user request, so its iCloud rendition may download.
    ///   This never applies to the analysis passes (`makeImageRequestOptions`), which keep the
    ///   local-only policy; nothing else in the app calls this factory.
    /// - `.opportunistic` → PhotoKit delivers a degraded frame first and the final render
    ///   second; `previewOutcome` routes the first to the interim channel instead of settling.
    /// - `.resizeMode = .exact` + `.aspectFit` → the delivered bitmap respects the requested
    ///   box, so the preview stays aspect-fit inside its frame without decoding full-resolution
    ///   pixels into memory.
    /// - `.version = .current` → the preview reflects the user's edits, matching the
    ///   visible-content provenance rule the analysis path uses.
    /// - `isSynchronous = false` → callback off the calling thread; no main-thread blocking.
    static func makePreviewRequestOptions() -> PHImageRequestOptions {
        let options = PHImageRequestOptions()
        options.isNetworkAccessAllowed = true
        options.version = .current
        options.deliveryMode = .opportunistic
        options.resizeMode = .exact
        options.isSynchronous = false
        return options
    }

    /// Every knob that matters for the analysis pass, in one testable place:
    /// - `isNetworkAccessAllowed = false` → local-only, matching the content-fingerprint
    ///   path: analysis never waits on a download (a non-local asset costs seconds each and
    ///   the Photos backend serializes them). Cloud-only assets are reported unavailable with
    ///   a reason instead of silently dropped or allowed to stall the scan.
    /// - `.highQualityFormat` → exactly one callback (no degraded-then-final double fire).
    /// - `.version = .current` → the thumbnail reflects the user's edits, matching the
    ///   visible-content provenance rule the fingerprinting path uses.
    /// - `.resizeMode = .exact` + `.aspectFit` request → the delivered bitmap respects the
    ///   requested bound; combined with `targetPixelSize` full-resolution pixels are never
    ///   decoded into memory. `.fast` on the perceptual pass trades exactness for speed on
    ///   a gate that only needs approximate pixels.
    /// - `isSynchronous = false` → callback off the calling thread; no main-thread blocking.
    static func makeImageRequestOptions(
        mode: PhotoThumbnailRequestMode = .verification
    ) -> PHImageRequestOptions {
        let options = PHImageRequestOptions()
        options.isNetworkAccessAllowed = false
        options.version = .current
        options.deliveryMode = .highQualityFormat
        options.resizeMode = mode == .perceptual ? .fast : .exact
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
            PhotoKitFailureTally.record(code: "image:nilResult")
            return .failure(PhotoContentError.unavailable)
        }
        return .success(cgImage)
    }

    /// `PHImageErrorKey` NSError → the loader vocabulary, using the documented `PHPhotosError`
    /// codes (iOS 15+, verified in the installed SDK headers) so downstream analysis can tell
    /// "Photos access is off" and "this photo is gone" apart from a generic failure.
    static func mapError(_ error: any Error) -> any Error {
        PhotoKitFailureTally.record(error)
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

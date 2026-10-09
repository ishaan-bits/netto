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
    /// Blur-analysis input: aspect-FILL into an exact `targetPixelSize × targetPixelSize`
    /// bitmap (center-cropped). PhotoKit's `.aspectFit` delivers a non-square rendition
    /// (e.g. 256×192 for 4:3), which the analyzer would then have to aspect-fill — a ~1.33×
    /// upscale that smooths the very signal blur detection measures. Requesting the fill
    /// from PhotoKit itself delivers an exact square with no post-scale smoothing.
    /// Same local-only, single-callback, `.exact` resize policy as `.verification`.
    case sharpness
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
/// - `.aspectFit` within a `targetPixelSize × targetPixelSize` box (perceptual and
///   verification) → thumbnails sized for analysis, never full-resolution decoding of the
///   library. The blur pass requests `.aspectFill` instead so PhotoKit delivers an exact
///   square (center-cropped) with no analyzer-side upscale smoothing.
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
///   the user just opened; nothing above — and no scanner call site — reaches them. It is
///   uncached (failures are never stored); when the primary request fails for a recoverable
///   reason, a local-rendition fallback ladder (`previewFallbackPixelSizes`) walks down to
///   whatever pixels Photos still has on disk before the screen shows an error.
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

    /// The preview's local-rendition fallback, injectable for the same reason. It runs only
    /// after a failed primary request and returns the best locally available pixels.
    typealias PreviewFallbackRequest = @Sendable (
        _ assetID: String,
        _ targetPixelSize: Int
    ) async throws -> CGImage

    private let request: ImageRequest
    private let previewRequest: PreviewImageRequest
    private let fallbackRequest: PreviewFallbackRequest

    init(
        request: @escaping ImageRequest = Self.liveRequest,
        previewRequest: @escaping PreviewImageRequest = Self.livePreviewRequest,
        fallbackRequest: @escaping PreviewFallbackRequest = Self.livePreviewFallbackRequest
    ) {
        self.request = request
        self.previewRequest = previewRequest
        self.fallbackRequest = fallbackRequest
    }

    func thumbnail(
        for assetID: String,
        targetPixelSize: Int,
        mode: PhotoThumbnailRequestMode
    ) async throws -> CGImage {
        try await request(assetID, max(1, targetPixelSize), mode)
    }

    /// The large Photo Details rendition: the primary network-enabled request, then — when it
    /// fails for a recoverable reason — one automatic fallback to the local-rendition ladder.
    ///
    /// The primary request can fail without the photo being gone: an edited asset whose large
    /// rendition only exists in iCloud (whose download may be broken on this device), a
    /// network blip, a timeout. Rather than showing "Photo unavailable" while a smaller local
    /// copy of the same photo sits on disk, `fallbackRequest` walks down `previewFallbackPixelSizes`
    /// and returns the best pixels Photos can serve locally — fresh requests throughout, never
    /// a replay of a cached miss. Cancellation and permanent failures (permission, missing
    /// asset) skip the fallback; if the fallback also fails, the *primary* error surfaces,
    /// because it explains the screen better than the ladder's last miss.
    func previewImage(
        for assetID: String,
        targetPixelSize: Int,
        onInterim: @escaping @Sendable (CGImage) -> Void
    ) async throws -> CGImage {
        let side = max(1, targetPixelSize)
        let primaryError: any Error
        do {
            return try await previewRequest(assetID, side, onInterim)
        } catch {
            primaryError = error
        }
        guard Self.isPreviewFallbackCandidate(primaryError), !Task.isCancelled else {
            throw primaryError
        }
        do {
            return try await fallbackRequest(assetID, side)
        } catch {
            if error is CancellationError || Task.isCancelled { throw error }
            throw primaryError
        }
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
            let contentMode: PHImageContentMode = mode == .sharpness ? .aspectFill : .aspectFit

            let requestID = PHImageManager.default().requestImage(
                for: asset,
                targetSize: targetSize,
                contentMode: contentMode,
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
    /// a result, and never a failure. A final frame settles with its pixels even if PhotoKit
    /// still flags the rendition as iCloud-origin; a final callback without pixels fails
    /// recoverably, and `previewImage` falls back to the local-rendition ladder before any
    /// error reaches the screen.
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

    /// Sizes the preview fallback tries, largest first, each strictly below the primary
    /// preview budget. Photos serves a local rendition only when the target fits what is on
    /// disk — verified: an edited asset whose 1400 px download fails still returns its ~256 px
    /// local thumbnail — so the ladder descends to the thumbnail floor (256 px), where every
    /// analyzed asset has served pixels at least once.
    static let previewFallbackPixelSizes: [Int] = [768, 512, 384, 256]

    /// Failsafe for one fallback step. Steps are local-or-fast-fail by construction (single-shot
    /// delivery at thumbnail-ish sizes), so 10 s bounds the pathological case — a step that is
    /// actually waiting on a download — without stacking another full preview timeout per rung.
    static let previewFallbackTimeoutNanos: UInt64 = 10_000_000_000

    /// The production fallback: fresh, direct `PHImageManager` requests descending
    /// `previewFallbackPixelSizes` until one returns pixels. Network stays allowed — a small
    /// target is satisfied by a local thumbnail without downloading (verified), while an asset
    /// with no local copy still gets its one chance to fetch — but these are the fallback's own
    /// options (single-shot, never the scanner's network-disabled path).
    private static func livePreviewFallbackRequest(
        assetID: String,
        targetPixelSize: Int
    ) async throws -> CGImage {
        try await previewFallbackLadder(targetPixelSize: targetPixelSize) { size in
            try await PendingPhotoRequest.run(timeoutNanos: previewFallbackTimeoutNanos) { resolve in
                let asset = try fetchAsset(assetID)
                let options = makePreviewFallbackRequestOptions()

                let side = CGFloat(size)
                let targetSize = CGSize(width: side, height: side)

                let requestID = PHImageManager.default().requestImage(
                    for: asset,
                    targetSize: targetSize,
                    contentMode: .aspectFit,
                    options: options
                ) { image, info in
                    resolve(result(image: image, info: info))
                }
                return { PHImageManager.default().cancelImageRequest(requestID) }
            }
        }
    }

    /// The ladder itself, extracted so its policy — largest first, stop at the first success,
    /// skip sizes the primary request already covered, never retry cancellation — is testable
    /// without a photo library. The last failure is what surfaces if no rung serves.
    static func previewFallbackLadder(
        targetPixelSize: Int,
        attempt: @Sendable (Int) async throws -> CGImage
    ) async throws -> CGImage {
        var lastError: (any Error)?
        for size in previewFallbackPixelSizes where size < targetPixelSize {
            if Task.isCancelled { throw CancellationError() }
            do {
                return try await attempt(size)
            } catch {
                if error is CancellationError { throw error }
                lastError = error
            }
        }
        throw lastError ?? PhotoContentError.unavailable
    }

    /// Whether a primary-preview failure is worth one local-rendition attempt. Cancellation is
    /// the user leaving — never retried. Permission and missing-asset failures are permanent
    /// (a ladder rung would fail identically). Everything else — iCloud, unavailable, timeout,
    /// foreign cloud/network errors — is exactly the case the ladder exists for.
    static func isPreviewFallbackCandidate(_ error: any Error) -> Bool {
        if error is CancellationError { return false }
        if let content = error as? PhotoContentError {
            switch content {
            case .permissionDenied, .assetNotFound: return false
            case .onlyInICloud, .unavailable: return true
            }
        }
        return true
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
            return .terminal(.failure(mapPreviewError(error)))
        }
        if info?[PHImageResultIsDegradedKey] as? Bool == true {
            return .interim
        }
        // Final, non-degraded callback. Valid pixels settle the preview even when PhotoKit
        // still flags the rendition as iCloud-origin: the SDK documents `PHImageResultIsInCloudKey`
        // as "a new request will need to get issued (with networkAccessAllowed set)" — the flag
        // describes where the pixels came from, not that they are absent, and this request
        // already allows the network. Rejecting a delivered final image here would blank a
        // working screen with "Photo unavailable".
        if let image, let frame = normalizedCGImage(from: image) {
            return .terminal(.success(frame))
        }
        // No pixels on the final callback: classify exactly like the analysis result path
        // (cloud-only vs. genuinely missing); the loader's single retry re-issues the request.
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

    /// Options for one rung of the local-rendition ladder:
    /// - `isNetworkAccessAllowed = true` → a small target is satisfied by a local thumbnail
    ///   without downloading (verified on a download-broken asset), while an asset with no
    ///   local copy still gets its one chance to fetch. The ladder is the preview's own
    ///   recovery path — it never adopts the scanner's network-disabled policy.
    /// - `.highQualityFormat` → exactly one callback: this request *is* the retry, so there is
    ///   no degraded-then-final dance, just a fast local answer or a fast failure.
    /// - `.version = .current` / `.resizeMode = .exact` / `isSynchronous = false` → same
    ///   provenance, bound, and threading rules as the primary preview request.
    static func makePreviewFallbackRequestOptions() -> PHImageRequestOptions {
        let options = PHImageRequestOptions()
        options.isNetworkAccessAllowed = true
        options.version = .current
        options.deliveryMode = .highQualityFormat
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
    /// - `.resizeMode = .exact` → the delivered bitmap respects the requested bound;
    ///   combined with `targetPixelSize` full-resolution pixels are never decoded into
    ///   memory. Content mode is not an options knob — it is chosen in `liveRequest`:
    ///   `.aspectFit` for perceptual/verification, `.aspectFill` for the `.sharpness`
    ///   blur pass (exact square, no analyzer-side upscale). `.fast` on the perceptual
    ///   pass trades exactness for speed on a gate that only needs approximate pixels.
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

    /// Preview-only mapping on top of `mapError`: Photos' cloud-download failures surface as
    /// `CloudPhotoLibraryErrorDomain` (e.g. code 1006, "Failed to download JPEGMedium") — an
    /// iCloud-download problem, so the honest copy is "only in iCloud", not the generic bucket.
    /// The scanner never issues a network request and therefore never observes this domain,
    /// which is why the shared `mapError` stays untouched.
    static func mapPreviewError(_ error: any Error) -> any Error {
        let nsError = error as NSError
        guard nsError.domain == "CloudPhotoLibraryErrorDomain" else { return mapError(error) }
        PhotoKitFailureTally.record(error)
        return PhotoContentError.onlyInICloud
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

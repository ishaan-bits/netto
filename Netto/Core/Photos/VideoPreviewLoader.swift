import AVFoundation
import Foundation
import Photos

/// Seam over video playback delivery, so preview behaviour is testable without a photo
/// library. Implementations must never download: a video whose content is only in iCloud
/// fails with `PhotoContentError.onlyInICloud` instead of silently fetching bytes.
protocol VideoPreviewLoading: Sendable {
    /// A **local, playable** file URL for the video, or a `PhotoContentError` explaining why
    /// this video cannot be previewed right now.
    func playbackURL(for assetID: String) async throws -> URL
}

/// iOS 17-compatible preview loading.
///
/// One `PHImageManager.requestAVAsset` per preview, with the same knobs the rest of the app
/// applies to local-only reads:
/// - `isNetworkAccessAllowed = false` → an iCloud-only video reports `.onlyInICloud`
///   instead of streaming during a preview.
/// - `version = .current` → the previewed file is the visible (edited) render, matching the
///   "visible content" provenance of sizing and fingerprinting.
/// - `.highQualityFormat` → the full local file for playback, not a medium-quality stream.
/// - The request runs through `PendingPhotoRequest`, so the continuation resumes exactly
///   once even though the handler may fire more than once or — when cancelled — not at all.
///
/// Only an `AVURLAsset` yields a URL: a non-file-backed asset cannot be handed to `AVPlayer`
/// without network access, so it is reported `.unavailable` rather than guessed at.
struct PhotoKitVideoPreviewLoader: VideoPreviewLoading {
    /// The PhotoKit request itself, injectable so tests can exercise success, failure, and
    /// cancellation without a photo library. The default is the live request below.
    typealias AssetRequest = @Sendable (_ assetID: String) async throws -> URL

    private let request: AssetRequest

    init() {
        request = Self.liveRequest
    }

    init(request: @escaping AssetRequest) {
        self.request = request
    }

    func playbackURL(for assetID: String) async throws -> URL {
        try await request(assetID)
    }

    /// The production path: one bounded, local-only request for a playable file URL.
    private static func liveRequest(assetID: String) async throws -> URL {
        try await PendingPhotoRequest.run { resolve in
            // Everything non-Sendable (PHAsset, AVAsset) stays inside this @Sendable closure;
            // only `Result<URL, any Error>` ever crosses a concurrency boundary.
            let asset = try PhotoKitThumbnailLoader.fetchAsset(assetID)
            let options = makeVideoRequestOptions()

            let requestID = PHImageManager.default().requestAVAsset(
                forVideo: asset,
                options: options
            ) { avAsset, _, info in
                resolve(Self.result(avAsset: avAsset, info: info))
            }
            return { PHImageManager.default().cancelImageRequest(requestID) }
        }
    }

    /// Every knob that matters for preview playback, in one testable place.
    static func makeVideoRequestOptions() -> PHVideoRequestOptions {
        let options = PHVideoRequestOptions()
        options.isNetworkAccessAllowed = false
        options.version = .current
        options.deliveryMode = .highQualityFormat
        return options
    }

    /// Pure decision function over the values PhotoKit hands back — the unit-testable core.
    static func result(
        avAsset: AVAsset?,
        info: [AnyHashable: Any]?
    ) -> Result<URL, any Error> {
        if let cancelled = info?[PHImageCancelledKey] as? Bool, cancelled {
            return .failure(CancellationError())
        }
        if let error = info?[PHImageErrorKey] as? any Error {
            return .failure(PhotoKitThumbnailLoader.mapError(error))
        }
        if let inCloud = info?[PHImageResultIsInCloudKey] as? Bool, inCloud {
            return .failure(PhotoContentError.onlyInICloud)
        }
        guard let urlAsset = avAsset as? AVURLAsset else {
            return .failure(PhotoContentError.unavailable)
        }
        return .success(urlAsset.url)
    }
}

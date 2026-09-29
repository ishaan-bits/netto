import AVFoundation
import Foundation
import Photos

/// iOS 17-compatible exact-content fingerprinting.
///
/// Like `PhotoKitAssetSizeProvider`, it resolves local file URLs through
/// `PHContentEditingInput` with `isNetworkAccessAllowed = false` — so nothing is ever downloaded
/// — and then works on those URLs only:
///
/// - photo / edited photo → `fullSizeImageURL`
/// - video → `AVURLAsset.url`
/// - Live Photo → still **and** paired video, both required
///
/// The two `ContentFingerprinting` methods map onto one resolution step:
/// - `byteKey` stats the files (no content read) — the cheap phase-1 pre-filter.
/// - `fingerprint` additionally streams SHA-256 over each file — phase 2, only for length
///   collisions.
///
/// Limitations, stated rather than hidden:
/// - iCloud-only content resolves to `.contentOnlyInICloud`; it is reported, never guessed at.
/// - A Live Photo whose paired video is not locally resolvable is `.contentUnreadable` rather
///   than a still-only fingerprint: fingerprinting just the still would let it "match" a plain
///   copy of the same image while its movie (which the user also owns) goes uncounted.
/// - For an edited asset the hashed image is the full-size render (PhotoKit renders it because
///   `canHandleAdjustmentData` always returns false), not the pre-edit original — the same
///   "visible content" provenance the sizing path uses.
struct PhotoKitContentFingerprinter: ContentFingerprinting {
    /// Resolution step, injectable so outcome mapping is testable without a photo library.
    /// The default is the live PhotoKit resolution below.
    typealias ContentResolution = @Sendable (PhotoAssetRecord) async throws -> ResolvedContent

    private let resolve: ContentResolution

    init() {
        resolve = Self.resolveLive
    }

    init(resolve: @escaping ContentResolution) {
        self.resolve = resolve
    }

    func byteKey(for record: PhotoAssetRecord) async throws -> ContentLengthOutcome {
        do {
            let content = try await resolve(record)
            return .key(
                ContentByteKey(imageBytes: content.imageBytes, videoBytes: content.videoBytes)
            )
        } catch let reason as PhotoAnalysisUnavailableReason {
            return .unavailable(reason)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as PhotoContentError {
            return .unavailable(Self.reason(for: error))
        }
    }

    func fingerprint(for record: PhotoAssetRecord) async throws -> ContentFingerprintOutcome {
        do {
            let content = try await resolve(record)
            var imageDigest: String?
            var videoDigest: String?
            if let image = content.image {
                imageDigest = try await ContentHasher.sha256Hex(ofFileAt: image.url)
            }
            if let video = content.video {
                videoDigest = try await ContentHasher.sha256Hex(ofFileAt: video.url)
            }
            return .fingerprinted(
                ContentFingerprint(
                    imageBytes: content.imageBytes,
                    videoBytes: content.videoBytes,
                    imageDigestHex: imageDigest,
                    videoDigestHex: videoDigest
                )
            )
        } catch let reason as PhotoAnalysisUnavailableReason {
            return .unavailable(reason)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as PhotoContentError {
            return .unavailable(Self.reason(for: error))
        }
    }

    /// `PhotoContentError` → the analysis vocabulary. Keeps "Photos access is off" and "this
    /// photo was deleted" distinct instead of collapsing both into "unreadable".
    static func reason(for error: PhotoContentError) -> PhotoAnalysisUnavailableReason {
        switch error {
        case .permissionDenied: return .permissionUnavailable
        case .assetNotFound: return .assetNotFound
        case .onlyInICloud: return .contentOnlyInICloud
        case .unavailable: return .contentUnreadable
        }
    }

    // MARK: - Resolution

    struct ResolvedContent: Sendable {
        let image: (url: URL, bytes: Int64)?
        let video: (url: URL, bytes: Int64)?

        var imageBytes: Int64 { image?.bytes ?? 0 }
        var videoBytes: Int64 { video?.bytes ?? 0 }
    }

    /// The production resolution: one local-only `PHContentEditingInput` request per asset.
    private static func resolveLive(_ record: PhotoAssetRecord) async throws -> ResolvedContent {
        // The PhotoKit callback runs on an arbitrary serial queue and hands back non-Sendable
        // objects, so the asset fetch, the options, and the whole conversion to a Sendable value
        // happen *inside* the @Sendable start closure — only `ResolvedContent` or a thrown
        // reason ever crosses a concurrency boundary.
        try await PendingPhotoRequest.run { resolve in
            let asset = try PhotoKitThumbnailLoader.fetchAsset(record.localIdentifier)

            let options = makeContentRequestOptions()

            let requestID = asset.requestContentEditingInput(with: options) { input, info in
                resolve(Self.resolveContent(
                    info: info,
                    record: record,
                    imageURL: input?.fullSizeImageURL,
                    videoURL: (input?.audiovisualAsset as? AVURLAsset)?.url
                ))
            }
            return { asset.cancelContentEditingInputRequest(requestID) }
        }
    }

    /// Every knob that matters for fingerprinting, in one testable place:
    /// - `isNetworkAccessAllowed = false` → local-only; an iCloud-only asset is reported, never
    ///   downloaded during an analysis pass.
    /// - `canHandleAdjustmentData = { _ in false }` → PhotoKit renders the edited version for
    ///   us, so the hashed bytes are the *visible* content (the provenance rule in
    ///   ARCHITECTURE.md), not the hidden pre-edit original.
    static func makeContentRequestOptions() -> PHContentEditingInputRequestOptions {
        let options = PHContentEditingInputRequestOptions()
        options.isNetworkAccessAllowed = false
        options.canHandleAdjustmentData = { _ in false }
        return options
    }

    /// Pure decision function over the values PhotoKit hands back — the unit-testable core of
    /// "what counts as readable, complete local content". `input`'s URLs are extracted by the
    /// caller because `PHContentEditingInput` has no public initializer, so tests drive this
    /// with plain URLs and info dictionaries instead.
    static func resolveContent(
        info: [AnyHashable: Any],
        record: PhotoAssetRecord,
        imageURL: URL?,
        videoURL: URL?
    ) -> Result<ResolvedContent, any Error> {
        if let cancelled = info[PHContentEditingInputCancelledKey] as? Bool, cancelled {
            return .failure(CancellationError())
        }
        if let inCloud = info[PHContentEditingInputResultIsInCloudKey] as? Bool, inCloud {
            return .failure(PhotoAnalysisUnavailableReason.contentOnlyInICloud)
        }
        if let error = info[PHContentEditingInputErrorKey] as? any Error {
            return .failure(reason(forPhotosError: error))
        }

        // Completeness rules — a fingerprint is only meaningful if it covers the asset's full
        // local content.
        if record.isLivePhoto, videoURL == nil {
            return .failure(PhotoAnalysisUnavailableReason.contentUnreadable)
        }
        if record.isVideo, videoURL == nil {
            return .failure(PhotoAnalysisUnavailableReason.contentUnreadable)
        }
        guard imageURL != nil || videoURL != nil else {
            return .failure(PhotoAnalysisUnavailableReason.contentUnreadable)
        }

        var image: (url: URL, bytes: Int64)?
        if let url = imageURL {
            guard let bytes = ContentHasher.fileSize(at: url) else {
                return .failure(PhotoAnalysisUnavailableReason.contentUnreadable)
            }
            image = (url, bytes)
        }

        var video: (url: URL, bytes: Int64)?
        if let url = videoURL {
            guard let bytes = ContentHasher.fileSize(at: url) else {
                return .failure(PhotoAnalysisUnavailableReason.contentUnreadable)
            }
            video = (url, bytes)
        }

        return .success(ResolvedContent(image: image, video: video))
    }

    /// `PHContentEditingInputErrorKey` NSError → analysis vocabulary, using the documented
    /// `PHPhotosError` codes (iOS 15+, verified in the installed SDK headers).
    static func reason(forPhotosError error: any Error) -> any Error {
        let nsError = error as NSError
        guard nsError.domain == PHPhotosErrorDomain else { return error }
        switch nsError.code {
        case PHPhotosError.Code.accessUserDenied.rawValue,
             PHPhotosError.Code.accessRestricted.rawValue:
            return PhotoAnalysisUnavailableReason.permissionUnavailable
        case PHPhotosError.Code.identifierNotFound.rawValue:
            return PhotoAnalysisUnavailableReason.assetNotFound
        case PHPhotosError.Code.networkAccessRequired.rawValue:
            return PhotoAnalysisUnavailableReason.contentOnlyInICloud
        default:
            return PhotoAnalysisUnavailableReason.contentUnreadable
        }
    }
}

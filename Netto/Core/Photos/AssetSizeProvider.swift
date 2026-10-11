import AVFoundation
import Foundation
import Photos

/// Which `PHAssetResourceType`s actually represent reclaimable user content.
///
/// A single `PHAsset` is not one file. It can hold an original, an edited full-size render,
/// adjustment blobs, a Live Photo paired video, a RAW alternate, and (on iOS 17+) a proxy — each
/// a separate resource. Summing everything blindly would double count and would credit metadata
/// blobs as user content. This scope is the documented answer to "what counts".
///
/// It is defined even though iOS 17 cannot cheaply apply it: `PHAssetResource.dataSize` is
/// iOS 27+. The policy is written down now so sizing has one authoritative rule instead of an
/// ad-hoc sum buried in a call site, and so adopting `dataSize` later is a mechanical change.
enum AssetResourceScope {
    /// Payload whose deletion frees space the user would recognize as "my photo / my video".
    static let countedTypes: Set<PHAssetResourceType> = [
        .photo,
        .video,
        .fullSizePhoto,
        .fullSizeVideo,
        .pairedVideo,
        .fullSizePairedVideo,
        .alternatePhoto,
    ]

    /// Excluded on purpose:
    /// - `adjustmentData` / `adjustmentBase*`: edit instructions and intermediates. Not user
    ///   content, and counting them alongside the render that replaced them double counts.
    /// - `audio`: no Photos asset in Netto's scope carries a standalone audio payload.
    /// - `photoProxy`: a lightweight stand-in, not the content itself.
    static let excludedTypes: Set<PHAssetResourceType> = [
        .adjustmentData,
        .adjustmentBasePhoto,
        .adjustmentBaseVideo,
        .adjustmentBasePairedVideo,
        .audio,
        .photoProxy,
    ]

    static func counts(_ type: PHAssetResourceType) -> Bool {
        countedTypes.contains(type)
    }

    static func countableTypes(in resources: [PHAssetResource]) -> [PHAssetResource] {
        resources.filter { counts($0.type) }
    }
}

/// Resolves exact byte sizes for assets the user is already moving toward review.
///
/// Contract:
/// - **Never called during enumeration.** The catalog stage must not depend on sizing to make
///   progress; sizing is a separate, explicitly triggered step over a bounded, user-selected set.
/// - **Absent means unknown.** Returned dictionaries omit identifiers that could not be measured.
///   Callers treat a missing entry as `nil`, never as `0`.
/// - **Measured, not estimated.** Values come from stat-ing content that is already on device;
///   nothing is downloaded to obtain a number.
protocol AssetSizeProviding: Sendable {
    func sizes(for localIdentifiers: [String]) async -> [String: Int64]
}

/// One asset's sizing outcome — measured bytes, or an honest "could not measure".
///
/// Distinct from a bare `[String: Int64]` so a batch of failures still advances progress:
/// the video-size pass can count attempts that resolved to unavailable without ever folding
/// them into the measured total (an unavailable size is never a completed measurement, and
/// it is never zero).
enum VideoSizeOutcome: Sendable, Equatable {
    case measured(Int64)
    case unavailable
}

extension AssetSizeProviding {
    /// Per-asset outcomes for the video-size pass. The default derives outcomes from
    /// `sizes(for:)` — every requested identifier the provider did not answer is
    /// unavailable (the documented "absent means unknown" contract). Providers that can
    /// classify natively override this; fixtures and test doubles need no change.
    func outcomes(for localIdentifiers: [String]) async -> [String: VideoSizeOutcome] {
        let sizes = await sizes(for: localIdentifiers)
        var outcomes: [String: VideoSizeOutcome] = [:]
        outcomes.reserveCapacity(localIdentifiers.count)
        for identifier in localIdentifiers {
            outcomes[identifier] = sizes[identifier].map(VideoSizeOutcome.measured) ?? .unavailable
        }
        return outcomes
    }
}

extension Array where Element == PhotoAssetRecord {
    /// Fills in `sizeInBytes` for records whose size is still unknown.
    ///
    /// Pass a bounded, user-selected subset — this resolves real content per asset and is not
    /// something to run across a whole library. Records the provider could not measure keep
    /// `nil`; they are never defaulted to zero.
    func resolvingSizes(using provider: any AssetSizeProviding) async -> [PhotoAssetRecord] {
        let unresolved = filter { $0.sizeInBytes == nil }.map(\.localIdentifier)
        guard !unresolved.isEmpty else { return self }

        let sizes = await provider.sizes(for: unresolved)
        return map { record in
            guard let bytes = sizes[record.localIdentifier] else { return record }
            return record.resolvingSize(bytes)
        }
    }
}

/// iOS 17-compatible exact sizing.
///
/// `PHAssetResource.dataSize` does not exist before iOS 27, so there is no metadata-only byte
/// count available at runtime. This provider instead asks PhotoKit for the asset's content editing
/// input **with network access disabled** — which never downloads anything — and stats the file
/// URLs it hands back:
///
/// - photo / edited photo → `fullSizeImageURL` (the render actually on disk)
/// - video and Live Photo paired video → `AVURLAsset.url`
///
/// Both are summed when present, which covers a Live Photo's still + movie. Adjustment blobs are
/// not summed; per `AssetResourceScope` they are not counted, and on iOS 17 they are not
/// measurable without fetching data.
///
/// Limitations, stated rather than hidden:
/// - An asset whose data lives only in iCloud has no local content URL here, so it is reported as
///   unknown rather than guessed.
/// - For an edited asset the measured image is the full-size render, not the pre-edit original.
/// - Resolution is short-lived and never touches the network, so an in-flight request is allowed
///   to complete rather than risking a continuation that PhotoKit never calls back into.
struct PhotoKitAssetSizeProvider: AssetSizeProviding {
    var maxConcurrentResolutions: Int = 4

    func sizes(for localIdentifiers: [String]) async -> [String: Int64] {
        let outcomes = await outcomes(for: localIdentifiers)
        var sizes: [String: Int64] = [:]
        for (identifier, outcome) in outcomes {
            if case .measured(let bytes) = outcome {
                sizes[identifier] = bytes
            }
        }
        return sizes
    }

    /// The native outcome pass: every requested asset resolves to `.measured` or
    /// `.unavailable` — never a silently dropped identifier — so the caller's progress
    /// reflects the work that actually happened even when a whole batch fails (an
    /// iCloud-only library used to leave the screen pinned at "0 of N" through every
    /// failed batch).
    func outcomes(for localIdentifiers: [String]) async -> [String: VideoSizeOutcome] {
        guard !localIdentifiers.isEmpty else { return [:] }

        let fetchOptions = PHFetchOptions()
        fetchOptions.fetchLimit = localIdentifiers.count
        let assets = PHAsset.fetchAssets(withLocalIdentifiers: localIdentifiers, options: fetchOptions)
        guard assets.count > 0 else {
            // Nothing resolved — every requested identifier is unavailable, honestly.
            var outcomes: [String: VideoSizeOutcome] = [:]
            outcomes.reserveCapacity(localIdentifiers.count)
            for identifier in localIdentifiers {
                outcomes[identifier] = .unavailable
            }
            return outcomes
        }

        let policy = ScanConcurrencyPolicy()
        var outcomes: [String: VideoSizeOutcome] = [:]
        outcomes.reserveCapacity(localIdentifiers.count)

        var index = 0
        while index < assets.count {
            // Thermal-adaptive batch width, re-read every batch so pressure changes during a
            // long video-size scan take effect; a critical state pauses between batches
            // (non-throwing API: cancellation exits early with what has been measured).
            while policy.isCriticallyPressed {
                if Task.isCancelled { return outcomes }
                try? await Task.sleep(for: .milliseconds(250))
            }
            let width = policy.width(base: maxConcurrentResolutions)
            let end = min(index + width, assets.count)
            let batch = (index..<end).map { assets.object(at: $0) }
            index = end

            let resolved = await withTaskGroup(
                of: SizeMeasurement.self,
                returning: [SizeMeasurement].self
            ) { group in
                for asset in batch {
                    group.addTask {
                        let bytes = await Self.contentBytes(for: asset)
                        return SizeMeasurement(
                            localIdentifier: asset.localIdentifier,
                            outcome: bytes.map(VideoSizeOutcome.measured) ?? .unavailable
                        )
                    }
                }
                var collected: [SizeMeasurement] = []
                for await value in group {
                    collected.append(value)
                }
                return collected
            }

            for measurement in resolved {
                outcomes[measurement.localIdentifier] = measurement.outcome
            }
        }

        // Identifiers the fetch never resolved (deleted mid-run, outside limited access)
        // are unavailable, not missing — the caller's counts stay honest either way.
        for identifier in localIdentifiers where outcomes[identifier] == nil {
            outcomes[identifier] = .unavailable
        }
        return outcomes
    }

    private struct SizeMeasurement: Sendable {
        let localIdentifier: String
        let outcome: VideoSizeOutcome
    }

    private static func contentBytes(for asset: PHAsset) async -> Int64? {
        await withCheckedContinuation { (continuation: CheckedContinuation<Int64?, Never>) in
            let options = PHContentEditingInputRequestOptions()
            options.isNetworkAccessAllowed = false
            options.canHandleAdjustmentData = { _ in false }

            _ = asset.requestContentEditingInput(with: options) { input, _ in
                guard let input else {
                    continuation.resume(returning: nil)
                    return
                }
                var total: Int64 = 0
                var found = false
                if let url = input.fullSizeImageURL, let size = Self.fileSize(at: url) {
                    total += size
                    found = true
                }
                if let urlAsset = input.audiovisualAsset as? AVURLAsset, let size = Self.fileSize(at: urlAsset.url) {
                    total += size
                    found = true
                }
                continuation.resume(returning: found ? total : nil)
            }
        }
    }

    private static func fileSize(at url: URL) -> Int64? {
        guard let values = try? FileManager.default.attributesOfItem(atPath: url.path),
              let number = values[.size] as? NSNumber else { return nil }
        let bytes = number.int64Value
        return bytes > 0 ? bytes : nil
    }
}

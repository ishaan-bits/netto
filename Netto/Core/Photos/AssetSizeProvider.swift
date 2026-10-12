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

/// iOS 17-compatible exact sizing, built so a cloud-only library can never hang the pass.
///
/// `PHAssetResource.dataSize` does not exist before iOS 27, so there is no metadata-only byte
/// count available at runtime. Measurement therefore stats the content URLs PhotoKit hands
/// back **with network access disabled** — which never downloads anything — racing every
/// callback against a hard deadline:
///
/// - **Plain videos** → `PHImageManager.requestAVAsset(forVideo:)`. A locally available
///   video answers promptly with an `AVURLAsset` whose file URL is stat-ed; a cloud-only
///   video answers promptly with nil (the API's documented "not available locally"
///   behaviour) — the honest unavailable outcome at callback speed, not after a deadline
///   wait. (The previous `requestContentEditingInput` path could delay its callback for a
///   cloud-only video indefinitely, which hung the whole pass at "0 of N".)
/// - **Live Photos and photos** → `requestContentEditingInput`, whose input hands back the
///   full-size image URL and/or the paired-video `AVURLAsset` (both stat-ed; summed for a
///   Live Photo, per `AssetResourceScope`).
///
/// Limitations, stated rather than hidden:
/// - An asset whose data lives only in iCloud has no local content URL here, so it is
///   reported as unavailable rather than guessed — and never downloaded to measure.
/// - For an edited asset the measured content is the current version, not the pre-edit
///   original.
/// - `requestContentEditingInput` is documented to report failure for a cloud-only asset,
///   but has been observed to delay that report indefinitely; the deadline race below is
///   what keeps such a callback from hanging an entire measurement pass.
struct PhotoKitAssetSizeProvider: AssetSizeProviding {
    var maxConcurrentResolutions: Int = 4
    /// Per-asset ceiling on a PhotoKit callback (see the type docs). Exceeding it yields an
    /// honest `.unavailable` — never a hang, never zero.
    var callbackDeadlineNanoseconds: UInt64 = 5_000_000_000
    /// Per-asset exact-bytes resolution, injectable for tests (M15-R1). `nil` binds the
    /// production PhotoKit resource ladder below. Keyed by local identifier so tests need
    /// neither a photo library nor network access.
    var exactBytes: (@Sendable (String) async -> Int64?)?

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

        // The injectable seam (M15-R1): tests drive the whole outcome mapping without a
        // photo library, so the measured/unavailable contract is deterministic.
        if let exactBytes {
            var outcomes: [String: VideoSizeOutcome] = [:]
            outcomes.reserveCapacity(localIdentifiers.count)
            for identifier in localIdentifiers {
                outcomes[identifier] = await exactBytes(identifier).map(VideoSizeOutcome.measured) ?? .unavailable
            }
            return outcomes
        }

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
        let deadline = callbackDeadlineNanoseconds
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
                let override = exactBytes
                for asset in batch {
                    group.addTask {
                        let bytes = await Self.contentBytes(
                            for: asset,
                            deadlineNanoseconds: deadline,
                            override: override
                        )
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

    /// First-answer-wins race of a PhotoKit callback against a hard deadline. Returns the
    /// callback's answer if it arrives in time, `nil` if the deadline wins; a callback that
    /// arrives late is dropped without a second resume. This is what keeps a pathological
    /// PhotoKit callback from hanging an entire measurement pass.
    static func withDeadline<Value: Sendable>(
        nanoseconds: UInt64,
        start: (@escaping @Sendable (Value?) -> Void) -> Void
    ) async -> Value? {
        let box = OneShotValue<Value>()
        let deadline = Task {
            try? await Task.sleep(nanoseconds: nanoseconds)
            guard !Task.isCancelled else { return }
            box.settle(with: nil)
        }
        start { box.settle(with: $0) }
        let value = await box.wait()
        deadline.cancel()
        return value
    }

    private static func contentBytes(
        for asset: PHAsset,
        deadlineNanoseconds: UInt64,
        override: (@Sendable (String) async -> Int64?)?
    ) async -> Int64? {
        if let override {
            return await override(asset.localIdentifier)
        }
        switch asset.mediaType {
        case .video where !asset.mediaSubtypes.contains(.photoLive):
            return await videoBytes(for: asset, deadlineNanoseconds: deadlineNanoseconds)
        default:
            // Live Photos keep the content-editing-input measurement (still + paired video,
            // per AssetResourceScope); photos use the same path for their full-size render.
            return await editingInputBytes(for: asset, deadlineNanoseconds: deadlineNanoseconds)
        }
    }

    /// The exact-bytes ladder for one plain video (M15-R1), all rungs local-only — a size
    /// is never obtained by downloading anything:
    ///
    /// 1. the **current version's** file (the one the user sees; for an unedited video
    ///    this is simply the video file on disk);
    /// 2. the **original version's** file. `requestAVAsset(version: .current)` answers an
    ///    `AVComposition` — no file URL — for an *edited* video even when the whole asset
    ///    is local, which used to classify fully local videos as unmeasurable. The
    ///    original file is still on disk and is exactly the bytes deleting frees (minus
    ///    the small adjustment record), so it is a validated measurement, not a guess;
    /// 3. otherwise `nil` — genuinely unavailable locally (cloud-only), reported honestly
    ///    and never as zero.
    ///
    /// Both rungs go through the same first-answer-wins deadline as every other PhotoKit
    /// callback here, so a pathological callback cannot hang a measurement batch.
    struct VideoBytesProbes: Sendable {
        var currentVersionURL: @Sendable (String) async -> URL?
        var originalVersionURL: @Sendable (String) async -> URL?
    }

    static func videoBytes(assetID: String, probes: VideoBytesProbes) async -> Int64? {
        if let url = await probes.currentVersionURL(assetID), let bytes = fileSize(at: url) {
            return bytes
        }
        if let url = await probes.originalVersionURL(assetID), let bytes = fileSize(at: url) {
            return bytes
        }
        return nil
    }

    /// The plain-video path: the production ladder over PhotoKit, network access disabled
    /// at every rung (a cloud-only video answers nil promptly — the honest unavailable
    /// outcome at callback speed).
    private static func videoBytes(
        for asset: PHAsset,
        deadlineNanoseconds: UInt64
    ) async -> Int64? {
        let assetID = asset.localIdentifier
        let deadline = deadlineNanoseconds
        return await videoBytes(
            assetID: assetID,
            probes: VideoBytesProbes(
                currentVersionURL: { id in
                    await assetURL(id, version: .current, deadlineNanoseconds: deadline)
                },
                originalVersionURL: { id in
                    await assetURL(id, version: .original, deadlineNanoseconds: deadline)
                }
            )
        )
    }

    /// One `requestAVAsset` rung: resolves the asset (process-wide reference cache), asks
    /// for one version with network access disabled, and answers the file URL if PhotoKit
    /// handed back a plain `AVURLAsset` (a composition has no file URL and answers nil).
    private static func assetURL(
        _ assetID: String,
        version: PHVideoRequestOptionsVersion,
        deadlineNanoseconds: UInt64
    ) async -> URL? {
        await withDeadline(nanoseconds: deadlineNanoseconds) { deliver in
            let asset = PhotoAssetReferenceCache.shared.asset(for: assetID)
            guard let asset, asset.mediaType == .video else {
                deliver(nil)
                return
            }
            let options = PHVideoRequestOptions()
            options.isNetworkAccessAllowed = false
            options.version = version
            PHImageManager.default().requestAVAsset(forVideo: asset, options: options) { avAsset, _, _ in
                deliver((avAsset as? AVURLAsset)?.url)
            }
        }
    }

    /// The Live Photo / photo path: the full-size render URL and the paired-video URL are
    /// both stat-ed and summed when present, covering a Live Photo's still + movie.
    private static func editingInputBytes(
        for asset: PHAsset,
        deadlineNanoseconds: UInt64
    ) async -> Int64? {
        await withDeadline(nanoseconds: deadlineNanoseconds) { deliver in
            let options = PHContentEditingInputRequestOptions()
            options.isNetworkAccessAllowed = false
            options.canHandleAdjustmentData = { _ in false }

            _ = asset.requestContentEditingInput(with: options) { input, _ in
                guard let input else {
                    deliver(nil)
                    return
                }
                var total: Int64 = 0
                var found = false
                if let url = input.fullSizeImageURL, let size = fileSize(at: url) {
                    total += size
                    found = true
                }
                if let urlAsset = input.audiovisualAsset as? AVURLAsset, let size = fileSize(at: urlAsset.url) {
                    total += size
                    found = true
                }
                deliver(found ? total : nil)
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

/// One-shot, first-wins delivery box for a callback that may answer late — or never.
///
/// The earliest `settle` wins; later settles (a PhotoKit callback arriving after the
/// deadline fired) are dropped without resuming twice. `wait` sees the value whether it
/// settles before or after the wait begins, so there is no lost-answer window.
///
/// `@unchecked Sendable`: every access goes through `lock`; `Value` is only moved, never
/// mutated.
final class OneShotValue<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var settled = false
    private var value: Value?
    private var continuation: CheckedContinuation<Value?, Never>?

    /// Delivers `value` — unless something has already been delivered.
    func settle(with value: Value?) {
        lock.lock()
        guard !settled else {
            lock.unlock()
            return
        }
        settled = true
        self.value = value
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(returning: value)
    }

    /// Suspends for the first delivery — or returns it immediately if one already happened.
    func wait() async -> Value? {
        await withCheckedContinuation { continuation in
            lock.lock()
            if settled {
                let value = self.value
                lock.unlock()
                continuation.resume(returning: value)
            } else {
                self.continuation = continuation
                lock.unlock()
            }
        }
    }
}

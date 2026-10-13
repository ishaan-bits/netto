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
/// - **Measured, not estimated.** Values come from Photos' own byte counts (iOS 27+ metadata) or
///   from stat-ing content that is already on device; nothing is downloaded to obtain a number.
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

/// Exact byte sizes for assets the user is already moving toward review — resolved by an
/// ordered **probe ladder**: first probe that answers with bytes wins, a probe that proves the
/// content is not on this device skips the stalling paths below it, and no answers at all is
/// an honest `.unavailable`. Never downloads, never estimates, never reports zero.
///
/// The ladder, in order (each step receives the asset's localIdentifier and answers
/// `.measured(bytes)` / `.notLocal` / `.noAnswer`):
///
/// 1. **`requestAVAsset(.current)` → stat** — the exact file size of the version the user
///    sees. Network access stays disabled, so a cloud-only video answers nil promptly (the
///    API's documented behaviour) — recorded as *not local*. An edited video answers with an
///    `AVComposition`, which carries no file URL — no answer, next step.
/// 2. **`requestAVAsset(.original)` → stat** — the pre-iOS 27 answer for edited videos:
///    their original file is a real, reclaimable payload even when the render has no URL.
/// 3. **`PHAssetResource.dataSize` (iOS 27+)** — Photos' own metadata byte count summed over
///    `AssetResourceScope`'s counted resources: synchronous, sandbox-independent, and the
///    answer when every content URL is unreadable. Missing or partial data → no answer.
/// 4. **`requestContentEditingInput` → stat** — full-size image URL and paired/AV URL, summed
///    per `AssetResourceScope` (a Live Photo = still + movie). **Skipped when a previous probe
///    proved the content is not local**: this callback has been observed to stall indefinitely
///    for such assets, and the deadline race is a backstop, not the strategy.
/// 5. **`requestImageDataAndOrientation` → byte count** — exact image bytes with no file URL
///    at all (last resort for non-Live photos; never used for videos).
///
/// Every callback probe races a hard deadline (`callbackDeadlineNanoseconds`), so one
/// pathological PhotoKit answer can delay at most one asset, never a whole pass.
///
/// Limitations, stated rather than hidden:
/// - An asset whose data lives only in iCloud has no local content URL here, so it ends
///   unavailable rather than guessed — and is never downloaded to measure.
/// - An edited asset measured through the original file reports the original's size.
/// - A genuinely empty file is never reported as a measured zero.
///
/// `probes` is the test seam: scripted id-level closures (defaulting to "no answer") so tests
/// exercise the ladder and the batching engine without touching PhotoKit.
struct PhotoKitAssetSizeProvider: AssetSizeProviding {
    var maxConcurrentResolutions: Int = 4
    /// Per-asset ceiling on a PhotoKit callback (see the type docs). Exceeding it yields an
    /// honest no-answer — never a hang, never zero.
    var callbackDeadlineNanoseconds: UInt64 = 5_000_000_000
    /// `nil` runs the production ladder against the real library; tests pass scripted probes.
    var probes: Probes? = nil

    /// What one probe says about one asset.
    enum ProbeAnswer: Sendable, Equatable {
        /// Exact bytes for content that is (at least partly) on this device.
        case measured(Int64)
        /// PhotoKit affirmatively reported the content is not available locally (and was not
        /// allowed to fetch it). The ladder never enters the stalling paths after this.
        case notLocal
        /// This probe has no answer: unsupported kind, no file URL, unreadable, or timed out.
        case noAnswer
    }

    /// The five ladder steps, keyed by localIdentifier. Every closure defaults to `.noAnswer`,
    /// so a partially specified `Probes` can never accidentally reach PhotoKit in tests.
    struct Probes: Sendable {
        var avCurrentBytes: @Sendable (String) async -> ProbeAnswer
        var avOriginalBytes: @Sendable (String) async -> ProbeAnswer
        var resourceBytes: @Sendable (String) async -> ProbeAnswer
        var editingInputBytes: @Sendable (String) async -> ProbeAnswer
        var imageDataBytes: @Sendable (String) async -> ProbeAnswer

        init(
            avCurrentBytes: @escaping @Sendable (String) async -> ProbeAnswer = { _ in .noAnswer },
            avOriginalBytes: @escaping @Sendable (String) async -> ProbeAnswer = { _ in .noAnswer },
            resourceBytes: @escaping @Sendable (String) async -> ProbeAnswer = { _ in .noAnswer },
            editingInputBytes: @escaping @Sendable (String) async -> ProbeAnswer = { _ in .noAnswer },
            imageDataBytes: @escaping @Sendable (String) async -> ProbeAnswer = { _ in .noAnswer }
        ) {
            self.avCurrentBytes = avCurrentBytes
            self.avOriginalBytes = avOriginalBytes
            self.resourceBytes = resourceBytes
            self.editingInputBytes = editingInputBytes
            self.imageDataBytes = imageDataBytes
        }

        /// The production ladder, wired to PhotoKit with the provider's per-callback deadline.
        static func photoKit(deadlineNanoseconds: UInt64) -> Probes {
            Probes(
                avCurrentBytes: { identifier in
                    await PhotoKitAssetSizeProvider.avBytes(
                        for: identifier, version: .current, deadlineNanoseconds: deadlineNanoseconds
                    )
                },
                avOriginalBytes: { identifier in
                    await PhotoKitAssetSizeProvider.avBytes(
                        for: identifier, version: .original, deadlineNanoseconds: deadlineNanoseconds
                    )
                },
                resourceBytes: { identifier in
                    await PhotoKitAssetSizeProvider.resourceBytes(for: identifier)
                },
                editingInputBytes: { identifier in
                    await PhotoKitAssetSizeProvider.editingInputBytes(
                        for: identifier, deadlineNanoseconds: deadlineNanoseconds
                    )
                },
                imageDataBytes: { identifier in
                    await PhotoKitAssetSizeProvider.imageDataBytes(
                        for: identifier, deadlineNanoseconds: deadlineNanoseconds
                    )
                }
            )
        }
    }

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

    /// The outcome pass: every requested identifier resolves to `.measured` or
    /// `.unavailable` — never a silently dropped identifier — so the caller's progress
    /// reflects the work that actually happened even when a whole batch fails (an
    /// iCloud-only library used to leave the screen pinned at "0 of N" through every
    /// failed batch).
    ///
    /// Bounded sequential batches under the shared thermal policy: a large video list
    /// produces cancellable progress instead of one unbounded fan-out, critical thermal
    /// pressure pauses between batches, and cancellation exits early with what landed.
    func outcomes(for localIdentifiers: [String]) async -> [String: VideoSizeOutcome] {
        guard !localIdentifiers.isEmpty else { return [:] }
        let probes = probes ?? .photoKit(deadlineNanoseconds: callbackDeadlineNanoseconds)

        let policy = ScanConcurrencyPolicy()
        var outcomes: [String: VideoSizeOutcome] = [:]
        outcomes.reserveCapacity(localIdentifiers.count)

        var index = 0
        while index < localIdentifiers.count {
            while policy.isCriticallyPressed {
                if Task.isCancelled { return outcomes }
                try? await Task.sleep(for: .milliseconds(250))
            }
            let width = policy.width(base: maxConcurrentResolutions)
            let end = min(index + width, localIdentifiers.count)
            let batch = Array(localIdentifiers[index..<end])
            index = end

            let resolved = await withTaskGroup(
                of: SizeMeasurement.self,
                returning: [SizeMeasurement].self
            ) { group in
                for identifier in batch {
                    group.addTask {
                        SizeMeasurement(
                            localIdentifier: identifier,
                            outcome: await Self.ladder(for: identifier, probes: probes)
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

        // Identifiers no probe answered (deleted mid-run, outside limited access) are
        // unavailable, not missing — the caller's counts stay honest either way.
        for identifier in localIdentifiers where outcomes[identifier] == nil {
            outcomes[identifier] = .unavailable
        }
        return outcomes
    }

    /// The ladder itself: first measured bytes win; a proven-remote asset never enters the
    /// stalling editing-input race; silence everywhere is `.unavailable`.
    static func ladder(for identifier: String, probes: Probes) async -> VideoSizeOutcome {
        var provenRemote = false

        for probe in [probes.avCurrentBytes, probes.avOriginalBytes] {
            switch await probe(identifier) {
            case .measured(let bytes):
                if bytes > 0 { return .measured(bytes) }
            case .notLocal:
                provenRemote = true
            case .noAnswer:
                break
            }
        }

        if case .measured(let bytes) = await probes.resourceBytes(identifier), bytes > 0 {
            return .measured(bytes)
        }

        guard !provenRemote else { return .unavailable }

        if case .measured(let bytes) = await probes.editingInputBytes(identifier), bytes > 0 {
            return .measured(bytes)
        }
        if case .measured(let bytes) = await probes.imageDataBytes(identifier), bytes > 0 {
            return .measured(bytes)
        }
        return .unavailable
    }

    private struct SizeMeasurement: Sendable {
        let localIdentifier: String
        let outcome: VideoSizeOutcome
    }

    // MARK: - Production probes (PhotoKit)

    private static func asset(for localIdentifier: String) -> PHAsset? {
        PHAsset.fetchAssets(withLocalIdentifiers: [localIdentifier], options: nil).firstObject
    }

    /// Steps 1–2: `requestAVAsset` with network access disabled, then stat the file URL.
    /// A locally stored video answers promptly with an `AVURLAsset`; a cloud-only one
    /// answers promptly with nil (recorded as not local); an edited `.current` render is an
    /// `AVComposition` with no file URL (no answer — step 2 gets the original).
    private static func avBytes(
        for localIdentifier: String,
        version: PHVideoRequestOptionsVersion,
        deadlineNanoseconds: UInt64
    ) async -> ProbeAnswer {
        guard let asset = asset(for: localIdentifier),
              asset.mediaType == .video,
              !asset.mediaSubtypes.contains(.photoLive) else {
            return .noAnswer
        }
        let answer: ProbeAnswer? = await withDeadline(nanoseconds: deadlineNanoseconds) { deliver in
            let options = PHVideoRequestOptions()
            options.isNetworkAccessAllowed = false
            options.version = version
            PHImageManager.default().requestAVAsset(forVideo: asset, options: options) { avAsset, _, info in
                guard let avAsset else {
                    let inCloud = (info?[PHImageResultIsInCloudKey] as? NSNumber)?.boolValue ?? false
                    deliver(inCloud ? .notLocal : .noAnswer)
                    return
                }
                guard let urlAsset = avAsset as? AVURLAsset else {
                    deliver(.noAnswer)
                    return
                }
                deliver(fileSize(at: urlAsset.url).map(ProbeAnswer.measured) ?? .noAnswer)
            }
        }
        return answer ?? .noAnswer
    }

    /// Step 3 (iOS 27+): Photos' own metadata byte count over the counted resources.
    /// Synchronous, no file access, no callbacks — and honest when Photos hasn't finished
    /// processing a resource (any counted resource without a size → no answer).
    private static func resourceBytes(for localIdentifier: String) async -> ProbeAnswer {
        guard #available(iOS 27.0, *),
              let asset = asset(for: localIdentifier) else {
            return .noAnswer
        }
        let counted = AssetResourceScope.countableTypes(
            in: PHAssetResource.assetResources(for: asset)
        )
        guard !counted.isEmpty else { return .noAnswer }
        var total: Int64 = 0
        for resource in counted {
            guard let size = resource.dataSize, size > 0 else { return .noAnswer }
            total += Int64(size)
        }
        return total > 0 ? .measured(total) : .noAnswer
    }

    /// Step 4: the full-size image URL and/or paired-video URL, summed per AssetResourceScope.
    /// Skipped for proven-remote assets by the ladder; the deadline race keeps a stalling
    /// callback from pinning an asset beyond the per-probe ceiling.
    private static func editingInputBytes(
        for localIdentifier: String,
        deadlineNanoseconds: UInt64
    ) async -> ProbeAnswer {
        guard let asset = asset(for: localIdentifier) else { return .noAnswer }
        let answer: ProbeAnswer? = await withDeadline(nanoseconds: deadlineNanoseconds) { deliver in
            let options = PHContentEditingInputRequestOptions()
            options.isNetworkAccessAllowed = false
            options.canHandleAdjustmentData = { _ in false }

            _ = asset.requestContentEditingInput(with: options) { input, _ in
                guard let input else {
                    deliver(.noAnswer)
                    return
                }
                var total: Int64 = 0
                var found = false
                if let url = input.fullSizeImageURL, let size = fileSize(at: url) {
                    total += size
                    found = true
                }
                if let urlAsset = input.audiovisualAsset as? AVURLAsset,
                   let size = fileSize(at: urlAsset.url) {
                    total += size
                    found = true
                }
                deliver(found ? .measured(total) : .noAnswer)
            }
        }
        return answer ?? .noAnswer
    }

    /// Step 5 (photos only): the exact byte count of the image data itself — no file URL
    /// involved, so it answers where every URL is unreadable. The buffer is transient.
    private static func imageDataBytes(
        for localIdentifier: String,
        deadlineNanoseconds: UInt64
    ) async -> ProbeAnswer {
        guard let asset = asset(for: localIdentifier),
              asset.mediaType == .image,
              !asset.mediaSubtypes.contains(.photoLive) else {
            return .noAnswer
        }
        let answer: ProbeAnswer? = await withDeadline(nanoseconds: deadlineNanoseconds) { deliver in
            let options = PHImageRequestOptions()
            options.isNetworkAccessAllowed = false
            options.version = .current
            PHImageManager.default()
                .requestImageDataAndOrientation(for: asset, options: options) { data, _, _, info in
                    guard let data, !data.isEmpty else {
                        let inCloud = (info?[PHImageResultIsInCloudKey] as? NSNumber)?.boolValue ?? false
                        deliver(inCloud ? .notLocal : .noAnswer)
                        return
                    }
                    deliver(.measured(Int64(data.count)))
                }
        }
        return answer ?? .noAnswer
    }

    /// Exact file size, or nil. PhotoKit content URLs can be security-scoped: if a plain
    /// stat fails, the same stat runs again while scoped access is held. Zero is not a
    /// measurement.
    private static func fileSize(at url: URL) -> Int64? {
        if let bytes = readFileSize(at: url), bytes > 0 { return bytes }
        guard url.startAccessingSecurityScopedResource() else { return nil }
        defer { url.stopAccessingSecurityScopedResource() }
        guard let bytes = readFileSize(at: url), bytes > 0 else { return nil }
        return bytes
    }

    private static func readFileSize(at url: URL) -> Int64? {
        guard let values = try? FileManager.default.attributesOfItem(atPath: url.path),
              let number = values[.size] as? NSNumber else { return nil }
        return number.int64Value
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

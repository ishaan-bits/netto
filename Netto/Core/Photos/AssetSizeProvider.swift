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
/// ordered **probe ladder**: first probe that answers with bytes wins; a probe that proves
/// the content is not on this device **stops the ladder immediately** (one locality probe,
/// no more); no answers at all is an honest `.unavailable`. Never downloads, never
/// estimates, never reports zero.
///
/// The ladder, in order (each step receives the asset's localIdentifier and answers
/// `.measured(bytes)` / `.notLocal` / `.noAnswer`):
///
/// 1. **`PHAssetResource.dataSize` (iOS 27+)** — Photos' own metadata byte count summed over
///    `AssetResourceScope`'s counted resources: synchronous, sandbox-independent, and exact
///    when the asset is local. Promoted to first because it is free on iOS ≤ 26 (the
///    `#available` guard fails before any XPC is issued — measured at 0.0 ms/asset on an
///    iPhone 17 Pro on iOS 26.5) and answers outright on iOS 27, so a future device drops
///    the whole scan to metadata speed.
/// 2. **`requestAVAsset(.current)` → stat** — the exact file size of the version the user
///    sees, and (with network access disabled) the **locality verdict**: a cloud-only video
///    answers nil promptly — terminal — while a local one answers an `AVURLAsset` to stat.
///    An edited video answers an `AVComposition` with no file URL — no answer, next step.
///    This is the expensive step (measured ~7 ms per asset, serialized by the Photos daemon
///    at ~125 videos/second no matter the concurrency) and the reason the pass walks the
///    dataset newest-first: locally stored videos are the newest ones, so a cloud-heavy
///    library surfaces its real, sized results within seconds.
/// 3. **`requestAVAsset(.original)` → stat** — the pre-iOS 27 answer for edited videos.
/// 4. **`requestContentEditingInput` → stat** — full-size image URL and paired/AV URL, summed
///    per `AssetResourceScope` (a Live Photo = still + movie). Only reached when nothing
///    above knew the locality; its callback has been observed to stall for remote assets,
///    and the deadline race is a backstop, not the strategy.
/// 5. **`requestImageDataAndOrientation` → byte count** — exact image bytes with no file URL
///    at all (last resort for non-Live photos; never used for videos).
///
/// Every callback probe races a hard deadline (`callbackDeadlineNanoseconds`), so one
/// pathological PhotoKit answer can delay at most one asset, never a whole pass.
///
/// Limitations, stated rather than hidden:
/// - An asset whose data lives only in iCloud ends unavailable after the single locality
///   probe rather than guessed — and is never downloaded to measure.
/// - An edited asset measured through the original file reports the original's size.
/// - A genuinely empty file is never reported as a measured zero.
/// - On iOS ≤ 26 there is no public metadata byte count, so classifying a whole library is
///   bound by the Photos daemon's ~125 verdicts/second (independent of width and of how many
///   `PHImageManager` connections are open — both measured). The ladder is therefore ordered
///   and the pass is driven newest-first so the sized, sorted result lands in seconds.
///
/// `probes` is the test seam: scripted id-level closures (defaulting to "no answer") so tests
/// exercise the ladder and the batching engine without touching PhotoKit.
struct PhotoKitAssetSizeProvider: AssetSizeProviding {
    /// XPC-bound probe width (thermal-scaled by `ScanConcurrencyPolicy`): each probe is a
    /// Photos-daemon round trip, not CPU work, so the pool runs wider than the CPU-bound
    /// passes. Eight is the measured sweet spot — the daemon serializes verdicts at ~125
    /// videos/second, and both a wider pool (up to 128) and extra `PHImageManager`
    /// connections (up to 16) left wall-clock unchanged on an iPhone 17 Pro, so a wider
    /// pool would only deepen the queue.
    var maxConcurrentResolutions: Int = 8
    /// Per-asset ceiling on a PhotoKit callback (see the type docs). Exceeding it yields an
    /// honest no-answer — never a hang, never zero.
    var callbackDeadlineNanoseconds: UInt64 = 5_000_000_000
    /// `nil` runs the production ladder against the real library; tests pass scripted probes.
    var probes: Probes? = nil

    /// What one probe says about one asset.
    enum ProbeAnswer: Sendable, Equatable {
        /// Exact bytes for content that is (at least partly) on this device.
        case measured(Int64)
        /// PhotoKit could not provide the content locally (network access was disabled).
        /// **Terminal**: the ladder answers `.unavailable` immediately — a proven-remote
        /// asset never pays for a second probe.
        case notLocal
        /// This probe has no answer: unsupported kind, no file URL, unreadable, or timed out.
        case noAnswer
    }

    /// The five ladder steps in ladder order, keyed by localIdentifier. Every closure
    /// defaults to `.noAnswer`, so a partially specified `Probes` can never accidentally
    /// reach PhotoKit in tests.
    struct Probes: Sendable {
        var resourceBytes: @Sendable (String) async -> ProbeAnswer
        var avCurrentBytes: @Sendable (String) async -> ProbeAnswer
        var avOriginalBytes: @Sendable (String) async -> ProbeAnswer
        var editingInputBytes: @Sendable (String) async -> ProbeAnswer
        var imageDataBytes: @Sendable (String) async -> ProbeAnswer

        init(
            resourceBytes: @escaping @Sendable (String) async -> ProbeAnswer = { _ in .noAnswer },
            avCurrentBytes: @escaping @Sendable (String) async -> ProbeAnswer = { _ in .noAnswer },
            avOriginalBytes: @escaping @Sendable (String) async -> ProbeAnswer = { _ in .noAnswer },
            editingInputBytes: @escaping @Sendable (String) async -> ProbeAnswer = { _ in .noAnswer },
            imageDataBytes: @escaping @Sendable (String) async -> ProbeAnswer = { _ in .noAnswer }
        ) {
            self.resourceBytes = resourceBytes
            self.avCurrentBytes = avCurrentBytes
            self.avOriginalBytes = avOriginalBytes
            self.editingInputBytes = editingInputBytes
            self.imageDataBytes = imageDataBytes
        }

        /// The production ladder, wired to PhotoKit with the provider's per-callback deadline.
        ///
        /// One `AssetIndex` backs every probe in the pass, so each asset is fetched once
        /// instead of once per probe. It is built lazily on first use (a single
        /// `PHFetchOptions` pass over the library's videos) and reused for the rest.
        static func photoKit(deadlineNanoseconds: UInt64) -> Probes {
            let index = AssetIndex()
            return Probes(
                resourceBytes: { identifier in
                    await PhotoKitAssetSizeProvider.resourceBytes(for: identifier, index: index)
                },
                avCurrentBytes: { identifier in
                    await PhotoKitAssetSizeProvider.avBytes(
                        for: identifier, version: .current, index: index,
                        deadlineNanoseconds: deadlineNanoseconds
                    )
                },
                avOriginalBytes: { identifier in
                    await PhotoKitAssetSizeProvider.avBytes(
                        for: identifier, version: .original, index: index,
                        deadlineNanoseconds: deadlineNanoseconds
                    )
                },
                editingInputBytes: { identifier in
                    await PhotoKitAssetSizeProvider.editingInputBytes(
                        for: identifier, index: index, deadlineNanoseconds: deadlineNanoseconds
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

    /// The ladder itself: first measured bytes win; a proven-remote asset stops right
    /// there — one locality probe, no original, no editing-input race; silence everywhere
    /// is `.unavailable`.
    static func ladder(for identifier: String, probes: Probes) async -> VideoSizeOutcome {
        // Step 1: Photos' own metadata byte count (iOS 27+). Free on iOS ≤ 26 (the guard
        // below fails before any XPC), exact on iOS 27 — so a device that has it answers
        // local videos here without ever touching the AV machinery.
        if case .measured(let bytes) = await probes.resourceBytes(identifier), bytes > 0 {
            return .measured(bytes)
        }

        // Step 2: the current version's file, and the locality verdict. A cloud-only video
        // answers nil promptly with network access disabled — terminal: nothing further
        // down the ladder can hold local bytes for content PhotoKit just reported as
        // absent.
        switch await probes.avCurrentBytes(identifier) {
        case .measured(let bytes):
            if bytes > 0 { return .measured(bytes) }
        case .notLocal:
            return .unavailable
        case .noAnswer:
            break
        }

        // Step 3: an edited render is an AVComposition with no file URL (no answer
        // above) — the original file is the pre-iOS 27 answer for it.
        switch await probes.avOriginalBytes(identifier) {
        case .measured(let bytes):
            if bytes > 0 { return .measured(bytes) }
        case .notLocal:
            return .unavailable
        case .noAnswer:
            break
        }

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

    /// A per-pass map from `localIdentifier` to `PHAsset`, fetched once.
    ///
    /// Every probe used to call `PHAsset.fetchAssets(withLocalIdentifiers:)` on its own —
    /// a synchronous XPC to the Photos daemon *per probe per asset*, stacked on top of the
    /// `requestAVAsset` callback. On a 7 000-video library that is tens of thousands of
    /// redundant round trips for assets the caller already enumerated into the catalog.
    /// Building the map once (a single `PHFetchOptions` pass over the requested videos) turns
    /// every per-probe fetch into a dictionary lookup.
    ///
    /// `@unchecked Sendable`: the cache is written under `lock` on first use and read-only
    /// thereafter; `PHAsset` is itself immutable and thread-safe to hold.
    final class AssetIndex: @unchecked Sendable {
        private let lock = NSLock()
        private var cache: [String: PHAsset]?

        init(cache: [String: PHAsset]? = nil) {
            self.cache = cache
        }

        /// The asset for `localIdentifier`, or nil if it is not in this pass's set.
        ///
        /// The first call builds the whole map in one fetch; later calls are dictionary
        /// lookups. An identifier missing from the map is not re-fetched one at a time —
        /// that is the redundancy this type exists to remove — it simply answers nil, and
        /// the probe reports "no answer".
        func asset(for localIdentifier: String) -> PHAsset? {
            lock.lock()
            defer { lock.unlock() }
            if let cache {
                return cache[localIdentifier]
            }
            var built: [String: PHAsset] = [:]
            let options = PHFetchOptions()
            options.predicate = NSPredicate(format: "mediaType == %d", PHAssetMediaType.video.rawValue)
            let fetch = PHAsset.fetchAssets(with: options)
            fetch.enumerateObjects { asset, _, _ in
                built[asset.localIdentifier] = asset
            }
            cache = built
            return built[localIdentifier]
        }
    }

    /// Steps 2–3: `requestAVAsset` with network access disabled, then stat the file URL.
    /// A locally stored video answers promptly with an `AVURLAsset`; a cloud-only one
    /// answers promptly with nil (recorded as not local); an edited `.current` render is an
    /// `AVComposition` with no file URL (no answer — step 3 gets the original).
    private static func avBytes(
        for localIdentifier: String,
        version: PHVideoRequestOptionsVersion,
        index: AssetIndex,
        deadlineNanoseconds: UInt64
    ) async -> ProbeAnswer {
        guard let asset = index.asset(for: localIdentifier),
              asset.mediaType == .video,
              !asset.mediaSubtypes.contains(.photoLive) else {
            return .noAnswer
        }
        let answer: ProbeAnswer? = await withDeadline(nanoseconds: deadlineNanoseconds) { deliver in
            let options = PHVideoRequestOptions()
            options.isNetworkAccessAllowed = false
            options.version = version
            PHImageManager.default().requestAVAsset(forVideo: asset, options: options) { avAsset, _, _ in
                guard let avAsset else {
                    // Network access is disabled, so nil means "no local content" —
                    // terminal for the ladder. The info dictionary's inCloud key is
                    // corroboration, not a requirement: a key-less nil used to count as
                    // "no answer", sending thousands of known-remote videos through
                    // every remaining probe.
                    deliver(.notLocal)
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

    /// Step 1 (iOS 27+): Photos' own metadata byte count over the counted resources.
    /// Synchronous, no file access, no callbacks — and honest when Photos hasn't finished
    /// processing a resource (any counted resource without a size → no answer).
    private static func resourceBytes(
        for localIdentifier: String,
        index: AssetIndex
    ) async -> ProbeAnswer {
        guard #available(iOS 27.0, *),
              let asset = index.asset(for: localIdentifier) else {
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
        index: AssetIndex,
        deadlineNanoseconds: UInt64
    ) async -> ProbeAnswer {
        guard let asset = index.asset(for: localIdentifier) else { return .noAnswer }
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
    ///
    /// Deliberately its own `fetchAssets` rather than a shared index: the index holds
    /// videos, and this probe only ever answers for a photo, so a dictionary lookup here
    /// would always miss and photos would stop being measured at all.
    private static func imageDataBytes(
        for localIdentifier: String,
        deadlineNanoseconds: UInt64
    ) async -> ProbeAnswer {
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [localIdentifier], options: nil).firstObject,
              asset.mediaType == .image,
              !asset.mediaSubtypes.contains(.photoLive) else {
            return .noAnswer
        }
        let answer: ProbeAnswer? = await withDeadline(nanoseconds: deadlineNanoseconds) { deliver in
            let options = PHImageRequestOptions()
            options.isNetworkAccessAllowed = false
            options.version = .current
            PHImageManager.default()
                .requestImageDataAndOrientation(for: asset, options: options) { data, _, _, _ in
                    guard let data, !data.isEmpty else {
                        // Network access is disabled: nil means no local content
                        // (same terminal semantics as the AV probes).
                        deliver(.notLocal)
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

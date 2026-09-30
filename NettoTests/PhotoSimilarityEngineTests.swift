import CoreGraphics
import Foundation
import Testing
@testable import Netto

// MARK: - Test doubles

private func trailingLevel(_ assetID: String) -> Int {
    guard let last = assetID.split(separator: "-").last, let value = Int(last) else { return 128 }
    return value
}

/// Deterministic per-id byte counts (FNV-1a), so default stub fingerprints never collide by
/// accident and tests must opt in to exact-duplicate pairs explicitly.
private func stableBytes(_ assetID: String) -> Int64 {
    var hash: UInt64 = 0xcbf2_9ce4_8422_2325
    for byte in assetID.utf8 {
        hash ^= UInt64(byte)
        hash = hash &* 0x0000_0100_0000_01b3
    }
    return Int64(bitPattern: hash)
}

private func solidGrayImage(level: Int, size: Int = 32) -> CGImage {
    let clamped = UInt8(max(0, min(255, level)))
    var buffer = [UInt8](repeating: 255, count: size * size * 4)
    for index in stride(from: 0, to: buffer.count, by: 4) {
        buffer[index] = clamped
        buffer[index + 1] = clamped
        buffer[index + 2] = clamped
    }
    let provider = CGDataProvider(data: Data(buffer) as CFData)!
    return CGImage(
        width: size,
        height: size,
        bitsPerComponent: 8,
        bitsPerPixel: 32,
        bytesPerRow: size * 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
        provider: provider,
        decode: nil,
        shouldInterpolate: false,
        intent: .defaultIntent
    )!
}

private func grayLevel(of image: CGImage) -> Int {
    guard let data = image.dataProvider?.data else { return -1 }
    let bytes = Data(referencing: data)
    guard let first = bytes.first else { return -1 }
    return Int(first)
}

private struct StubFingerprinter: ContentFingerprinting {
    var byteKeyOutcomes: [String: ContentLengthOutcome] = [:]
    var fingerprintOutcomes: [String: ContentFingerprintOutcome] = [:]
    /// Asset ids whose phase-1 probe throws instead of resolving (drives the timeout path).
    var byteKeyThrowingIDs: Set<String> = []
    /// Delay for phase 1, used to keep a run in flight while a test cancels it.
    var phaseOneDelayNanos: UInt64 = 0

    func byteKey(for record: PhotoAssetRecord) async throws -> ContentLengthOutcome {
        if phaseOneDelayNanos > 0 {
            try await Task.sleep(nanoseconds: phaseOneDelayNanos)
        }
        if byteKeyThrowingIDs.contains(record.localIdentifier) {
            throw PhotoRequestTimeoutError()
        }
        if let outcome = byteKeyOutcomes[record.localIdentifier] {
            return outcome
        }
        return .key(
            ContentByteKey(imageBytes: stableBytes(record.localIdentifier), videoBytes: 0)
        )
    }

    func fingerprint(for record: PhotoAssetRecord) async throws -> ContentFingerprintOutcome {
        if let outcome = fingerprintOutcomes[record.localIdentifier] {
            return outcome
        }
        let id = record.localIdentifier
        return .fingerprinted(
            ContentFingerprint(
                imageBytes: stableBytes(id),
                videoBytes: 0,
                imageDigestHex: id,
                videoDigestHex: nil
            )
        )
    }
}

private struct StubThumbnails: PhotoThumbnailLoading {
    var failures: [String: PhotoContentError] = [:]
    /// Asset ids whose thumbnail request hangs past the failsafe (throws the timeout error).
    var timeoutIDs: Set<String> = []

    func thumbnail(for assetID: String, targetPixelSize: Int) async throws -> CGImage {
        if timeoutIDs.contains(assetID) {
            throw PhotoRequestTimeoutError()
        }
        if let failure = failures[assetID] {
            throw failure
        }
        return solidGrayImage(level: trailingLevel(assetID))
    }
}

private struct StubExtractor: PhotoFeatureExtracting {
    let kind: FeaturePrintKind
    /// Gray levels whose extraction fails (drives `visionFailed` / `imageUnavailable` paths).
    var failingLevels: Set<Int> = []

    func prepare() async {}

    func featurePrint(for thumbnail: CGImage) async throws -> FeaturePrint {
        let level = grayLevel(of: thumbnail)
        if failingLevels.contains(level) {
            throw FeatureExtractionError.backendUnavailable
        }
        // /256 keeps single-step distances exact in Float: 64/256 == 0.25 bit-for-bit, which is
        // what makes the threshold-boundary test deterministic.
        return FeaturePrint(kind: kind, values: [Float(level) / 256])
    }
}

private final class RecordingObserver: PhotoAnalysisStageObserving, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [PhotoAnalysisStage] = []
    private var finished = false

    func analysisStageWillBegin(_ stage: PhotoAnalysisStage) throws {
        lock.lock()
        storage.append(stage)
        lock.unlock()
    }

    func analysisDidFinish() {
        lock.lock()
        finished = true
        lock.unlock()
    }

    var stages: [PhotoAnalysisStage] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    var didFinish: Bool {
        lock.lock()
        defer { lock.unlock() }
        return finished
    }
}

/// Deterministic abort seam: throws at the first report of `target` stage, from whichever task
/// happens to be reporting (parent stage entry or a worker's interleaved transition).
private final class AbortingObserver: PhotoAnalysisStageObserving, @unchecked Sendable {
    private let lock = NSLock()
    private let target: PhotoAnalysisStage
    private var fired = false
    private var finished = false

    init(target: PhotoAnalysisStage) {
        self.target = target
    }

    func analysisStageWillBegin(_ stage: PhotoAnalysisStage) throws {
        lock.lock()
        let shouldAbort = stage == target && !fired
        if shouldAbort { fired = true }
        lock.unlock()
        if shouldAbort { throw CancellationError() }
    }

    func analysisDidFinish() {
        lock.lock()
        finished = true
        lock.unlock()
    }

    var didFinish: Bool {
        lock.lock()
        defer { lock.unlock() }
        return finished
    }
}

private final class ProgressLog: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [PhotoAnalysisProgress] = []

    func append(_ progress: PhotoAnalysisProgress) {
        lock.lock()
        values.append(progress)
        lock.unlock()
    }

    var snapshot: [PhotoAnalysisProgress] {
        lock.lock()
        defer { lock.unlock() }
        return values
    }
}

// MARK: - Fixtures

private func makeRecord(
    id: String,
    mediaType: PhotoMediaType = .image,
    pixelWidth: Int = 4032,
    pixelHeight: Int = 3024,
    creationDate: Date? = Date(timeIntervalSince1970: 1_700_000_000)
) -> PhotoAssetRecord {
    PhotoAssetRecord(
        localIdentifier: id,
        mediaType: mediaType,
        mediaSubtypes: [],
        pixelWidth: pixelWidth,
        pixelHeight: pixelHeight,
        creationDate: creationDate,
        modificationDate: nil,
        duration: 0,
        isFavorite: false,
        isHidden: false,
        sourceType: [.library],
        hasAdjustments: false,
        representsBurst: false,
        burstIdentifier: nil
    )
}

private func makeEngine(
    fingerprinter: StubFingerprinter = StubFingerprinter(),
    thumbnails: StubThumbnails = StubThumbnails(),
    extractor: any PhotoFeatureExtracting = StubExtractor(kind: .cpuGrid),
    observer: any PhotoAnalysisStageObserving = NoopStageObserver(),
    metrics: AnalysisMetrics? = nil,
    threshold: Float? = 0.3,
    workers: Int = 2
) -> PhotoSimilarityEngine {
    var configuration = PhotoAnalysisConfiguration()
    configuration.similarityThreshold = threshold
    configuration.maxConcurrentWorkers = workers
    return PhotoSimilarityEngine(
        configuration: configuration,
        fingerprinter: fingerprinter,
        thumbnailLoader: thumbnails,
        featureExtractor: extractor,
        stageObserver: observer,
        metrics: metrics
    )
}

// MARK: - Engine behaviour

struct PhotoSimilarityEngineTests {
    @Test func emptyLibraryEmitsAllStagesAndAnEmptyResult() async throws {
        let observer = RecordingObserver()
        let engine = makeEngine(observer: observer)

        let log = ProgressLog()
        let result = try await engine.analyze(records: [], onProgress: { log.append($0) })

        #expect(result.exactGroups.isEmpty)
        #expect(result.similarGroups.isEmpty)
        #expect(result.unavailableAssets.isEmpty)
        #expect(result.descriptorKind == nil)
        #expect(result.visionAvailable == false)
        #expect(result.similarityThreshold == nil)
        #expect(result.totalRecordCount == 0)
        #expect(result.candidateBucketCount == 0)
        #expect(result.candidatePairCount == 0)

        #expect(
            observer.stages == [
                .preparing, .generatingCandidates, .fingerprinting,
                .extractingFeatures, .comparing, .grouping, .finalizing,
            ]
        )
        #expect(observer.didFinish)
        #expect(log.snapshot.allSatisfy { $0.stage != .generatingCandidates || $0.fraction == nil })
    }

    @Test func stageOrderIsDeterministicForOneBucket() async throws {
        let observer = RecordingObserver()
        let engine = makeEngine(observer: observer, workers: 1)
        let records = [
            makeRecord(id: "photo-10"),
            makeRecord(id: "photo-20"),
            makeRecord(id: "photo-30"),
        ]

        _ = try await engine.analyze(records: records)

        // With one worker, the interleaved extraction/comparison pair alternates exactly once
        // per bucket and the completion reports round-trip through it.
        #expect(
            observer.stages == [
                .preparing, .generatingCandidates, .fingerprinting,
                .extractingFeatures, .comparing,
                .extractingFeatures, .comparing,
                .grouping, .finalizing,
            ]
        )
        #expect(observer.didFinish)
    }

    @Test func exactDuplicatesAreGroupedAndExcludedFromNearReporting() async throws {
        var fingerprinter = StubFingerprinter()
        let shared = ContentFingerprint(
            imageBytes: 42,
            videoBytes: 0,
            imageDigestHex: "shared-content",
            videoDigestHex: nil
        )
        fingerprinter.byteKeyOutcomes = [
            "photo-0": .key(ContentByteKey(imageBytes: 42, videoBytes: 0)),
            "dup-0": .key(ContentByteKey(imageBytes: 42, videoBytes: 0)),
            "photo-200": .key(ContentByteKey(imageBytes: 99, videoBytes: 0)),
        ]
        fingerprinter.fingerprintOutcomes = [
            "photo-0": .fingerprinted(shared),
            "dup-0": .fingerprinted(shared),
        ]

        let engine = makeEngine(fingerprinter: fingerprinter)
        let records = [
            makeRecord(id: "photo-0"),
            makeRecord(id: "dup-0"),
            makeRecord(id: "photo-200"),
        ]

        let result = try await engine.analyze(records: records)

        #expect(result.exactGroups.count == 1)
        let exact = result.exactGroups[0]
        #expect(exact.memberAssetIDs == ["dup-0", "photo-0"])
        #expect(exact.kind == .exactDuplicates)
        if case .exactContent(let tag, let bytes) = exact.evidence {
            #expect(tag == "shared-content/-")
            #expect(bytes == 42)
        } else {
            Issue.record("expected exactContent evidence")
        }

        // The same pair's prints are identical (distance 0), but byte-identical pairs are the
        // exact group's job — they must not be double-reported as near-duplicates.
        #expect(result.similarGroups.isEmpty)
        #expect(result.unavailableAssets.isEmpty)
    }

    @Test func nearDuplicatePairIsGroupedWithDistanceEvidence() async throws {
        let engine = makeEngine(threshold: 0.3)
        let records = [
            makeRecord(id: "photo-0"),
            makeRecord(id: "photo-40"),
            makeRecord(id: "photo-255"),
        ]

        let result = try await engine.analyze(records: records)

        #expect(result.exactGroups.isEmpty)
        #expect(result.similarGroups.count == 1)
        let group = result.similarGroups[0]
        #expect(group.memberAssetIDs == ["photo-0", "photo-40"])
        #expect(group.kind == .nearDuplicates)
        if case .visualSimilarity(let min, let max, let threshold) = group.evidence {
            #expect(abs(min - (40.0 / 256.0)) < 0.000_001)
            #expect(min == max)
            #expect(threshold == 0.3)
        } else {
            Issue.record("expected visualSimilarity evidence")
        }
        #expect(result.descriptorKind == .cpuGrid)
        #expect(result.visionAvailable == false)
        #expect(result.similarityThreshold == 0.3)
        #expect(result.candidateBucketCount == 1)
        #expect(result.candidatePairCount == 3)
    }

    @Test func chainOfLooseRelationsDoesNotSwallowTheUnrelatedThird() async throws {
        // grays 0/60/120 → d(0,60)=0.234 ≤ 0.3, d(60,120)=0.234 ≤ 0.3, d(0,120)=0.469 > 0.3.
        let engine = makeEngine(threshold: 0.3)
        let records = [
            makeRecord(id: "photo-0"),
            makeRecord(id: "photo-60"),
            makeRecord(id: "photo-120"),
        ]

        let result = try await engine.analyze(records: records)

        #expect(result.similarGroups.count == 1)
        #expect(result.similarGroups[0].memberAssetIDs == ["photo-0", "photo-60"])
    }

    @Test func pairExactlyAtThresholdIsIncluded() async throws {
        // 64/256 == 0.25 exactly in Float (power of two), so "distance == threshold" is a real
        // bit-exact boundary, not a rounding accident.
        let engine = makeEngine(threshold: 0.25)
        let records = [
            makeRecord(id: "photo-0"),
            makeRecord(id: "photo-64"),
        ]

        let result = try await engine.analyze(records: records)
        #expect(result.similarGroups.count == 1)
        #expect(result.similarGroups[0].memberAssetIDs == ["photo-0", "photo-64"])
    }

    @Test func pairOneStepAboveThresholdIsExcluded() async throws {
        let engine = makeEngine(threshold: 0.25)
        let records = [
            makeRecord(id: "photo-0"),
            makeRecord(id: "photo-65"),
        ]

        let result = try await engine.analyze(records: records)
        #expect(result.similarGroups.isEmpty)
    }

    @Test func unavailableAssetsAreReportedWithReasonsNeverSilentlyGrouped() async throws {
        var fingerprinter = StubFingerprinter()
        fingerprinter.byteKeyOutcomes["cloud-0"] = .unavailable(.contentOnlyInICloud)
        fingerprinter.byteKeyOutcomes["broken-7"] = .unavailable(.contentUnreadable)

        var thumbnails = StubThumbnails()
        thumbnails.failures["gone-100"] = .onlyInICloud

        // Backend available (probe passed) but fails on level 110 only.
        let extractor = StubExtractor(kind: .visionFeaturePrint, failingLevels: [110])

        let engine = makeEngine(
            fingerprinter: fingerprinter,
            thumbnails: thumbnails,
            extractor: extractor
        )
        let records = [
            makeRecord(id: "cloud-0"),
            makeRecord(id: "broken-7"),
            makeRecord(id: "gone-100"),
            makeRecord(id: "bad-110"),
            makeRecord(id: "good-0"),
        ]

        let result = try await engine.analyze(records: records)

        let reasons = Dictionary(
            uniqueKeysWithValues: result.unavailableAssets.map { ($0.assetID, $0.reason) }
        )
        #expect(reasons["cloud-0"] == .contentOnlyInICloud)
        #expect(reasons["broken-7"] == .contentUnreadable)
        #expect(reasons["gone-100"] == .contentOnlyInICloud)
        #expect(reasons["bad-110"] == .visionFailed)
        #expect(reasons["good-0"] == nil)
        #expect(result.unavailableAssets.map(\.assetID) == result.unavailableAssets.map(\.assetID).sorted())

        // Availability is per analysis path: `gone-100` and `bad-110` never got a descriptor, so
        // they cannot appear in any group. `cloud-0` / `broken-7` failed only the *content* path —
        // their thumbnails worked, so visual grouping may legitimately include them (with visual
        // evidence, not content evidence). Unavailable assets are never silently classified as
        // duplicates of content they could not read.
        let grouped = Set(
            (result.exactGroups + result.similarGroups).flatMap(\.memberAssetIDs)
        )
        #expect(!grouped.contains("gone-100"))
        #expect(!grouped.contains("bad-110"))
        #expect(result.exactGroups.isEmpty)
    }

    @Test func nonAnalyzableMediaIsReportedNotBucketed() async throws {
        let engine = makeEngine()
        let records = [
            makeRecord(id: "photo-0"),
            makeRecord(id: "voice-1", mediaType: .audio),
        ]

        let result = try await engine.analyze(records: records)

        #expect(result.unavailableAssets == [
            PhotoAnalysisUnavailable(assetID: "voice-1", reason: .notAnalyzable),
        ])
        #expect(result.candidateBucketCount == 1)
    }

    @Test func exactDuplicateVideosAreGroupedWithoutVisualAnalysis() async throws {
        var fingerprinter = StubFingerprinter()
        let shared = ContentFingerprint(
            imageBytes: 0,
            videoBytes: 700,
            imageDigestHex: nil,
            videoDigestHex: "video-digest"
        )
        fingerprinter.byteKeyOutcomes = [
            "clip-a": .key(ContentByteKey(imageBytes: 0, videoBytes: 700)),
            "clip-b": .key(ContentByteKey(imageBytes: 0, videoBytes: 700)),
            "other-clip": .key(ContentByteKey(imageBytes: 0, videoBytes: 500)),
        ]
        fingerprinter.fingerprintOutcomes = [
            "clip-a": .fingerprinted(shared),
            "clip-b": .fingerprinted(shared),
        ]

        let engine = makeEngine(fingerprinter: fingerprinter)
        let records = [
            makeRecord(id: "clip-a", mediaType: .video),
            makeRecord(id: "clip-b", mediaType: .video),
            makeRecord(id: "other-clip", mediaType: .video),
            makeRecord(id: "photo-0"),
        ]

        let result = try await engine.analyze(records: records)

        #expect(result.exactGroups.count == 1)
        #expect(result.exactGroups[0].memberAssetIDs == ["clip-a", "clip-b"])
        // Videos never enter visual buckets; only the still does.
        #expect(result.candidateBucketCount == 1)
        #expect(result.unavailableAssets.isEmpty)
    }

    @Test func abortingAtAnyStageTerminatesWithoutCompleting() async throws {
        let records = [
            makeRecord(id: "photo-0"),
            makeRecord(id: "photo-40"),
            makeRecord(id: "photo-255"),
        ]

        for stage in PhotoAnalysisStage.allCases {
            let observer = AbortingObserver(target: stage)
            let engine = makeEngine(observer: observer, workers: 1)

            var sawCompleted = false
            var caughtError: (any Error)?
            do {
                for try await event in engine.makeAnalysisStream(records: records) {
                    if case .completed = event {
                        sawCompleted = true
                    }
                }
            } catch {
                caughtError = error
            }

            if let caughtError {
                let isCancellation = caughtError is CancellationError
                let isAnalysisCancel = caughtError as? PhotoAnalysisFailure == .cancelled
                #expect(isCancellation || isAnalysisCancel, "stage \(stage): \(caughtError)")
            } else {
                Issue.record("stream for stage \(stage) ended without an error")
            }
            #expect(!sawCompleted, "stage \(stage) produced a completed event")
            #expect(observer.didFinish, "stage \(stage) skipped analysisDidFinish")
        }
    }

    @Test func consumerCancellationEndsTheStreamWithoutCompleting() async throws {
        var fingerprinter = StubFingerprinter()
        fingerprinter.phaseOneDelayNanos = 20_000_000 // 20 ms per asset, phase 1
        let engine = makeEngine(fingerprinter: fingerprinter, workers: 1)
        let records = (0..<40).map { makeRecord(id: "photo-\($0)") }

        let task = Task<Bool, Never> {
            do {
                for try await event in engine.makeAnalysisStream(records: records) {
                    if case .completed = event {
                        return true
                    }
                    if case .progress(let progress) = event, progress.stage == .fingerprinting {
                        withUnsafeCurrentTask { $0?.cancel() }
                    }
                }
            } catch {
                return false
            }
            return false
        }

        let sawCompleted = await task.value
        #expect(sawCompleted == false)
    }

    @Test func candidatePairsStayBoundedForALargeCatalog() async throws {
        // 600 same-aspect photos, ten seconds apart: one temporal chain, split into capped
        // buckets. Comparisons must stay ~n × maxBucketSize, never n².
        let records = (0..<600).map { index in
            makeRecord(
                id: String(format: "photo-%03d", index),
                creationDate: Date(timeIntervalSince1970: 1_700_000_000 + Double(index) * 10)
            )
        }

        let engine = makeEngine(threshold: 0.3, workers: 4)
        let result = try await engine.analyze(records: records)

        let unbounded = CandidateBuckets.unboundedPairCount(records: records.count)
        #expect(unbounded == 600 * 599 / 2)
        // The real guarantee: comparisons grow linearly with n (n × maxBucketSize), not n².
        #expect(result.candidatePairCount <= records.count * 64)
        #expect(result.candidatePairCount < unbounded)
        #expect(Double(result.candidatePairCount) / Double(unbounded) < 0.25)
        #expect(result.candidateBucketCount >= 9)
        #expect(result.descriptorKind == .cpuGrid)
        #expect(result.exactGroups.isEmpty)
    }

    @Test func repeatedRunsProduceIdenticalResults() async throws {
        let records = [
            makeRecord(id: "photo-0"),
            makeRecord(id: "photo-40"),
            makeRecord(id: "photo-41"),
            makeRecord(id: "photo-255"),
        ]

        let first = try await makeEngine(threshold: 0.3).analyze(records: records)
        let second = try await makeEngine(threshold: 0.3).analyze(records: records)
        #expect(first == second)
        #expect(first.similarGroups.count == 1)
    }

    @Test func progressPerStageIsMonotonicAndFinishesComplete() async throws {
        let records = (0..<120).map { index in
            makeRecord(
                id: String(format: "photo-%03d", index),
                creationDate: Date(timeIntervalSince1970: 1_700_000_000 + Double(index) * 5)
            )
        }

        let log = ProgressLog()
        let engine = makeEngine(threshold: 0.3, workers: 3)
        _ = try await engine.analyze(records: records, onProgress: { log.append($0) })

        let events = log.snapshot
        #expect(!events.isEmpty)

        for stage in PhotoAnalysisStage.allCases {
            let stageEvents = events.filter { $0.stage == stage }
            #expect(!stageEvents.isEmpty, "stage \(stage) never reported")

            var lastCompleted = -1
            for event in stageEvents {
                #expect(
                    event.completedUnits >= lastCompleted,
                    "stage \(stage) went backwards: \(event.completedUnits) after \(lastCompleted)"
                )
                lastCompleted = event.completedUnits
            }
            if let total = stageEvents.last?.totalUnits, total > 0 {
                #expect(lastCompleted == total, "stage \(stage) never reached its total")
            }
        }

        // Indeterminate stages never claim a fraction.
        let candidateEvents = events.filter { $0.stage == .generatingCandidates }
        #expect(candidateEvents.allSatisfy { $0.fraction == nil })
    }

    @Test func fingerprintingProgressTicksThroughTheLongFirstPhase() async throws {
        // The regression this pins: phase 1 (a PhotoKit round trip per asset) used to report
        // nothing until every asset was done, so the dashboard sat at "Fingerprinting 0 of N"
        // for the whole phase. With a slowed phase 1, intermediate events must appear.
        var fingerprinter = StubFingerprinter()
        fingerprinter.phaseOneDelayNanos = 20_000_000 // 20 ms × 40 assets ÷ 2 workers ≈ 400 ms
        let log = ProgressLog()
        let engine = makeEngine(fingerprinter: fingerprinter, workers: 2)
        let records = (0..<40).map { makeRecord(id: "photo-\($0)") }

        _ = try await engine.analyze(records: records, onProgress: { log.append($0) })

        let events = log.snapshot.filter { $0.stage == .fingerprinting }
        #expect(!events.isEmpty)
        let intermediate = events.filter {
            $0.completedUnits > 0 && $0.completedUnits < $0.totalUnits
        }
        #expect(!intermediate.isEmpty, "phase 1 never reported movement — the scan would look frozen")
        #expect(events.last?.completedUnits == events.last?.totalUnits)
    }

    @Test func byteLengthCollisionsGrowTheFingerprintingTotalAndCompleteExactly() async throws {
        // Two assets share a byte key → phase 2 hashes them. The total must grow by the
        // collision count so hashing still ticks, progress stays monotonic, and the stage
        // ends exactly at completed == total.
        var fingerprinter = StubFingerprinter()
        let sharedKey = ContentByteKey(imageBytes: 777, videoBytes: 0)
        let sharedFingerprint = ContentFingerprint(
            imageBytes: 777,
            videoBytes: 0,
            imageDigestHex: "shared",
            videoDigestHex: nil
        )
        fingerprinter.byteKeyOutcomes["photo-1"] = .key(sharedKey)
        fingerprinter.byteKeyOutcomes["photo-2"] = .key(sharedKey)
        fingerprinter.fingerprintOutcomes["photo-1"] = .fingerprinted(sharedFingerprint)
        fingerprinter.fingerprintOutcomes["photo-2"] = .fingerprinted(sharedFingerprint)

        let log = ProgressLog()
        let engine = makeEngine(fingerprinter: fingerprinter, workers: 2)
        let records = ["photo-0", "photo-1", "photo-2", "photo-3"].map { makeRecord(id: $0) }
        let result = try await engine.analyze(records: records, onProgress: { log.append($0) })

        let events = log.snapshot.filter { $0.stage == .fingerprinting }
        #expect(events.last?.completedUnits == 6) // 4 byte-key probes + 2 hashes
        #expect(events.last?.totalUnits == 6)
        var lastCompleted = -1
        for event in events {
            #expect(
                event.completedUnits >= lastCompleted,
                "fingerprinting went backwards: \(event.completedUnits) after \(lastCompleted)"
            )
            lastCompleted = event.completedUnits
        }
        #expect(result.exactGroups.count == 1)
        #expect(Set(result.exactGroups[0].memberAssetIDs) == ["photo-1", "photo-2"])
    }

    @Test func timedOutRequestsAreSkippedAndTheRunStillCompletes() async throws {
        // A request that hangs past the failsafe arrives here as `PhotoRequestTimeoutError`.
        // The asset must be recorded as unavailable with a reason and the pipeline must
        // reach a terminal state — never stall waiting for the hung callback.
        var fingerprinter = StubFingerprinter()
        fingerprinter.byteKeyThrowingIDs = ["photo-9"]
        var thumbnails = StubThumbnails()
        thumbnails.timeoutIDs = ["photo-11"]

        let engine = makeEngine(fingerprinter: fingerprinter, thumbnails: thumbnails)
        let records = ["photo-0", "photo-9", "photo-11"].map { makeRecord(id: $0) }
        let result = try await engine.analyze(records: records)

        let reasons = Dictionary(
            uniqueKeysWithValues: result.unavailableAssets.map { ($0.assetID, $0.reason) }
        )
        #expect(reasons["photo-9"] == .contentUnreadable)
        #expect(reasons["photo-11"] == .imageUnavailable)
        #expect(result.totalRecordCount == 3)
    }

    @Test func defaultThresholdsApplyWhenConfigurationOmitsOne() async throws {
        var configuration = PhotoAnalysisConfiguration()
        configuration.similarityThreshold = nil
        configuration.maxConcurrentWorkers = 2
        let engine = PhotoSimilarityEngine(
            configuration: configuration,
            fingerprinter: StubFingerprinter(),
            thumbnailLoader: StubThumbnails(),
            featureExtractor: StubExtractor(kind: .cpuGrid),
            stageObserver: NoopStageObserver()
        )

        let records = [
            makeRecord(id: "photo-0"),
            makeRecord(id: "photo-30"),
        ]
        let result = try await engine.analyze(records: records)

        // 30/256 = 0.117 ≤ 0.15 default → grouped, with the default reported as applied.
        #expect(result.similarityThreshold == FeaturePrintKind.cpuGrid.defaultSimilarityThreshold)
        #expect(result.similarGroups.count == 1)
    }

    // MARK: - Live error semantics (milestone: PhotoKit integration)

    @Test func permissionAndMissingAssetsSurfaceTheirSpecificReasons() async throws {
        // The full cross-seam mapping must stay granular: permission off, asset deleted,
        // and a CPU-fallback failure each reach the caller as their own reason — the
        // vocabulary future UI depends on (ARCHITECTURE §10).
        var fingerprinter = StubFingerprinter()
        fingerprinter.byteKeyOutcomes["locked-1"] = .unavailable(.permissionUnavailable)
        fingerprinter.byteKeyOutcomes["deleted-2"] = .unavailable(.assetNotFound)

        var thumbnails = StubThumbnails()
        thumbnails.failures["locked-3"] = .permissionDenied
        thumbnails.failures["deleted-4"] = .assetNotFound

        let extractor = StubExtractor(kind: .cpuGrid, failingLevels: [110])

        let engine = makeEngine(
            fingerprinter: fingerprinter,
            thumbnails: thumbnails,
            extractor: extractor
        )
        let records = [
            makeRecord(id: "locked-1"),
            makeRecord(id: "deleted-2"),
            makeRecord(id: "locked-3"),
            makeRecord(id: "deleted-4"),
            makeRecord(id: "broken-110"),
        ]

        let result = try await engine.analyze(records: records)

        let reasons = Dictionary(
            uniqueKeysWithValues: result.unavailableAssets.map { ($0.assetID, $0.reason) }
        )
        #expect(reasons["locked-1"] == .permissionUnavailable)
        #expect(reasons["deleted-2"] == .assetNotFound)
        #expect(reasons["locked-3"] == .permissionUnavailable)
        #expect(reasons["deleted-4"] == .assetNotFound)
        #expect(reasons["broken-110"] == .cpuDescriptorFailed)

        // Assets with no descriptor can never be grouped. (Content-stage failures with a
        // working thumbnail may still be visually grouped — with visual evidence only — which
        // is the established policy; see `unavailableAssetsAreReportedWithReasonsNever…`.)
        let grouped = Set(
            (result.exactGroups + result.similarGroups).flatMap(\.memberAssetIDs)
        )
        #expect(!grouped.contains("broken-110"))
        #expect(!grouped.contains("locked-3"))
        #expect(!grouped.contains("deleted-4"))
    }

    @Test func everyDurationAndCounterIsRecordedOnACompletedRun() async throws {
        // The device-validation instrumentation must be complete on success: all seven
        // durations present, and counters that agree with the result envelope.
        var fingerprinter = StubFingerprinter()
        fingerprinter.byteKeyOutcomes["cloud-0"] = .unavailable(.contentOnlyInICloud)

        let metrics = AnalysisMetrics()
        let engine = makeEngine(
            fingerprinter: fingerprinter,
            metrics: metrics,
            threshold: 0.3
        )
        let records = [
            makeRecord(id: "photo-0"),
            makeRecord(id: "photo-64"),
            makeRecord(id: "cloud-0"),
        ]

        let result = try await engine.analyze(records: records)
        #expect(result.similarGroups.count == 1)

        let snapshot = metrics.snapshot()
        for category in AnalysisMetrics.Duration.allCases {
            guard let seconds = snapshot.durations[category] else {
                Issue.record("duration \(category) was never recorded")
                continue
            }
            #expect(seconds >= 0, "duration \(category) went negative")
        }
        #expect(snapshot.durations[.total, default: 0] > 0)

        #expect(snapshot.counters[.assetsConsidered] == 3)
        #expect(snapshot.counters[.assetsFingerprinted] == 2)
        #expect(snapshot.counters[.descriptorsExtracted] == 3)
        #expect(snapshot.counters[.assetsUnavailable] == 1)
        #expect(snapshot.counters[.exactGroups] == 0)
        #expect(snapshot.counters[.similarGroups] == 1)
    }

    @Test func totalIsRecordedEvenWhenTheRunAborts() async throws {
        // Cancellation timings are exactly what a device-validation session wants to see:
        // an aborted run must still emit its `.total` duration (via the run's defer), while
        // success-only counters stay unset.
        let metrics = AnalysisMetrics()
        let observer = AbortingObserver(target: .extractingFeatures)
        let engine = makeEngine(observer: observer, metrics: metrics, workers: 1)
        let records = [
            makeRecord(id: "photo-0"),
            makeRecord(id: "photo-40"),
        ]

        var thrown: (any Error)?
        do {
            _ = try await engine.analyze(records: records)
        } catch {
            thrown = error
        }
        #expect(thrown != nil)
        #expect(observer.didFinish)

        let snapshot = metrics.snapshot()
        #expect(snapshot.durations[.total] != nil)
        #expect(snapshot.counters[.assetsConsidered] == nil)
        #expect(snapshot.counters[.similarGroups] == nil)
    }

    @Test func mixedDescriptorFamiliesNeverCorruptGrouping() async throws {
        // Hostile extractor: it latches one family for `descriptorKind` but returns prints
        // from the *other* family for some thumbnails. Every cross-family distance must
        // fail with kindMismatch (swallowed by the comparison loop) — no crash, no
        // fabricated relation, no unavailable-inflation either.
        let engine = makeEngine(extractor: MixedKindExtractor(), threshold: 0.9)
        let records = [
            makeRecord(id: "photo-0"),
            makeRecord(id: "photo-65"),
        ]

        let result = try await engine.analyze(records: records)

        #expect(result.similarGroups.isEmpty)
        #expect(result.exactGroups.isEmpty)
        #expect(result.unavailableAssets.isEmpty)
    }
}

/// Returns `.cpuGrid` prints for even gray levels and `.visionFeaturePrint` for odd ones,
/// so a single run mixes descriptor families within one bucket.
private struct MixedKindExtractor: PhotoFeatureExtracting {
    var kind: FeaturePrintKind { .cpuGrid }

    func prepare() async {}

    func featurePrint(for thumbnail: CGImage) async throws -> FeaturePrint {
        let level = grayLevel(of: thumbnail)
        let returned: FeaturePrintKind = level.isMultiple(of: 2) ? .cpuGrid : .visionFeaturePrint
        return FeaturePrint(kind: returned, values: [Float(level) / 256])
    }
}

import Foundation
import Photos
import Testing
@testable import Netto

// MARK: - Test doubles

private struct StubPhotoLibrary: PhotoLibraryReading {
    let accessLevel: PermissionState
    let stubbed: [PhotoAssetRecord]
    /// What `assetCount()` reports, independent of how many records can actually be read.
    let declaredCount: Int?
    let assetCountError: PhotoLibraryReadError?
    let cancelsDuringFirstRead: Bool

    init(
        accessLevel: PermissionState = .authorized,
        stubbed: [PhotoAssetRecord] = [],
        declaredCount: Int? = nil,
        assetCountError: PhotoLibraryReadError? = nil,
        cancelsDuringFirstRead: Bool = false
    ) {
        self.accessLevel = accessLevel
        self.stubbed = stubbed
        self.declaredCount = declaredCount
        self.assetCountError = assetCountError
        self.cancelsDuringFirstRead = cancelsDuringFirstRead
    }

    func assetCount() throws -> Int {
        if let assetCountError { throw assetCountError }
        return declaredCount ?? stubbed.count
    }

    func records(in range: Range<Int>) throws -> [PhotoAssetRecord] {
        if cancelsDuringFirstRead { withUnsafeCurrentTask { $0?.cancel() } }
        let lower = max(0, range.lowerBound)
        let upper = min(range.upperBound, stubbed.count)
        guard lower < upper else { return [] }
        return Array(stubbed[lower..<upper])
    }
}

private struct StubSizeProvider: AssetSizeProviding {
    let measured: [String: Int64]

    func sizes(for localIdentifiers: [String]) async -> [String: Int64] {
        measured.filter { localIdentifiers.contains($0.key) }
    }
}

private final class ProgressLog: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [CatalogScanProgress] = []

    func append(_ progress: CatalogScanProgress) {
        lock.lock()
        values.append(progress)
        lock.unlock()
    }

    var snapshot: [CatalogScanProgress] {
        lock.lock()
        defer { lock.unlock() }
        return values
    }
}

// MARK: - Fixtures

private func makeRecord(
    id: String = "asset-0",
    mediaType: PhotoMediaType = .image,
    subtypes: PhotoMediaSubtypes = [],
    pixelWidth: Int = 4032,
    pixelHeight: Int = 3024,
    creationDate: Date? = Date(timeIntervalSince1970: 1_700_000_000),
    modificationDate: Date? = Date(timeIntervalSince1970: 1_700_000_600),
    duration: TimeInterval = 0,
    isFavorite: Bool = false,
    isHidden: Bool = false,
    sourceType: PhotoSourceTypes = [.library],
    hasAdjustments: Bool = false,
    representsBurst: Bool = false,
    burstIdentifier: String? = nil,
    sizeInBytes: Int64? = nil
) -> PhotoAssetRecord {
    PhotoAssetRecord(
        localIdentifier: id,
        mediaType: mediaType,
        mediaSubtypes: subtypes,
        pixelWidth: pixelWidth,
        pixelHeight: pixelHeight,
        creationDate: creationDate,
        modificationDate: modificationDate,
        duration: duration,
        isFavorite: isFavorite,
        isHidden: isHidden,
        sourceType: sourceType,
        hasAdjustments: hasAdjustments,
        representsBurst: representsBurst,
        burstIdentifier: burstIdentifier,
        sizeInBytes: sizeInBytes
    )
}

private func makeRecords(count: Int) -> [PhotoAssetRecord] {
    (0..<count).map { makeRecord(id: "asset-\($0)") }
}

// MARK: - Catalog enumeration

struct PhotoCatalogBuilderTests {
    @Test func emptyLibraryCompletesWithEmptyResult() async throws {
        let result = try await PhotoCatalogBuilder().build(reading: StubPhotoLibrary())
        #expect(result.isEmpty)
        #expect(result.scannedAssetCount == 0)
        #expect(result.libraryAssetCount == 0)
        #expect(result.accessLevel == .authorized)
    }

    @Test func everyRecordIsVisitedExactlyOnceInOrder() async throws {
        let expected = makeRecords(count: 10)
        let result = try await PhotoCatalogBuilder(chunkSize: 3).build(
            reading: StubPhotoLibrary(stubbed: expected)
        )
        #expect(result.records.map(\.localIdentifier) == expected.map(\.localIdentifier))
    }

    @Test func progressIsMonotonicAndFinishesAtTotal() async {
        let log = ProgressLog()
        let expectedCount = 10

        do {
            _ = try await PhotoCatalogBuilder(chunkSize: 3).build(
                reading: StubPhotoLibrary(stubbed: makeRecords(count: expectedCount)),
                onProgress: { log.append($0) }
            )
        } catch {
            Issue.record("unexpected failure: \(error)")
            return
        }

        let events = log.snapshot
        #expect(events.count >= 2)
        #expect(events.first?.enumeratedCount == 0)
        #expect(events.last?.enumeratedCount == expectedCount)
        #expect(events.last?.totalCount == expectedCount)
        #expect(events.last?.isComplete == true)

        for (previous, next) in zip(events, events.dropFirst()) {
            #expect(next.enumeratedCount >= previous.enumeratedCount)
            #expect(next.totalCount == previous.totalCount)
        }
    }

    @Test func cancellationBetweenChunksSurfacesAsCancelled() async {
        let library = StubPhotoLibrary(
            stubbed: makeRecords(count: 20),
            cancelsDuringFirstRead: true
        )

        do {
            _ = try await PhotoCatalogBuilder(chunkSize: 4).build(reading: library)
            Issue.record("expected the catalog build to be cancelled")
        } catch let failure as CatalogScanFailure {
            #expect(failure == .cancelled)
        } catch {
            Issue.record("unexpected error type: \(error)")
        }
    }

    @Test func deniedAccessSurfacesAsPhotoLibraryUnavailable() async {
        let library = StubPhotoLibrary(assetCountError: .accessDenied)

        do {
            _ = try await PhotoCatalogBuilder().build(reading: library)
            Issue.record("expected the catalog build to fail")
        } catch let failure as CatalogScanFailure {
            #expect(failure == .photoLibraryUnavailable)
            #expect(!failure.userMessage.isEmpty)
        } catch {
            Issue.record("unexpected error type: \(error)")
        }
    }

    @Test func libraryShrinkingMidScanDegradesInsteadOfTrapping() async throws {
        let available = makeRecords(count: 6)
        let library = StubPhotoLibrary(stubbed: available, declaredCount: 10)

        let result = try await PhotoCatalogBuilder(chunkSize: 4).build(reading: library)
        #expect(result.libraryAssetCount == 10)
        #expect(result.scannedAssetCount == 6)
        #expect(result.records.map(\.localIdentifier) == available.map(\.localIdentifier))
    }

    @Test func limitedAndFullAccessRemainDistinguishable() async throws {
        let full = try await PhotoCatalogBuilder().build(
            reading: StubPhotoLibrary(accessLevel: .authorized, stubbed: makeRecords(count: 2))
        )
        let limited = try await PhotoCatalogBuilder().build(
            reading: StubPhotoLibrary(accessLevel: .limited, stubbed: makeRecords(count: 2))
        )

        #expect(full.accessLevel == .authorized)
        #expect(limited.accessLevel == .limited)
        #expect(full.accessLevel != limited.accessLevel)
    }

    @Test func streamEmitsOrderedProgressThenCompleted() async throws {
        let builder = PhotoCatalogBuilder(chunkSize: 2)
        let reading = StubPhotoLibrary(stubbed: makeRecords(count: 5))

        var events: [CatalogScanEvent] = []
        for try await event in builder.makeScanStream(reading: reading) {
            events.append(event)
        }

        #expect(events.count >= 2)
        guard case .completed(let result) = events.last else {
            Issue.record("last event must be .completed, got \(String(describing: events.last))")
            return
        }
        #expect(result.scannedAssetCount == 5)
        #expect(events.dropLast().allSatisfy { event in
            if case .progress = event { return true }
            return false
        })
    }
}

// MARK: - Catalog record

struct PhotoAssetRecordTests {
    @Test func screenshotFlagComesFromMediaSubtypeOnly() {
        let screenshot = makeRecord(subtypes: [.screenshot])
        let panorama = makeRecord(subtypes: [.panorama])
        let plain = makeRecord()

        #expect(screenshot.isScreenshot)
        #expect(!panorama.isScreenshot)
        #expect(!plain.isScreenshot)
    }

    @Test func mediaTypeDrivesImageAndVideoFlags() {
        let video = makeRecord(mediaType: .video, subtypes: [.videoScreenRecording], duration: 90)
        #expect(video.isVideo)
        #expect(!video.isImage)
        #expect(!video.isScreenshot)

        let image = makeRecord(mediaType: .image, subtypes: [.livePhoto])
        #expect(image.isImage)
        #expect(image.isLivePhoto)
        #expect(!image.isVideo)
    }

    @Test func sizeIsUnknownByDefaultAndNeverZero() {
        let record = makeRecord()
        #expect(record.sizeInBytes == nil)
        #expect(!record.isSizeKnown)
    }

    @Test func resolvingSizeOnlyChangesSize() {
        let original = makeRecord(id: "asset-7")
        let resolved = original.resolvingSize(4_096)

        #expect(resolved.sizeInBytes == 4_096)
        #expect(resolved.isSizeKnown)
        #expect(resolved.localIdentifier == original.localIdentifier)
        #expect(resolved.mediaType == original.mediaType)
        #expect(resolved.creationDate == original.creationDate)
        #expect(original.sizeInBytes == nil, "resolvingSize must not mutate the source record")
    }

    @Test func knownSizeTotalIgnoresUnknownEntries() {
        let known = makeRecord(id: "a", sizeInBytes: 100)
        let unknown = makeRecord(id: "b", sizeInBytes: nil)
        let result = CatalogScanResult(
            records: [known, unknown],
            libraryAssetCount: 2,
            accessLevel: .authorized
        )
        #expect(result.knownSizeBytes == 100)
    }

    @Test func cacheKeyChangesWhenModificationDateChanges() {
        let base = makeRecord(id: "asset-1", modificationDate: Date(timeIntervalSince1970: 100))
        let edited = makeRecord(id: "asset-1", modificationDate: Date(timeIntervalSince1970: 200))
        let same = makeRecord(id: "asset-1", modificationDate: Date(timeIntervalSince1970: 100))
        let otherAsset = makeRecord(id: "asset-2", modificationDate: Date(timeIntervalSince1970: 100))

        #expect(base.cacheKey == same.cacheKey)
        #expect(base.cacheKey != edited.cacheKey)
        #expect(base.cacheKey != otherAsset.cacheKey)
    }

    @Test func catalogCountsClassifyWithoutAnalysis() {
        let result = CatalogScanResult(
            records: [
                makeRecord(id: "s", subtypes: [.screenshot]),
                makeRecord(id: "v", mediaType: .video, duration: 60),
                makeRecord(id: "l", subtypes: [.livePhoto]),
                makeRecord(id: "e", hasAdjustments: true),
            ],
            libraryAssetCount: 4,
            accessLevel: .limited
        )

        #expect(result.screenshotCount == 1)
        #expect(result.videoCount == 1)
        #expect(result.livePhotoCount == 1)
        #expect(result.adjustedCount == 1)
        #expect(result.imageCount == 3)
        #expect(result.accessLevel == .limited)
        #expect(!result.isEmpty)
    }
}

// MARK: - Scan state

struct CatalogScanStateTests {
    @Test func progressFractionHandlesEmptyTotals() {
        let indeterminate = CatalogScanProgress.indeterminate
        #expect(indeterminate.fraction == 0)
        #expect(!indeterminate.isComplete)

        let partial = CatalogScanProgress(enumeratedCount: 1, totalCount: 4)
        #expect(partial.fraction == 0.25)
        #expect(!partial.isComplete)

        let done = CatalogScanProgress(enumeratedCount: 4, totalCount: 4)
        #expect(done.isComplete)
    }

    @Test func stateMachineExposesRunningDistinctly() {
        #expect(!CatalogScanState.notStarted.isRunning)
        #expect(CatalogScanState.running(.indeterminate).isRunning)
        #expect(!CatalogScanState.cancelled.isRunning)
        #expect(!CatalogScanState.failed(.cancelled).isRunning)
        #expect(!CatalogScanState.completed(
            CatalogScanResult(records: [], libraryAssetCount: 0, accessLevel: .authorized)
        ).isRunning)
    }

    @Test func failuresCarryHumanReadableMessages() {
        for failure in [CatalogScanFailure.photoLibraryUnavailable, .cancelled, .underlying("x")] {
            #expect(!failure.userMessage.isEmpty)
        }
    }
}

// MARK: - Resource scope & sizing

struct AssetResourceScopeTests {
    @Test func payloadTypesCountAndMetadataTypesDoNot() {
        #expect(AssetResourceScope.counts(.photo))
        #expect(AssetResourceScope.counts(.video))
        #expect(AssetResourceScope.counts(.fullSizePhoto))
        #expect(AssetResourceScope.counts(.fullSizeVideo))
        #expect(AssetResourceScope.counts(.pairedVideo))
        #expect(AssetResourceScope.counts(.fullSizePairedVideo))
        #expect(AssetResourceScope.counts(.alternatePhoto))

        #expect(!AssetResourceScope.counts(.adjustmentData))
        #expect(!AssetResourceScope.counts(.adjustmentBasePhoto))
        #expect(!AssetResourceScope.counts(.adjustmentBaseVideo))
        #expect(!AssetResourceScope.counts(.adjustmentBasePairedVideo))
        #expect(!AssetResourceScope.counts(.audio))
        #expect(!AssetResourceScope.counts(.photoProxy))
    }

    @Test func scopePartitionsEveryKnownResourceType() {
        let all: Set<PHAssetResourceType> = [
            .photo, .video, .audio, .alternatePhoto,
            .fullSizePhoto, .fullSizeVideo,
            .adjustmentData, .adjustmentBasePhoto,
            .pairedVideo, .fullSizePairedVideo,
            .adjustmentBasePairedVideo, .adjustmentBaseVideo,
            .photoProxy,
        ]

        #expect(AssetResourceScope.countedTypes.union(AssetResourceScope.excludedTypes) == all)
        #expect(AssetResourceScope.countedTypes.isDisjoint(with: AssetResourceScope.excludedTypes))
    }
}

struct AssetSizeProviderTests {
    @Test func providerFillsKnownSizesAndLeavesUnknownNil() async {
        let measured = makeRecord(id: "measured")
        let unknown = makeRecord(id: "unknown")
        let provider = StubSizeProvider(measured: ["measured": 2_048])

        let resolved = await [measured, unknown].resolvingSizes(using: provider)

        #expect(resolved[0].sizeInBytes == 2_048)
        #expect(resolved[1].sizeInBytes == nil)
        #expect(resolved[1].isSizeKnown == false)
    }

    @Test func alreadyResolvedSizesAreNotRequestedAgain() async {
        let resolved = makeRecord(id: "done", sizeInBytes: 99)
        let pending = makeRecord(id: "pending")
        let provider = StubSizeProvider(measured: ["done": 1, "pending": 2])

        let result = await [resolved, pending].resolvingSizes(using: provider)

        #expect(result[0].sizeInBytes == 99)
        #expect(result[1].sizeInBytes == 2)
    }

    @Test func emptySelectionShortCircuits() async {
        let provider = StubSizeProvider(measured: [:])
        let records = [makeRecord(id: "a", sizeInBytes: 5)]
        let result = await records.resolvingSizes(using: provider)
        #expect(result[0].sizeInBytes == 5)
    }
}

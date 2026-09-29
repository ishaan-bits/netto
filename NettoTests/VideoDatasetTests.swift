import Foundation
import Testing
@testable import Netto

// MARK: - VideoDataset: classification, resolution, deterministic ordering
//
// Videos are a media-type filter over the catalog — every test here builds plain records and
// proves the dataset never invents an identity, a size, or an ordering the inputs don't have.

struct VideoDatasetTests {
    // MARK: Classification (a filter, never a second enumeration)

    @Test func datasetIsExactlyTheVideoRecordsInCatalogOrder() {
        let catalog = makeCatalog([
            record(id: "p-01", mediaType: .image),
            record(id: "v-01", mediaType: .video),
            record(id: "shot-01", mediaType: .image, subtypes: [.screenshot]),
            record(id: "v-02", mediaType: .video),
            record(id: "audio-01", mediaType: .audio),
            record(id: "live-01", mediaType: .image, subtypes: [.livePhoto]),
            record(id: "unknown-01", mediaType: .unknown),
        ])

        let videos = VideoDataset.records(in: catalog)

        #expect(videos.map(\.localIdentifier) == ["v-01", "v-02"])
    }

    @Test func livePhotosScreenshotsAndPhotosAreNeverVideos() {
        let catalog = makeCatalog([
            record(id: "p-01", mediaType: .image),
            record(id: "shot-01", mediaType: .image, subtypes: [.screenshot]),
            record(id: "live-01", mediaType: .image, subtypes: [.livePhoto]),
        ])
        #expect(VideoDataset.records(in: catalog).isEmpty)
        #expect(VideoDataset.identifiers(in: catalog).isEmpty)
    }

    @Test func identifiersAreASetAndIgnoreDuplicateIDs() {
        let duplicated = record(id: "v-01", mediaType: .video)
        let catalog = makeCatalog([duplicated, duplicated, record(id: "v-02", mediaType: .video)])

        #expect(VideoDataset.identifiers(in: catalog) == ["v-01", "v-02"])
    }

    // MARK: Signature (plan staleness fingerprint)

    @Test func signatureIsStableAndTracksMembershipAndCount() {
        let base = VideoDataset.identifiers(in: makeCatalog([
            record(id: "v-01", mediaType: .video),
            record(id: "v-02", mediaType: .video),
        ]))
        let same = VideoDataset.identifiers(in: makeCatalog([
            record(id: "v-02", mediaType: .video),
            record(id: "v-01", mediaType: .video), // order must not matter
        ]))
        let grew = VideoDataset.identifiers(in: makeCatalog([
            record(id: "v-01", mediaType: .video),
            record(id: "v-02", mediaType: .video),
            record(id: "v-03", mediaType: .video),
        ]))
        let shrank = VideoDataset.identifiers(in: makeCatalog([
            record(id: "v-01", mediaType: .video),
        ]))

        #expect(VideoDataset.signature(for: base) == VideoDataset.signature(for: same))
        #expect(VideoDataset.signature(for: base) != VideoDataset.signature(for: grew))
        #expect(VideoDataset.signature(for: base) != VideoDataset.signature(for: shrank))
        #expect(VideoDataset.signature(for: base).hasPrefix("v1-videos|"))
    }

    @Test func signatureIgnoresNonVideoCatalogChanges() {
        let withoutPhoto = makeCatalog([record(id: "v-01", mediaType: .video)])
        let withPhoto = makeCatalog([
            record(id: "v-01", mediaType: .video),
            record(id: "p-01", mediaType: .image),
        ])
        #expect(
            VideoDataset.signature(in: withoutPhoto) == VideoDataset.signature(in: withPhoto)
        )
    }

    // MARK: Size resolution (embed, never fabricate)

    @Test func resolvedEmbedsMeasuredBytesAndKeepsMissingAsUnknown() {
        let records = [
            record(id: "v-01", mediaType: .video),
            record(id: "v-02", mediaType: .video),
            record(id: "v-03", mediaType: .video),
        ]

        let resolved = VideoDataset.resolved(records, with: ["v-01": 100, "v-03": 300])

        #expect(resolved.first { $0.localIdentifier == "v-01" }?.sizeInBytes == 100)
        #expect(resolved.first { $0.localIdentifier == "v-02" }?.sizeInBytes == nil)
        #expect(resolved.first { $0.localIdentifier == "v-03" }?.sizeInBytes == 300)
        // An absent measurement is unknown — never zero.
        #expect(resolved.first { $0.localIdentifier == "v-02" }?.isSizeKnown == false)
    }

    // MARK: Sorting (largest first, fully deterministic)

    @Test func measuredSizesSortDescendingAndUnknownsComeLast() {
        let sorted = VideoDataset.sorted([
            record(id: "unknown", mediaType: .video, daysAgo: 1),
            record(id: "small", mediaType: .video, daysAgo: 2, size: 100),
            record(id: "huge", mediaType: .video, daysAgo: 3, size: 1_000_000),
            record(id: "medium", mediaType: .video, daysAgo: 4, size: 50_000),
        ])

        #expect(sorted.map(\.localIdentifier) == ["huge", "medium", "small", "unknown"])
    }

    @Test func unknownSizesAreNeverRankedAsZero() {
        // The unmeasured video is the OLDEST, so any zero-defaulting comparator would push it
        // to the very top. It must stay at the bottom: unknown ≠ zero.
        let sorted = VideoDataset.sorted([
            record(id: "unknown-oldest", mediaType: .video, daysAgo: 999, size: nil),
            record(id: "known-newest", mediaType: .video, daysAgo: 1, size: 1),
        ])
        #expect(sorted.map(\.localIdentifier) == ["known-newest", "unknown-oldest"])
    }

    @Test func equalSizesBreakTowardNewerThenByIdentifier() {
        let sorted = VideoDataset.sorted([
            record(id: "b", mediaType: .video, daysAgo: 5, size: 500),
            record(id: "a", mediaType: .video, daysAgo: 5, size: 500), // same size, same date
            record(id: "c", mediaType: .video, daysAgo: 1, size: 500), // same size, newer
        ])
        #expect(sorted.map(\.localIdentifier) == ["c", "a", "b"])
    }

    @Test func unknownSizesTowardNewerThenByIdentifier() {
        let sorted = VideoDataset.sorted([
            record(id: "b", mediaType: .video, daysAgo: 5),
            record(id: "a", mediaType: .video, daysAgo: 5),
            record(id: "c", mediaType: .video, daysAgo: 1),
        ])
        #expect(sorted.map(\.localIdentifier) == ["c", "a", "b"])
    }

    @Test func datedRecordsSortBeforeUndatedOnesAtEqualSize() {
        let dated = record(id: "dated", mediaType: .video, daysAgo: 500, size: 10)
        let undated = PhotoAssetRecord(
            localIdentifier: "undated",
            mediaType: .video,
            mediaSubtypes: [],
            pixelWidth: 100,
            pixelHeight: 100,
            creationDate: nil,
            modificationDate: nil,
            duration: 0,
            isFavorite: false,
            isHidden: false,
            sourceType: .library,
            hasAdjustments: false,
            representsBurst: false,
            burstIdentifier: nil,
            sizeInBytes: 10
        )
        #expect(VideoDataset.sorted([undated, dated]).map(\.localIdentifier) == ["dated", "undated"])
    }

    @Test func sortingIsDeterministicAcrossInputOrders() {
        let records: [PhotoAssetRecord] = (0..<24).map { index in
            let size: Int64? = index % 5 == 0 ? nil : Int64((index % 7) * 1_000)
            return record(
                id: "v-\(index)",
                mediaType: .video,
                daysAgo: Double(index % 6),
                size: size
            )
        }
        let expected = VideoDataset.sorted(records).map(\.localIdentifier)

        // Fixed-seed shuffle: any input order must produce the identical output order.
        var generator = SplitMix64(seed: 0x5EED)
        for _ in 0..<50 {
            var shuffled = records
            shuffled.shuffle(using: &generator)
            #expect(VideoDataset.sorted(shuffled).map(\.localIdentifier) == expected)
        }
    }

    @Test func partialMeasurementListKeepsUnknownsAfterMeasuredOnes() {
        // The dataset-level partial state: 2 of 3 measured. The unknown one is listed last,
        // ordered by date among the other unknowns (there are none here).
        let records = VideoDataset.resolved(
            [
                record(id: "v-small", mediaType: .video, daysAgo: 1, size: nil),
                record(id: "v-big", mediaType: .video, daysAgo: 2, size: nil),
                record(id: "v-mid", mediaType: .video, daysAgo: 3, size: nil),
            ],
            with: ["v-big": 900, "v-mid": 400]
        )
        #expect(VideoDataset.sorted(records).map(\.localIdentifier) == ["v-big", "v-mid", "v-small"])
    }

    // MARK: Large synthetic dataset (performance guard, no real video files)

    @Test func sortingA20ThousandVideoLibraryStaysCorrectAndFast() {
        var generator = SplitMix64(seed: 0xC0FFEE)
        let synthetic = (0..<20_000).map { index in
            record(
                id: "synthetic-\(index)",
                mediaType: .video,
                daysAgo: Double(Int.random(in: 0..<10_000, using: &generator)),
                size: index % 11 == 0 ? nil : Int64(Int.random(in: 0..<1_000_000_000, using: &generator))
            )
        }

        let start = ContinuousClock.now
        let sorted = VideoDataset.sorted(synthetic)
        let elapsed = ContinuousClock.now - start

        #expect(sorted.count == synthetic.count)
        // Every measured record precedes every unknown one…
        let firstUnknownIndex = sorted.firstIndex { $0.sizeInBytes == nil }
        if let firstUnknownIndex {
            #expect(sorted[..<firstUnknownIndex].allSatisfy { $0.isSizeKnown })
            #expect(sorted[firstUnknownIndex...].allSatisfy { !$0.isSizeKnown })
        }
        // …and measured records are non-increasing in bytes.
        let measured = sorted.compactMap(\.sizeInBytes)
        #expect(measured == measured.sorted(by: >))
        // Generous bound: an accidental quadratic comparator over 20k records would blow it.
        #expect(elapsed < .seconds(5))
    }

    // MARK: Phase mapping + presentation

    @Test func phaseFollowsPermissionBeforeCatalog() {
        #expect(
            VideosPresentation.phase(
                permission: .notDetermined, catalog: .completed(VideosFixture.completed),
                resolution: .idle
            ) == .permissionRequired
        )
        #expect(
            VideosPresentation.phase(
                permission: .denied, catalog: .completed(VideosFixture.completed),
                resolution: .idle
            ) == .permissionDenied
        )
    }

    @Test func phaseIsScanRequiredWithoutCompletedCatalog() {
        #expect(
            VideosPresentation.phase(
                permission: .authorized, catalog: .notStarted, resolution: .idle
            ) == .scanRequired
        )
        #expect(
            VideosPresentation.phase(
                permission: .authorized, catalog: .cancelled, resolution: .idle
            ) == .scanRequired
        )
    }

    @Test func emptyCatalogOfVideosIsEmptyPhase() {
        #expect(
            VideosPresentation.phase(
                permission: .authorized, catalog: .completed(VideosFixture.noVideosResult),
                resolution: .idle
            ) == .empty
        )
    }

    @Test func idleAndMeasuringBothPresentAsMeasuringProgress() {
        let catalog = CatalogScanState.completed(VideosFixture.completed)
        let videoCount = VideosFixture.videos.count

        #expect(
            VideosPresentation.phase(
                permission: .authorized, catalog: catalog, resolution: .idle
            ) == .measuringVideos(measured: 0, total: videoCount)
        )
        #expect(
            VideosPresentation.phase(
                permission: .authorized, catalog: catalog,
                resolution: .measuring(
                    VideoSizeResolution.Measurement(
                        datasetSignature: VideoDataset.signature(in: VideosFixture.completed),
                        bytes: ["video-01": 1],
                        total: videoCount
                    )
                )
            ) == .measuringVideos(measured: 1, total: videoCount)
        )
    }

    @Test func resultsAreSortedWithMeasuredSizesEmbedded() {
        let phase = VideosPresentation.phase(
            permission: .authorized,
            catalog: .completed(VideosFixture.completed),
            resolution: VideosFixture.settledPartial
        )
        guard case .results(let records) = phase else {
            Issue.record("expected results, got \(phase)")
            return
        }
        #expect(records.count == VideosFixture.videos.count)
        // Largest measured first; the unmeasured fixture video is last with nil size.
        #expect(records.map(\.localIdentifier).first == "video-03") // 1.6 GB
        #expect(records.last?.localIdentifier == "video-06") // never measured
        #expect(records.last?.sizeInBytes == nil)
        let bytes = records.compactMap(\.sizeInBytes)
        #expect(bytes == bytes.sorted(by: >))
    }

    @Test func aMeasurementFromAnotherDatasetIsTreatedAsIdle() {
        let stale = VideoSizeResolution.settled(
            VideoSizeResolution.Measurement(
                datasetSignature: "v1-videos|0|",
                bytes: ["video-01": 1],
                total: 6
            )
        )
        let phase = VideosPresentation.phase(
            permission: .authorized,
            catalog: .completed(VideosFixture.completed),
            resolution: stale
        )
        #expect(phase == .measuringVideos(measured: 0, total: VideosFixture.videos.count))
    }

    // MARK: Dashboard status honesty

    @Test func statusTextStatesMeasurementHonesty() {
        let catalog = CatalogScanState.completed(VideosFixture.completed)

        #expect(
            VideosPresentation.statusText(
                permission: .authorized, catalog: catalog, resolution: .idle
            ) == "6 videos · sizes not measured yet"
        )
        let partialText = VideosPresentation.statusText(
            permission: .authorized, catalog: catalog, resolution: VideosFixture.settledPartial
        )
        #expect(partialText.hasPrefix("6 videos · measured "))
        #expect(partialText.hasSuffix("1 size pending"))
        var allSix = VideosFixture.measuredBytes
        allSix["video-06"] = 50_000_000
        let full = VideoSizeResolution.settled(
            VideoSizeResolution.Measurement(
                datasetSignature: VideoDataset.signature(in: VideosFixture.completed),
                bytes: allSix,
                total: VideosFixture.videos.count
            )
        )
        let fullText = VideosPresentation.statusText(
            permission: .authorized, catalog: catalog, resolution: full
        )
        #expect(fullText.hasPrefix("6 videos · measured "))
        #expect(!fullText.contains("pending"))
    }

    @Test func statusTextNeverClaimsAZeroMeasurement() {
        let catalog = CatalogScanState.completed(VideosFixture.completed)
        // Settled but nothing measured (a run cancelled before its first batch landed):
        // naming a zero total would claim a measurement that never happened.
        let nothingMeasured = VideoSizeResolution.settled(
            VideoSizeResolution.Measurement(
                datasetSignature: VideoDataset.signature(in: VideosFixture.completed),
                bytes: [:],
                total: VideosFixture.videos.count
            )
        )
        let text = VideosPresentation.statusText(
            permission: .authorized, catalog: catalog, resolution: nothingMeasured
        )
        #expect(text == "6 videos · 6 sizes pending")
        #expect(!text.contains("measured"))
    }

    @Test func statusTextCoversEmptyPermissionAndScanStates() {
        #expect(
            VideosPresentation.statusText(
                permission: .notDetermined, catalog: .notStarted, resolution: .idle
            ) == "Photos access needed"
        )
        #expect(
            VideosPresentation.statusText(
                permission: .denied, catalog: .notStarted, resolution: .idle
            ) == "Photos access is off"
        )
        #expect(
            VideosPresentation.statusText(
                permission: .authorized, catalog: .notStarted, resolution: .idle
            ) == "Not scanned yet"
        )
        #expect(
            VideosPresentation.statusText(
                permission: .authorized, catalog: .completed(VideosFixture.noVideosResult),
                resolution: .idle
            ) == "No videos found"
        )
    }

    @Test func durationTextFormatsClockReadouts() {
        #expect(VideosPresentation.durationText(0) == "0:00")
        #expect(VideosPresentation.durationText(7) == "0:07")
        #expect(VideosPresentation.durationText(14) == "0:14")
        #expect(VideosPresentation.durationText(63) == "1:03")
        #expect(VideosPresentation.durationText(3_725) == "1:02:05")
    }

    @Test func previewMessagesKeepTheFailureModesDistinct() {
        let iCloud = VideosPresentation.previewUnavailableMessage(for: .onlyInICloud)
        let missing = VideosPresentation.previewUnavailableMessage(for: .assetNotFound)
        let denied = VideosPresentation.previewUnavailableMessage(for: .permissionDenied)
        let broken = VideosPresentation.previewUnavailableMessage(for: .unavailable)

        #expect(iCloud.contains("iCloud"))
        #expect(missing.contains("no longer"))
        #expect(denied.contains("Settings"))
        #expect(broken.contains("can't be played"))
        #expect(Set([iCloud, missing, denied, broken]).count == 4)
    }

    // MARK: Resolution state shape

    @Test func resolutionProgressIsMeasuredCountOverTotalNeverZeroFilled() {
        let measurement = VideoSizeResolution.Measurement(
            datasetSignature: "sig",
            bytes: ["a": 10, "b": 20],
            total: 5
        )
        let measuring = VideoSizeResolution.measuring(measurement)

        #expect(measuring.bytes.count == 2)
        #expect(measuring.isMeasuring)
        #expect(measurement.measuredCount == 2)
        #expect(measurement.isPartial) // 2 of 5 — pending is named, not counted as zero
        #expect(!VideoSizeResolution.idle.bytes.keys.contains("a"))

        let settled = VideoSizeResolution.settled(measurement)
        #expect(settled.isCurrent(for: "sig"))
        #expect(!settled.isCurrent(for: "other"))
    }
}

// MARK: - Helpers

private let fixtureBaseDate = Date(timeIntervalSince1970: 1_760_000_000)

private func record(
    id: String,
    mediaType: PhotoMediaType,
    subtypes: PhotoMediaSubtypes = [],
    daysAgo: Double = 1,
    size: Int64? = nil
) -> PhotoAssetRecord {
    PhotoAssetRecord(
        localIdentifier: id,
        mediaType: mediaType,
        mediaSubtypes: subtypes,
        pixelWidth: 1920,
        pixelHeight: 1080,
        creationDate: fixtureBaseDate.addingTimeInterval(-daysAgo * 86_400),
        modificationDate: nil,
        duration: 0,
        isFavorite: false,
        isHidden: false,
        sourceType: .library,
        hasAdjustments: false,
        representsBurst: false,
        burstIdentifier: nil,
        sizeInBytes: size
    )
}

private func makeCatalog(_ records: [PhotoAssetRecord]) -> CatalogScanResult {
    CatalogScanResult(
        records: records,
        libraryAssetCount: records.count,
        accessLevel: .authorized
    )
}

/// Deterministic shuffle companion — `SystemRandomNumberGenerator` would make failures
/// unreproducible.
private struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

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

    /// The fixture catalog's fingerprint — what the environment's cache would supply.
    private var fixtureSignature: String {
        VideoDataset.signature(in: VideosFixture.completed)
    }

    @Test func phaseFollowsPermissionBeforeCatalog() {
        #expect(
            VideosPresentation.phase(
                permission: .notDetermined, catalog: .completed(VideosFixture.completed),
                resolution: .idle, datasetSignature: fixtureSignature
            ) == .permissionRequired
        )
        #expect(
            VideosPresentation.phase(
                permission: .denied, catalog: .completed(VideosFixture.completed),
                resolution: .idle, datasetSignature: fixtureSignature
            ) == .permissionDenied
        )
    }

    @Test func phaseIsScanRequiredWithoutCompletedCatalog() {
        #expect(
            VideosPresentation.phase(
                permission: .authorized, catalog: .notStarted, resolution: .idle,
                datasetSignature: ""
            ) == .scanRequired
        )
        #expect(
            VideosPresentation.phase(
                permission: .authorized, catalog: .cancelled, resolution: .idle,
                datasetSignature: ""
            ) == .scanRequired
        )
    }

    @Test func emptyCatalogOfVideosIsEmptyPhase() {
        #expect(
            VideosPresentation.phase(
                permission: .authorized, catalog: .completed(VideosFixture.noVideosResult),
                resolution: .idle,
                datasetSignature: VideoDataset.signature(in: VideosFixture.noVideosResult)
            ) == .empty
        )
    }

    @Test func idleAndMeasuringBothPresentAsMeasuringProgress() {
        let catalog = CatalogScanState.completed(VideosFixture.completed)
        let videoCount = VideosFixture.videos.count

        #expect(
            VideosPresentation.phase(
                permission: .authorized, catalog: catalog, resolution: .idle,
                datasetSignature: fixtureSignature
            ) == .measuringVideos(measured: 0, total: videoCount, unavailable: 0)
        )
        #expect(
            VideosPresentation.phase(
                permission: .authorized, catalog: catalog,
                resolution: .measuring(
                    VideoSizeResolution.Measurement(
                        datasetSignature: fixtureSignature,
                        bytes: ["video-01": 1],
                        total: videoCount
                    )
                ),
                datasetSignature: fixtureSignature
            ) == .measuringVideos(measured: 1, total: videoCount, unavailable: 0)
        )
    }

    @Test func measuringSurfacesUnavailableSizesAsTheirOwnFigure() {
        // Attempted-but-unmeasurable videos advance progress honestly: they show as
        // `unavailable`, never folded into `measured` (and never zero).
        let measurement = VideoSizeResolution.Measurement(
            datasetSignature: fixtureSignature,
            bytes: ["video-01": 1],
            total: 6,
            unavailableIDs: ["video-04", "video-05"]
        )
        let phase = VideosPresentation.phase(
            permission: .authorized,
            catalog: .completed(VideosFixture.completed),
            resolution: .measuring(measurement),
            datasetSignature: fixtureSignature
        )
        #expect(phase == .measuringVideos(measured: 1, total: 6, unavailable: 2))
    }

    @Test func resultsAreSortedWithMeasuredSizesEmbedded() {
        let phase = VideosPresentation.phase(
            permission: .authorized,
            catalog: .completed(VideosFixture.completed),
            resolution: VideosFixture.settledPartial,
            datasetSignature: fixtureSignature
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

    @Test func aCallerSuppliedSettledRecordsListIsUsedVerbatim() {
        // The environment passes its cached resolved+sorted list; the pure function must
        // render exactly that (no second sort), and it must match what nil computes.
        let records = VideoDataset.sorted(
            VideoDataset.resolved(VideosFixture.videos, with: VideosFixture.measuredBytes)
        )
        let phase = VideosPresentation.phase(
            permission: .authorized,
            catalog: .completed(VideosFixture.completed),
            resolution: VideosFixture.settledPartial,
            datasetSignature: fixtureSignature,
            settledRecords: records
        )
        #expect(phase == .results(records))
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
            resolution: stale,
            datasetSignature: fixtureSignature
        )
        #expect(
            phase == .measuringVideos(
                measured: 0, total: VideosFixture.videos.count, unavailable: 0
            )
        )
    }

    // MARK: Dashboard status honesty

    @Test func statusTextStatesMeasurementHonesty() {
        let catalog = CatalogScanState.completed(VideosFixture.completed)

        #expect(
            VideosPresentation.statusText(
                permission: .authorized, catalog: catalog, resolution: .idle,
                datasetSignature: fixtureSignature
            ) == "6 videos · sizes not measured yet"
        )
        let partialText = VideosPresentation.statusText(
            permission: .authorized, catalog: catalog, resolution: VideosFixture.settledPartial,
            datasetSignature: fixtureSignature
        )
        #expect(partialText.hasPrefix("6 videos · measured "))
        // video-06 was attempted and failed: named as unavailable, not lumped into pending.
        #expect(partialText.hasSuffix("1 size unavailable"))
        var allSix = VideosFixture.measuredBytes
        allSix["video-06"] = 50_000_000
        let full = VideoSizeResolution.settled(
            VideoSizeResolution.Measurement(
                datasetSignature: fixtureSignature,
                bytes: allSix,
                total: VideosFixture.videos.count
            )
        )
        let fullText = VideosPresentation.statusText(
            permission: .authorized, catalog: catalog, resolution: full,
            datasetSignature: fixtureSignature
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
                datasetSignature: fixtureSignature,
                bytes: [:],
                total: VideosFixture.videos.count
            )
        )
        let text = VideosPresentation.statusText(
            permission: .authorized, catalog: catalog, resolution: nothingMeasured,
            datasetSignature: fixtureSignature
        )
        #expect(text == "6 videos · 6 sizes pending")
        #expect(!text.contains("measured"))
    }

    @Test func statusTextNamesUnavailableSizesDuringMeasurement() {
        let catalog = CatalogScanState.completed(VideosFixture.completed)
        let measuring = VideoSizeResolution.measuring(
            VideoSizeResolution.Measurement(
                datasetSignature: fixtureSignature,
                bytes: ["video-01": 1],
                total: 6,
                unavailableIDs: ["video-02", "video-04"]
            )
        )
        let text = VideosPresentation.statusText(
            permission: .authorized, catalog: catalog, resolution: measuring,
            datasetSignature: fixtureSignature
        )
        #expect(text == "Measuring sizes · 1 of 6 videos… · 2 unavailable")
    }

    @Test func statusTextSplitsAttemptedFailuresFromStillPendingSizes() {
        // A mixed remainder: attempted failures are "unavailable", untouched ids stay
        // "pending" — never conflated in either direction.
        let catalog = CatalogScanState.completed(VideosFixture.completed)
        var fourBytes = VideosFixture.measuredBytes
        fourBytes.removeValue(forKey: "video-05") // video-05 not yet attempted → pending
        let mixed = VideoSizeResolution.settled(
            VideoSizeResolution.Measurement(
                datasetSignature: fixtureSignature,
                bytes: fourBytes, // 4 measured, video-06 attempted-and-failed, video-05 pending
                total: 6,
                unavailableIDs: ["video-06"]
            )
        )
        let text = VideosPresentation.statusText(
            permission: .authorized, catalog: catalog, resolution: mixed,
            datasetSignature: fixtureSignature
        )
        #expect(text.hasPrefix("6 videos · measured "))
        #expect(text.contains("1 size unavailable"))
        #expect(text.contains("1 size pending"))
    }

    // MARK: Video Cleanup summary honesty

    @Test func cleanupSummarySaysNotMeasuredBeforeAnythingRuns() {
        // Idle / no current measurement: the screen must not claim
        // "0 bytes measured · N size unavailable" — that asserted a run that never
        // happened (the starved-measurement failure).
        let line = VideosPresentation.videoCleanupSummaryLine(
            known: [],
            unknown: VideosFixture.videos,
            resolution: .idle,
            datasetSignature: fixtureSignature
        )
        #expect(line == "sizes not measured yet")

        let stale = VideosPresentation.videoCleanupSummaryLine(
            known: [],
            unknown: VideosFixture.videos,
            resolution: VideosFixture.settledPartial,
            datasetSignature: "another-dataset"
        )
        #expect(stale == "sizes not measured yet")
    }

    @Test func cleanupSummarySplitsAttemptedFailuresFromUntouchedOnes() {
        let known = VideosFixture.videos.compactMap { record -> PhotoAssetRecord? in
            guard let bytes = VideosFixture.measuredBytes[record.localIdentifier] else {
                return nil
            }
            return record.resolvingSize(bytes)
        }
        let unknown = VideosFixture.videos.filter {
            VideosFixture.measuredBytes[$0.localIdentifier] == nil
        } // [video-06]

        // Settled fixture: video-06 was attempted and failed.
        let attemptedLine = VideosPresentation.videoCleanupSummaryLine(
            known: known,
            unknown: unknown,
            resolution: VideosFixture.settledPartial,
            datasetSignature: fixtureSignature
        )
        #expect(attemptedLine.contains("measured"))
        #expect(attemptedLine.contains("1 size unavailable"))
        #expect(!attemptedLine.contains("not measured"))
        #expect(!attemptedLine.hasPrefix("0 ")) // no zero-measurement claim

        // The same bytes, but video-06 was never attempted: pending, never "unavailable".
        let untouched = VideoSizeResolution.settled(
            VideoSizeResolution.Measurement(
                datasetSignature: fixtureSignature,
                bytes: VideosFixture.measuredBytes,
                total: 6
            )
        )
        let pendingLine = VideosPresentation.videoCleanupSummaryLine(
            known: known,
            unknown: unknown,
            resolution: untouched,
            datasetSignature: fixtureSignature
        )
        #expect(pendingLine.contains("measured"))
        #expect(pendingLine.contains("1 size not measured"))
        #expect(!pendingLine.contains("unavailable"))
    }

    @Test func rowCaptionsSeparateMeasuredAttemptedAndUntouched() {
        let measured = VideosPresentation.videoCleanupSizeCaption(bytes: 240_000_000, attempted: false)
        #expect(measured.text == ByteFormat.string(240_000_000))
        #expect(!measured.isWarning)

        let failed = VideosPresentation.videoCleanupSizeCaption(bytes: nil, attempted: true)
        #expect(failed.text == "Size unavailable — not stored locally")
        #expect(failed.isWarning)

        let untouched = VideosPresentation.videoCleanupSizeCaption(bytes: nil, attempted: false)
        #expect(untouched.text == "Size not measured yet")
        #expect(!untouched.isWarning)
    }

    @Test func unknownSectionTitleNamesICloudOnlyAfterAnAttempt() {
        #expect(
            VideosPresentation.videoUnknownSectionTitle(attempted: 0) == "Sizes not measured yet"
        )
        #expect(
            VideosPresentation.videoUnknownSectionTitle(attempted: 3) == "iCloud / size unavailable"
        )
    }

    @Test func statusTextCoversEmptyPermissionAndScanStates() {
        #expect(
            VideosPresentation.statusText(
                permission: .notDetermined, catalog: .notStarted, resolution: .idle,
                datasetSignature: ""
            ) == "Photos access needed"
        )
        #expect(
            VideosPresentation.statusText(
                permission: .denied, catalog: .notStarted, resolution: .idle,
                datasetSignature: ""
            ) == "Photos access is off"
        )
        #expect(
            VideosPresentation.statusText(
                permission: .authorized, catalog: .notStarted, resolution: .idle,
                datasetSignature: ""
            ) == "Not scanned yet"
        )
        #expect(
            VideosPresentation.statusText(
                permission: .authorized, catalog: .completed(VideosFixture.noVideosResult),
                resolution: .idle,
                datasetSignature: VideoDataset.signature(in: VideosFixture.noVideosResult)
            ) == "No videos found"
        )
    }

    @Test func measuringMessageNeverClaimsProgressBeforeARunIsActive() {
        // Idle: nothing has started — say what is about to happen, never "0 of N done".
        #expect(
            VideosPresentation.measuringMessage(
                measured: 0, total: 6, unavailable: 0, isActive: false
            ) == "Preparing to measure 6 videos…"
        )
        // Active: honest progress, with unmeasurable sizes surfaced as their own figure.
        #expect(
            VideosPresentation.measuringMessage(
                measured: 2, total: 6, unavailable: 3, isActive: true
            ) == "Measuring video sizes… 2 of 6 done (3 unavailable)"
        )
        #expect(
            VideosPresentation.measuringMessage(
                measured: 0, total: 0, unavailable: 0, isActive: true
            ) == "Measuring video sizes…"
        )
    }

    // MARK: Inventory summary (enumeration counts first, always)

    @Test func inventorySummaryShowsTheTotalWhileNothingIsMeasured() {
        // Enumerate first: the inventory total never waits on measurement, and an idle
        // run says so instead of claiming a progress that is not running.
        #expect(
            VideosPresentation.inventorySummary(total: 6, measured: 0, unavailable: 0)
                == ["6 videos total", "Sizes not measured yet"]
        )
    }

    @Test func inventorySummaryNamesMixedMeasuredAndUnavailableCounts() {
        #expect(
            VideosPresentation.inventorySummary(total: 6, measured: 4, unavailable: 2)
                == [
                    "6 videos total",
                    "2 sizes unavailable — stored in iCloud or unavailable locally",
                    "4 videos sorted by known size",
                ]
        )
    }

    @Test func anAllCloudInventoryNamesItsTotalAndUnavailableFigure() {
        // The iCloud-only library: total first, then exactly why nothing sorted — the
        // screen is never "0 videos", and it never claims a measurement that never ran.
        #expect(
            VideosPresentation.inventorySummary(total: 7061, measured: 0, unavailable: 7061)
                == [
                    "7061 videos total",
                    "7061 sizes unavailable — stored in iCloud or unavailable locally",
                ]
        )
    }

    @Test func inventorySummaryOfAnEmptyLibraryIsEmpty() {
        #expect(
            VideosPresentation.inventorySummary(total: 0, measured: 0, unavailable: 0).isEmpty
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

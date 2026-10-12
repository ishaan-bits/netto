import Foundation
import Testing
@testable import Netto

// MARK: - Helpers

/// Pure presentation logic only — no PhotoKit, no I/O, no AppEnvironment.
private func record(
    id: String,
    mediaType: PhotoMediaType = .image,
    subtypes: PhotoMediaSubtypes = [],
    creationDate: Date? = nil,
    sourceType: PhotoSourceTypes = [.library]
) -> PhotoAssetRecord {
    let r = PhotoAssetRecord(
        localIdentifier: id,
        mediaType: mediaType,
        mediaSubtypes: subtypes,
        pixelWidth: 100,
        pixelHeight: 100,
        creationDate: creationDate,
        modificationDate: nil,
        duration: 0,
        isFavorite: false,
        isHidden: false,
        sourceType: sourceType,
        hasAdjustments: false,
        representsBurst: false,
        burstIdentifier: nil
    )
    return r
}

private func catalog(_ records: [PhotoAssetRecord]) -> CatalogScanResult {
    CatalogScanResult(records: records, libraryAssetCount: records.count, accessLevel: .authorized)
}

// MARK: - Video source classification

/// The classification rule is the only place "origin" is decided, so it must be total,
/// never guess, and never let a shared import masquerade as a device recording.
struct VideoSourceClassificationTests {
    @Test func libraryOnlyIsRecorded() {
        #expect(VideoSourceClassification.of(record(id: "a", mediaType: .video)) == .recorded)
    }

    @Test func itunesSyncedIsDownloaded() {
        let r = record(id: "a", mediaType: .video, sourceType: [.library, .itunesSynced])
        #expect(VideoSourceClassification.of(r) == .downloaded)
    }

    @Test func cloudSharedIsOtherNeverRecordedOrDownloaded() {
        let r = record(id: "a", mediaType: .video, sourceType: [.library, .cloudShared])
        #expect(VideoSourceClassification.of(r) == .other)
    }

    @Test func itunesSyncedBeatsCloudSharedWhenBothPresent() {
        // Downloaded is the only positive non-device signal; when both are present the
        // stronger, more specific evidence wins.
        let r = record(id: "a", mediaType: .video, sourceType: [.library, .itunesSynced, .cloudShared])
        #expect(VideoSourceClassification.of(r) == .downloaded)
    }

    @Test func everyCaseIsReachableAndDistinct() {
        #expect(VideoSourceClassification.allCases.count == 3)
    }
}

// MARK: - Old Screenshots (90-day rule)

/// The rule must never guess an age: unknown `creationDate` is never "old", and the
/// boundary is inclusive (exactly 90 days old counts).
struct OldScreenshotsTests {
    private static let now = Date(timeIntervalSince1970: 1_700_000_000)
    private static let day: TimeInterval = 86_400

    @Test func defaultThresholdIsNinetyDays() {
        #expect(OldScreenshotsPresentation.defaultAgeThresholdDays == 90)
    }

    @Test func eligibleIsOldestFirstAndInclusiveAtTheBoundary() {
        let veryOld = record(id: "veryOld", subtypes: [.screenshot],
                             creationDate: Self.now.addingTimeInterval(-200 * Self.day))
        let exactlyBoundary = record(id: "boundary", subtypes: [.screenshot],
                                     creationDate: Self.now.addingTimeInterval(-90 * Self.day))
        let justInside = record(id: "inside", subtypes: [.screenshot],
                                creationDate: Self.now.addingTimeInterval(-89 * Self.day))
        let notYet = record(id: "notYet", subtypes: [.screenshot],
                            creationDate: Self.now.addingTimeInterval(-10 * Self.day))
        let unknown = record(id: "unknown", subtypes: [.screenshot], creationDate: nil)

        let eligible = OldScreenshotsPresentation.eligibleRecords(
            in: catalog([notYet, justInside, unknown, exactlyBoundary, veryOld]),
            now: Self.now
        )

        #expect(eligible.map(\.localIdentifier) == ["veryOld", "boundary"])
    }

    @Test func unknownDateIsNeverEligibleButIsReportedSeparately() {
        let unknown = record(id: "unknown", subtypes: [.screenshot], creationDate: nil)
        let result = catalog([unknown])

        #expect(OldScreenshotsPresentation.eligibleRecords(in: result, now: Self.now).isEmpty)
        #expect(OldScreenshotsPresentation.unknownDateRecords(in: result).map(\.localIdentifier) == ["unknown"])
    }

    @Test func nonScreenshotsNeverEnterEitherList() {
        let plain = record(id: "plain", creationDate: Self.now.addingTimeInterval(-400 * Self.day))
        let video = record(id: "video", mediaType: .video,
                           creationDate: Self.now.addingTimeInterval(-400 * Self.day))
        let result = catalog([plain, video])

        #expect(OldScreenshotsPresentation.eligibleRecords(in: result, now: Self.now).isEmpty)
        #expect(OldScreenshotsPresentation.unknownDateRecords(in: result).isEmpty)
    }

    @Test func phaseIsScanRequiredBeforeACatalogExistsAndPermissionGatesEverything() {
        #expect(OldScreenshotsPresentation.phase(permission: .notDetermined, catalog: .notStarted, now: Self.now) == .permissionRequired)
        #expect(OldScreenshotsPresentation.phase(permission: .denied, catalog: .completed(catalog([])), now: Self.now) == .permissionDenied)
        #expect(OldScreenshotsPresentation.phase(permission: .authorized, catalog: .notStarted, now: Self.now) == .scanRequired)
    }

    @Test func phaseCountsEligibleAndUnknownSeparatelyAndNeverConflatesThem() {
        let old = record(id: "old", subtypes: [.screenshot],
                         creationDate: Self.now.addingTimeInterval(-100 * Self.day))
        let unknown = record(id: "unknown", subtypes: [.screenshot], creationDate: nil)
        let fresh = record(id: "fresh", subtypes: [.screenshot],
                           creationDate: Self.now.addingTimeInterval(-1 * Self.day))

        let phase = OldScreenshotsPresentation.phase(
            permission: .authorized, catalog: .completed(catalog([old, unknown, fresh])), now: Self.now
        )
        guard case .results(let count, let unknownCount) = phase else {
            Issue.record("expected .results, got \(phase)")
            return
        }
        #expect(count == 1)
        #expect(unknownCount == 1)
    }

    @Test func phaseIsNoScreenshotsWhenCatalogHasNoScreenshotsAtAll() {
        let phase = OldScreenshotsPresentation.phase(
            permission: .authorized, catalog: .completed(catalog([record(id: "p")])), now: Self.now
        )
        #expect(phase == .noScreenshots)
    }

    @Test func statusTextAndDashboardStatusUseTheSameHonestRule() {
        let old = record(id: "old", subtypes: [.screenshot],
                         creationDate: Self.now.addingTimeInterval(-100 * Self.day))
        let phase = OldScreenshotsPresentation.phase(
            permission: .authorized, catalog: .completed(catalog([old])), now: Self.now
        )

        #expect(OldScreenshotsPresentation.statusText(phase: phase) == "1 older than 90 days")
        #expect(OldScreenshotsPresentation.dashboardStatus(phase: phase) == .count(1))
    }

    @Test func statusTextForZeroEligibleNamesTheThresholdNotAZeroCount() {
        let fresh = record(id: "fresh", subtypes: [.screenshot],
                           creationDate: Self.now.addingTimeInterval(-1 * Self.day))
        let phase = OldScreenshotsPresentation.phase(
            permission: .authorized, catalog: .completed(catalog([fresh])), now: Self.now
        )
        #expect(OldScreenshotsPresentation.statusText(phase: phase) == "No screenshots older than 90 days")
    }

    @Test func customThresholdIsRespected() {
        let twentyDays = record(id: "d20", subtypes: [.screenshot],
                                creationDate: Self.now.addingTimeInterval(-20 * Self.day))
        let result = catalog([twentyDays])
        let eligible = OldScreenshotsPresentation.eligibleRecords(in: result, now: Self.now, thresholdDays: 14)
        #expect(eligible.map(\.localIdentifier) == ["d20"])
    }
}

// MARK: - Dashboard section status aggregation

/// A section must never show a confident count while a harder blocker (permission, scan,
/// failure) is what actually stands in the way.
struct DashboardSectionsTests {
    @Test func allFourSectionsExistInOrder() {
        #expect(DashboardCleanupSection.allCases.count == 4)
        #expect(DashboardCleanupSection.allCases.map(\.self) == [
            .imageCleanup, .videoCleanup, .duplicateContacts, .swipeCleanup
        ])
    }

    @Test func worstStatusPrefersFailureOverEverythingElse() {
        let statuses: [CleanupDestinationStatus] = [.count(3), .failed("boom"), .empty("none")]
        #expect(DashboardCleanupPresentation.worstStatus(from: statuses) == .failed("boom"))
    }

    @Test func worstStatusPrefersPermissionBlockerOverACount() {
        let statuses: [CleanupDestinationStatus] = [.count(9), .unavailable(reason: "off")]
        #expect(DashboardCleanupPresentation.worstStatus(from: statuses) == .unavailable(reason: "off"))
    }

    @Test func worstStatusPrefersACountOverAnEmptyState() {
        let statuses: [CleanupDestinationStatus] = [.empty("none"), .count(2)]
        #expect(DashboardCleanupPresentation.worstStatus(from: statuses) == .count(2))
    }

    @Test func worstStatusOfNoStatusesIsNilNeverAPlaceholder() {
        #expect(DashboardCleanupPresentation.worstStatus(from: []) == nil)
    }

    @Test func duplicateContactsReportsTheContactScanTruth() {
        let status = DashboardCleanupPresentation.status(
            for: .duplicateContacts,
            permission: .authorized,
            contactsPermission: .notDetermined,
            catalog: .notStarted,
            analysis: .notStarted,
            blur: .notStarted,
            resolution: .idle,
            videoSignature: "",
            videoRecords: [],
            contactScan: .notStarted
        )
        #expect(status == .unavailable(reason: "Allow Contacts access to continue."))
    }

    @Test func imageCleanupNeverFabricatesACountBeforeAnalysisCompletes() {
        // Authorized permission, catalog not started, analysis not started: the row reports
        // an unknown count ("Not analyzed yet"), never a fabricated 0.
        let status = DashboardCleanupPresentation.status(
            for: .imageCleanup,
            permission: .authorized,
            contactsPermission: .authorized,
            catalog: .notStarted,
            analysis: .notStarted,
            blur: .notStarted,
            resolution: .idle,
            videoSignature: "",
            videoRecords: [],
            contactScan: .notStarted
        )
        #expect(status == .unknownCount("Not analyzed yet"))
    }

    @Test func imageCleanupReportsPermissionBlockerBeforeAnythingElse() {
        let status = DashboardCleanupPresentation.status(
            for: .imageCleanup,
            permission: .notDetermined,
            contactsPermission: .authorized,
            catalog: .notStarted,
            analysis: .notStarted,
            blur: .notStarted,
            resolution: .idle,
            videoSignature: "",
            videoRecords: [],
            contactScan: .notStarted
        )
        #expect(status == .unavailable(reason: "Allow Photos access to continue."))
    }
}

// MARK: - Unified Duplicate & Similar Photos destination (M14)

/// One destination for both group kinds: the hub shows exactly one row for the one
/// analysis pass, its status counts both kinds, and the in-screen filter narrows one
/// shared result set — it never re-runs, re-selects, or fabricates groups.
struct ImageCleanupUnifiedDestinationTests {
    private static let exact = PhotoSimilarityGroup(
        kind: .exactDuplicates,
        memberAssetIDs: ["a", "b"],
        evidence: .exactContent(fingerprint: "f", byteLength: 1),
        recommendedBestAssetID: "a",
        memberScores: [:]
    )
    private static let similar = PhotoSimilarityGroup(
        kind: .nearDuplicates,
        memberAssetIDs: ["c", "d", "e"],
        evidence: .visualSimilarity(minDistance: 0.05, maxDistance: 0.1, threshold: 0.15),
        recommendedBestAssetID: "c",
        memberScores: [:]
    )
    private static let mixedResult = PhotoAnalysisResult(
        exactGroups: [exact],
        similarGroups: [similar],
        unavailableAssets: [],
        descriptorKind: .cpuGrid,
        visionAvailable: false,
        similarityThreshold: 0.15,
        totalRecordCount: 5,
        candidateBucketCount: 1,
        candidatePairCount: 4
    )

    @Test func theHubHasExactlyOneDuplicateAndSimilarDestination() {
        #expect(ImageCleanupDestination.allCases == [
            .duplicateSimilarPhotos, .blurryImages, .oldScreenshots
        ])
        #expect(ImageCleanupDestination.duplicateSimilarPhotos.title == "Duplicate & Similar Photos")
        #expect(ImageCleanupDestination.duplicateSimilarPhotos.accessibilityIdentifier
            == "duplicateSimilarPhotosRow")
    }

    @Test func theMergedRowStatusCountsBothGroupKinds() {
        let status = ImageCleanupDestination.status(
            for: .duplicateSimilarPhotos,
            permission: .authorized,
            catalog: .notStarted,
            analysis: .completed(Self.mixedResult),
            blur: .notStarted
        )
        // 1 exact + 1 similar group — one count over the shared result, never a
        // per-source or per-kind fabrication.
        #expect(status == .count(2))
    }

    @Test func theMergedRowNeverFabricatesBeforeTheAnalysisCompletes() {
        let idle = ImageCleanupDestination.status(
            for: .duplicateSimilarPhotos,
            permission: .authorized,
            catalog: .notStarted,
            analysis: .notStarted,
            blur: .notStarted
        )
        #expect(idle == .unknownCount("Not analyzed yet"))
    }

    @Test func theFilterNarrowsOneSharedResultSet() {
        #expect(SimilarPhotosGroupFilter.all.showsExact && SimilarPhotosGroupFilter.all.showsSimilar)
        #expect(SimilarPhotosGroupFilter.exact.showsExact && !SimilarPhotosGroupFilter.exact.showsSimilar)
        #expect(!SimilarPhotosGroupFilter.similar.showsExact && SimilarPhotosGroupFilter.similar.showsSimilar)
        // Every filter keeps the same underlying result: it is presentation only.
        #expect(SimilarPhotosGroupFilter.allCases.count == 3)
    }

    @Test func theHubIntroDescribesTheUnifiedDestination() {
        let intro = ImageCleanupDestination.hubIntro(
            permission: .authorized,
            catalog: .notStarted,
            analysis: .completed(Self.mixedResult),
            blur: .notStarted
        )
        #expect(intro.contains("Duplicate & Similar Photos lists 1 exact group and 1 visually alike group"))
        // The old two-row split is gone — the intro never names separate destinations.
        #expect(!intro.contains("Duplicate Images lists"))
        #expect(!intro.contains("Similar Images lists"))
    }
}

// MARK: - Unified video inventory status (M14)

/// The Video Cleanup card reports the unified inventory — one count over every video the
/// catalog holds, never a Recorded/Downloaded split and never a source figure.
struct VideoInventoryUnifiedTests {
    @Test func theDashboardCardCountsTheUnifiedInventoryRegardlessOfSource() {
        // One local video and one iTunes-synced import: the old split counted them on
        // separate rows; the unified card counts the inventory as one.
        let records = [
            record(id: "v1", mediaType: .video),
            record(id: "v2", mediaType: .video, sourceType: [.library, .itunesSynced]),
        ]
        let status = DashboardCleanupPresentation.status(
            for: .videoCleanup,
            permission: .authorized,
            contactsPermission: .notDetermined,
            catalog: .completed(catalog(records)),
            analysis: .notStarted,
            blur: .notStarted,
            resolution: .settled(VideoSizeResolution.Measurement(
                datasetSignature: "sig",
                bytes: ["v1": 100, "v2": 200],
                total: 2
            )),
            videoSignature: "sig",
            videoRecords: VideoDataset.sorted(
                VideoDataset.resolved(VideoDataset.records(in: catalog(records)), with: ["v1": 100, "v2": 200])
            ),
            contactScan: .notStarted
        )
        #expect(status == .count(2))
    }

    @Test func theTotalNeverDependsOnMeasurement() {
        // Nothing measured yet: the card still reports the enumerated inventory — never a
        // fabricated zero, never waiting on sizes.
        let records = [record(id: "v1", mediaType: .video)]
        let status = DashboardCleanupPresentation.status(
            for: .videoCleanup,
            permission: .authorized,
            contactsPermission: .notDetermined,
            catalog: .completed(catalog(records)),
            analysis: .notStarted,
            blur: .notStarted,
            resolution: .idle,
            videoSignature: "sig",
            videoRecords: records,
            contactScan: .notStarted
        )
        #expect(status == .measurement("1 video · sizes not measured yet"))
    }

    @Test func inventorySummaryTotalsAreHonestAndMeasurementIndependent() {
        let empty = VideosPresentation.inventorySummary(total: 0, measured: 0, unavailable: 0)
        #expect(empty.isEmpty)

        let unknownOnly = VideosPresentation.inventorySummary(total: 7061, measured: 0, unavailable: 0)
        #expect(unknownOnly.first == "7061 videos total")
        #expect(unknownOnly.contains("Sizes not measured yet"))

        let mixed = VideosPresentation.inventorySummary(total: 41, measured: 12, unavailable: 29)
        #expect(mixed.first == "41 videos total")
        // Unknown sizes are named as unmeasurable locally — never given a cause this
        // screen cannot evidence.
        #expect(mixed.contains("29 sizes unavailable — could not be measured locally"))
        #expect(mixed.contains("12 videos sorted by known size"))
    }
}

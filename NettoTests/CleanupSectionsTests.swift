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
    sourceType: PhotoSourceTypes = [.library],
    sizeInBytes: Int64? = nil
) -> PhotoAssetRecord {
    var r = PhotoAssetRecord(
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
    r.sizeInBytes = sizeInBytes
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

// MARK: - Large Files phase / sorting

/// Large Files shares the videos pipeline's phase, so a disagreement here would be a
/// disagreement between two screens showing the same measurement.
struct LargeFilesTests {
    @Test func permissionRequiredMapsToPermissionRequiredAndScanBlockedMapsToScanRequired() {
        let notDetermined = LargeFilesPresentation.phase(
            permission: .notDetermined, catalog: .notStarted, resolution: .idle, datasetSignature: "sig"
        )
        #expect(notDetermined == .permissionRequired)

        let authorizedNotScanned = LargeFilesPresentation.phase(
            permission: .authorized, catalog: .notStarted, resolution: .idle, datasetSignature: "sig"
        )
        #expect(authorizedNotScanned == .scanRequired)

        let authorizedNotStarted = LargeFilesPresentation.phase(
            permission: .authorized, catalog: .notStarted, resolution: .idle, datasetSignature: "sig"
        )
        #expect(authorizedNotStarted == .scanRequired)
    }

    @Test func sortedRecordsPlacesUnknownSizesAfterMeasuredOnesAndNeverAsZero() {
        let big = record(id: "big", mediaType: .video, sizeInBytes: 5_000)
        let small = record(id: "small", mediaType: .video, sizeInBytes: 100)
        let unknown = record(id: "unknown", mediaType: .video, sizeInBytes: nil)

        let sorted = LargeFilesPresentation.sortedRecords([unknown, small, big])

        #expect(sorted.map(\.localIdentifier) == ["big", "small", "unknown"])
    }

    @Test func dashboardStatusSurfacesPermissionAndScanBlockersVerbatim() {
        #expect(LargeFilesPresentation.dashboardStatus(phase: .permissionRequired)
                == .unavailable(reason: "Allow Photos access to continue."))
        #expect(LargeFilesPresentation.dashboardStatus(phase: .scanRequired)
                == .unknownCount("Not scanned yet"))
    }
}

// MARK: - Dashboard section status aggregation

/// A section must never show a confident count while a harder blocker (permission, scan,
/// failure) is what actually stands in the way.
struct DashboardSectionsTests {
    @Test func allFiveSectionsExistInOrder() {
        #expect(DashboardCleanupSection.allCases.count == 5)
        #expect(DashboardCleanupSection.allCases.map(\.self) == [
            .imageCleanup, .videoCleanup, .largeFiles, .duplicateContacts, .swipeCleanup
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
            pendingBehindOtherPass: false,
            resolution: .idle,
            videoSignature: "",
            videoRecords: [],
            recordedVideos: [],
            downloadedVideos: [],
            otherVideoCount: 0,
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
            pendingBehindOtherPass: false,
            resolution: .idle,
            videoSignature: "",
            videoRecords: [],
            recordedVideos: [],
            downloadedVideos: [],
            otherVideoCount: 0,
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
            pendingBehindOtherPass: false,
            resolution: .idle,
            videoSignature: "",
            videoRecords: [],
            recordedVideos: [],
            downloadedVideos: [],
            otherVideoCount: 0,
            contactScan: .notStarted
        )
        #expect(status == .unavailable(reason: "Allow Photos access to continue."))
    }
}

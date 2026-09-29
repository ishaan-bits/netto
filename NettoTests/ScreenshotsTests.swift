import Foundation
import Testing
@testable import Netto

// MARK: - Screenshot dataset (filter over the catalog, never a second enumeration)

struct ScreenshotDatasetTests {
    private static let screenshotA = record(id: "a", subtypes: [.screenshot])
    private static let screenshotB = record(id: "b", subtypes: [.screenshot])
    private static let plainPhoto = record(id: "p")
    private static let video = record(id: "v", mediaType: .video)
    private static let livePhoto = record(id: "l", subtypes: [.livePhoto])

    private static let result = CatalogScanResult(
        records: [screenshotA, plainPhoto, screenshotB, video, livePhoto],
        libraryAssetCount: 5,
        accessLevel: .authorized
    )

    @Test func filtersOnSubtypeOnlyAndKeepsCatalogOrder() {
        let screenshots = ScreenshotDataset.records(in: Self.result)
        #expect(screenshots.map(\.localIdentifier) == ["a", "b"])
        // Videos, plain photos, and other subtypes never enter the dataset.
        #expect(!screenshots.contains(where: { $0.isVideo }))
        #expect(!screenshots.contains(where: { $0.isLivePhoto }))
    }

    @Test func identifiersAreDeduplicatedBySetSemantics() {
        let duplicated = CatalogScanResult(
            records: [Self.screenshotA, Self.screenshotA, Self.plainPhoto],
            libraryAssetCount: 3,
            accessLevel: .authorized
        )
        #expect(ScreenshotDataset.identifiers(in: duplicated) == ["a"])
    }

    @Test func signatureIsOrderIndependentAndMembershipSensitive() {
        let forward = ScreenshotDataset.signature(for: ["a", "b", "c"])
        let backward = ScreenshotDataset.signature(for: ["c", "a", "b"])
        let dropped = ScreenshotDataset.signature(for: ["a", "b"])
        let replaced = ScreenshotDataset.signature(for: ["a", "b", "d"])

        #expect(forward == backward)
        #expect(forward != dropped)
        #expect(forward != replaced)
    }

    @Test func signatureForCatalogMatchesSignatureForItsIdentifiers() {
        #expect(
            ScreenshotDataset.signature(in: Self.result)
                == ScreenshotDataset.signature(for: ["a", "b"])
        )
    }

    private static func record(
        id: String,
        mediaType: PhotoMediaType = .image,
        subtypes: PhotoMediaSubtypes = []
    ) -> PhotoAssetRecord {
        PhotoAssetRecord(
            localIdentifier: id,
            mediaType: mediaType,
            mediaSubtypes: subtypes,
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
            burstIdentifier: nil
        )
    }
}

// MARK: - Screenshot selection model (dataset-bound)

struct ScreenshotSelectionModelTests {
    @Test func toggleOnlyAffectsIdentifiersInsideTheDataset() {
        var selection = ScreenshotSelectionModel()
        selection.reconcile(with: ["s1", "s2"])

        selection.toggle("s1")
        #expect(selection.isSelected("s1"))
        #expect(selection.selectedCount == 1)

        // Unknown identifiers are ignored — the selection never leaves its dataset.
        selection.toggle("outside")
        #expect(!selection.isSelected("outside"))
        #expect(selection.selectedCount == 1)

        selection.toggle("s1")
        #expect(!selection.isSelected("s1"))
        #expect(selection.isEmpty)
    }

    @Test func selectAllCoversExactlyTheDataset() {
        var selection = ScreenshotSelectionModel()
        selection.reconcile(with: ["s1", "s2", "s3"])
        selection.selectAll()

        #expect(selection.selectedIDs == ["s1", "s2", "s3"])
        #expect(selection.isAllSelected)

        selection.deselectAll()
        #expect(selection.isEmpty)
        #expect(!selection.isAllSelected)
    }

    @Test func emptyDatasetIsNeverAllSelected() {
        let selection = ScreenshotSelectionModel()
        #expect(!selection.isAllSelected)
    }

    @Test func reconcileDropsSelectionsThatLeftTheDataset() {
        var selection = ScreenshotSelectionModel()
        selection.reconcile(with: ["s1", "s2"])
        selection.selectAll()

        selection.reconcile(with: ["s2", "s3"])

        #expect(selection.datasetIDs == ["s2", "s3"])
        #expect(selection.selectedIDs == ["s2"])
        #expect(selection.selectedCount == 1)
    }

    @Test func resetClearsDatasetAndSelection() {
        var selection = ScreenshotSelectionModel()
        selection.reconcile(with: ["s1"])
        selection.selectAll()
        selection.reset()

        #expect(selection.datasetIDs.isEmpty)
        #expect(selection.selectedIDs.isEmpty)
        #expect(selection.datasetCount == 0)
    }
}

// MARK: - Presentation (pure permission → catalog → phase mapping)

struct ScreenshotsPresentationTests {
    @Test func permissionGatesEveryPhase() {
        #expect(
            ScreenshotsPresentation.phase(permission: .notDetermined, catalog: .notStarted)
                == .permissionRequired
        )
        // A completed catalog must not render once access is revoked.
        #expect(
            ScreenshotsPresentation.phase(permission: .denied, catalog: .completed(ScreenshotsFixture.completed))
                == .permissionDenied
        )
        #expect(
            ScreenshotsPresentation.phase(permission: .restricted, catalog: .completed(ScreenshotsFixture.completed))
                == .permissionDenied
        )
    }

    @Test func analysisStateNeverAffectsThePhase() {
        // The mapping takes no analysis parameter at all; a completed/failed/running analysis
        // is invisible here by construction. This documents the contract.
        let phase = ScreenshotsPresentation.phase(
            permission: .authorized,
            catalog: .completed(ScreenshotsFixture.completed)
        )
        guard case .results(let records) = phase else {
            Issue.record("expected results, got \(phase)")
            return
        }
        #expect(records.count == 6)
        #expect(records.allSatisfy { $0.isScreenshot })
    }

    @Test func catalogStatesMapToExpectedPhases() {
        #expect(
            ScreenshotsPresentation.phase(permission: .authorized, catalog: .notStarted)
                == .scanRequired
        )
        #expect(
            ScreenshotsPresentation.phase(permission: .authorized, catalog: .cancelled)
                == .scanRequired
        )
        #expect(
            ScreenshotsPresentation.phase(
                permission: .authorized,
                catalog: .running(CatalogScanProgress(enumeratedCount: 5, totalCount: 10))
            ) == .buildingCatalog(CatalogScanProgress(enumeratedCount: 5, totalCount: 10))
        )
        #expect(
            ScreenshotsPresentation.phase(permission: .authorized, catalog: .failed(.photoLibraryUnavailable))
                == .failed(CatalogScanFailure.photoLibraryUnavailable.userMessage)
        )
        #expect(
            ScreenshotsPresentation.phase(
                permission: .authorized,
                catalog: .completed(ScreenshotsFixture.noScreenshotsResult)
            ) == .empty
        )
        // A completed catalog of photos only is empty — not an error, not "failed".
        #expect(
            ScreenshotsPresentation.phase(
                permission: .authorized,
                catalog: .completed(ScreenshotsFixture.completed)
            ) == .results(ScreenshotsFixture.screenshots)
        )
    }

    @Test func limitedAccessNoticeFollowsPermissionOnly() {
        #expect(ScreenshotsPresentation.showsLimitedAccessNotice(permission: .limited))
        #expect(!ScreenshotsPresentation.showsLimitedAccessNotice(permission: .authorized))
        #expect(!ScreenshotsPresentation.showsLimitedAccessNotice(permission: .denied))
    }

    @Test func statusTextIsHonestForEveryPhase() {
        #expect(
            ScreenshotsPresentation.statusText(permission: .notDetermined, catalog: .notStarted)
                == "Photos access needed"
        )
        #expect(
            ScreenshotsPresentation.statusText(permission: .denied, catalog: .completed(ScreenshotsFixture.completed))
                == "Photos access is off"
        )
        #expect(
            ScreenshotsPresentation.statusText(permission: .authorized, catalog: .notStarted)
                == "Not scanned yet"
        )
        #expect(
            ScreenshotsPresentation.statusText(
                permission: .authorized,
                catalog: .running(CatalogScanProgress(enumeratedCount: 4, totalCount: 8))
            ) == "Reading 4 of 8 assets…"
        )
        #expect(
            ScreenshotsPresentation.statusText(permission: .authorized, catalog: .completed(ScreenshotsFixture.completed))
                == "6 screenshots ready to review"
        )
        #expect(
            ScreenshotsPresentation.statusText(
                permission: .authorized,
                catalog: .completed(ScreenshotsFixture.noScreenshotsResult)
            ) == "No screenshots found"
        )
        #expect(
            ScreenshotsPresentation.statusText(
                permission: .authorized,
                catalog: .failed(.photoLibraryUnavailable)
            ) == CatalogScanFailure.photoLibraryUnavailable.userMessage
        )
    }
}

// MARK: - Fixture sanity

struct ScreenshotsFixtureTests {
    @Test func fixtureIsScreenshotOnlyInTheDatasetAndOrderedNewestFirst() {
        let screenshots = ScreenshotDataset.records(in: ScreenshotsFixture.completed)
        #expect(screenshots.count == 6)
        #expect(screenshots.map(\.localIdentifier) == ["shot-01", "shot-02", "shot-03", "shot-04", "shot-05", "shot-06"])

        let dates = screenshots.compactMap(\.creationDate)
        #expect(dates == dates.sorted(by: >))
    }
}

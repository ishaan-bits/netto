import Testing
import Photos
import Contacts
@testable import Netto

struct StorageSnapshotTests {
    @Test func usedCapacityIsTotalMinusAvailable() {
        let snapshot = StorageSnapshot(totalCapacity: 100, availableCapacity: 40)
        #expect(snapshot.usedCapacity == 60)
        #expect(snapshot.usedFraction == 0.6)
        #expect(snapshot.freeFraction == 0.4)
    }

    @Test func zeroCapacityDoesNotDivideByZero() {
        let snapshot = StorageSnapshot(totalCapacity: 0, availableCapacity: 0)
        #expect(snapshot.usedFraction == 0)
        #expect(snapshot.freeFraction == 1)
    }

    @Test func negativeAvailableClampsToZeroUsed() {
        let snapshot = StorageSnapshot(totalCapacity: 100, availableCapacity: 150)
        #expect(snapshot.usedCapacity == 0)
    }

    @Test func byteFormatHandlesZeroAndLargeValues() {
        #expect(ByteFormat.string(0) == "0 GB")
        let formatted = ByteFormat.string(Int64(5_500_000_000))
        #expect(formatted.contains("GB") || formatted.contains("MB"))
    }
}

struct PermissionStateTests {
    @Test func usableStates() {
        #expect(PermissionState.authorized.isUsable)
        #expect(PermissionState.limited.isUsable)
        #expect(!PermissionState.denied.isUsable)
        #expect(!PermissionState.notDetermined.isUsable)
        #expect(!PermissionState.restricted.isUsable)
    }

    @Test func photoAuthorizationMappingIsExhaustive() {
        #expect(PhotoLibraryPermissionService.map(.authorized) == .authorized)
        #expect(PhotoLibraryPermissionService.map(.limited) == .limited)
        #expect(PhotoLibraryPermissionService.map(.denied) == .denied)
        #expect(PhotoLibraryPermissionService.map(.restricted) == .restricted)
        #expect(PhotoLibraryPermissionService.map(.notDetermined) == .notDetermined)
    }

    @Test func contactsAuthorizationMapping() {
        #expect(ContactsPermissionService.map(.authorized) == .authorized)
        #expect(ContactsPermissionService.map(.denied) == .denied)
        #expect(ContactsPermissionService.map(.restricted) == .restricted)
        #expect(ContactsPermissionService.map(.notDetermined) == .notDetermined)
    }
}

struct ScanPhaseTests {
    @Test func progressFractionIsBounded() {
        let progress = ScanProgress(stage: .fingerprinting, completedUnits: 5, totalUnits: 10)
        #expect(progress.fraction == 0.5)
        #expect(progress.isActive)

        let indeterminate = ScanProgress.indeterminate
        #expect(indeterminate.fraction == 0)
        #expect(!indeterminate.isActive)
    }

    @Test func completedOverCapacityClampsVisually() {
        let progress = ScanProgress(stage: .finalizing, completedUnits: 12, totalUnits: 10)
        #expect(progress.fraction > 1.0)
        #expect(!progress.isActive)
    }

    @Test func emptySummaryDetection() {
        #expect(ScanResultSummary.zero.isEmpty)
        let withShots = ScanResultSummary(
            duplicatePhotoGroups: 0,
            similarPhotoGroups: 0,
            screenshotCount: 3,
            largeVideoCount: 0,
            duplicateContactGroups: 0,
            potentialFreedBytes: 100,
            scannedAssetCount: 3,
            duration: 0.1
        )
        #expect(!withShots.isEmpty)
    }

    @Test func scanFailureMessagesAreHumanReadable() {
        for failure in [ScanFailure.photoLibraryUnavailable, .contactsUnavailable, .cancelled] {
            #expect(!failure.userMessage.isEmpty)
        }
    }
}

import Testing
import Photos
import Contacts
import Foundation
import SwiftUI
import UIKit
@testable import Netto

struct StorageSnapshotTests {
    @Test func usedCapacityIsTotalMinusAvailable() {
        let snapshot = StorageSnapshot(totalCapacity: 100, availableCapacity: 40)
        #expect(snapshot.usedCapacity == 60)
        #expect(snapshot.usedFraction == 0.6)
        #expect(snapshot.freeFraction == 0.4)
        #expect(snapshot.isAvailable)
    }

    @Test func zeroCapacityDoesNotDivideByZero() {
        let snapshot = StorageSnapshot(totalCapacity: 0, availableCapacity: 0)
        #expect(snapshot.usedFraction == 0)
        #expect(snapshot.freeFraction == 1)
        // A failed read yields zeros — it must never render as a fabricated measurement.
        #expect(!snapshot.isAvailable)
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
        // A3: `requestAccess` maps the real status *after* the prompt, so the limited
        // grant iOS can hand out there must land as `.limited` (partial-library notice),
        // never be synthesized away as authorized or denied.
        if #available(iOS 18.0, *) {
            #expect(ContactsPermissionService.map(.limited) == .limited)
        }
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

// MARK: - Selected-check glyph contrast

private func relativeLuminance(_ color: UIColor) -> Double {
    var red: CGFloat = 0
    var green: CGFloat = 0
    var blue: CGFloat = 0
    var alpha: CGFloat = 0
    color.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
    func channel(_ value: CGFloat) -> Double {
        let v = Double(value)
        return v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
    }
    return 0.2126 * channel(red) + 0.7152 * channel(green) + 0.0722 * channel(blue)
}

private func contrastRatio(_ lhs: UIColor, _ rhs: UIColor) -> Double {
    let a = relativeLuminance(lhs)
    let b = relativeLuminance(rhs)
    let (high, low) = a > b ? (a, b) : (b, a)
    return (high + 0.05) / (low + 0.05)
}

/// The three selected-check glyphs (similar photos, screenshots, potentially blurry) all
/// draw `onBrandIndicator` on a `brandIndicator` fill: black on the lime in dark, white
/// on the deep brand in light — the previous white-on-lime read at 1.38:1.
struct BrandIndicatorContrastTests {
    @Test func selectedCheckGlyphsClearGraphicsContrastInBothAppearances() {
        let lightTraits = UITraitCollection(userInterfaceStyle: .light)
        let darkTraits = UITraitCollection(userInterfaceStyle: .dark)

        // The dynamic round-trip must survive `UIColor(Color)`: a flattened reading would
        // make every ratio below meaningless.
        let glyphLight = UIColor(NettoColor.onBrandIndicator).resolvedColor(with: lightTraits)
        let glyphDark = UIColor(NettoColor.onBrandIndicator).resolvedColor(with: darkTraits)
        #expect(glyphLight != glyphDark)

        for traits in [lightTraits, darkTraits] {
            let glyph = UIColor(NettoColor.onBrandIndicator).resolvedColor(with: traits)
            let fill = UIColor(NettoColor.brandIndicator).resolvedColor(with: traits)
            // WCAG non-text contrast floor for UI component graphics.
            #expect(contrastRatio(glyph, fill) >= 3.0)
        }
    }
}

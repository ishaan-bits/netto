import CoreGraphics
import Foundation
import UIKit

/// Deterministic, personal-data-free fixtures for SwiftUI previews.
///
/// Every thumbnail a preview renders is synthesized from its asset id — never from a real
/// photo library — so previews are stable across machines and leak nothing about the
/// developer's library. Group and score fixtures mirror exactly what the analysis engine
/// produces.
enum PreviewData {
    // MARK: Synthetic images

    /// A solid hue with a lighter disc, derived deterministically from `seed`.
    static func image(seed: String, size: CGSize = CGSize(width: 96, height: 96)) -> CGImage {
        let hue = CGFloat(stableHash(seed) % 360) / 360
        let base = UIColor(hue: hue, saturation: 0.55, brightness: 0.85, alpha: 1)
        let accent = UIColor(hue: hue, saturation: 0.75, brightness: 1.0, alpha: 1)

        let width = max(1, Int(size.width.rounded()))
        let height = max(1, Int(size.height.rounded()))
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            fatalError("PreviewData could not create a bitmap context")
        }
        context.setFillColor(base.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(accent.cgColor)
        let inset = CGFloat(min(width, height)) * 0.22
        context.fillEllipse(
            in: CGRect(x: inset, y: inset, width: CGFloat(width) - inset * 2, height: CGFloat(height) - inset * 2)
        )
        guard let image = context.makeImage() else {
            fatalError("PreviewData could not render a bitmap")
        }
        return image
    }

    /// Deterministic djb2-style hash — `String.hashValue` is randomized per launch, which would
    /// make previews recolor themselves between renders.
    static func stableHash(_ string: String) -> Int {
        var hash = 5381
        for byte in string.utf8 {
            hash = ((hash << 5) &+ hash) &+ Int(byte)
        }
        return hash & 0x7FFF_FFFF
    }

    // MARK: Fixtures

    private static let baseDate = Date(timeIntervalSince1970: 1_750_000_000)

    private static func score(
        _ id: String,
        favorite: Bool = false,
        edited: Bool = false,
        burst: Bool = false,
        megapixels: Double = 12,
        daysAgo: Double = 0
    ) -> PhotoAssetQualityScore {
        PhotoAssetQualityScore(
            localIdentifier: id,
            isFavorite: favorite,
            representsBurst: burst,
            pixelCount: Int(megapixels * 1_000_000),
            hasAdjustments: edited,
            creationDate: baseDate.addingTimeInterval(-daysAgo * 86_400)
        )
    }

    static let exactGroup = PhotoSimilarityGroup(
        kind: .exactDuplicates,
        memberAssetIDs: ["dup-1", "dup-2", "dup-3"],
        evidence: .exactContent(fingerprint: "sha256:0f3a…c1", byteLength: 2_400_000),
        recommendedBestAssetID: "dup-1",
        memberScores: [
            "dup-1": score("dup-1", favorite: true, megapixels: 48),
            "dup-2": score("dup-2", megapixels: 48),
            "dup-3": score("dup-3", megapixels: 48, daysAgo: 1)
        ]
    )

    static let exactGroupSmall = PhotoSimilarityGroup(
        kind: .exactDuplicates,
        memberAssetIDs: ["dup-a", "dup-b"],
        evidence: .exactContent(fingerprint: "sha256:77b2…9d", byteLength: 91_000_000),
        recommendedBestAssetID: "dup-a",
        memberScores: [
            "dup-a": score("dup-a", edited: true, megapixels: 12),
            "dup-b": score("dup-b", megapixels: 12, daysAgo: 3)
        ]
    )

    static let nearGroup = PhotoSimilarityGroup(
        kind: .nearDuplicates,
        memberAssetIDs: ["near-1", "near-2", "near-3", "near-4"],
        evidence: .visualSimilarity(minDistance: 0.03, maxDistance: 0.11, threshold: 0.15),
        recommendedBestAssetID: "near-2",
        memberScores: [
            "near-1": score("near-1", megapixels: 12),
            "near-2": score("near-2", favorite: true, megapixels: 48),
            "near-3": score("near-3", burst: true, megapixels: 12, daysAgo: 0.01),
            "near-4": score("near-4", burst: true, megapixels: 12, daysAgo: 0.02)
        ]
    )

    static let largeNearGroup: PhotoSimilarityGroup = {
        let ids = (1...8).map { "burst-\($0)" }
        var scores: [String: PhotoAssetQualityScore] = [:]
        for (index, id) in ids.enumerated() {
            scores[id] = score(id, burst: index > 0, megapixels: 12, daysAgo: Double(index) * 0.01)
        }
        return PhotoSimilarityGroup(
            kind: .nearDuplicates,
            memberAssetIDs: ids,
            evidence: .visualSimilarity(minDistance: 0.01, maxDistance: 0.09, threshold: 0.15),
            recommendedBestAssetID: "burst-1",
            memberScores: scores
        )
    }()

    static let result = PhotoAnalysisResult(
        exactGroups: [exactGroup, exactGroupSmall],
        similarGroups: [nearGroup, largeNearGroup],
        unavailableAssets: [PhotoAnalysisUnavailable(assetID: "cloud-1", reason: .contentOnlyInICloud)],
        descriptorKind: .visionFeaturePrint,
        visionAvailable: true,
        similarityThreshold: 0.15,
        totalRecordCount: 1_240,
        candidateBucketCount: 96,
        candidatePairCount: 312
    )

    /// A finished run where every photo is distinct — the "nothing to review" result.
    static let resultWithoutGroups = PhotoAnalysisResult(
        exactGroups: [],
        similarGroups: [],
        unavailableAssets: [],
        descriptorKind: .cpuGrid,
        visionAvailable: false,
        similarityThreshold: 0.15,
        totalRecordCount: 860,
        candidateBucketCount: 40,
        candidatePairCount: 120
    )

    // MARK: Preview environment

    /// Thumbnail loader that serves synthesized images — previews never touch PhotoKit.
    struct ThumbnailLoader: PhotoThumbnailLoading {
        func thumbnail(for assetID: String, targetPixelSize: Int) async throws -> CGImage {
            let side = CGFloat(max(1, targetPixelSize))
            return PreviewData.image(seed: assetID, size: CGSize(width: side, height: side))
        }
    }

    /// An `AppEnvironment` preloaded with the requested state. Its library factory always
    /// throws, so tapping "Analyze" in a preview lands on the honest failure state instead of
    /// attempting a real scan.
    @MainActor
    static func environment(
        permission: PermissionState = .authorized,
        catalog: CatalogScanState = .notStarted,
        analysis: PhotoAnalysisState = .notStarted
    ) -> AppEnvironment {
        let env = AppEnvironment(
            makePhotoLibrary: { () throws -> any PhotoLibraryReading in
                throw PhotoLibraryReadError.accessDenied
            },
            thumbnailLoader: ThumbnailLoader()
        )
        env.photoPermissionState = permission
        env.catalogState = catalog
        env.analysisState = analysis
        if case .completed(let completed) = analysis {
            env.selection = PhotoSelectionModel(result: completed)
        }
        env.storageSnapshot = StorageSnapshot(
            totalCapacity: 128_000_000_000,
            availableCapacity: 41_000_000_000
        )
        return env
    }
}

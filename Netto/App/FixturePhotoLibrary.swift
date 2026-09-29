#if DEBUG

import Foundation

/// Synthetic, personal-data-free photo library for Simulator runs launched with
/// `-fixtureLibrary`.
///
/// The Simulator's real Photos library contains no screenshot-flagged assets, so this reader
/// serves one fixed deterministic catalog — screenshots, photos, and videos — through the same
/// `PhotoLibraryReading` seam the real reader uses. Fixture identifiers do not exist in Photos:
/// any deletion attempt over them is stopped by `PhotoDeletionService`'s existence
/// revalidation with zero mutation, which is exactly what a Simulator validation run should
/// observe. Metadata reads only; this type never touches `PHAsset`.
struct FixturePhotoLibrary: PhotoLibraryReading {
    let accessLevel: PermissionState = .authorized

    /// Newest-first, mirroring the real reader's `creationDate` ordering.
    static let fixtureRecords: [PhotoAssetRecord] = {
        var records: [PhotoAssetRecord] = []
        // 10 screenshots, interleaved with photos as they would appear in a real library.
        for index in 1...12 {
            records.append(Self.record(
                id: "fixture-photo-\(padded(index))",
                daysAgo: Double(index) * 0.5
            ))
            if index <= 10 {
                records.append(Self.record(
                    id: index == 9 ? "fixture-shot-\(padded(index))-nosize" : "fixture-shot-\(padded(index))",
                    mediaSubtypes: [.screenshot],
                    daysAgo: Double(index) * 0.5 + 0.25
                ))
            }
        }
        records.append(Self.record(id: "fixture-video-01", mediaType: .video, duration: 14, daysAgo: 40))
        records.append(Self.record(id: "fixture-video-02", mediaType: .video, duration: 63, daysAgo: 60))
        return records
    }()

    func assetCount() throws -> Int {
        Self.fixtureRecords.count
    }

    func records(in range: Range<Int>) throws -> [PhotoAssetRecord] {
        let lower = max(0, range.lowerBound)
        let upper = min(range.upperBound, Self.fixtureRecords.count)
        guard lower < upper else { return [] }
        return Array(Self.fixtureRecords[lower..<upper])
    }

    private static let baseDate = Date(timeIntervalSince1970: 1_760_000_000)

    private static func padded(_ index: Int) -> String {
        index < 10 ? "0\(index)" : "\(index)"
    }

    private static func record(
        id: String,
        mediaType: PhotoMediaType = .image,
        mediaSubtypes: PhotoMediaSubtypes = [],
        duration: TimeInterval = 0,
        daysAgo: Double
    ) -> PhotoAssetRecord {
        PhotoAssetRecord(
            localIdentifier: id,
            mediaType: mediaType,
            mediaSubtypes: mediaSubtypes,
            pixelWidth: 1290,
            pixelHeight: 2796,
            creationDate: baseDate.addingTimeInterval(-daysAgo * 86_400),
            modificationDate: nil,
            duration: duration,
            isFavorite: false,
            isHidden: false,
            sourceType: .library,
            hasAdjustments: false,
            representsBurst: false,
            burstIdentifier: nil
        )
    }
}

/// Deterministic byte sizes for fixture assets. One fixture intentionally has no size, so the
/// review screen exercises the partial ("size unavailable") wording with real unresolved `nil`.
struct FixtureSizeProvider: AssetSizeProviding {
    func sizes(for localIdentifiers: [String]) async -> [String: Int64] {
        var sizes: [String: Int64] = [:]
        for id in localIdentifiers where !id.contains("nosize") {
            sizes[id] = Int64(2_000_000 + (PreviewData.stableHash(id) % 30_000_000))
        }
        return sizes
    }
}

#endif

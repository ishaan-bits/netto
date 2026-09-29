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
        // Videos for the Large Videos screen: varied durations, resolutions, and ages so the
        // largest-first ordering is meaningful in Simulator. One id contains "nosize", so
        // `FixtureSizeProvider` leaves it unmeasured and the unknown-size state is reachable.
        records.append(Self.record(
            id: "fixture-video-01", mediaType: .video, duration: 14,
            width: 1080, height: 1920, daysAgo: 40
        ))
        records.append(Self.record(
            id: "fixture-video-02", mediaType: .video, duration: 63,
            width: 1920, height: 1080, daysAgo: 60
        ))
        records.append(Self.record(
            id: "fixture-video-03", mediaType: .video, duration: 321,
            width: 3840, height: 2160, daysAgo: 5
        ))
        records.append(Self.record(
            id: "fixture-video-04", mediaType: .video, duration: 7,
            width: 720, height: 1280, daysAgo: 90
        ))
        records.append(Self.record(
            id: "fixture-video-05", mediaType: .video, duration: 756,
            width: 1920, height: 1080, daysAgo: 15
        ))
        records.append(Self.record(
            id: "fixture-video-06-nosize", mediaType: .video, duration: 42,
            width: 1280, height: 720, daysAgo: 3
        ))
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
        width: Int = 1290,
        height: Int = 2796,
        daysAgo: Double
    ) -> PhotoAssetRecord {
        PhotoAssetRecord(
            localIdentifier: id,
            mediaType: mediaType,
            mediaSubtypes: mediaSubtypes,
            pixelWidth: width,
            pixelHeight: height,
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
            // DJB2 outputs for near-identical ids differ by only a few units, which would make
            // every fixture video round to the same displayed size. Fold with a multiplicative
            // hash and xor-shift so largest-first ordering is actually visible in the fixture.
            let base = UInt64(PreviewData.stableHash(id))
            let mixed = base &* 2_654_435_761
            let spread = mixed ^ (mixed >> 15)
            sizes[id] = Int64(2_000_000 + (spread % 30_000_000))
        }
        return sizes
    }
}

#endif

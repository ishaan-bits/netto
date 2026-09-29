import Foundation

/// Everything the videos screen can be showing, derived — never stored.
///
/// Videos need a completed *catalog* only (they are a media-type filter recorded during
/// enumeration), plus the explicit size-measurement state that gives the list its honest
/// largest-first ordering. Similarity analysis never participates.
enum VideosPhase: Sendable, Equatable {
    /// Photos access has never been requested.
    case permissionRequired
    /// Photos access is off (denied or restricted) — only Settings can fix it.
    case permissionDenied
    /// A catalog build is running.
    case buildingCatalog(CatalogScanProgress)
    /// Permission is fine but no catalog exists yet (or the last build was cancelled).
    case scanRequired
    /// The last catalog build failed; carries the user-facing message.
    case failed(String)
    /// The catalog is complete and contains no videos.
    case empty
    /// Sizes are being measured (or measurement has not started yet). `measured` only counts
    /// videos whose size the provider actually resolved — unknowns are never counted as zero.
    case measuringVideos(measured: Int, total: Int)
    /// The video dataset, sorted largest first, with measured sizes embedded per record
    /// (`sizeInBytes == nil` = size unknown, never zero).
    case results([PhotoAssetRecord])
}

enum VideosPresentation {
    /// The single permission → catalog → size-resolution → phase mapping. Analysis state never
    /// participates: an analysis running or failed in the background changes nothing here.
    static func phase(
        permission: PermissionState,
        catalog: CatalogScanState,
        resolution: VideoSizeResolution
    ) -> VideosPhase {
        switch permission {
        case .notDetermined:
            return .permissionRequired
        case .denied, .restricted:
            return .permissionDenied
        case .authorized, .limited:
            break
        }

        switch catalog {
        case .running(let progress):
            return .buildingCatalog(progress)
        case .failed(let failure):
            return .failed(failure.userMessage)
        case .notStarted, .cancelled:
            return .scanRequired
        case .completed(let result):
            let videos = VideoDataset.records(in: result)
            guard !videos.isEmpty else { return .empty }

            // A measurement from another dataset is treated as idle — bytes are never mixed
            // across catalogs, and the screen re-measures on appear.
            let signature = VideoDataset.signature(in: result)
            guard resolution.isCurrent(for: signature) else {
                return .measuringVideos(measured: 0, total: videos.count)
            }

            switch resolution {
            case .idle:
                return .measuringVideos(measured: 0, total: videos.count)
            case .measuring(let measurement):
                return .measuringVideos(
                    measured: measurement.measuredCount,
                    total: max(measurement.total, measurement.measuredCount)
                )
            case .settled(let measurement):
                let resolved = VideoDataset.resolved(videos, with: measurement.bytes)
                return .results(VideoDataset.sorted(resolved))
            }
        }
    }

    /// Limited access still shows usable results — but only the granted assets count, so the
    /// UI must say that "no videos" means "none among the assets Netto can see".
    static func showsLimitedAccessNotice(permission: PermissionState) -> Bool {
        permission == .limited
    }

    /// Dashboard status line for the Large Videos section: count, measured total, and honest
    /// measurement state in one short sentence. Byte totals are lower bounds — pending sizes
    /// are named as pending, never folded into a zero.
    static func statusText(
        permission: PermissionState,
        catalog: CatalogScanState,
        resolution: VideoSizeResolution
    ) -> String {
        switch phase(permission: permission, catalog: catalog, resolution: resolution) {
        case .permissionRequired:
            return "Photos access needed"
        case .permissionDenied:
            return "Photos access is off"
        case .scanRequired:
            return "Not scanned yet"
        case .buildingCatalog(let progress):
            return progress.totalCount > 0
                ? "Reading \(progress.enumeratedCount) of \(progress.totalCount) assets…"
                : "Counting assets…"
        case .failed(let message):
            return message
        case .empty:
            return "No videos found"
        case .measuringVideos(let measured, let total):
            if case .idle = resolution {
                return "\(total) videos · sizes not measured yet"
            }
            return "Measuring sizes · \(measured) of \(total) videos…"
        case .results(let records):
            guard let measurement = resolution.measurement else {
                return "\(records.count) videos ready to review"
            }
            let countText = "\(records.count) \(records.count == 1 ? "video" : "videos")"
            let total = measurement.bytes.values.reduce(Int64(0), +)
            let sizeText = "measured \(ByteFormat.string(total))"
            guard measurement.isPartial else {
                return "\(countText) · \(sizeText)"
            }
            let pending = measurement.total - measurement.measuredCount
            return "\(countText) · \(sizeText) · \(pending) \(pending == 1 ? "size" : "sizes") pending"
        }
    }

    /// `0:14` / `1:03` / `1:02:05` — playback time, from the duration already in the catalog.
    static func durationText(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let remainder = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, remainder)
        }
        return String(format: "%d:%02d", minutes, remainder)
    }

    /// User-facing preview failure copy. PhotoKit's vocabulary stays distinct: "only in
    /// iCloud", "not found", and "Photos access is off" are different problems for the user.
    static func previewUnavailableMessage(for error: PhotoContentError) -> String {
        switch error {
        case .onlyInICloud:
            return "This video is only in iCloud. Download it in Photos, then try again — Netto never downloads videos for previews."
        case .assetNotFound:
            return "This video is no longer in your library."
        case .permissionDenied:
            return "Photos access is off. Enable it in Settings to preview videos."
        case .unavailable:
            return "This video can't be played right now."
        }
    }
}

/// Deterministic, personal-data-free video fixtures for previews and tests.
enum VideosFixture {
    /// A completed-enumeration-shaped catalog: 6 videos (newest first) plus photos and
    /// screenshots, so the video filter has something to filter.
    static let records: [PhotoAssetRecord] = {
        var records: [PhotoAssetRecord] = [
            video(id: "video-01", duration: 95, width: 3840, height: 2160, daysAgo: 2),
            video(id: "video-02", duration: 14, width: 1920, height: 1080, daysAgo: 5),
            video(id: "video-03", duration: 3_725, width: 1920, height: 1080, daysAgo: 9),
            video(id: "video-04", duration: 63, width: 1280, height: 720, daysAgo: 40),
            video(id: "video-05", duration: 7, width: 720, height: 1280, daysAgo: 88),
            video(id: "video-06", duration: 31, width: 1920, height: 1080, daysAgo: 200),
        ]
        for index in 1...3 {
            records.append(photo(id: "photo-0\(index)", daysAgo: Double(index)))
            records.append(screenshot(id: "shot-0\(index)", daysAgo: Double(index) + 0.5))
        }
        return records
    }()

    /// The video subset, in catalog order.
    static let videos = records.filter(\.isVideo)

    /// The catalog exactly as a completed enumeration would leave it.
    static let completed = CatalogScanResult(
        records: records,
        libraryAssetCount: records.count,
        accessLevel: .authorized
    )

    /// A completed catalog with no videos at all (the `.empty` phase).
    static let noVideosResult = CatalogScanResult(
        records: records.filter { !$0.isVideo },
        libraryAssetCount: records.count - videos.count,
        accessLevel: .authorized
    )

    /// Deterministic measured bytes for five of the six fixture videos — `video-06` stays
    /// unknown, so previews and tests exercise the honest partial state.
    static let measuredBytes: [String: Int64] = [
        "video-01": 240_000_000,
        "video-02": 18_000_000,
        "video-03": 1_600_000_000,
        "video-04": 64_000_000,
        "video-05": 4_500_000,
    ]

    /// A settled, partial measurement over `completed` (one video's size still unknown).
    static let settledPartial = VideoSizeResolution.settled(
        VideoSizeResolution.Measurement(
            datasetSignature: VideoDataset.signature(in: completed),
            bytes: measuredBytes,
            total: videos.count
        )
    )

    private static let baseDate = Date(timeIntervalSince1970: 1_760_000_000)

    private static func video(
        id: String,
        duration: TimeInterval,
        width: Int,
        height: Int,
        daysAgo: Double
    ) -> PhotoAssetRecord {
        record(
            id: id,
            mediaType: .video,
            duration: duration,
            width: width,
            height: height,
            daysAgo: daysAgo
        )
    }

    private static func photo(id: String, daysAgo: Double) -> PhotoAssetRecord {
        record(id: id, mediaType: .image, duration: 0, width: 1290, height: 2796, daysAgo: daysAgo)
    }

    private static func screenshot(id: String, daysAgo: Double) -> PhotoAssetRecord {
        record(
            id: id,
            mediaType: .image,
            mediaSubtypes: [.screenshot],
            duration: 0,
            width: 1290,
            height: 2796,
            daysAgo: daysAgo
        )
    }

    private static func record(
        id: String,
        mediaType: PhotoMediaType,
        mediaSubtypes: PhotoMediaSubtypes = [],
        duration: TimeInterval,
        width: Int,
        height: Int,
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

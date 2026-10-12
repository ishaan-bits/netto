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
    /// The catalog build was interrupted and saved its progress; resumable — never
    /// presented as a running build.
    case paused(stage: String)
    /// Permission is fine but no catalog exists yet (or the last build was cancelled).
    case scanRequired
    /// The last catalog build failed; carries the user-facing message.
    case failed(String)
    /// The catalog is complete and contains no videos.
    case empty
    /// Sizes are being measured (or measurement has not started yet). `measured` only counts
    /// videos whose size the provider actually resolved — unknowns are never counted as zero;
    /// `unavailable` counts the ones the provider *attempted* and could not measure (iCloud-
    /// only, unreadable), so a library of failures still shows work happening honestly.
    case measuringVideos(measured: Int, total: Int, unavailable: Int)
    /// The video dataset, sorted largest first, with measured sizes embedded per record
    /// (`sizeInBytes == nil` = size unknown, never zero).
    case results([PhotoAssetRecord])
}

enum VideosPresentation {
    /// The single permission → catalog → size-resolution → phase mapping. Analysis state never
    /// participates: an analysis running or failed in the background changes nothing here.
    ///
    /// `datasetSignature` is the current catalog's video fingerprint — passed in (the
    /// environment caches it) because recomputing it is O(videos log videos) and this runs on
    /// every dashboard and screen render. `settledRecords` is the environment's cached
    /// resolved + largest-first list for the same reason; `nil` computes it here (tests and
    /// previews), matching the pre-cache behaviour exactly.
    static func phase(
        permission: PermissionState,
        catalog: CatalogScanState,
        resolution: VideoSizeResolution,
        datasetSignature: String,
        settledRecords: [PhotoAssetRecord]? = nil
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
        case .paused(let progress):
            return .paused(stage: DashboardPresentation.catalogStage(progress))
        case .failed(let failure):
            return .failed(failure.userMessage)
        case .notStarted, .cancelled:
            return .scanRequired
        case .completed(let result):
            let videos = VideoDataset.records(in: result)
            guard !videos.isEmpty else { return .empty }
            let total = videos.count

            // A measurement from another dataset is treated as idle — bytes are never mixed
            // across catalogs, and the screen re-measures on appear.
            guard resolution.isCurrent(for: datasetSignature), !datasetSignature.isEmpty else {
                return .measuringVideos(measured: 0, total: total, unavailable: 0)
            }

            switch resolution {
            case .idle:
                return .measuringVideos(measured: 0, total: total, unavailable: 0)
            case .measuring(let measurement):
                return .measuringVideos(
                    measured: measurement.measuredCount,
                    total: max(measurement.total, measurement.measuredCount),
                    unavailable: measurement.unavailableCount
                )
            case .settled(let measurement):
                let records = settledRecords ?? VideoDataset.sorted(
                    VideoDataset.resolved(videos, with: measurement.bytes)
                )
                return .results(records)
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
        resolution: VideoSizeResolution,
        datasetSignature: String,
        settledRecords: [PhotoAssetRecord]? = nil
    ) -> String {
        switch phase(
            permission: permission,
            catalog: catalog,
            resolution: resolution,
            datasetSignature: datasetSignature,
            settledRecords: settledRecords
        ) {
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
        case .paused:
            return "Scan paused"
        case .failed(let message):
            return message
        case .empty:
            return "No videos found"
        case .measuringVideos(let measured, let total, let unavailable):
            if case .idle = resolution {
                return "\(total) \(total == 1 ? "video" : "videos") · sizes not measured yet"
            }
            var text = "Measuring sizes · \(measured) of \(total) videos…"
            if unavailable > 0 {
                text += " · \(unavailable) unavailable"
            }
            return text
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
            let pendingText = "\(pending) \(pending == 1 ? "size" : "sizes") pending"
            // Nothing measured yet: naming a zero total would claim a measurement that never
            // happened — the pending count alone is the honest state.
            guard measurement.measuredCount > 0 else {
                return "\(countText) · \(pendingText)"
            }
            return "\(countText) · \(sizeText) · \(pendingText)"
        }
    }

    /// The measuring screen's progress message. An idle state has started nothing, so it
    /// never claims "0 of N done" — it says what is about to happen. An active run names
    /// its honest progress, and surfaces sizes the provider could not measure (they are
    /// real outcomes of real work, never folded into the measured count).
    static func measuringMessage(
        measured: Int,
        total: Int,
        unavailable: Int,
        isActive: Bool
    ) -> String {
        guard isActive else {
            return total > 0
                ? "Preparing to measure \(total) videos…"
                : "Preparing to measure video sizes…"
        }
        var message = total > 0
            ? "Measuring video sizes… \(measured) of \(total) done"
            : "Measuring video sizes…"
        if unavailable > 0 {
            message += " (\(unavailable) unavailable)"
        }
        return message
    }

    /// The inventory summary lines — enumeration's counts first, always, then honest
    /// measurement figures derived from actual data. Illustrative shape:
    ///
    ///     7,061 videos total
    ///     7,020 sizes unavailable — not measured locally
    ///     41 videos sorted by known size
    ///
    /// - `total` is the enumerated inventory — it never waits on measurement, and never
    ///   depends on it.
    /// - `unavailable` counts sizes the measurement could not resolve; never folded into
    ///   measured, never zero, never given a cause this screen cannot evidence (whether a
    ///   video lives in iCloud is not something the inventory claims).
    /// - `measured` counts videos actually sorted by a known size; the line is omitted
    ///   while nothing has been measured yet (an idle run says so instead, and an
    ///   all-unavailable library names only its unavailable figure).
    static func inventorySummary(total: Int, measured: Int, unavailable: Int) -> [String] {
        guard total > 0 else { return [] }
        var lines = ["\(total) videos total"]
        if unavailable > 0 {
            lines.append("\(unavailable) sizes unavailable — could not be measured locally")
        }
        if measured > 0 {
            lines.append("\(measured) videos sorted by known size")
        } else if unavailable == 0 {
            lines.append("Sizes not measured yet")
        }
        // The remainder is what the running (or interrupted) pass still has to attempt —
        // named so the counters always add up instead of leaving rows silently labelled.
        let stillToMeasure = total - measured - unavailable
        if stillToMeasure > 0 {
            lines.append("\(stillToMeasure) still to measure")
        }
        return lines
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

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
                return "\(total) videos · sizes not measured yet"
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
            // Pending means "not yet attempted": attempted-but-unmeasurable sizes are
            // named as unavailable instead of being folded into the pending figure.
            let unavailableCount = measurement.unavailableCount
            let pending = max(0, measurement.total - measurement.measuredCount - unavailableCount)
            var parts = [countText]
            // Nothing measured yet: naming a zero total would claim a measurement that
            // never happened — the pending count alone is the honest state.
            if measurement.measuredCount > 0 {
                parts.append(sizeText)
            }
            if unavailableCount > 0 {
                parts.append("\(unavailableCount) \(unavailableCount == 1 ? "size" : "sizes") unavailable")
            }
            if pending > 0 {
                parts.append("\(pending) \(pending == 1 ? "size" : "sizes") pending")
            }
            return parts.joined(separator: " · ")
        }
    }

    /// The measuring screen's progress message. An idle state has started nothing, so it
    /// never claims "0 of N done" — it says what is about to happen. An active run names
    /// its honest progress as *resolved* work (measured plus honestly-unavailable, matching
    /// the progress bar), and surfaces sizes the provider could not measure as their own
    /// figure — never folded into the measured count.
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
            ? "Measuring video sizes… \(measured + unavailable) of \(total) done"
            : "Measuring video sizes…"
        if unavailable > 0 {
            message += " (\(unavailable) unavailable)"
        }
        return message
    }

    /// The Video Cleanup summary line — honest about whether measurement has even run.
    ///
    /// - No current measurement (never started, or another dataset's fingerprint): the
    ///   screen says so instead of claiming "0 bytes measured · N size unavailable" —
    ///   which asserted a measurement that had been starved and never attempted.
    /// - A current measurement splits the unknowns by *attempt*: failed-and-known ids are
    ///   "unavailable", the rest are "not measured", and measured bytes are only summed
    ///   from records that actually have sizes.
    static func videoCleanupSummaryLine(
        known: [PhotoAssetRecord],
        unknown: [PhotoAssetRecord],
        resolution: VideoSizeResolution,
        datasetSignature: String
    ) -> String {
        guard !datasetSignature.isEmpty,
              resolution.isCurrent(for: datasetSignature),
              let measurement = resolution.measurement else {
            return "sizes not measured yet"
        }
        let attempted = unknown.filter {
            measurement.unavailableIDs.contains($0.localIdentifier)
        }.count
        let pending = unknown.count - attempted
        let totalBytes = known.reduce(Int64(0)) { $0 + ($1.sizeInBytes ?? 0) }

        var parts: [String] = []
        if measurement.measuredCount > 0 {
            parts.append("\(ByteFormat.string(totalBytes)) measured")
        }
        if attempted > 0 {
            parts.append("\(attempted) \(attempted == 1 ? "size" : "sizes") unavailable")
        }
        if pending > 0 {
            parts.append("\(pending) \(pending == 1 ? "size" : "sizes") not measured")
        }
        guard !parts.isEmpty else { return "sizes not measured yet" }
        return parts.joined(separator: " · ")
    }

    /// One row's size caption and whether it is the warning state. "Size unavailable" is
    /// reserved for ids the run actually *attempted* — a row nothing has tried yet says
    /// "not measured", never a failure it has not earned.
    static func videoCleanupSizeCaption(
        bytes: Int64?,
        attempted: Bool
    ) -> (text: String, isWarning: Bool) {
        if let bytes {
            return (ByteFormat.string(bytes), false)
        }
        if attempted {
            return ("Size unavailable — not stored locally", true)
        }
        return ("Size not measured yet", false)
    }

    /// The unknowns' section title: names iCloud only once a failure is proven by an
    /// attempt; before that the section simply says the sizes have not been measured.
    static func videoUnknownSectionTitle(attempted: Int) -> String {
        attempted > 0 ? "iCloud / size unavailable" : "Sizes not measured yet"
    }

    /// The top-of-list iCloud line: how many of the library's videos have no size
    /// because they are not stored on this iPhone. Only shown once a run has actually
    /// proven those sizes unavailable (attempted and failed the local check) — never
    /// as a guess, and nil while there is nothing honest to say.
    static func videoICloudHeader(unavailable: Int, total: Int) -> String? {
        guard unavailable > 0, total > 0 else { return nil }
        return "\(unavailable) of \(total) videos' size unavailable — stored in iCloud"
    }

    /// The inventory summary lines — enumeration's counts first, always, then honest
    /// measurement figures derived from actual data. Illustrative shape:
    ///
    ///     7,061 videos total
    ///     7,061 sizes unavailable — stored in iCloud or unavailable locally
    ///     12 videos sorted by known size
    ///
    /// - `total` is the enumerated inventory — it never waits on measurement.
    /// - `unavailable` counts attempted-and-unmeasurable sizes (stored in iCloud, unreadable);
    ///   never folded into measured, never zero.
    /// - `measured` counts videos actually sorted by a known size; the line is omitted
    ///   while nothing has been measured yet (an idle run says so instead, and an
    ///   all-unavailable library names only its unavailable figure).
    static func inventorySummary(total: Int, measured: Int, unavailable: Int) -> [String] {
        guard total > 0 else { return [] }
        var lines = ["\(total) videos total"]
        if unavailable > 0 {
            lines.append("\(unavailable) sizes unavailable — stored in iCloud or unavailable locally")
        }
        if measured > 0 {
            lines.append("\(measured) videos sorted by known size")
        } else if unavailable == 0 {
            lines.append("Sizes not measured yet")
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

    /// A settled, partial measurement over `completed` — `video-06` was attempted and
    /// could not be measured (the honest shape of a finished run over fixture data).
    static let settledPartial = VideoSizeResolution.settled(
        VideoSizeResolution.Measurement(
            datasetSignature: VideoDataset.signature(in: completed),
            bytes: measuredBytes,
            total: videos.count,
            unavailableIDs: ["video-06"]
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

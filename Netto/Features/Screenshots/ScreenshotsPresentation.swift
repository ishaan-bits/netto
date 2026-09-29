import Foundation

/// Everything the screenshots screen can be showing, derived — never stored.
///
/// Screenshots need a completed *catalog* only: screenshot identity is a PhotoKit media
/// subtype already recorded during enumeration, so no similarity analysis — and no second
/// library read — ever runs for this feature.
enum ScreenshotsPhase: Sendable, Equatable {
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
    /// The catalog is complete and nothing in it is flagged as a screenshot.
    case empty
    /// The screenshot subset of the catalog, in catalog order.
    case results([PhotoAssetRecord])
}

enum ScreenshotsPresentation {
    /// The single permission → catalog → phase mapping. Analysis state never participates:
    /// an analysis running or failed in the background changes nothing here.
    static func phase(
        permission: PermissionState,
        catalog: CatalogScanState
    ) -> ScreenshotsPhase {
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
            let screenshots = ScreenshotDataset.records(in: result)
            return screenshots.isEmpty ? .empty : .results(screenshots)
        }
    }

    /// Limited access still shows usable results — but only the granted photos count, so the
    /// UI must say that "no screenshots" means "none among the photos Netto can see".
    static func showsLimitedAccessNotice(permission: PermissionState) -> Bool {
        permission == .limited
    }

    /// Dashboard status line for the Screenshots section — same states as the screen, in one
    /// short sentence.
    static func statusText(permission: PermissionState, catalog: CatalogScanState) -> String {
        switch phase(permission: permission, catalog: catalog) {
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
            return "No screenshots found"
        case .results(let records):
            return "\(records.count) \(records.count == 1 ? "screenshot" : "screenshots") ready to review"
        }
    }
}

/// Deterministic, personal-data-free screenshot fixtures for previews and tests.
enum ScreenshotsFixture {
    /// Every fixture record as a completed enumeration would leave them: 6 screenshots
    /// (newest first) followed by 4 plain photos.
    static let records: [PhotoAssetRecord] = {
        var records: [PhotoAssetRecord] = []
        for index in 1...6 {
            records.append(record(id: "shot-0\(index)", screenshot: true, daysAgo: Double(index)))
        }
        for index in 1...4 {
            records.append(record(id: "photo-0\(index)", screenshot: false, daysAgo: Double(index) + 0.5))
        }
        return records
    }()

    /// The screenshot subset, in catalog order.
    static let screenshots = records.filter(\.isScreenshot)

    /// The catalog exactly as a completed enumeration would leave it.
    static let completed = CatalogScanResult(
        records: records,
        libraryAssetCount: records.count,
        accessLevel: .authorized
    )

    /// A completed catalog with no screenshots at all (the `.empty` phase).
    static let noScreenshotsResult = CatalogScanResult(
        records: records.filter { !$0.isScreenshot },
        libraryAssetCount: 4,
        accessLevel: .authorized
    )

    private static let baseDate = Date(timeIntervalSince1970: 1_760_000_000)

    private static func record(id: String, screenshot: Bool, daysAgo: Double) -> PhotoAssetRecord {
        PhotoAssetRecord(
            localIdentifier: id,
            mediaType: .image,
            mediaSubtypes: screenshot ? [.screenshot] : [],
            pixelWidth: 1290,
            pixelHeight: 2796,
            creationDate: baseDate.addingTimeInterval(-daysAgo * 86_400),
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

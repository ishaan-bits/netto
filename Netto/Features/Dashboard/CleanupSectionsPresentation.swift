import Foundation

// MARK: - Destination status

/// A destination's honest one-line status, shown on dashboard rows and hub rows alike.
///
/// Kept deliberately small: every case carries a state the app can actually be in, so no
/// view can invent a count or a claim that is not backed by real state. `.unknownCount`
/// names a real quantity the app does not hold; `.unavailable(reason)` names a blocking
/// cause with an explanation.
enum CleanupDestinationStatus: Equatable, Sendable {
    /// A real count of items in the destination.
    case count(Int)
    /// A running quantity the app cannot express as a count — measured vs total.
    case measurement(String)
    /// A progress line with its real, already-formatted fraction (or none).
    case progress(message: String, fraction: Double?)
    /// A real quantity that cannot be counted yet (e.g. unmeasured sizes awaiting a scan).
    case unknownCount(String)
    /// The destination cannot do its job right now; the reason is actionable.
    case unavailable(reason: String)
    /// A completed pass found nothing eligible.
    case empty(String)
    /// An explicit pass is waiting on the analysis coordinator (M10 queue).
    case queued(String)
    /// A failed pass or scan; carries the user-facing message.
    case failed(String)
    /// A paused run; carries the stage line shown to the user.
    case paused(String)

    /// The line shown on a row. Kept short enough for an iPhone-width dashboard row.
    var shortText: String {
        switch self {
        case .count(let n):
            return n == 1 ? "1 item" : "\(n) items"
        case .measurement(let text):
            return text
        case .progress(let message, _):
            return message
        case .unknownCount(let text):
            return text
        case .unavailable(let reason):
            return reason
        case .empty(let text):
            return text
        case .queued(let text):
            return text
        case .failed(let message):
            return message
        case .paused(let text):
            return text
        }
    }

    /// The compact line used on a dashboard section row, where a numeric count is preferred
    /// whenever one honestly exists.
    var dashboardSummary: String {
        switch self {
        case .count(let n):
            return n == 1 ? "1 item" : "\(n) items"
        default:
            return shortText
        }
    }
}

// MARK: - Video source classification

/// How a video's origin is classified, from evidence the catalog already holds.
///
/// iOS exposes no universal, authoritative "recorded vs downloaded" property for every
/// Photos asset. This classification therefore uses only what `PhotoAssetRecord` actually
/// records — the `PHAssetSourceType` bridge (`.library`, `.itunesSynced`, `.cloudShared`)
/// and the video screen-recording subtype — and never infers origin from a missing signal.
/// A video that is neither positively a screen recording nor an iTunes-synced import is
/// `.recorded`; a video with any other source evidence (e.g. shared) is `.other`.
enum VideoSourceClassification: String, Sendable, Equatable, CaseIterable {
    /// The device's own library videos — includes camera recordings and screen recordings
    /// (both are `.library` source; the screen-recording subtype is noted, never required).
    case recorded
    /// Imported via iTunes sync — the only positive "not made by this device's camera"
    /// signal PhotoKit exposes per asset.
    case downloaded
    /// Origin cannot be established from the available evidence (e.g. a shared import).
    case other

    /// The classification rule for one record. Pure: no PhotoKit, no I/O.
    static func of(_ record: PhotoAssetRecord) -> VideoSourceClassification {
        if record.sourceType.contains(.itunesSynced) {
            return .downloaded
        }
        if record.sourceType.contains(.cloudShared) {
            return .other
        }
        return .recorded
    }
}

/// Honest counts for one video-source subset, including the assets whose sizes the
/// measurement could not resolve (never folded into the measured total, never zero).
struct VideoSourceSummary: Equatable, Sendable {
    let total: Int
    let measured: Int
    let unavailable: Int

    init(total: Int, measured: Int, unavailable: Int) {
        self.total = total
        self.measured = measured
        self.unavailable = unavailable
    }

    /// The inventory summary lines for this subset, most honest first. An unmeasured
    /// subset never fabricates a byte total; an all-unavailable subset names only its
    /// unavailable figure.
    var summaryLines: [String] {
        guard total > 0 else { return [] }
        var lines = ["\(total) \(total == 1 ? "video" : "videos")"]
        if unavailable > 0 {
            lines.append("\(unavailable) size\(unavailable == 1 ? "" : "s") unavailable")
        }
        if measured > 0 {
            lines.append("\(measured) sorted by known size")
        } else if unavailable == 0 {
            lines.append("Sizes not measured yet")
        }
        return lines
    }
}

// MARK: - Image Cleanup hub

/// The destinations of the Image Cleanup hub, in the order they are shown, with the
/// status each row reports from real app state. Exact-duplicate groups and visually
/// similar groups both live under Similar Images — one row, one screen, one list.
enum ImageCleanupDestination: String, CaseIterable, Sendable, Equatable {
    case similarImages = "Similar Images"
    case blurryImages = "Blurry Images"
    case oldScreenshots = "Old Screenshots"

    var title: String { rawValue }

    var icon: String {
        switch self {
        case .similarImages: return "photo.on.rectangle.angled"
        case .blurryImages: return "camera.metering.unknown"
        case .oldScreenshots: return "clock.badge.questionmark"
        }
    }

    var accessibilityIdentifier: String {
        switch self {
        case .similarImages: return "similarImagesRow"
        case .blurryImages: return "blurryImagesRow"
        case .oldScreenshots: return "oldScreenshotsRow"
        }
    }

    /// What the destination is for, in one short line shown under its title.
    var subtitle: String {
        switch self {
        case .similarImages:
            return "Identical copies and visually alike shots"
        case .blurryImages:
            return "Photos flagged for soft focus or shake"
        case .oldScreenshots:
            return "Screenshots older than \(OldScreenshotsPresentation.defaultAgeThresholdDays) days"
        }
    }

    /// The honest one-line intro for the Image Cleanup hub, derived from the similarity
    /// analysis state — the single pass that produces both exact-duplicate and similar
    /// groups. Never claims a run that has not happened.
    static func hubIntro(
        permission: PermissionState,
        catalog: CatalogScanState,
        analysis: PhotoAnalysisState,
        blur: BlurAnalysisState,
        pendingBehindOtherPass: Bool
    ) -> String {
        let phase = SimilarPhotosPresentation.phase(
            permission: permission,
            catalog: catalog,
            analysis: analysis,
            pendingBehindOtherPass: pendingBehindOtherPass
        )
        switch phase {
        case .permissionRequired, .permissionDenied:
            return "Duplicate and similar groups come from one on-device analysis pass, both listed under Similar Images — byte-identical copies found by content hash, and visually alike shots. Neither is ever deleted automatically."
        case .idle, .cancelled, .failed:
            return "Duplicate and similar groups come from one on-device analysis pass, run only when you start it — both listed under Similar Images: byte-identical copies and visually alike shots."
        case .buildingCatalog:
            return "Reading your library on this iPhone. Similar Images will list byte-identical copies and visually alike shots together. Nothing is deleted automatically."
        case .analyzing:
            let summary = analysisSummary(analysis)
            return "Analyzing on this iPhone — \(summary.exactGroupCount) exact \(summary.exactGroupCount == 1 ? "group" : "groups") and \(summary.similarGroupCount) similar \(summary.similarGroupCount == 1 ? "group" : "groups") so far, all reported under Similar Images."
        case .paused:
            return "The analysis is paused. Similar Images will fill in with duplicate and similar groups when it finishes. Nothing is deleted automatically."
        case .queuedBehindBlur:
            return "The analysis is queued and starts when the sharpness check finishes. Similar Images will list byte-identical copies and visually alike shots."
        case .emptyLibrary:
            return "No photos are visible to Netto, so there is nothing to compare."
        case .results:
            let summary = analysisSummary(analysis)
            if summary.exactGroupCount == 0 && summary.similarGroupCount == 0 {
                return "The analysis finished and found no duplicate or similar groups — Similar Images would list byte-identical copies and visually alike shots."
            }
            return "Similar Images lists \(summary.exactGroupCount) byte-identical \(summary.exactGroupCount == 1 ? "group" : "groups") and \(summary.similarGroupCount) visually alike \(summary.similarGroupCount == 1 ? "group" : "groups"). Blurry Images and Old Screenshots are independent of this pass."
        }
    }

    private static func analysisSummary(_ analysis: PhotoAnalysisState) -> SimilarPhotosSummary {
        if case .completed(let result) = analysis {
            return SimilarPhotosSummary(result: result)
        }
        return SimilarPhotosSummary(result: .empty)
    }

    /// The destination's row status from the real analysis/scan state it reports on.
    /// Similar Images covers both group kinds — one analysis run, exact and near groups
    /// reported together — so it shows the same honest phase, never a fabricated count.
    static func status(
        for destination: ImageCleanupDestination,
        permission: PermissionState,
        catalog: CatalogScanState,
        analysis: PhotoAnalysisState,
        blur: BlurAnalysisState,
        pendingBehindOtherPass: Bool
    ) -> CleanupDestinationStatus {
        switch destination {
        case .similarImages:
            return similarityStatus(phase: SimilarPhotosPresentation.phase(
                permission: permission,
                catalog: catalog,
                analysis: analysis,
                pendingBehindOtherPass: pendingBehindOtherPass
            ))
        case .blurryImages:
            return blurStatus(phase: PotentiallyBlurryPresentation.phase(
                permission: permission,
                catalog: catalog,
                blur: blur
            ))
        case .oldScreenshots:
            return oldScreenshotsStatus(
                permission: permission,
                catalog: catalog,
                now: Date()
            )
        }
    }

    /// The similarity pass reports one honest status for Similar Images — exact
    /// duplicates and visually similar groups are both part of the same analysis result,
    /// never a separate run, so the row counts them together.
    private static func similarityStatus(
        phase: SimilarPhotosPhase
    ) -> CleanupDestinationStatus {
        switch phase {
        case .permissionRequired:
            return .unavailable(reason: "Allow Photos access to continue.")
        case .permissionDenied:
            return .unavailable(reason: "Photos access is off — enable it in Settings.")
        case .idle:
            return .unknownCount("Not analyzed yet")
        case .buildingCatalog:
            return .progress(message: "Reading library…", fraction: nil)
        case .analyzing(let progress):
            return .progress(
                message: SimilarPhotosPresentation.stageMessage(for: progress),
                fraction: SimilarPhotosPresentation.barFraction(for: progress)
            )
        case .paused:
            return .paused("Analysis paused")
        case .queuedBehindBlur:
            return .queued("Queued — starts when the sharpness check finishes")
        case .emptyLibrary:
            return .empty("No photos visible to Netto")
        case .cancelled:
            return .unknownCount("Last run cancelled")
        case .failed(let message):
            return .failed(message)
        case .results(let result):
            let summary = SimilarPhotosSummary(result: result)
            let count = summary.exactGroupCount + summary.similarGroupCount
            if count == 0 {
                return .empty("No groups found")
            }
            return .count(count)
        }
    }

    private static func blurStatus(phase: PotentiallyBlurryPhase) -> CleanupDestinationStatus {
        switch phase {
        case .permissionRequired:
            return .unavailable(reason: "Allow Photos access to continue.")
        case .permissionDenied:
            return .unavailable(reason: "Photos access is off — enable it in Settings.")
        case .buildingCatalog:
            return .progress(message: "Reading library…", fraction: nil)
        case .scanRequired:
            return .unknownCount("Not scanned yet")
        case .catalogFailed(let message):
            return .failed(message)
        case .notStarted:
            return .unknownCount("Not analyzed yet")
        case .analyzing(let progress):
            return .progress(
                message: PotentiallyBlurryPresentation.analyzingMessage(progress),
                fraction: progress.fraction
            )
        case .paused:
            return .paused("Scan paused")
        case .queuedBehindSimilarity:
            return .queued("Queued — starts when Similar Photos finishes")
        case .cancelled:
            return .unknownCount("Last run cancelled")
        case .failed(let message):
            return .failed(message)
        case .emptyLibrary:
            return .empty("No photos visible to Netto")
        case .noCandidates:
            return .empty("No blurry candidates found")
        case .results(let result):
            return .count(result.candidates.count)
        }
    }

    private static func oldScreenshotsStatus(
        permission: PermissionState,
        catalog: CatalogScanState,
        now: Date
    ) -> CleanupDestinationStatus {
        switch permission {
        case .notDetermined:
            return .unavailable(reason: "Allow Photos access to continue.")
        case .denied, .restricted:
            return .unavailable(reason: "Photos access is off — enable it in Settings.")
        case .authorized, .limited:
            break
        }
        switch catalog {
        case .notStarted, .cancelled:
            return .unknownCount("Not scanned yet")
        case .running:
            return .progress(message: "Reading library…", fraction: nil)
        case .paused:
            return .paused("Scan paused")
        case .failed(let failure):
            return .failed(failure.userMessage)
        case .completed(let result):
            let eligible = OldScreenshotsPresentation.eligibleRecords(
                in: result,
                now: now
            )
            return eligible.isEmpty
                ? .empty("No screenshots older than \(OldScreenshotsPresentation.defaultAgeThresholdDays) days")
                : .count(eligible.count)
        }
    }
}

// MARK: - Video Cleanup hub

/// The two source-filtered destinations of the Video Cleanup hub, plus the honest
/// unclassified count the dashboard shows when origin evidence is incomplete.
enum VideoCleanupDestination: String, CaseIterable, Sendable, Equatable {
    case recorded = "Recorded Videos"
    case downloaded = "Downloaded Videos"

    var title: String { rawValue }

    var icon: String {
        switch self {
        case .recorded: return "video"
        case .downloaded: return "icloud.and.arrow.down"
        }
    }

    var accessibilityIdentifier: String {
        switch self {
        case .recorded: return "recordedVideosRow"
        case .downloaded: return "downloadedVideosRow"
        }
    }

    var subtitle: String {
        switch self {
        case .recorded:
            return "Videos from this device's library"
        case .downloaded:
            return "Imported via iTunes sync"
        }
    }

    var classification: VideoSourceClassification {
        switch self {
        case .recorded: return .recorded
        case .downloaded: return .downloaded
        }
    }

    /// The honest one-line intro for the Video Cleanup hub, derived from the real video
    /// inventory and its size-measurement state. Names the unclassified count whenever any
    /// video's origin could not be established — never folds it into a bucket.
    static func hubIntro(
        permission: PermissionState,
        catalog: CatalogScanState,
        resolution: VideoSizeResolution,
        videoSignature: String,
        videoRecords: [PhotoAssetRecord],
        otherVideoCount: Int
    ) -> String {
        let phase = VideosPresentation.phase(
            permission: permission,
            catalog: catalog,
            resolution: resolution,
            datasetSignature: videoSignature,
            settledRecords: videoRecords
        )
        switch phase {
        case .permissionRequired, .permissionDenied:
            return "Videos are grouped by origin using the source evidence your library exposes. Recorded and Downloaded never download anything; sizes are measured on this iPhone."
        case .scanRequired, .failed:
            return "Videos are grouped by origin using the source evidence your library exposes. Recorded covers this device's library; Downloaded covers iTunes-synced imports. Opening a group never downloads cloud-only videos."
        case .buildingCatalog:
            return "Reading your library on this iPhone. Videos will group into Recorded and Downloaded by their source evidence."
        case .paused:
            return "The library scan is paused. Video groups fill in when it finishes."
        case .empty:
            return "Your library has no videos, so there is nothing to group."
        case .measuringVideos:
            return "Sizes are being measured on this iPhone — cloud-only videos are never downloaded. Videos group into Recorded and Downloaded by their source evidence."
        case .results(let records):
            let total = records.count
            var intro = "\(total) \(total == 1 ? "video" : "videos"), grouped by source evidence. Recorded covers this device's library; Downloaded covers iTunes-synced imports."
            if otherVideoCount > 0 {
                intro += " \(otherVideoCount) \(otherVideoCount == 1 ? "video has" : "videos have") an unconfirmed source and is shown separately, never guessed."
            }
            return intro
        }
    }
}

// MARK: - Dashboard four-section hierarchy

/// The four primary cleanup sections of the dashboard, in their fixed display order.
/// Each row routes into exactly one hub or feature screen; no section is decorative.
enum DashboardCleanupSection: String, CaseIterable, Sendable, Equatable {
    case imageCleanup = "Image Cleanup"
    case videoCleanup = "Video Cleanup"
    case duplicateContacts = "Duplicate Contacts"
    case swipeCleanup = "Swipe Cleanup"

    var title: String { rawValue }

    var icon: String {
        switch self {
        case .imageCleanup: return "photo.stack"
        case .videoCleanup: return "video"
        case .duplicateContacts: return "person.2"
        case .swipeCleanup: return "arrow.left.and.right"
        }
    }

    var accessibilityIdentifier: String {
        switch self {
        case .imageCleanup: return "imageCleanupSection"
        case .videoCleanup: return "videoCleanupSection"
        case .duplicateContacts: return "duplicateContactsSection"
        case .swipeCleanup: return "swipeCleanupSection"
        }
    }

    /// What the section is for, in one short line shown under its title.
    var subtitle: String {
        switch self {
        case .imageCleanup:
            return "Duplicate & similar shots, blur, old screenshots"
        case .videoCleanup:
            return "All your videos, largest first"
        case .duplicateContacts:
            return "Likely-duplicate contact entries"
        case .swipeCleanup:
            return "Review photos one by one, KEEP or DELETE"
        }
    }
}

enum DashboardCleanupPresentation {
    /// The single derivation of one section's one-line dashboard status from real app
    /// state. Never invents a count; the worst blocking state wins so a user always sees
    /// what actually stands between them and the section's contents.
    static func status(
        for section: DashboardCleanupSection,
        permission: PermissionState,
        contactsPermission: PermissionState,
        catalog: CatalogScanState,
        analysis: PhotoAnalysisState,
        blur: BlurAnalysisState,
        pendingBehindOtherPass: Bool,
        resolution: VideoSizeResolution,
        videoSignature: String,
        videoRecords: [PhotoAssetRecord],
        recordedVideos: [PhotoAssetRecord],
        downloadedVideos: [PhotoAssetRecord],
        otherVideoCount: Int,
        contactScan: ContactScanState,
        now: Date = Date()
    ) -> CleanupDestinationStatus {
        switch section {
        case .imageCleanup:
            let statuses = ImageCleanupDestination.allCases.map {
                ImageCleanupDestination.status(
                    for: $0,
                    permission: permission,
                    catalog: catalog,
                    analysis: analysis,
                    blur: blur,
                    pendingBehindOtherPass: pendingBehindOtherPass
                )
            }
            return worstStatus(from: statuses) ?? .unknownCount("Not scanned yet")

        case .videoCleanup:
            return videoStatus(
                permission: permission,
                catalog: catalog,
                resolution: resolution,
                videoSignature: videoSignature,
                videoRecords: videoRecords,
                recordedVideos: recordedVideos,
                downloadedVideos: downloadedVideos,
                otherVideoCount: otherVideoCount
            )

        case .duplicateContacts:
            return contactsStatus(permission: contactsPermission, scan: contactScan)

        case .swipeCleanup:
            return swipeStatus(permission: permission, catalog: catalog)
        }
    }

    /// The worst status in a set of destination statuses — the one that most needs the
    /// user's attention (a blocking permission beats a count; a count beats an empty).
    static func worstStatus(from statuses: [CleanupDestinationStatus]) -> CleanupDestinationStatus? {
        guard !statuses.isEmpty else { return nil }
        func rank(_ status: CleanupDestinationStatus) -> Int {
            switch status {
            case .failed: return 0
            case .unavailable: return 1
            case .paused: return 2
            case .queued: return 3
            case .progress: return 4
            case .unknownCount: return 5
            case .count: return 6
            case .empty: return 7
            case .measurement: return 8
            }
        }
        return statuses.min { lhs, rhs in
            rank(lhs) == rank(rhs) ? false : rank(lhs) < rank(rhs)
        }
    }

    private static func videoStatus(
        permission: PermissionState,
        catalog: CatalogScanState,
        resolution: VideoSizeResolution,
        videoSignature: String,
        videoRecords: [PhotoAssetRecord],
        recordedVideos: [PhotoAssetRecord],
        downloadedVideos: [PhotoAssetRecord],
        otherVideoCount: Int
    ) -> CleanupDestinationStatus {
        let phase = VideosPresentation.phase(
            permission: permission,
            catalog: catalog,
            resolution: resolution,
            datasetSignature: videoSignature,
            settledRecords: videoRecords
        )
        switch phase {
        case .permissionRequired:
            return .unavailable(reason: "Allow Photos access to continue.")
        case .permissionDenied:
            return .unavailable(reason: "Photos access is off — enable it in Settings.")
        case .scanRequired:
            return .unknownCount("Not scanned yet")
        case .buildingCatalog:
            return .progress(message: "Reading library…", fraction: nil)
        case .paused:
            return .paused("Scan paused")
        case .failed(let message):
            return .failed(message)
        case .empty:
            return .empty("No videos found")
        case .measuringVideos:
            // The associated counts are re-derived by statusText from the same inputs,
            // so they are unused here; matching without binding keeps it warning-free.
            return .measurement(
                VideosPresentation.statusText(
                    permission: permission,
                    catalog: catalog,
                    resolution: resolution,
                    datasetSignature: videoSignature,
                    settledRecords: videoRecords
                )
            )
        case .results(let records):
            // One unified inventory (M11-era Large Files shape, restored): the count is
            // every video the catalog holds — no source split, no source figures.
            let total = records.count
            guard total > 0 else {
                return .empty("No videos found")
            }
            return .count(total)
        }
    }

    private static func contactsStatus(
        permission: PermissionState,
        scan: ContactScanState
    ) -> CleanupDestinationStatus {
        switch ContactsPresentation.phase(permission: permission, scan: scan) {
        case .permissionRequired:
            return .unavailable(reason: "Allow Contacts access to continue.")
        case .permissionDenied:
            return .unavailable(reason: "Contacts access is off — enable it in Settings.")
        case .scanRequired:
            return .unknownCount("Not scanned yet")
        case .scanning:
            return .progress(message: "Finding likely duplicates…", fraction: nil)
        case .failed(let message):
            return .failed(message)
        case .empty:
            return .empty("No contacts found")
        case .noDuplicates:
            return .empty("No likely duplicates")
        case .results(let groups):
            return .count(groups.count)
        }
    }

    private static func swipeStatus(
        permission: PermissionState,
        catalog: CatalogScanState
    ) -> CleanupDestinationStatus {
        switch permission {
        case .notDetermined:
            return .unavailable(reason: "Allow Photos access to continue.")
        case .denied, .restricted:
            return .unavailable(reason: "Photos access is off — enable it in Settings.")
        case .authorized, .limited:
            break
        }
        switch catalog {
        case .notStarted:
            return .unknownCount("Not scanned yet")
        case .running:
            return .progress(message: "Reading library…", fraction: nil)
        case .paused:
            return .paused("Scan paused")
        case .cancelled:
            return .unknownCount("Last run cancelled")
        case .failed(let failure):
            return .failed(failure.userMessage)
        case .completed(let catalog):
            let images = catalog.imageCount
            return images == 0
                ? .empty("No photos visible to Netto")
                : .count(images)
        }
    }
}

/// The Old Screenshots screen: the screenshot subset of the existing catalog, filtered
/// by a transparent, shown-in-the-UI age threshold. Screenshot identity comes only from
/// the PhotoKit media subtype already bridged during enumeration — no filename, OCR,
/// Vision, EXIF, or dimension heuristic. An asset with an unknown creation date is never
/// treated as old; it is honestly reported as such instead.
enum OldScreenshotsPresentation {
    /// The default age threshold: a screenshot is "old" when it was created at least this
    /// many days before now. Shown in the UI so the user always knows why an item appears.
    static let defaultAgeThresholdDays = 90

    /// The oldest-first, age-thresholded screenshots from a completed catalog.
    /// Eligibility: a screenshot with a known `creationDate` at least `thresholdDays` old.
    /// Unknown dates are excluded from the eligible list (never guessed to be old).
    static func eligibleRecords(
        in result: CatalogScanResult,
        now: Date,
        thresholdDays: Int = defaultAgeThresholdDays
    ) -> [PhotoAssetRecord] {
        let threshold = TimeInterval(thresholdDays) * 86_400
        return result.screenshotRecords
            .filter { record in
                guard let date = record.creationDate else { return false }
                return now.timeIntervalSince(date) >= threshold
            }
            .sorted { lhs, rhs in
                switch (lhs.creationDate, rhs.creationDate) {
                case let (l?, r?) where l != r:
                    return l < r // oldest first
                default:
                    return lhs.localIdentifier < rhs.localIdentifier
                }
            }
    }

    /// The screenshots excluded from the eligible list because their creation date is
    /// unknown — reported honestly, never guessed to be old or young.
    static func unknownDateRecords(in result: CatalogScanResult) -> [PhotoAssetRecord] {
        result.screenshotRecords.filter { $0.creationDate == nil }
    }

    /// The phase the Old Screenshots screen can be in.
    enum Phase: Equatable, Sendable {
        case permissionRequired
        case permissionDenied
        case buildingCatalog(CatalogScanProgress)
        case paused(stage: String)
        case scanRequired
        case failed(String)
        /// The catalog is complete, but there are no screenshots at all.
        case noScreenshots
        /// The catalog is complete; `count` is the eligible, oldest-first set; `unknownDateCount`
        /// is honestly reported separately (never folded into eligible).
        case results(count: Int, unknownDateCount: Int)
    }

    static func phase(
        permission: PermissionState,
        catalog: CatalogScanState,
        now: Date = Date(),
        thresholdDays: Int = defaultAgeThresholdDays
    ) -> Phase {
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
            guard !result.screenshotRecords.isEmpty else { return .noScreenshots }
            let eligible = eligibleRecords(in: result, now: now, thresholdDays: thresholdDays)
            let unknown = unknownDateRecords(in: result).count
            return .results(count: eligible.count, unknownDateCount: unknown)
        }
    }

    /// The screen's honest status line: a real eligible count, or the blocking reason.
    static func statusText(phase: Phase, thresholdDays: Int = defaultAgeThresholdDays) -> String {
        switch phase {
        case .permissionRequired:
            return "Photos access needed"
        case .permissionDenied:
            return "Photos access is off"
        case .scanRequired:
            return "Not scanned yet"
        case .buildingCatalog:
            return "Reading library…"
        case .paused:
            return "Scan paused"
        case .failed(let message):
            return message
        case .noScreenshots:
            return "No screenshots found"
        case .results(let count, _):
            return count == 0
                ? "No screenshots older than \(thresholdDays) days"
                : "\(count) older than \(thresholdDays) days"
        }
    }

    /// The dashboard's one-line status for the Old Screenshots row.
    static func dashboardStatus(phase: Phase, thresholdDays: Int = defaultAgeThresholdDays) -> CleanupDestinationStatus {
        switch phase {
        case .permissionRequired:
            return .unavailable(reason: "Allow Photos access to continue.")
        case .permissionDenied:
            return .unavailable(reason: "Photos access is off — enable it in Settings.")
        case .scanRequired:
            return .unknownCount("Not scanned yet")
        case .buildingCatalog:
            return .progress(message: "Reading library…", fraction: nil)
        case .paused:
            return .paused("Scan paused")
        case .failed(let message):
            return .failed(message)
        case .noScreenshots:
            return .empty("No screenshots found")
        case .results(let count, _):
            return count == 0
                ? .empty("No screenshots older than \(thresholdDays) days")
                : .count(count)
        }
    }
}

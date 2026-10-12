import SwiftUI

/// The Video Cleanup hub — one screen grouping the two source-filtered video destinations.
///
/// It starts no size measurement on appear. Both destinations read the shared video
/// inventory and the existing measurement state; classification is by source evidence only.
struct VideoCleanupView: View {
    @Environment(AppEnvironment.self) private var env: AppEnvironment

    var body: some View {
        CleanupHubScreen(
            title: "Video Cleanup",
            intro: VideoCleanupDestination.hubIntro(
                permission: env.photoPermissionState,
                catalog: env.catalogState,
                resolution: env.videoSizeResolution,
                videoSignature: env.videoDatasetSignature,
                videoRecords: env.videoRecordsForDisplay,
                otherVideoCount: env.otherVideosCount
            )
        ) {
            unclassifiedNote

            ForEach(VideoCleanupDestination.allCases, id: \.self) { destination in
                CleanupDestinationRow(
                    title: destination.title,
                    subtitle: destination.subtitle,
                    icon: destination.icon,
                    status: status(for: destination),
                    accessibilityIdentifier: destination.accessibilityIdentifier
                ) {
                    VideoInventoryView(source: destination.classification)
                }
            }
        }
        .onAppear { env.refreshPermissions() }
    }

    /// The unclassified count is shown as its own honest line — never folded into either
    /// bucket, and absent entirely when every video's source was established.
    @ViewBuilder
    private var unclassifiedNote: some View {
        let other = env.otherVideosCount
        if other > 0 {
            HStack(spacing: NettoLayout.Spacing.sm) {
                NettoIcon(name: "questionmark.circle", size: NettoIconSize.row, weight: .semibold, tint: NettoColor.warning)
                Text("\(other) \(other == 1 ? "video" : "videos") with an unconfirmed source")
                    .font(NettoType.caption)
                    .foregroundStyle(NettoColor.textSecondary)
                Spacer(minLength: 0)
            }
            .padding(NettoLayout.Spacing.md)
            .nettoSurface(.elevated, cornerRadius: NettoLayout.Radius.card)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("unclassifiedVideosNote")
        }
    }

    private func status(for destination: VideoCleanupDestination) -> CleanupDestinationStatus {
        let records: [PhotoAssetRecord]
        switch destination.classification {
        case .recorded: records = env.recordedVideosForDisplay
        case .downloaded: records = env.downloadedVideosForDisplay
        case .other: records = []
        }
        let phase = VideosPresentation.phase(
            permission: env.photoPermissionState,
            catalog: env.catalogState,
            resolution: env.videoSizeResolution,
            datasetSignature: env.videoDatasetSignature,
            settledRecords: env.videoRecordsForDisplay
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
            return .measurement(VideosPresentation.statusText(
                permission: env.photoPermissionState,
                catalog: env.catalogState,
                resolution: env.videoSizeResolution,
                datasetSignature: env.videoDatasetSignature,
                settledRecords: env.videoRecordsForDisplay
            ))
        case .results:
            return records.isEmpty
                ? .empty("None found")
                : .count(records.count)
        }
    }
}

#Preview("Video Cleanup") {
    NavigationStack {
        VideoCleanupView()
    }
    .environment(
        PreviewData.environment(
            catalog: .completed(VideosFixture.completed),
            videoResolution: VideosFixture.settledPartial
        )
    )
}

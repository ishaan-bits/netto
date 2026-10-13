import SwiftUI

/// The Image Cleanup hub — one screen grouping the photo destinations.
///
/// It launches no analysis on appear. The similarity pass is the single engine behind
/// Similar Images, which lists both byte-identical duplicates and visually alike shots
/// in one screen; Blurry Images and Old Screenshots are independent. Every row reports
/// the honest status of the feature it opens.
struct ImageCleanupView: View {
    @Environment(AppEnvironment.self) private var env: AppEnvironment

    private var pendingBehindOtherPass: Bool { env.pendingAnalysisRequest == .similarity }

    var body: some View {
        CleanupHubScreen(
            title: "Image Cleanup",
            intro: ImageCleanupDestination.hubIntro(
                permission: env.photoPermissionState,
                catalog: env.catalogState,
                analysis: env.analysisState,
                blur: env.blurAnalysisState,
                pendingBehindOtherPass: pendingBehindOtherPass
            )
        ) {
            ForEach(ImageCleanupDestination.allCases, id: \.self) { destination in
                CleanupDestinationRow(
                    title: destination.title,
                    subtitle: destination.subtitle,
                    icon: destination.icon,
                    status: ImageCleanupDestination.status(
                        for: destination,
                        permission: env.photoPermissionState,
                        catalog: env.catalogState,
                        analysis: env.analysisState,
                        blur: env.blurAnalysisState,
                        pendingBehindOtherPass: pendingBehindOtherPass
                    ),
                    accessibilityIdentifier: destination.accessibilityIdentifier
                ) {
                    switch destination {
                    case .similarImages:
                        // One screen for both group kinds: exact-duplicate groups and
                        // visually similar groups share one list, ordered exact-first.
                        // Opening this destination does not start a run.
                        SimilarPhotosView()
                    case .blurryImages:
                        PotentiallyBlurryView()
                    case .oldScreenshots:
                        OldScreenshotsView()
                    }
                }
            }
        }
        .onAppear { env.refreshPermissions() }
    }
}

#Preview("Image Cleanup") {
    NavigationStack {
        ImageCleanupView()
    }
    .environment(PreviewData.environment())
}

#Preview("Image Cleanup · analyzed") {
    NavigationStack {
        ImageCleanupView()
    }
    .environment(PreviewData.environment(analysis: .completed(PreviewData.result)))
}

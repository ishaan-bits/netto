import SwiftUI

/// The Image Cleanup hub — one screen grouping the four photo destinations.
///
/// It launches no analysis on appear. The similar/exact pass is the single existing engine
/// behind both Duplicate Images and Similar Images; Blurry Images and Old Screenshots are
/// independent. Every row reports the honest status of the feature it opens.
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
                    case .duplicateImages:
                        // Same engine and screen as Similar Images: exact-duplicate groups
                        // are a first-class section of the Similar Photos result, never a
                        // renamed stand-in. Opening this destination does not start a run.
                        SimilarPhotosView(highlightExactDuplicates: true)
                    case .similarImages:
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

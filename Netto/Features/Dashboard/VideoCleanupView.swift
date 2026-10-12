import SwiftUI

/// The VIDEO CLEANUP entry — the immediate, local-first video inventory (M14).
///
/// The hub's old Recorded/Downloaded split is gone: one tap from the dashboard opens the
/// unified inventory directly. Known sizes are listed first (largest to smallest), the
/// size-unavailable group below; measurement starts automatically and never holds up the
/// list. No cloud-only video is ever downloaded to measure or classify it.
struct VideoCleanupView: View {
    var body: some View {
        VideosView()
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

import AVFoundation
import AVKit
import Combine
import SwiftUI

/// Playback for one previewed video.
///
/// Ownership rules this model exists to enforce:
/// - The `AVPlayer` (and its current item) is created here, used only while the preview is
///   open, and released on close/dismiss — no player outlives the screen.
/// - Every open bumps a generation; a late response for a previously opened (or already
///   closed) video can never overwrite the current stage or install a stale player.
/// - The loader seam never downloads: an iCloud-only video lands in `.unavailable` with
///   distinct copy instead of silently streaming bytes.
@MainActor
final class VideoPreviewModel: ObservableObject {
    enum Stage: Equatable {
        case idle
        case loading
        case ready
        case unavailable(PhotoContentError)
    }

    @Published private(set) var stage: Stage = .idle
    @Published private(set) var player: AVPlayer?

    private let loader: any VideoPreviewLoading
    private var generation = 0
    private var loadTask: Task<Void, Never>?
    private(set) var presentedAssetID: String?

    init(loader: any VideoPreviewLoading = PhotoKitVideoPreviewLoader()) {
        self.loader = loader
    }

    /// Starts loading (and then playing) the video. Each open supersedes the previous one.
    func open(assetID: String) {
        generation += 1
        let generation = generation
        presentedAssetID = assetID
        releasePlayer()
        stage = .loading
        loadTask?.cancel()

        loadTask = Task { [weak self] in
            guard let self else { return }
            do {
                let url = try await self.loader.playbackURL(for: assetID)
                guard self.generation == generation else { return }
                let player = AVPlayer(url: url)
                self.player = player
                self.stage = .ready
                player.play()
            } catch {
                guard self.generation == generation else { return }
                self.stage = .unavailable(Self.contentError(for: error))
            }
        }
    }

    /// Leaves the preview and releases every playback resource. Safe to call repeatedly.
    func close() {
        generation += 1
        loadTask?.cancel()
        loadTask = nil
        presentedAssetID = nil
        releasePlayer()
        stage = .idle
    }

    private func releasePlayer() {
        player?.pause()
        player?.replaceCurrentItem(with: nil)
        player = nil
    }

    private static func contentError(for error: any Error) -> PhotoContentError {
        error as? PhotoContentError ?? .unavailable
    }
}

/// The video preview screen: tap a row in the videos list, the local file plays here.
///
/// Nothing in this screen touches selection or deletion — previewing is read-only, and every
/// playback resource is released when the screen goes away.
struct VideoPreviewView: View {
    let assetID: String
    let duration: TimeInterval

    @Environment(\.dismiss) private var dismiss
    @StateObject private var model: VideoPreviewModel

    init(
        assetID: String,
        duration: TimeInterval,
        loader: any VideoPreviewLoading = PhotoKitVideoPreviewLoader()
    ) {
        self.assetID = assetID
        self.duration = duration
        _model = StateObject(wrappedValue: VideoPreviewModel(loader: loader))
    }

    var body: some View {
        content
            .background(.black)
            .onAppear { model.open(assetID: assetID) }
            .onDisappear { model.close() }
    }

    @ViewBuilder
    private var content: some View {
        switch model.stage {
        case .idle, .loading:
            VStack(spacing: Theme.Spacing.lg) {
                ProgressView()
                    .tint(.white)
                Text("Loading video…")
                    .font(.subheadline)
                    .foregroundStyle(.white)
                closeButton
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

        case .ready:
            if let player = model.player {
                VideoPlayer(player: player)
                    .ignoresSafeArea()
                    .overlay(alignment: .topTrailing) { closeButton.padding() }
            }

        case .unavailable(let error):
            VStack(spacing: Theme.Spacing.lg) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 44))
                    .foregroundStyle(.white)
                Text("Preview unavailable")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.white)
                Text(VideosPresentation.previewUnavailableMessage(for: error))
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.8))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, Theme.Spacing.xl)
                closeButton
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var closeButton: some View {
        Button {
            dismiss()
        } label: {
            Label("Close", systemImage: "xmark.circle.fill")
                .labelStyle(.iconOnly)
                .font(.title2)
                .foregroundStyle(.white)
                .padding(Theme.Spacing.sm)
        }
        .accessibilityLabel("Close preview")
    }
}

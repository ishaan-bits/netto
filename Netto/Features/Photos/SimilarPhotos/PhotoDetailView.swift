import Combine
import CoreGraphics
import SwiftUI

// MARK: - Preview model

/// Lifecycle of the large Photo Details preview image.
///
/// Ownership rules this model exists to enforce (mirroring `VideoPreviewModel`):
/// - `open` starts exactly one load for the presented asset; every open/retry bumps a
///   generation, so a late frame for a superseded (or already closed) screen can never
///   resurrect itself over the current state.
/// - Interim (degraded) frames from the loader surface for progressive sharpening but never
///   settle the stage: `.loading` stays until the final frame or a real failure.
/// - `close` cancels the in-flight request **and releases the decoded bitmap** — the large
///   image lives exactly as long as the screen does, never in the strip's thumbnail cache.
/// - Failures are retryable: the preview request path is uncached, so Retry is a fresh load
///   rather than a replay of a negatively cached miss.
/// - Nothing here reads or writes selection, analysis, or deletion — previewing is read-only.
@MainActor
final class PhotoPreviewModel: ObservableObject {
    enum Stage: Equatable {
        case idle
        case loading
        case ready
        case unavailable(PhotoContentError)
    }

    @Published private(set) var stage: Stage = .idle
    /// The current frame: an interim (degraded) one while loading, the final one when ready.
    /// `nil` when no frame exists — before the first load and after `close`.
    @Published private(set) var image: CGImage?
    /// Whether the full-screen inspection viewer is up. Owned here so presentation shares the
    /// model's lifecycle and tests can prove opening it mutates neither selection nor analysis.
    @Published private(set) var isFullScreenPresented = false

    private(set) var presentedAssetID: String?

    private var loader: (any PhotoThumbnailLoading)?
    private var generation = 0
    private var loadTask: Task<Void, Never>?

    /// Starts (or restarts) the preview load. The loader arrives from the environment at open
    /// time so fixtures and previews serve synthetic images through this same code path.
    func open(assetID: String, using loader: any PhotoThumbnailLoading) {
        generation += 1
        let generation = generation
        presentedAssetID = assetID
        self.loader = loader
        image = nil
        isFullScreenPresented = false
        stage = .loading
        loadTask?.cancel()

        loadTask = Task { [weak self] in
            guard let self else { return }
            do {
                let final = try await loader.previewImage(
                    for: assetID,
                    targetPixelSize: SimilarPhotosPresentation.previewTargetPixelSize
                ) { [weak self] interim in
                    // PhotoKit calls back off the model's actor; hop to the main actor and
                    // apply only while this load is still the current, still-waiting one.
                    Task { @MainActor [weak self] in
                        guard let self, self.generation == generation, self.stage == .loading else {
                            return
                        }
                        self.image = interim
                    }
                }
                guard self.generation == generation else { return }
                self.image = final
                self.stage = .ready
            } catch {
                guard self.generation == generation else { return }
                if self.image != nil {
                    // A usable interim frame survived the failure — keep showing the pixels
                    // the user can already inspect instead of discarding them for an error.
                    self.stage = .ready
                } else {
                    self.stage = .unavailable(Self.contentError(for: error))
                }
            }
        }
    }

    /// Leaves the preview and releases every resource, including the large bitmap. Safe to
    /// call repeatedly and before any open.
    func close() {
        generation += 1
        loadTask?.cancel()
        loadTask = nil
        presentedAssetID = nil
        image = nil
        isFullScreenPresented = false
        stage = .idle
    }

    /// Reissues the load after a failure. The request path is uncached, so this is a fresh
    /// PhotoKit request, not a replay of a cached miss.
    func retry() {
        guard let assetID = presentedAssetID, let loader else { return }
        open(assetID: assetID, using: loader)
    }

    /// Presents or dismisses the full-screen inspection viewer. Presentation state only —
    /// it never touches selection, analysis, or the in-flight load.
    func setFullScreen(_ presented: Bool) {
        isFullScreenPresented = presented
    }

    private static func contentError(for error: any Error) -> PhotoContentError {
        if let content = error as? PhotoContentError { return content }
        // Timeouts and unknown failures land in the honest generic bucket, still retryable.
        return .unavailable
    }
}

// MARK: - Detail sheet

/// One asset, enlarged, with everything the analysis knows about it and the per-asset
/// selection control.
///
/// Metadata comes from the group's `memberScores` (score inputs recorded at analysis time) —
/// no extra PhotoKit reads happen just to populate this sheet. The large preview loads through
/// `PhotoPreviewModel` via the environment's loader with the explicitly user-requested preview
/// policy (large box, network allowed for an iCloud rendition, interim frames surfaced) and is
/// released when the sheet goes away. No deletion or mutation API is reachable from here; the
/// only action besides inspection is toggling the in-memory selection.
struct PhotoDetailView: View {
    let group: PhotoSimilarityGroup
    let assetID: String

    @EnvironmentObject private var env: AppEnvironment
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @StateObject private var model: PhotoPreviewModel = PhotoPreviewModel()
    /// Drives the skeleton's shimmer sweep; only ever animated when Reduce Motion is off.
    @State private var shimmerSwept = false

    private var score: PhotoAssetQualityScore? { group.memberScores[assetID] }
    private var isRecommended: Bool { group.recommendedBestAssetID == assetID }
    private var isSelected: Bool { env.selection.isSelected(assetID) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: Theme.Spacing.lg) {
                    preview
                    infoCard
                    selectionButton
                }
                .padding(Theme.Spacing.lg)
            }
            .background(NettoColor.background.ignoresSafeArea())
            .navigationTitle("Photo Details")
            .nettoAppear()
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .fullScreenCover(isPresented: fullScreenBinding) {
                PhotoFullScreenViewer(image: model.image) {
                    model.setFullScreen(false)
                }
            }
        }
        .onAppear { model.open(assetID: assetID, using: env.thumbnailLoader) }
        .onDisappear { model.close() }
    }

    private var fullScreenBinding: Binding<Bool> {
        Binding(
            get: { model.isFullScreenPresented },
            set: { model.setFullScreen($0) }
        )
    }

    // MARK: Preview

    /// The large preview box: fixed height, full available width, with the image aspect-fit
    /// inside a rounded, dark-letterboxed frame — never cropped, never a square fill.
    private var preview: some View {
        previewContent
            .frame(maxWidth: .infinity)
            .frame(height: SimilarPhotosPresentation.previewBoxHeight)
            .clipShape(RoundedRectangle(cornerRadius: NettoLayout.Radius.card, style: .continuous))
            .overlay(alignment: .topLeading) { bestBadge }
            .overlay(alignment: .topTrailing) { expandButton }
            .nettoAnimate(.success, value: isRecommended)
            .accessibilityElement(children: .contain)
            .accessibilityLabel(isRecommended ? "Photo, recommended to keep" : "Photo")
    }

    @ViewBuilder
    private var previewContent: some View {
        // Letterbox backdrop: the image sits aspect-fit over a dark neutral background, so
        // portrait and landscape assets both show in full within the box.
        ZStack {
            Color.black

            switch model.stage {
            case .idle:
                Color.black

            case .loading:
                if let image = model.image {
                    // Interim (degraded) frame: shown while the final render is still coming.
                    previewImage(image)
                } else {
                    skeleton
                }

            case .ready:
                if let image = model.image {
                    previewImage(image)
                } else {
                    skeleton
                }

            case .unavailable(let error):
                failureState(error)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            guard model.image != nil else { return }
            model.setFullScreen(true)
        }
    }

    private func previewImage(_ image: CGImage) -> some View {
        Image(image, scale: 1, orientation: .up, label: Text("Photo preview"))
            .resizable()
            .aspectRatio(contentMode: .fit)
            .transition(.opacity)
            .accessibilityHidden(true)
    }

    /// Loading skeleton. Under Reduce Motion the shimmer sweep (a repeating motion) is
    /// replaced by a static placeholder with the loading caption — same information, no motion.
    private var skeleton: some View {
        ZStack {
            RoundedRectangle(cornerRadius: NettoLayout.Radius.control, style: .continuous)
                .fill(Color.white.opacity(0.07))
                .padding(Theme.Spacing.lg)

            if reduceMotion {
                Text(SimilarPhotosPresentation.previewLoadingMessage)
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.7))
            } else {
                shimmeringSweep
                Text(SimilarPhotosPresentation.previewLoadingMessage)
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.7))
                    .padding(.top, Theme.Spacing.xl)
            }
        }
        .accessibilityElement()
        .accessibilityLabel(SimilarPhotosPresentation.previewLoadingMessage)
    }

    /// One soft highlight sweeping left-to-right over the placeholder. Decoration only —
    /// never rendered when Reduce Motion is on (the branch above isn't taken then).
    private var shimmeringSweep: some View {
        RoundedRectangle(cornerRadius: NettoLayout.Radius.control, style: .continuous)
            .fill(Color.white.opacity(0.07))
            .padding(Theme.Spacing.lg)
            .overlay {
                GeometryReader { geo in
                    LinearGradient(
                        colors: [.clear, .white.opacity(0.16), .clear],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                    .frame(width: geo.size.width * 0.5)
                    .offset(x: geo.size.width * (shimmerSwept ? 1.2 : -0.7))
                    .clipped()
                }
                .clipped()
            }
            .onAppear {
                withAnimation(.linear(duration: 1.4).repeatForever(autoreverses: false)) {
                    shimmerSwept = true
                }
            }
    }

    private func failureState(_ error: PhotoContentError) -> some View {
        VStack(spacing: Theme.Spacing.md) {
            Image(systemName: SimilarPhotosPresentation.previewFailureSymbol(for: error))
                .font(.system(size: 34))
                .foregroundStyle(.white.opacity(0.75))
            Text(SimilarPhotosPresentation.previewUnavailableTitle)
                .font(.headline)
                .foregroundStyle(.white)
            Text(SimilarPhotosPresentation.previewUnavailableMessage(for: error))
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.8))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Button {
                model.retry()
            } label: {
                Text("Try Again")
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, Theme.Spacing.lg)
                    .padding(.vertical, Theme.Spacing.sm)
                    .background(.white.opacity(0.16), in: Capsule())
                    .foregroundStyle(.white)
            }
            .accessibilityLabel("Try loading the photo again")
        }
        .padding(Theme.Spacing.lg)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(SimilarPhotosPresentation.previewUnavailableTitle)
    }

    private var bestBadge: some View {
        Group {
            if isRecommended {
                Label("Best", systemImage: "star.fill")
                    .font(.caption.weight(.bold))
                    .padding(.horizontal, Theme.Spacing.sm)
                    .padding(.vertical, Theme.Spacing.xs)
                    .background(NettoColor.success, in: Capsule())
                    .foregroundStyle(.white)
                    .padding(Theme.Spacing.sm)
                    .transition(.scale(scale: 0.8).combined(with: .opacity))
            }
        }
    }

    /// Discoverable activation for the full-screen viewer (the whole image is also tappable).
    private var expandButton: some View {
        Group {
            if model.image != nil {
                Button {
                    model.setFullScreen(true)
                } label: {
                    Label("Show full screen", systemImage: "arrow.up.left.and.arrow.down.right")
                        .labelStyle(.iconOnly)
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(.white)
                        .padding(Theme.Spacing.sm)
                        .background(.black.opacity(0.55), in: Circle())
                }
                .padding(Theme.Spacing.sm)
                .accessibilityLabel("Show photo full screen")
            }
        }
    }

    // MARK: Info

    private var infoCard: some View {
        VStack(spacing: 0) {
            infoRow("Created", value: creationText)
            Divider()
            infoRow("Resolution", value: resolutionText)
            Divider()
            infoRow("Favorite", value: flagText(score?.isFavorite))
            Divider()
            infoRow("Edited", value: flagText(score?.hasAdjustments))
            Divider()
            infoRow("Burst shot", value: flagText(score?.representsBurst))
        }
        .padding(.horizontal, Theme.Spacing.lg)
        .nettoSurface(.elevated, cornerRadius: NettoLayout.Radius.card)
    }

    private func infoRow(_ title: String, value: String) -> some View {
        HStack {
            Text(title)
                .font(.subheadline)
                .foregroundStyle(NettoColor.textSecondary)
            Spacer()
            Text(value)
                .font(.subheadline.weight(.medium))
                .monospacedDigit()
                .foregroundStyle(NettoColor.textPrimary)
        }
        .padding(.vertical, Theme.Spacing.md)
    }

    private var creationText: String {
        guard let date = score?.creationDate else { return "Unknown" }
        return date.formatted(date: .abbreviated, time: .shortened)
    }

    private var resolutionText: String {
        guard let pixelCount = score?.pixelCount, pixelCount > 0 else { return "Unknown" }
        let megapixels = Double(pixelCount) / 1_000_000
        return String(format: "%.1f MP", megapixels)
    }

    private func flagText(_ value: Bool?) -> String {
        switch value {
        case .some(true): return "Yes"
        case .some(false): return "No"
        case nil: return "Unknown"
        }
    }

    // MARK: Selection

    private var selectionButton: some View {
        VStack(spacing: Theme.Spacing.sm) {
            if isSelected {
                Button(action: toggle) {
                    Text("Remove from Cleanup")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(NettoSecondaryButtonStyle())
            } else {
                Button(action: toggle) {
                    Text("Mark for Cleanup")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(NettoPrimaryButtonStyle())
            }

            Text(isSelected
                 ? "Selected for cleanup. Nothing is deleted yet."
                 : "Kept — Netto will not include this photo in a cleanup.")
                .font(NettoType.caption)
                .foregroundStyle(NettoColor.textSecondary)
                .multilineTextAlignment(.center)
                .nettoAnimate(.stateChange, value: isSelected)
        }
    }

    private func toggle() {
        env.mutateSelection { $0.toggle(assetID) }
    }
}

// MARK: - Full-screen viewer

/// Full-screen inspection of the previewed photo: native pinch-zoom, Done to return.
///
/// Strictly read-only — this screen carries no selection or deletion control and holds no
/// reference to the environment at all, so opening it cannot mutate anything. The bitmap it
/// shows is the detail sheet's preview frame; nothing extra is loaded or retained here.
struct PhotoFullScreenViewer: View {
    let image: CGImage?
    let onClose: () -> Void

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if let image {
                ZoomablePhotoView(image: image)
                    .ignoresSafeArea()
            } else {
                // The sheet dismissed (or a late cover) while no frame exists: show the same
                // loading language rather than a blank black screen.
                ProgressView()
                    .tint(.white)
            }
        }
        .overlay(alignment: .topTrailing) { closeButton }
    }

    private var closeButton: some View {
        Button(action: onClose) {
            Label("Close", systemImage: "xmark.circle.fill")
                .labelStyle(.iconOnly)
                .font(.title2)
                .foregroundStyle(.white)
                .padding(Theme.Spacing.md)
        }
        .accessibilityLabel("Close full screen photo")
    }
}

/// Native pinch/pan zoom over the preview bitmap — a plain `UIScrollView` hosting the image
/// with `viewForZooming`, so pinch, pan, and zoom-bounce are system behaviour rather than
/// reimplemented gesture math. The image is aspect-fit and centered at zoom 1; zooming scales
/// around the user's fingers. No custom gestures, no editing surface.
struct ZoomablePhotoView: UIViewRepresentable {
    let image: CGImage

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> UIScrollView {
        let scrollView = UIScrollView()
        scrollView.delegate = context.coordinator
        scrollView.minimumZoomScale = 1
        scrollView.maximumZoomScale = 6
        scrollView.bouncesZoom = true
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.showsVerticalScrollIndicator = false
        scrollView.backgroundColor = .black

        let imageView = UIImageView(image: UIImage(cgImage: image))
        imageView.contentMode = .scaleAspectFit
        context.coordinator.imageView = imageView
        scrollView.addSubview(imageView)
        return scrollView
    }

    func updateUIView(_ scrollView: UIScrollView, context: Context) {
        // A sharper interim→final frame swap while the viewer is already up.
        context.coordinator.imageView.image = UIImage(cgImage: image)
        context.coordinator.layout(in: scrollView)
    }

    final class Coordinator: NSObject, UIScrollViewDelegate {
        var imageView = UIImageView()

        func viewForZooming(in scrollView: UIScrollView) -> UIView? {
            imageView
        }

        /// Sizes the scrollable content to the aspect-fit image inside the current bounds;
        /// a smaller-than-bounds content rect is auto-centered by the scroll view, which is
        /// exactly the letterboxed look at zoom 1. Re-run on every update (rotation, new frame).
        func layout(in scrollView: UIScrollView) {
            let boundsSize = scrollView.bounds.size
            guard boundsSize.width > 0, boundsSize.height > 0 else { return }
            guard let imageSize = imageView.image?.size,
                  imageSize.width > 0, imageSize.height > 0 else { return }

            let scale = min(boundsSize.width / imageSize.width, boundsSize.height / imageSize.height)
            let fitted = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
            imageView.frame = CGRect(origin: .zero, size: fitted)
            scrollView.contentSize = fitted
        }
    }
}

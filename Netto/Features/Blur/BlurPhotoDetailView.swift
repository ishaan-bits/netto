import SwiftUI

/// One candidate, enlarged, with the verdict that put it here and the per-asset selection
/// control — the blur counterpart of `PhotoDetailView`.
///
/// Reuses the same preview machinery as Photo Details (`PhotoPreviewModel` +
/// `PhotoFullScreenViewer`): the large rendition loads through the environment's loader
/// with the explicitly user-requested preview policy and is released when the sheet goes
/// away. Deliberately does *not* reuse `PhotoDetailView` itself: that sheet is bound to a
/// `PhotoSimilarityGroup` and to the similar-photos selection, and driving either from a
/// blur candidate would fabricate duplicate evidence and toggle the wrong selection.
///
/// The evidence shown is exactly what the blur pass measured for this asset — the verdict
/// and the raw Laplacian variance recorded at analysis time. No deletion or mutation API
/// is reachable from here; the only action besides inspection is toggling the in-memory
/// selection.
struct BlurPhotoDetailView: View {
    let assetID: String
    /// The candidate record from the completed result; `nil` only if the result changed
    /// between grid tap and sheet presentation (the sheet then shows no verdict rather
    /// than inventing one).
    let candidate: BlurCandidate?

    @Environment(AppEnvironment.self) private var env: AppEnvironment
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @StateObject private var model: PhotoPreviewModel = PhotoPreviewModel()
    @State private var shimmerSwept = false

    private var isSelected: Bool { env.blurSelection.isSelected(assetID) }
    private var record: PhotoAssetRecord? {
        guard case .completed(let catalog) = env.catalogState else { return nil }
        return catalog.records.first { $0.localIdentifier == assetID }
    }

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

    /// The large preview box: fixed height, full available width, image aspect-fit inside
    /// a rounded, dark-letterboxed frame — identical to Photo Details.
    private var preview: some View {
        previewContent
            .frame(maxWidth: .infinity)
            .frame(height: SimilarPhotosPresentation.previewBoxHeight)
            .clipShape(RoundedRectangle(cornerRadius: NettoLayout.Radius.card, style: .continuous))
            .overlay(alignment: .topLeading) { verdictBadge }
            .overlay(alignment: .topTrailing) { expandButton }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Potentially blurry photo")
    }

    @ViewBuilder
    private var previewContent: some View {
        ZStack {
            Color.black

            switch model.stage {
            case .idle:
                Color.black

            case .loading:
                if let image = model.image {
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

    private var verdictBadge: some View {
        Group {
            if let candidate {
                Label(
                    candidate.verdict == .likelyBlurry ? "Likely blurry" : "Borderline",
                    systemImage: candidate.verdict == .likelyBlurry ? "exclamationmark.triangle.fill" : "questionmark.circle.fill"
                )
                .font(.caption.weight(.bold))
                .padding(.horizontal, Theme.Spacing.sm)
                .padding(.vertical, Theme.Spacing.xs)
                .background(candidate.verdict == .likelyBlurry ? NettoColor.brand : Theme.Palette.warning, in: Capsule())
                // Black reads on both capsule fills in both appearances (≥9.8:1) — white
                // was 1.38:1 on the lime and 2.1:1 on the orange.
                .foregroundStyle(.black)
                .padding(Theme.Spacing.sm)
                .transition(.scale(scale: 0.8).combined(with: .opacity))
            }
        }
    }

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

    /// Everything shown is recorded data: the verdict + raw score the blur pass measured
    /// for this asset, and catalog metadata for the record. Nothing is recomputed here.
    private var infoCard: some View {
        VStack(spacing: 0) {
            infoRow("Sharpness verdict", value: verdictText)
            Divider()
            infoRow("Detail score", value: varianceText)
            Divider()
            infoRow("Created", value: creationText)
            Divider()
            infoRow("Resolution", value: resolutionText)
            Divider()
            infoRow("Favorite", value: flagText(record?.isFavorite))
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

    private var verdictText: String {
        switch candidate?.verdict {
        case .likelyBlurry: return "Likely blurry"
        case .borderline: return "Borderline"
        default: return "Unknown"
        }
    }

    private var varianceText: String {
        guard let variance = candidate?.laplacianVariance else { return "Unknown" }
        return String(format: "%.5f", variance)
    }

    private var creationText: String {
        guard let date = record?.creationDate else { return "Unknown" }
        return date.formatted(date: .abbreviated, time: .shortened)
    }

    private var resolutionText: String {
        guard let record, record.pixelCount > 0 else { return "Unknown" }
        let megapixels = Double(record.pixelCount) / 1_000_000
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
        env.mutateBlurSelection { $0.toggle(assetID) }
    }
}

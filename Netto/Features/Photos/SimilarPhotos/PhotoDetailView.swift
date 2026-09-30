import SwiftUI

/// One asset, enlarged, with everything the analysis knows about it and the per-asset
/// selection control.
///
/// Metadata comes from the group's `memberScores` (score inputs recorded at analysis time) —
/// no extra PhotoKit reads happen just to populate this sheet, and the thumbnail comes from
/// `ThumbnailStore` at the detail pixel budget. No deletion or mutation API is reachable from
/// here; the only action is toggling the in-memory selection.
struct PhotoDetailView: View {
    let group: PhotoSimilarityGroup
    let assetID: String

    @EnvironmentObject private var env: AppEnvironment
    @Environment(\.dismiss) private var dismiss

    private var score: PhotoAssetQualityScore? { group.memberScores[assetID] }
    private var isRecommended: Bool { group.recommendedBestAssetID == assetID }
    private var isSelected: Bool { env.selection.isSelected(assetID) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: Theme.Spacing.lg) {
                    thumbnail
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
        }
    }

    // MARK: Thumbnail

    private var thumbnail: some View {
        PhotoThumbnailView(assetID: assetID, pointSize: 300, store: env.thumbnails)
            .frame(maxWidth: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: NettoLayout.Radius.card, style: .continuous))
            .overlay(alignment: .topLeading) {
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
            .nettoAnimate(.success, value: isRecommended)
            .accessibilityLabel(isRecommended ? "Photo, recommended to keep" : "Photo")
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

import SwiftUI

/// One similarity group in the review list: identity, why it matched, its thumbnail strip, and
/// the selection controls for its members.
///
/// The row is a pure value — it reads a `PhotoSelectionModel` snapshot and reports intent
/// through closures, so it can be previewed and reasoned about without an `AppEnvironment`.
/// The two cell buttons are **siblings** inside a `ZStack` (never nested): tapping the photo
/// opens the detail sheet, tapping the corner control toggles selection.
struct SimilarPhotoGroupRow: View {
    let group: PhotoSimilarityGroup
    let selection: PhotoSelectionModel
    let store: ThumbnailStore
    let onToggle: (String) -> Void
    let onSelectAllExceptRecommended: () -> Void
    let onClear: () -> Void
    let onKeepRecommended: () -> Void
    let onOpenDetail: (String) -> Void

    /// `true` while the recommended "keep" photo is *not* marked for cleanup — the resting
    /// default the app guarantees unless the user explicitly overrides it.
    private var isRecommendedKept: Bool {
        !selection.isSelected(group.recommendedBestAssetID)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            header
            strip
            footer
        }
        .padding(.vertical, Theme.Spacing.xs)
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Text(evidenceText)
                    .font(.caption)
                    .foregroundStyle(Theme.Palette.secondaryLabel)
            }
            Spacer(minLength: Theme.Spacing.sm)
            Menu {
                Button("Select All Except Recommended", action: onSelectAllExceptRecommended)
                Button("Keep Recommended", action: onKeepRecommended)
                Button("Clear Selection", action: onClear)
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.title3)
                    .foregroundStyle(Theme.Palette.secondaryLabel)
            }
            .accessibilityLabel("Group actions")
        }
    }

    private var title: String {
        group.kind == .exactDuplicates
            ? "\(group.count) identical copies"
            : "\(group.count) similar photos"
    }

    private var evidenceText: String {
        switch group.evidence {
        case .exactContent(_, let byteLength):
            return "Identical content · \(ByteFormat.string(byteLength)) per item"
        case .visualSimilarity(let minDistance, let maxDistance, let threshold):
            return String(
                format: "Near-identical · distance %.2f–%.2f (threshold %.2f)",
                minDistance,
                maxDistance,
                threshold
            )
        }
    }

    // MARK: Strip

    private var strip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(spacing: Theme.Spacing.sm) {
                ForEach(group.memberAssetIDs, id: \.self) { assetID in
                    cell(assetID)
                }
            }
        }
    }

    private func cell(_ assetID: String) -> some View {
        let recommended = group.recommendedBestAssetID == assetID
        let selected = selection.isSelected(assetID)
        return ZStack(alignment: .topTrailing) {
            Button {
                onOpenDetail(assetID)
            } label: {
                PhotoThumbnailView(assetID: assetID, pointSize: 96, store: store)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.sm))
                    .overlay {
                        RoundedRectangle(cornerRadius: Theme.Radius.sm)
                            .stroke(
                                selected ? Theme.Palette.accent : Theme.Palette.separator,
                                lineWidth: selected ? 2 : 1
                            )
                    }
                    .overlay(alignment: .bottomLeading) {
                        if recommended {
                            keepBadge
                        }
                    }
            }
            .buttonStyle(.plain)
            .accessibilityLabel(recommended ? "Photo details, recommended to keep" : "Photo details")

            Button {
                onToggle(assetID)
            } label: {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(Color.white)
                    .padding(5)
                    .background(
                        selected ? Theme.Palette.accent : Color.black.opacity(0.45),
                        in: Circle()
                    )
                    .padding(4)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(selected ? "Selected for cleanup" : "Not selected")
        }
        .frame(width: 96, height: 96)
    }

    private var keepBadge: some View {
        Text("KEEP")
            .font(.system(size: 9, weight: .heavy))
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(Theme.Palette.success, in: Capsule())
            .foregroundStyle(.white)
            .padding(4)
            .accessibilityLabel("Recommended to keep")
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: Theme.Spacing.sm) {
            Text(selectionText)
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(Theme.Palette.secondaryLabel)
            Spacer()
            if isRecommendedKept {
                Label("Best photo kept", systemImage: "star.fill")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(Theme.Palette.success)
            }
        }
    }

    private var selectionText: String {
        switch selection.selectionState(inGroup: group.id) {
        case .none:
            return "Nothing selected"
        case .some(let selected, let total):
            return "\(selected) of \(total) selected"
        case .all:
            return "All \(group.count) selected"
        }
    }
}

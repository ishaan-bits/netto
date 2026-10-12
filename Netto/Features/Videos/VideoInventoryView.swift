import SwiftUI

/// One row of the unified video inventory (M14): poster thumbnail, duration, resolution and
/// date, an honest size — measured bytes, or "not measured locally" — and the selection
/// check. Tapping the row opens the video preview.
///
/// There is no source split anywhere in this file: the inventory lists every video the
/// catalog holds, in one list, and size status is the only grouping (measured first,
/// largest to smallest; size-unavailable below). Selection lives in the shared
/// `videoSelection`, so the review → confirmation → mutation → verification pipeline and
/// its deletion-safety guarantees are exactly the ones every other video surface uses.
struct VideoInventoryRow: View {
    let record: PhotoAssetRecord
    let isSelected: Bool
    let store: ThumbnailStore
    let onPreview: () -> Void
    let toggle: () -> Void

    var body: some View {
        HStack(spacing: Theme.Spacing.md) {
            Button(action: onPreview) {
                HStack(spacing: Theme.Spacing.md) {
                    thumbnail

                    VStack(alignment: .leading, spacing: 2) {
                        Text(VideosPresentation.durationText(record.duration))
                            .font(.subheadline.weight(.semibold))
                            .monospacedDigit()
                        Text(metadataLine)
                            .font(.caption)
                            .foregroundStyle(Theme.Palette.secondaryLabel)
                            .lineLimit(1)
                        Text(sizeText)
                            .font(record.isSizeKnown ? .subheadline.weight(.medium) : .subheadline)
                            .monospacedDigit()
                            .foregroundStyle(record.isSizeKnown ? Theme.Palette.secondaryLabel : NettoColor.warning)
                    }
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel(previewAccessibilityLabel)
            .accessibilityHint("Opens the video preview")

            Spacer(minLength: Theme.Spacing.sm)

            Button(action: toggle) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    // ~20 pt glyph with no frame — the toggle needs the 44 pt minimum
                    // target; the glyph stays optically identical, centred by the frame.
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
                    .foregroundStyle(
                        isSelected ? NettoColor.brandIndicator : Theme.Palette.secondaryLabel
                    )
            }
            .nettoPress()
            .nettoAnimate(.selection, value: isSelected)
            .accessibilityLabel("Select video")
            .accessibilityValue(isSelected ? "Selected" : "Not selected")
            .accessibilityAddTraits(isSelected ? [.isSelected] : [])
        }
        .contentShape(Rectangle())
    }

    /// Poster frame through the shared thumbnail store (PhotoKit delivers a still for
    /// videos; a cloud-only video degrades to the standard placeholder) with a play
    /// affordance on top.
    private var thumbnail: some View {
        ZStack {
            PhotoThumbnailView(
                assetID: record.localIdentifier,
                pointSize: 72,
                store: store
            )
            .clipShape(RoundedRectangle(cornerRadius: NettoLayout.Radius.control, style: .continuous))

            RoundedRectangle(cornerRadius: NettoLayout.Radius.control, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [.clear, .black.opacity(0.45)],
                        startPoint: .center,
                        endPoint: .bottom
                    )
                )

            Image(systemName: "play.fill")
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 34, height: 34)
                .background(.ultraThinMaterial, in: Circle())
                .environment(\.colorScheme, .dark)
                .shadow(radius: 3, y: 1)
        }
        .frame(width: 72, height: 72)
        .accessibilityHidden(true)
    }

    private var metadataLine: String {
        let resolution = "\(record.pixelWidth)×\(record.pixelHeight)"
        guard let date = record.creationDate else { return resolution }
        return "\(resolution) · \(date.formatted(date: .abbreviated, time: .omitted))"
    }

    /// The honest size line: measured bytes, or an explicit "not measured locally" — never
    /// a guessed zero, and never a claim about *why* a size is unknown (iCloud residency is
    /// not evidence this screen holds).
    private var sizeText: String {
        if let bytes = record.sizeInBytes {
            return ByteFormat.string(bytes)
        }
        return "Size unavailable — not measured locally"
    }

    private var previewAccessibilityLabel: String {
        let size = record.sizeInBytes.map(ByteFormat.string) ?? "size not measured locally"
        return "Video, \(VideosPresentation.durationText(record.duration)), \(size)"
    }
}

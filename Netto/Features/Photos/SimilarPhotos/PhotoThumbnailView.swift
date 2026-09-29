import CoreGraphics
import SwiftUI

/// One asset's thumbnail in the review UI, driven by `ThumbnailStore`.
///
/// Sizing contract: `pointSize` is a layout size; the request sent to PhotoKit is
/// `pointSize × displayScale` pixels (about 96 pt for strip cells, 300 pt for the detail sheet).
/// Full-resolution pixels are never requested, and every state — loading, ready, failed — is
/// explicit so a missing thumbnail degrades to a placeholder instead of a blank cell.
struct PhotoThumbnailView: View {
    let assetID: String
    let pointSize: CGFloat
    let store: ThumbnailStore

    @Environment(\.displayScale) private var displayScale

    @State private var state: LoadState = .loading

    private enum LoadState {
        case loading
        case ready(CGImage)
        case failed
    }

    var body: some View {
        ZStack {
            switch state {
            case .loading:
                Theme.Palette.tertiaryBackground
                ProgressView()
                    .controlSize(.small)
            case .ready(let image):
                Image(image, scale: 1, orientation: .up, label: Text("Photo thumbnail"))
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            case .failed:
                Theme.Palette.tertiaryBackground
                Image(systemName: "photo.badge.exclamationmark")
                    .font(.title3)
                    .foregroundStyle(Theme.Palette.secondaryLabel)
            }
        }
        .frame(width: pointSize, height: pointSize)
        .clipped()
        .accessibilityHidden(true)
        .task(id: requestKey) {
            await load()
        }
    }

    private var requestKey: String {
        "\(assetID)|\(Int(pointSize * displayScale))"
    }

    private func load() async {
        state = .loading
        do {
            let pixels = max(1, Int((pointSize * displayScale).rounded()))
            let image = try await store.image(for: assetID, targetPixelSize: pixels)
            state = .ready(image)
        } catch is CancellationError {
            // Superseded by a new key or a disappeared view — nothing to report.
        } catch {
            state = .failed
        }
    }
}

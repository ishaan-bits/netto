import SwiftUI

/// The destination of the review screen's "Review" button: an inspection of exactly what has
/// been marked for cleanup — and an explicit statement that cleanup itself does not exist yet.
///
/// Nothing here deletes, trashes, or mutates the photo library. The screen exists so the
/// selection can be verified as a set (every selected photo, once, with its group context)
/// before a future milestone adds the confirmation step and the actual cleanup.
struct ReviewSelectionView: View {
    @EnvironmentObject private var env: AppEnvironment

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                    Text("\(env.selection.selectedCount) photos selected")
                        .font(.headline)
                    Text("Cleanup is not implemented yet. Netto will not remove anything from your library until an explicit confirmation step exists — this screen only shows what you have marked.")
                        .font(.subheadline)
                        .foregroundStyle(Theme.Palette.secondaryLabel)
                }
                .padding(.vertical, Theme.Spacing.xs)
            }

            if sections.isEmpty {
                Section {
                    Text("Nothing is marked for cleanup. Select photos inside the groups first.")
                        .font(.subheadline)
                        .foregroundStyle(Theme.Palette.secondaryLabel)
                }
            } else {
                ForEach(sections, id: \.group.id) { entry in
                    Section(headerLabel(for: entry.group)) {
                        ForEach(entry.assetIDs, id: \.self) { assetID in
                            row(assetID, group: entry.group)
                        }
                    }
                }
            }
        }
        .navigationTitle("Cleanup Review")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: Selection projection

    private struct SectionEntry {
        let group: PhotoSimilarityGroup
        let assetIDs: [String]
    }

    /// Selected assets grouped by the group they were picked in. An asset member of two groups
    /// appears exactly once (first group wins), so the rows always add up to `selectedCount`.
    private var sections: [SectionEntry] {
        guard let result = analysisResult else { return [] }
        var seen: Set<String> = []
        var entries: [SectionEntry] = []
        for group in result.exactGroups + result.similarGroups {
            var ids: [String] = []
            for assetID in group.memberAssetIDs {
                guard env.selection.isSelected(assetID) else { continue }
                guard seen.insert(assetID).inserted else { continue }
                ids.append(assetID)
            }
            if !ids.isEmpty {
                entries.append(SectionEntry(group: group, assetIDs: ids))
            }
        }
        return entries
    }

    private var analysisResult: PhotoAnalysisResult? {
        if case .completed(let result) = env.analysisState { return result }
        return nil
    }

    private func headerLabel(for group: PhotoSimilarityGroup) -> String {
        switch group.kind {
        case .exactDuplicates:
            return "Exact · \(group.count) identical copies"
        case .nearDuplicates:
            return "Similar · \(group.count) photos"
        }
    }

    // MARK: Row

    private func row(_ assetID: String, group: PhotoSimilarityGroup) -> some View {
        HStack(spacing: Theme.Spacing.md) {
            PhotoThumbnailView(assetID: assetID, pointSize: 48, store: env.thumbnails)
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.sm))

            VStack(alignment: .leading, spacing: 2) {
                Text(group.recommendedBestAssetID == assetID
                     ? "Marked for cleanup (was recommended to keep)"
                     : "Marked for cleanup")
                    .font(.subheadline)
                if let date = group.memberScores[assetID]?.creationDate {
                    Text(date.formatted(date: .abbreviated, time: .omitted))
                        .font(.caption)
                        .foregroundStyle(Theme.Palette.secondaryLabel)
                }
            }

            Spacer()

            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(Theme.Palette.accent)
        }
        .accessibilityElement(children: .combine)
    }
}

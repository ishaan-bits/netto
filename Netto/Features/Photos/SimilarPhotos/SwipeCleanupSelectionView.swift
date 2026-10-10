import SwiftUI

/// Editable Review Cleanup for a Swipe Review session: every photo *this session* marked
/// Delete (Kept photos and never-reviewed photos are excluded by construction), all
/// selected by default, with individual toggles plus Select All / Deselect All, a live
/// selected count, and a thumbnail preview of every candidate.
///
/// This screen **selects only** — it never deletes and never builds a plan. The handoff is
/// into the *existing* `ReviewSelectionView(source: .swipeReview)`, which resolves sizes,
/// re-validates the identifiers, and runs the same explicit confirmation → `PhotoDeleting`
/// pipeline every other feature uses; the checked set lives in `AppEnvironment` (so it
/// survives navigation within the flow), and the plan refuses to execute if the checked set
/// or the shared selection changed after it was built.
struct SwipeCleanupSelectionView: View {
    @Environment(AppEnvironment.self) private var env: AppEnvironment

    /// The session that produced the candidates — read on appear only (candidate
    /// derivation), never per render.
    let model: SwipeReviewModel

    var body: some View {
        content
            .background(NettoColor.background.ignoresSafeArea())
            .navigationTitle(SwipeReviewPresentation.cleanupTitle)
            .navigationBarTitleDisplayMode(.inline)
            .nettoAppear()
            .accessibilityIdentifier(SwipeReviewPresentation.cleanupScreenAccessibilityID)
            .onAppear { enterCleanup() }
    }

    /// Deck-ordered Delete marks, reconciled against the catalog as it is now (assets
    /// deleted since the deck was built drop out here — before any plan can see them).
    private var candidates: [SwipeReviewItem] { env.swipeCleanupCandidates }

    private var checkedIDs: Set<String> { env.swipeCleanupCheckedIDs }
    private var selectedCount: Int { env.swipeCleanupCheckedCount }

    @ViewBuilder
    private var content: some View {
        if candidates.isEmpty {
            emptyState
        } else {
            candidateList
        }
    }

    /// Refreshes the environment's candidate list from the session + live selection. Explicit
    /// per-asset choices made earlier in the review flow are keyed by asset and preserved —
    /// re-entering never resets what the user unchecked, while a photo marked Delete since
    /// the last visit joins already selected (the default).
    private func enterCleanup() {
        let availableAssetIDs: Set<String>? = {
            guard case .completed(let catalog) = env.catalogState else { return nil }
            return Set(catalog.records.lazy.map(\.localIdentifier))
        }()
        env.enterSwipeCleanup(
            model.cleanupCandidates(selection: env.selection, availableAssetIDs: availableAssetIDs)
        )
    }

    private var emptyState: some View {
        PhaseMessage(
            systemImage: "checkmark.circle",
            title: "Nothing marked yet",
            message: SwipeReviewPresentation.cleanupEmptyMessage
        )
    }

    private var candidateList: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                    Text(SwipeReviewPresentation.selectedOfTotalText(
                        selected: selectedCount,
                        total: candidates.count
                    ))
                    .font(NettoType.cardTitle)
                    .monospacedDigit()
                    .foregroundStyle(NettoColor.textPrimary)
                    .accessibilityIdentifier(
                        SwipeReviewPresentation.cleanupSelectedCountAccessibilityID
                    )

                    HStack(spacing: Theme.Spacing.md) {
                        Button(SwipeReviewPresentation.selectAllTitle) {
                            env.selectAllSwipeCleanup()
                        }
                        .buttonStyle(NettoSecondaryButtonStyle())

                        Button(SwipeReviewPresentation.deselectAllTitle) {
                            env.deselectAllSwipeCleanup()
                        }
                        .buttonStyle(NettoSecondaryButtonStyle())
                    }
                }
                .padding(.vertical, Theme.Spacing.xs)
            }

            Section("Marked for cleanup") {
                ForEach(candidates) { item in
                    candidateRow(item)
                }
            }

            Section {
                Label(
                    SwipeReviewPresentation.keepExclusionNote,
                    systemImage: "heart"
                )
                Label(
                    SwipeReviewPresentation.confirmNote,
                    systemImage: "checkmark.shield"
                )
            } footer: {
                Text("Analysis, selection, and the scan are local to this iPhone.")
            }
            .font(.caption)
            .foregroundStyle(Theme.Palette.secondaryLabel)
        }
        .scrollContentBackground(.hidden)
        .background(NettoColor.background.ignoresSafeArea())
        .safeAreaInset(edge: .bottom) {
            reviewBar
        }
    }

    private func candidateRow(_ item: SwipeReviewItem) -> some View {
        let checked = checkedIDs.contains(item.assetID)
        return Button {
            env.setSwipeCleanupChecked(item.assetID, checked: !checked)
        } label: {
            HStack(spacing: Theme.Spacing.md) {
                PhotoThumbnailView(assetID: item.assetID, pointSize: 48, store: env.thumbnails)
                    .clipShape(RoundedRectangle(
                        cornerRadius: NettoLayout.Radius.control,
                        style: .continuous
                    ))

                VStack(alignment: .leading, spacing: 2) {
                    Text(rowLabel(for: item))
                        .font(.subheadline)
                        .foregroundStyle(NettoColor.textPrimary)
                    Text("Marked for cleanup")
                        .font(.caption)
                        .foregroundStyle(NettoColor.textSecondary)
                }

                Spacer()

                Image(systemName: checked ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(checked ? NettoColor.brandDeep : NettoColor.textSecondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(SwipeReviewPresentation.cleanupRowAccessibilityID(item.assetID))
        .accessibilityAddTraits(checked ? .isSelected : [])
    }

    private func rowLabel(for item: SwipeReviewItem) -> String {
        item.isLibraryItem ? "Photo" : SwipeReviewPresentation.kindLabel(item.groupKind)
    }

    /// The handoff: the checked subset enters the *existing* review screen as its own
    /// source. Disabled while nothing is checked — an empty plan can never be prepared, and
    /// opening the review to say so would be a dead end.
    private var reviewBar: some View {
        let enabled = SwipeReviewPresentation.reviewCleanupEnabled(selectedCount: selectedCount)
        return VStack(spacing: Theme.Spacing.sm) {
            Text(SwipeReviewPresentation.selectedForCleanupText(selectedCount))
                .font(NettoType.secondaryBody.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(NettoColor.brandDeep)
                .nettoCount(selectedCount)
                .accessibilityIdentifier(SwipeReviewPresentation.selectedCountAccessibilityID)

            NavigationLink {
                ReviewSelectionView(source: .swipeReview)
            } label: {
                Text(SwipeReviewPresentation.reviewButtonTitle(selectedCount))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(NettoPrimaryButtonStyle())
            .disabled(!enabled)
            .opacity(enabled ? 1 : 0.45)
            .accessibilityIdentifier(SwipeReviewPresentation.cleanupReviewAccessibilityID)
        }
        .frame(maxWidth: .infinity)
        .nettoFloatingBar()
    }
}

// MARK: - Previews

#Preview("Swipe Cleanup") {
    NavigationStack {
        SwipeCleanupSelectionView(
            model: SwipeReviewModel(items: SwipeReviewPresentation.items(from: PreviewData.result))
        )
    }
    .environment(PreviewData.environment(analysis: .completed(PreviewData.result)))
}

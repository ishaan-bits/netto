import SwiftUI

/// The final review before deletion: exactly what was selected, what is known about its size,
/// and the only place a destructive action can be started.
///
/// This screen never mutates anything by itself. The destructive button only opens a system
/// confirmation dialog; the dialog's confirm action is the sole call path into
/// `AppEnvironment.confirmDeletion()`, and the deletion service refuses to run from any state
/// other than `.awaitingConfirmation`. Counts, sizes, and staleness all come from the immutable
/// `DeletionPlan` through `DeletionPresentation` — this view stores nothing but the dialog flag.
struct ReviewSelectionView: View {
    @EnvironmentObject private var env: AppEnvironment
    @Environment(\.dismiss) private var dismiss
    @State private var showConfirmation = false

    /// Which selection this review was opened from. Both sources share the same plan →
    /// confirmation → mutation pipeline; the source only steers plan preparation and the
    /// empty-selection copy.
    var source: DeletionSelectionSource = .similarPhotos

    private var phase: DeletionReviewPhase {
        DeletionPresentation.phase(for: env.deletionState)
    }

    var body: some View {
        content
            .navigationTitle("Review & Delete")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear {
                env.reviewDidAppear(from: source)
            }
    }

    // MARK: Phase dispatch

    @ViewBuilder
    private var content: some View {
        switch phase {
        case .empty:
            if env.selectionCount(for: source) == 0 {
                ReviewPhaseMessage(
                    systemImage: "checkmark.circle",
                    title: "Nothing is marked",
                    message: source == .screenshots
                        ? "No screenshots are selected. Choose screenshots first, then come back to review them."
                        : "No photos are selected for cleanup. Pick photos inside a group first."
                )
            } else {
                buildingState
            }

        case .building:
            buildingState

        case .ready(let plan):
            reviewContent(plan)

        case .stale(let reasons):
            staleState(reasons)

        case .deleting:
            deletingState

        case .succeeded(let success):
            resultState(success, isPartial: false)

        case .needsReview(let success):
            resultState(success, isPartial: true)

        case .failed(let message):
            failureState(message)

        case .permissionRequired(let state):
            permissionState(state)
        }
    }

    // MARK: Review

    private func reviewContent(_ plan: DeletionPlan) -> some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                    Text("\(plan.count) \(plan.count == 1 ? "item" : "items") selected for deletion")
                        .font(.headline)
                    Text(DeletionPresentation.categorySummary(for: plan))
                        .font(.subheadline)
                        .foregroundStyle(Theme.Palette.secondaryLabel)
                    Text(DeletionPresentation.sizeMessage(for: plan))
                        .font(.subheadline.weight(.medium))
                        .monospacedDigit()
                }
                .padding(.vertical, Theme.Spacing.xs)
            }

            Section("To be deleted") {
                ForEach(plan.items) { item in
                    itemRow(item)
                }
            }

            Section {
                Label(
                    "Moved to Recently Deleted — recoverable for about 30 days.",
                    systemImage: "arrow.counterclockwise.circle"
                )
                Label(
                    "Only the items listed above are touched; nothing else in your library changes.",
                    systemImage: "checkmark.shield"
                )
                Text(DeletionPresentation.storageCaveat)
            } footer: {
                Text("Analysis, selection, and the scan are local to this iPhone.")
            }
            .font(.caption)
            .foregroundStyle(Theme.Palette.secondaryLabel)
        }
        .safeAreaInset(edge: .bottom) {
            actionBar(plan)
        }
        .confirmationDialog(
            "Delete \(plan.count) \(plan.count == 1 ? "photo" : "photos")?",
            isPresented: $showConfirmation,
            titleVisibility: .visible
        ) {
            Button(role: .destructive) {
                env.beginConfirmation()
                Task { await env.confirmDeletion() }
            } label: {
                Text(DeletionPresentation.destructiveTitle(for: plan))
            }
            Button("Keep Photos", role: .cancel) { }
        } message: {
            Text(DeletionPresentation.sizeMessage(for: plan)
                 + " — moved to Recently Deleted, not erased immediately.")
        }
    }

    private func itemRow(_ item: DeletionPlanItem) -> some View {
        HStack(spacing: Theme.Spacing.md) {
            PhotoThumbnailView(assetID: item.localIdentifier, pointSize: 48, store: env.thumbnails)
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.sm))

            VStack(alignment: .leading, spacing: 2) {
                Text(label(for: item))
                    .font(.subheadline)
                if let bytes = item.sizeInBytes {
                    Text(ByteFormat.string(bytes))
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(Theme.Palette.secondaryLabel)
                } else {
                    Text("Size unavailable")
                        .font(.caption)
                        .foregroundStyle(Theme.Palette.secondaryLabel)
                }
            }

            Spacer()

            Image(systemName: "trash")
                .foregroundStyle(Theme.Palette.danger)
        }
        .accessibilityElement(children: .combine)
    }

    private func label(for item: DeletionPlanItem) -> String {
        switch item.category {
        case .exactDuplicates:
            return item.mediaType == .video ? "Exact duplicate video" : "Exact duplicate"
        case .nearDuplicates:
            return item.mediaType == .video ? "Similar video" : "Similar photo"
        case nil:
            return item.mediaType == .video ? "Video" : "Photo"
        }
    }

    private func actionBar(_ plan: DeletionPlan) -> some View {
        HStack(spacing: Theme.Spacing.md) {
            Button {
                dismiss()
            } label: {
                Text("Change Selection")
            }
            .buttonStyle(.bordered)

            Spacer()

            Button(role: .destructive) {
                showConfirmation = true
            } label: {
                Text(DeletionPresentation.destructiveTitle(for: plan))
            }
            .buttonStyle(.borderedProminent)
            .tint(Theme.Palette.danger)
        }
        .padding(Theme.Spacing.md)
        .background(.bar)
    }

    // MARK: Other states

    private var buildingState: some View {
        VStack(spacing: Theme.Spacing.lg) {
            Spacer()
            ProgressView()
            Text("Preparing your review…")
                .font(.subheadline)
                .foregroundStyle(Theme.Palette.secondaryLabel)
            Text("Resolving real sizes for the selected items.")
                .font(.caption)
                .foregroundStyle(Theme.Palette.secondaryLabel)
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, Theme.Spacing.xl)
    }

    private var deletingState: some View {
        VStack(spacing: Theme.Spacing.lg) {
            Spacer()
            ProgressView()
            Text("Deleting…")
                .font(.headline)
            Text("Netto is removing exactly the items you reviewed. This cannot be undone from here — they stay recoverable in Recently Deleted.")
                .font(.subheadline)
                .foregroundStyle(Theme.Palette.secondaryLabel)
                .multilineTextAlignment(.center)
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, Theme.Spacing.xl)
    }

    private func staleState(_ reasons: [PlanStalenessReason]) -> some View {
        ReviewPhaseMessage(
            systemImage: "exclamationmark.arrow.circlepath",
            title: "Review out of date",
            message: DeletionPresentation.staleMessage(reasons),
            primaryTitle: "Review Again"
        ) {
            env.prepareDeletionPlan(from: source)
        }
    }

    private func resultState(_ success: DeletionSuccess, isPartial: Bool) -> some View {
        ReviewPhaseMessage(
            systemImage: isPartial ? "exclamationmark.circle" : "checkmark.circle.fill",
            title: isPartial ? "Some items remain" : "Moved to Recently Deleted",
            message: (isPartial
                      ? DeletionPresentation.partialMessage(for: success)
                      : DeletionPresentation.successMessage(for: success))
                + " " + DeletionPresentation.storageCaveat,
            primaryTitle: "Done"
        ) {
            env.dismissDeletionResult()
            dismiss()
        }
    }

    private func failureState(_ message: String) -> some View {
        ReviewPhaseMessage(
            systemImage: "exclamationmark.triangle",
            title: "Deletion failed",
            message: message,
            primaryTitle: "Review Again"
        ) {
            env.prepareDeletionPlan(from: source)
        }
    }

    private func permissionState(_ state: PermissionState) -> some View {
        ReviewPhaseMessage(
            systemImage: "lock.fill",
            title: "Photos access needed",
            message: DeletionPresentation.permissionMessage(for: state),
            primaryTitle: "Open Settings"
        ) {
            openSettings()
        }
    }

    private func openSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }
}

/// Full-screen state view for the non-review phases of this screen.
private struct ReviewPhaseMessage: View {
    let systemImage: String
    let title: String
    let message: String
    var primaryTitle: String?
    var primaryAction: () -> Void = {}

    var body: some View {
        VStack(spacing: Theme.Spacing.lg) {
            Spacer(minLength: Theme.Spacing.xl)
            Image(systemName: systemImage)
                .font(.system(size: 44))
                .foregroundStyle(Theme.Palette.accent)
            Text(title)
                .font(.title3.weight(.semibold))
                .multilineTextAlignment(.center)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(Theme.Palette.secondaryLabel)
                .multilineTextAlignment(.center)
                .padding(.horizontal, Theme.Spacing.xl)
            if let primaryTitle {
                Button(primaryTitle, action: primaryAction)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
            }
            Spacer(minLength: Theme.Spacing.xl)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Previews

#Preview("Review") {
    NavigationStack {
        ReviewSelectionView()
    }
    .environmentObject(PreviewData.environment(analysis: .completed(PreviewData.result)))
}

import SwiftUI

/// The SIMILAR PHOTOS review screen: every state the analysis pipeline can be in, and — when a
/// run completes — the group list, thumbnails, best-photo recommendation, and selection model.
///
/// All state is derived from `AppEnvironment` through `SimilarPhotosPresentation.phase`; this
/// view stores nothing itself except the currently open detail sheet. There is no deletion or
/// mutation API anywhere in this file — the only writes are selection changes.
struct SimilarPhotosView: View {
    @Environment(AppEnvironment.self) private var env: AppEnvironment
    @State private var detailTarget: DetailTarget?

    private struct DetailTarget: Identifiable {
        let group: PhotoSimilarityGroup
        let assetID: String
        var id: String { "\(group.id)#\(assetID)" }
    }

    private var phase: SimilarPhotosPhase {
        SimilarPhotosPresentation.phase(
            permission: env.photoPermissionState,
            catalog: env.catalogState,
            analysis: env.analysisState
        )
    }

    var body: some View {
        content
            .background(NettoColor.background.ignoresSafeArea())
            .navigationTitle("Similar Photos")
            .nettoAppear()
            .nettoStateTransition(phaseID)
            .onAppear { env.refreshPermissions() }
            .sheet(item: $detailTarget) { target in
                PhotoDetailView(group: target.group, assetID: target.assetID)
                    .environment(env)
            }
    }

    // MARK: Phase dispatch

    @ViewBuilder
    private var content: some View {
        switch phase {
        case .permissionRequired:
            PhaseMessage(
                systemImage: "photo.on.rectangle.angled",
                title: "Photos access needed",
                message: "Netto reads your photo library on this iPhone to find exact duplicates and similar shots. Images never leave your device.",
                buttonTitle: "Allow Photos Access"
            ) {
                Task { await env.requestPhotoAccess() }
            }

        case .permissionDenied:
            PhaseMessage(
                systemImage: "lock.fill",
                title: "Photos access is off",
                message: "Netto needs Photos access to find duplicates and similar shots. Enable it in Settings to continue.",
                buttonTitle: "Open Settings"
            ) {
                openSettings()
            }

        case .idle:
            PhaseMessage(
                systemImage: "square.stack.3d.up",
                title: "Find duplicates and similar shots",
                message: "Analysis runs entirely on this iPhone: exact copies by content hash, near-duplicates by visual similarity. Nothing is deleted until you confirm it on the final review screen.",
                buttonTitle: "Analyze Photo Library"
            ) {
                env.startSimilarityAnalysis()
            }

        case .buildingCatalog(let progress):
            progressState(
                message: catalogMessage(for: progress),
                fraction: progress.totalCount > 0 ? progress.fraction : nil,
                cancel: { env.cancelCatalogBuild() }
            )

        case .analyzing(let progress):
            progressState(
                message: SimilarPhotosPresentation.stageMessage(for: progress),
                fraction: SimilarPhotosPresentation.barFraction(for: progress),
                cancel: { env.cancelSimilarityAnalysis() }
            )

        case .paused(let stage, let fraction):
            // The run was interrupted (backgrounding, termination, lock) and saved its
            // checkpoint; resume continues it from the saved stage — never a fresh start.
            pausedState(stage: stage, fraction: fraction)

        case .cancelled:
            PhaseMessage(
                systemImage: "arrow.counterclockwise",
                title: "Analysis cancelled",
                message: "No results were produced. You can start again whenever you like.",
                buttonTitle: "Start Again"
            ) {
                env.startSimilarityAnalysis()
            }

        case .failed(let message):
            PhaseMessage(
                systemImage: "exclamationmark.triangle",
                title: "Analysis failed",
                message: message,
                buttonTitle: "Try Again"
            ) {
                env.startSimilarityAnalysis()
            }

        case .emptyLibrary:
            PhaseMessage(
                systemImage: "photo.badge.exclamationmark",
                title: "No photos visible to Netto",
                message: "There is nothing to analyze. If you granted limited access, add the photos you want Netto to see in Settings.",
                // The body asks the user to act in Settings — offer the action (U2);
                // a genuinely empty authorized library has no Settings action to offer.
                buttonTitle: env.photoPermissionState == .limited ? "Open Settings" : nil
            ) {
                openSettings()
            }

        case .results(let result):
            resultsContent(result)
        }
    }

    // MARK: States

    private func progressState(
        message: String,
        fraction: Double?,
        cancel: @escaping () -> Void
    ) -> some View {
        NettoProgressPanel(message: message, fraction: fraction, cancel: cancel)
    }

    /// The paused counterpart of `progressState`: the saved stage (with the saved percent,
    /// when one existed), no cancel action (nothing is running), no ETA (the estimator was
    /// reset with the pause) — the single action is Resume, which continues the saved run.
    private func pausedState(stage: String, fraction: Double?) -> some View {
        let savedPercent = fraction.map {
            "\(Int(($0 * 100).rounded()))% complete — "
        } ?? ""
        return PhaseMessage(
            systemImage: "pause.circle",
            title: "Scan paused",
            message: "\(stage) \(savedPercent)Nothing was changed — resume to continue where it stopped.",
            buttonTitle: "Resume"
        ) {
            env.resumeInterruptedWork()
        }
    }

    // MARK: Results

    private func resultsContent(_ result: PhotoAnalysisResult) -> some View {
        let summary = SimilarPhotosSummary(result: result)
        return Group {
            if summary.hasNoGroups {
                noGroupsContent(result, summary: summary)
            } else {
                groupsList(result, summary: summary)
            }
        }
    }

    private func groupsList(_ result: PhotoAnalysisResult, summary: SimilarPhotosSummary) -> some View {
        List {
            if SimilarPhotosPresentation.showsLimitedAccessNotice(permission: env.photoPermissionState) {
                Section {
                    Label(
                        "Only the photos you selected for Netto are analyzed.",
                        systemImage: "info.circle"
                    )
                    .font(.caption)
                    .foregroundStyle(NettoColor.warning)
                }
            }

            if summary.unavailableCount > 0 {
                Section {
                    Label(
                        "\(summary.unavailableCount) items could not be analyzed (iCloud-only, unreadable, or no longer present).",
                        systemImage: "exclamationmark.triangle"
                    )
                    .font(.caption)
                    .foregroundStyle(Theme.Palette.secondaryLabel)
                }
            }

            Section {
                summaryHeader(result, summary: summary)
            }

            if !result.exactGroups.isEmpty {
                Section("Exact Duplicates") {
                    ForEach(result.exactGroups) { group in
                        groupRow(group)
                    }
                }
            }

            if !result.similarGroups.isEmpty {
                Section("Similar Photos") {
                    ForEach(result.similarGroups) { group in
                        groupRow(group)
                    }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(NettoColor.background.ignoresSafeArea())
        .safeAreaInset(edge: .top, spacing: 0) {
            selectionToolbar
        }
        .safeAreaInset(edge: .bottom) {
            selectionBar
        }
    }

    // MARK: Top selection toolbar

    /// Compact selection controls at the top of the screen, next to the live selection state.
    /// Exposes exactly two actions — "Deselect All" and "Reset to Recommended" (see
    /// `SimilarPhotosPresentation.selectionToolbarActions`; no bulk "Select All") — and never
    /// sits beside the bottom Review action, which stays focused on "N photos selected →
    /// Review". Every action is selection-only: nothing deletes, rescans, or touches the
    /// analysis results or their KEEP recommendations.
    private var selectionToolbar: some View {
        HStack(spacing: Theme.Spacing.md) {
            Text("\(env.selection.selectedCount) selected")
                .font(.subheadline.weight(.semibold))
                .monospacedDigit()
                .lineLimit(1)
                .nettoCount(env.selection.selectedCount)
                .accessibilityIdentifier("selectionStateLabel")

            Spacer(minLength: Theme.Spacing.xs)

            // Secondary selection-management control: subtle text + small chevron on the
            // shared glass — never a capsule or accent color that could compete with the
            // bottom Review button, which stays the screen's only primary action.
            Menu {
                ForEach(SimilarPhotosPresentation.selectionToolbarActions, id: \.rawValue) { action in
                    if SimilarPhotosPresentation.shows(action, selectedCount: env.selection.selectedCount) {
                        Button(action.rawValue) {
                            perform(action)
                        }
                        .accessibilityIdentifier(SimilarPhotosPresentation.selectionActionIdentifier(action))
                    }
                }
            } label: {
                HStack(spacing: 2) {
                    Text(SimilarPhotosPresentation.selectionToolbarMenuLabel)
                    Image(systemName: "chevron.down")
                        .font(.caption2.weight(.semibold))
                }
                .font(.subheadline.weight(.medium))
                .foregroundStyle(Theme.Palette.secondaryLabel)
                .lineLimit(1)
            }
            .menuIndicator(.hidden)
            .accessibilityValue(
                SimilarPhotosPresentation.selectionToolbarAccessibilityValue(
                    selectedCount: env.selection.selectedCount
                )
            )
            .accessibilityIdentifier("selectionMenu")
        }
        .padding(Theme.Spacing.md)
        .nettoGlass()
        .padding(.horizontal, Theme.Spacing.md)
        .padding(.top, Theme.Spacing.xs)
    }

    private func perform(_ action: SimilarPhotosPresentation.SelectionToolbarAction) {
        switch action {
        case .deselectAll:
            env.mutateSelection { $0.deselectAll() }
        case .resetToRecommended:
            env.mutateSelection { $0.resetToRecommended() }
        }
    }

    private func summaryHeader(_ result: PhotoAnalysisResult, summary: SimilarPhotosSummary) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("\(summary.exactGroupCount) duplicate groups · \(summary.similarGroupCount) similar groups")
                .font(.subheadline.weight(.semibold))
            Text("\(summary.groupedAssetCount) photos involved · analyzed on this iPhone")
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(Theme.Palette.secondaryLabel)
            if let threshold = result.similarityThreshold {
                Text("Similarity threshold \(String(format: "%.2f", threshold)) over \(result.candidatePairCount) compared pairs")
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(Theme.Palette.secondaryLabel)
            }
        }
        .padding(.vertical, Theme.Spacing.xs)
    }

    private func noGroupsContent(_ result: PhotoAnalysisResult, summary: SimilarPhotosSummary) -> some View {
        VStack(spacing: Theme.Spacing.lg) {
            if SimilarPhotosPresentation.showsLimitedAccessNotice(permission: env.photoPermissionState) {
                limitedNotice
            }
            if summary.unavailableCount > 0 {
                unavailableNotice(summary)
            }
            PhaseMessage(
                systemImage: "checkmark.seal",
                title: "No duplicates found",
                message: SimilarPhotosPresentation.noDuplicatesMessage(result: result),
                buttonTitle: "Analyze Again"
            ) {
                env.startSimilarityAnalysis()
            }
        }
    }

    private var limitedNotice: some View {
        Label(
            "Only the photos you selected for Netto are analyzed.",
            systemImage: "info.circle"
        )
        .font(.caption)
        .foregroundStyle(NettoColor.warning)
        .padding(.horizontal, Theme.Spacing.lg)
        .padding(.top, Theme.Spacing.lg)
    }

    private func unavailableNotice(_ summary: SimilarPhotosSummary) -> some View {
        Label(
            "\(summary.unavailableCount) items could not be analyzed (iCloud-only, unreadable, or no longer present).",
            systemImage: "exclamationmark.triangle"
        )
        .font(.caption)
        .foregroundStyle(Theme.Palette.secondaryLabel)
        .padding(.horizontal, Theme.Spacing.lg)
    }

    private func groupRow(_ group: PhotoSimilarityGroup) -> some View {
        SimilarPhotoGroupRow(
            group: group,
            selection: env.selection,
            store: env.thumbnails,
            onToggle: { assetID in
                env.mutateSelection { $0.toggle(assetID) }
            },
            onSelectAllExceptRecommended: {
                env.mutateSelection { $0.selectAllExceptRecommended(inGroup: group.id) }
            },
            onClear: {
                env.mutateSelection { $0.clearGroup(group.id) }
            },
            onKeepRecommended: {
                env.mutateSelection { $0.keepRecommended(inGroup: group.id) }
            },
            onOpenDetail: { assetID in
                detailTarget = DetailTarget(group: group, assetID: assetID)
            }
        )
    }

    // MARK: Bottom bar

    private var selectionBar: some View {
        HStack(spacing: Theme.Spacing.md) {
            VStack(alignment: .leading, spacing: 0) {
                Text("\(env.selection.selectedCount) photos selected")
                    .font(.subheadline.weight(.semibold))
                    .monospacedDigit()
                    .nettoCount(env.selection.selectedCount)
                Text("Nothing is deleted yet")
                    .font(.caption2)
                    .foregroundStyle(Theme.Palette.secondaryLabel)
            }

            Spacer()

            // Selection management (Deselect All / Reset to Recommended) lives in the top
            // toolbar — this action row stays focused on the count and Review.
            NavigationLink {
                ReviewSelectionView()
            } label: {
                Text(SimilarPhotosPresentation.primaryReviewActionLabel)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(NettoPrimaryButtonStyle())
            .disabled(env.selection.selectedCount == 0)
            .opacity(env.selection.selectedCount == 0 ? 0.45 : 1)
        }
        .nettoFloatingBar()
    }

    /// The state *category* on screen — never the payload, so a progress tick or a changing
    /// error string cannot remount the screen.
    private var phaseID: String {
        switch phase {
        case .permissionRequired: return "permissionRequired"
        case .permissionDenied: return "permissionDenied"
        case .idle: return "idle"
        case .buildingCatalog: return "buildingCatalog"
        case .analyzing: return "analyzing"
        case .paused: return "paused"
        case .cancelled: return "cancelled"
        case .failed: return "failed"
        case .emptyLibrary: return "emptyLibrary"
        case .results: return "results"
        }
    }

    // MARK: Helpers

    private func catalogMessage(for progress: CatalogScanProgress) -> String {
        progress.totalCount > 0
            ? "Reading \(progress.enumeratedCount) of \(progress.totalCount) assets…"
            : "Counting assets…"
    }

    private func openSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }
}

/// Shared full-screen state view for the non-results phases (also used by ScreenshotsView,
/// VideosView, and DuplicateContactsView).
struct PhaseMessage: View {
    let systemImage: String
    let title: String
    let message: String
    var buttonTitle: String?
    var buttonAction: () -> Void = {}

    private var isPositive: Bool {
        systemImage.hasPrefix("checkmark") || systemImage.hasPrefix("person.crop.circle.badge")
    }

    var body: some View {
        VStack(spacing: NettoLayout.Spacing.lg) {
            Spacer(minLength: NettoLayout.Spacing.xl)

            ZStack {
                Circle()
                    .fill((isPositive ? NettoColor.success : NettoColor.brand).opacity(0.16))
                    .frame(width: 96, height: 96)
                Image(systemName: systemImage)
                    .font(.system(size: 38, weight: .semibold))
                    .foregroundStyle(isPositive ? NettoColor.success : NettoColor.brand)
                    .nettoSuccessPop(isPositive)
            }
            .accessibilityHidden(true)

            Text(title)
                .font(NettoType.sectionTitle)
                .foregroundStyle(NettoColor.textPrimary)
                .multilineTextAlignment(.center)

            Text(message)
                .font(NettoType.secondaryBody)
                .foregroundStyle(NettoColor.textSecondary)
                .multilineTextAlignment(.center)
                .lineSpacing(3)
                .padding(.horizontal, NettoLayout.Spacing.xl)

            if let buttonTitle {
                Button(buttonTitle, action: buttonAction)
                    .buttonStyle(NettoPrimaryButtonStyle())
                    .padding(.horizontal, NettoLayout.Spacing.xl)
            }

            Spacer(minLength: NettoLayout.Spacing.xl)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .nettoAppear()
    }
}

// MARK: - Previews

#Preview("Results") {
    NavigationStack {
        SimilarPhotosView()
    }
    .environment(PreviewData.environment(analysis: .completed(PreviewData.result)))
}

#Preview("Idle") {
    NavigationStack {
        SimilarPhotosView()
    }
    .environment(PreviewData.environment())
}

#Preview("Analyzing") {
    NavigationStack {
        SimilarPhotosView()
    }
    .environment(
        PreviewData.environment(
            analysis: .running(PhotoAnalysisProgress(stage: .comparing, completedUnits: 7, totalUnits: 19))
        )
    )
}

#Preview("Permission") {
    NavigationStack {
        SimilarPhotosView()
    }
    .environment(PreviewData.environment(permission: .notDetermined))
}

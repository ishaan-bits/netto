import SwiftUI

/// The Old Screenshots screen — the screenshot subset of the catalog, age-filtered.
///
/// A screenshot is "old" when its `creationDate` is at least `OldScreenshotsPresentation
/// .defaultAgeThresholdDays` old. A screenshot with no known creation date is never counted
/// as old — it is reported separately as an unknown-date count, because guessing an age
/// would be fabricating evidence. Selection goes through the existing `screenshotSelection`
/// and the existing `.screenshots` review source, so review → confirmation → mutation →
/// verification is unchanged.
struct OldScreenshotsView: View {
    @Environment(AppEnvironment.self) private var env: AppEnvironment

    private var phase: OldScreenshotsPresentation.Phase {
        OldScreenshotsPresentation.phase(
            permission: env.photoPermissionState,
            catalog: env.catalogState
        )
    }

    private var phaseID: String {
        switch phase {
        case .permissionRequired: return "permissionRequired"
        case .permissionDenied: return "permissionDenied"
        case .buildingCatalog: return "buildingCatalog"
        case .paused: return "paused"
        case .scanRequired: return "scanRequired"
        case .failed: return "failed"
        case .noScreenshots: return "noScreenshots"
        case .results: return "results"
        }
    }

    var body: some View {
        content
            .background(NettoColor.background.ignoresSafeArea())
            .navigationTitle("Old Screenshots")
            .nettoAppear()
            .nettoStateTransition(phaseID)
            .onAppear {
                env.refreshPermissions()
                env.synchronizeScreenshotDataset()
            }
            .onChange(of: env.catalogState) { _, _ in
                env.synchronizeScreenshotDataset()
            }
    }

    @ViewBuilder
    private var content: some View {
        switch phase {
        case .permissionRequired:
            PhaseMessage(
                systemImage: "clock.badge.questionmark",
                title: "Photos access needed",
                message: "Netto reads your library's metadata on this iPhone to find screenshots older than \(OldScreenshotsPresentation.defaultAgeThresholdDays) days. Nothing is deleted until you confirm it on the review screen.",
                buttonTitle: "Allow Photos Access"
            ) { Task { await env.requestPhotoAccess() } }

        case .permissionDenied:
            PhaseMessage(
                systemImage: "lock.fill",
                title: "Photos access is off",
                message: "Netto needs Photos access to show your old screenshots. Enable it in Settings to continue.",
                buttonTitle: "Open Settings"
            ) { openSettings() }

        case .scanRequired:
            PhaseMessage(
                systemImage: "photo.stack",
                title: "Find your old screenshots",
                message: "Netto reads your library's metadata on this iPhone and lists screenshots older than \(OldScreenshotsPresentation.defaultAgeThresholdDays) days, oldest first. Nothing is deleted until you confirm it on the review screen.",
                buttonTitle: "Build Catalog"
            ) { env.startCatalogBuild() }

        case .buildingCatalog(let progress):
            NettoProgressPanel(
                message: progress.totalCount > 0
                    ? "Reading \(progress.enumeratedCount) of \(progress.totalCount) assets…"
                    : "Counting assets…",
                fraction: progress.totalCount > 0 ? progress.fraction : nil,
                cancel: { env.cancelCatalogBuild() }
            )

        case .paused(let stage):
            PhaseMessage(
                systemImage: "pause.circle",
                title: "Scan paused",
                message: "\(stage) Nothing was changed — resume to continue where it stopped.",
                buttonTitle: "Resume"
            ) { env.resumeInterruptedWork() }

        case .failed(let message):
            PhaseMessage(
                systemImage: "exclamationmark.triangle",
                title: "Scan failed",
                message: message,
                buttonTitle: "Try Again"
            ) { env.startCatalogBuild() }

        case .noScreenshots:
            PhaseMessage(
                systemImage: "checkmark.seal",
                title: "No screenshots found",
                message: env.photoPermissionState == .limited
                    ? "None of the photos you granted Netto are screenshots. If you granted limited access, add more in Settings."
                    : "Nothing in your library is flagged as a screenshot."
            )

        case .results(let count, let unknownDateCount):
            if count == 0 {
                emptyResults(unknownDateCount: unknownDateCount)
            } else {
                resultsContent(
                    records: env.oldScreenshotRecords,
                    unknownDateCount: unknownDateCount
                )
            }
        }
    }

    // MARK: Empty-after-filter

    private func emptyResults(unknownDateCount: Int) -> some View {
        PhaseMessage(
            systemImage: "checkmark.seal",
            title: "None are old enough",
            message: emptyMessage(unknownDateCount: unknownDateCount)
        )
    }

    private func emptyMessage(unknownDateCount: Int) -> String {
        var message = "Every screenshot is newer than \(OldScreenshotsPresentation.defaultAgeThresholdDays) days."
        if unknownDateCount > 0 {
            message += " \(unknownDateCount) more \(unknownDateCount == 1 ? "has" : "have") no recorded date, so Netto can't tell how old \(unknownDateCount == 1 ? "it is" : "they are") and never counts them as old."
        }
        return message
    }

    // MARK: Results

    private func resultsContent(records: [PhotoAssetRecord], unknownDateCount: Int) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: NettoLayout.Spacing.md) {
                if ScreenshotsPresentation.showsLimitedAccessNotice(permission: env.photoPermissionState) {
                    limitedNotice
                }
                thresholdExplainer
                summaryHeader(count: records.count, unknownDateCount: unknownDateCount)
                screenshotGrid(records)
            }
            .padding(NettoLayout.Spacing.lg)
        }
        .safeAreaInset(edge: .bottom) { selectionBar }
    }

    private var limitedNotice: some View {
        Label(
            "Only the photos you selected for Netto are shown.",
            systemImage: "info.circle"
        )
        .font(.caption)
        .foregroundStyle(NettoColor.warning)
    }

    /// The rule, stated on screen, so the user always knows why an item appears.
    private var thresholdExplainer: some View {
        Text("Showing screenshots at least \(OldScreenshotsPresentation.defaultAgeThresholdDays) days old, oldest first. Nothing is selected or deleted automatically.")
            .font(NettoType.caption)
            .foregroundStyle(NettoColor.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("oldScreenshotsThresholdExplainer")
    }

    private func summaryHeader(count: Int, unknownDateCount: Int) -> some View {
        VStack(alignment: .leading, spacing: NettoLayout.Spacing.xxs) {
            Text("\(count) old \(count == 1 ? "screenshot" : "screenshots")")
                .font(NettoType.metricNumber)
                .monospacedDigit()
                .foregroundStyle(NettoColor.textPrimary)
            if unknownDateCount > 0 {
                Text("\(unknownDateCount) more with no recorded date — not counted as old")
                    .font(NettoType.caption)
                    .foregroundStyle(NettoColor.warning)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("oldScreenshotsSummary")
    }

    private func screenshotGrid(_ records: [PhotoAssetRecord]) -> some View {
        let columns = [GridItem(.adaptive(minimum: 100), spacing: Theme.Spacing.sm)]
        return LazyVGrid(columns: columns, spacing: Theme.Spacing.sm) {
            ForEach(records, id: \.localIdentifier) { record in
                cell(for: record)
            }
        }
    }

    private func cell(for record: PhotoAssetRecord) -> some View {
        let isSelected = env.screenshotSelection.isSelected(record.localIdentifier)
        return Button {
            env.mutateScreenshotSelection { $0.toggle(record.localIdentifier) }
        } label: {
            PhotoThumbnailView(
                assetID: record.localIdentifier,
                pointSize: 100,
                store: env.thumbnails
            )
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.sm))
            .overlay {
                RoundedRectangle(cornerRadius: Theme.Radius.sm)
                    .stroke(isSelected ? NettoColor.brandIndicator : .clear, lineWidth: 3)
            }
            .overlay(alignment: .topTrailing) {
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.subheadline)
                        .foregroundStyle(NettoColor.onBrandIndicator)
                        .padding(5)
                        .background(Circle().fill(NettoColor.brandIndicator))
                        .padding(6)
                        .transition(.scale(scale: 0.4).combined(with: .opacity))
                }
            }
        }
        .nettoPress()
        .nettoAnimate(.selection, value: isSelected)
        .accessibilityLabel(
            "Screenshot" + (record.creationDate.map {
                ", \($0.formatted(date: .abbreviated, time: .omitted))"
            } ?? ", no recorded date")
        )
        .accessibilityValue(isSelected ? "Selected" : "Not selected")
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    private var selectionBar: some View {
        HStack(spacing: Theme.Spacing.md) {
            VStack(alignment: .leading, spacing: 0) {
                Text("\(env.screenshotSelection.selectedCount) of \(env.screenshotSelection.datasetCount) screenshots selected")
                    .font(.subheadline.weight(.semibold))
                    .monospacedDigit()
                Text("Nothing is deleted yet")
                    .font(.caption2)
                    .foregroundStyle(Theme.Palette.secondaryLabel)
            }
            Spacer()
            NavigationLink {
                ReviewSelectionView(source: .screenshots)
            } label: {
                Text("Review").frame(maxWidth: .infinity)
            }
            .buttonStyle(NettoPrimaryButtonStyle())
            .disabled(env.screenshotSelection.selectedCount == 0)
            .opacity(env.screenshotSelection.selectedCount == 0 ? 0.45 : 1)
        }
        .nettoFloatingBar()
    }

    private func openSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }
}

#Preview("Old Screenshots · results") {
    NavigationStack {
        OldScreenshotsView()
    }
    .environment(
        PreviewData.environment(catalog: .completed(ScreenshotsFixture.completed))
    )
}

#Preview("Old Screenshots · none old enough") {
    NavigationStack {
        OldScreenshotsView()
    }
    .environment(
        PreviewData.environment(catalog: .completed(ScreenshotsFixture.noScreenshotsResult))
    )
}

#Preview("Old Screenshots · permission") {
    NavigationStack {
        OldScreenshotsView()
    }
    .environment(PreviewData.environment(permission: .notDetermined))
}

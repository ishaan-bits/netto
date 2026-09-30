import SwiftUI

/// The SCREENSHOTS cleanup screen: the screenshot subset of the existing catalog, in a
/// selection grid that feeds the shared review → confirmation → mutation → verification
/// pipeline.
///
/// Screenshot identity comes from the PhotoKit subtype recorded during enumeration — no
/// filename, OCR, Vision, EXIF, or dimension guessing. All state is derived from
/// `AppEnvironment` through `ScreenshotsPresentation.phase`; the only writes this view makes
/// are selection changes. Thumbnails go through the same bounded `ThumbnailStore` as the
/// review UI — never full-resolution pixels.
struct ScreenshotsView: View {
    @EnvironmentObject private var env: AppEnvironment

    private var phase: ScreenshotsPhase {
        ScreenshotsPresentation.phase(
            permission: env.photoPermissionState,
            catalog: env.catalogState
        )
    }

    private let columns = [
        GridItem(.adaptive(minimum: 100), spacing: Theme.Spacing.sm)
    ]

    /// The state *category* on screen — never the payload, so a progress tick cannot remount
    /// the grid.
    private var phaseID: String {
        switch phase {
        case .permissionRequired: return "permissionRequired"
        case .permissionDenied: return "permissionDenied"
        case .scanRequired: return "scanRequired"
        case .buildingCatalog: return "buildingCatalog"
        case .failed: return "failed"
        case .empty: return "empty"
        case .results: return "results"
        }
    }

    var body: some View {
        content
            .background(NettoColor.background.ignoresSafeArea())
            .navigationTitle("Screenshots")
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

    // MARK: Phase dispatch

    @ViewBuilder
    private var content: some View {
        switch phase {
        case .permissionRequired:
            PhaseMessage(
                systemImage: "photo.on.rectangle.angled",
                title: "Photos access needed",
                message: "Netto reads your photo library metadata on this iPhone to find screenshots. Images never leave your device, and nothing is deleted until you confirm it on the review screen.",
                buttonTitle: "Allow Photos Access"
            ) {
                Task { await env.requestPhotoAccess() }
            }

        case .permissionDenied:
            PhaseMessage(
                systemImage: "lock.fill",
                title: "Photos access is off",
                message: "Netto needs Photos access to show your screenshots. Enable it in Settings to continue.",
                buttonTitle: "Open Settings"
            ) {
                openSettings()
            }

        case .scanRequired:
            PhaseMessage(
                systemImage: "photo.stack",
                title: "Find your screenshots",
                message: "Netto reads your library's metadata on this iPhone and shows everything flagged as a screenshot. Nothing is deleted until you confirm it on the final review screen.",
                buttonTitle: "Build Catalog"
            ) {
                env.startCatalogBuild()
            }

        case .buildingCatalog(let progress):
            progressState(
                message: progress.totalCount > 0
                    ? "Reading \(progress.enumeratedCount) of \(progress.totalCount) assets…"
                    : "Counting assets…",
                fraction: progress.totalCount > 0 ? progress.fraction : nil,
                cancel: { env.cancelCatalogBuild() }
            )

        case .failed(let message):
            PhaseMessage(
                systemImage: "exclamationmark.triangle",
                title: "Scan failed",
                message: message,
                buttonTitle: "Try Again"
            ) {
                env.startCatalogBuild()
            }

        case .empty:
            VStack(spacing: Theme.Spacing.lg) {
                if ScreenshotsPresentation.showsLimitedAccessNotice(permission: env.photoPermissionState) {
                    limitedNotice
                }
                PhaseMessage(
                    systemImage: "checkmark.seal",
                    title: "No screenshots found",
                    message: env.photoPermissionState == .limited
                        ? "None of the photos you granted Netto are flagged as screenshots. If you granted limited access, add more photos in Settings."
                        : "Nothing in your library is flagged as a screenshot."
                )
            }

        case .results(let records):
            resultsContent(records)
        }
    }

    // MARK: Results

    private func resultsContent(_ records: [PhotoAssetRecord]) -> some View {
        ScrollView {
            if ScreenshotsPresentation.showsLimitedAccessNotice(permission: env.photoPermissionState) {
                limitedNotice
                    .padding(.horizontal, Theme.Spacing.md)
                    .padding(.top, Theme.Spacing.md)
            }

            summaryHeader(count: records.count)
                .padding(.horizontal, Theme.Spacing.md)
                .padding(.top, Theme.Spacing.md)

            LazyVGrid(columns: columns, spacing: Theme.Spacing.sm) {
                ForEach(records, id: \.localIdentifier) { record in
                    cell(for: record)
                }
            }
            .padding(Theme.Spacing.md)
        }
        .background(NettoColor.background.ignoresSafeArea())
        .safeAreaInset(edge: .bottom) { selectionBar }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                selectAllButton
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
                    .stroke(isSelected ? NettoColor.brand : .clear, lineWidth: 3)
            }
            .overlay(alignment: .topTrailing) {
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.subheadline)
                        .foregroundStyle(.white)
                        .padding(5)
                        .background(Circle().fill(NettoColor.brand))
                        .padding(6)
                        .transition(.scale(scale: 0.4).combined(with: .opacity))
                }
            }
        }
        .nettoPress()
        .nettoAnimate(.selection, value: isSelected)
        .accessibilityLabel("Screenshot")
        .accessibilityValue(isSelected ? "Selected" : "Not selected")
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    private var selectAllButton: some View {
        Button(env.screenshotSelection.isAllSelected ? "Deselect All" : "Select All") {
            env.mutateScreenshotSelection { model in
                if model.isAllSelected {
                    model.deselectAll()
                } else {
                    model.selectAll()
                }
            }
        }
    }

    private var limitedNotice: some View {
        Label(
            "Only the photos you selected for Netto are shown.",
            systemImage: "info.circle"
        )
        .font(.caption)
        .foregroundStyle(Theme.Palette.warning)
    }

    // MARK: Bottom bar

    private var selectionBar: some View {
        HStack(spacing: Theme.Spacing.md) {
            VStack(alignment: .leading, spacing: 0) {
                Text("\(env.screenshotSelection.selectedCount) of \(env.screenshotSelection.datasetCount) screenshots selected")
                    .font(.subheadline.weight(.semibold))
                    .monospacedDigit()
                    .nettoCount(env.screenshotSelection.selectedCount)
                Text("Nothing is deleted yet")
                    .font(.caption2)
                    .foregroundStyle(Theme.Palette.secondaryLabel)
            }

            Spacer()

            NavigationLink {
                ReviewSelectionView(source: .screenshots)
            } label: {
                Text("Review")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(NettoPrimaryButtonStyle())
            .disabled(env.screenshotSelection.selectedCount == 0)
            .opacity(env.screenshotSelection.selectedCount == 0 ? 0.45 : 1)
        }
        .nettoFloatingBar()
    }

    // MARK: Helpers

    private func progressState(
        message: String,
        fraction: Double?,
        cancel: @escaping () -> Void
    ) -> some View {
        NettoProgressPanel(message: message, fraction: fraction, cancel: cancel)
    }

    /// Real, counted total — nothing here is estimated.
    private func summaryHeader(count: Int) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: NettoLayout.Spacing.sm) {
            Text("\(count)")
                .font(NettoType.metricNumber)
                .monospacedDigit()
                .foregroundStyle(NettoColor.textPrimary)
                .nettoCount(count)
            Text(count == 1 ? "screenshot" : "screenshots")
                .font(NettoType.secondaryBody)
                .foregroundStyle(NettoColor.textSecondary)
            Spacer(minLength: NettoLayout.Spacing.sm)
            Text("flagged on this iPhone")
                .font(NettoType.caption)
                .foregroundStyle(NettoColor.textTertiary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(count) screenshots flagged on this iPhone")
    }

    private func openSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }
}

// MARK: - Previews

#Preview("Results") {
    NavigationStack {
        ScreenshotsView()
    }
    .environmentObject(
        PreviewData.environment(catalog: .completed(ScreenshotsFixture.completed))
    )
}

#Preview("Scan Required") {
    NavigationStack {
        ScreenshotsView()
    }
    .environmentObject(PreviewData.environment())
}

#Preview("Building Catalog") {
    NavigationStack {
        ScreenshotsView()
    }
    .environmentObject(
        PreviewData.environment(
            catalog: .running(CatalogScanProgress(enumeratedCount: 40, totalCount: 120))
        )
    )
}

#Preview("Empty") {
    NavigationStack {
        ScreenshotsView()
    }
    .environmentObject(
        PreviewData.environment(catalog: .completed(ScreenshotsFixture.noScreenshotsResult))
    )
}

#Preview("Permission") {
    NavigationStack {
        ScreenshotsView()
    }
    .environmentObject(PreviewData.environment(permission: .notDetermined))
}

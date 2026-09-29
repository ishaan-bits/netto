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

    var body: some View {
        content
            .navigationTitle("Screenshots")
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
            LazyVGrid(columns: columns, spacing: Theme.Spacing.sm) {
                ForEach(records, id: \.localIdentifier) { record in
                    cell(for: record)
                }
            }
            .padding(Theme.Spacing.md)
        }
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
                    .stroke(isSelected ? Theme.Palette.accent : .clear, lineWidth: 3)
            }
            .overlay(alignment: .topTrailing) {
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.subheadline)
                        .foregroundStyle(.white)
                        .padding(5)
                        .background(Circle().fill(Theme.Palette.accent))
                        .padding(6)
                }
            }
        }
        .buttonStyle(.plain)
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
                Text("Nothing is deleted yet")
                    .font(.caption2)
                    .foregroundStyle(Theme.Palette.secondaryLabel)
            }

            Spacer()

            NavigationLink {
                ReviewSelectionView(source: .screenshots)
            } label: {
                Text("Review")
            }
            .buttonStyle(.borderedProminent)
            .disabled(env.screenshotSelection.selectedCount == 0)
        }
        .padding(Theme.Spacing.md)
        .background(.bar)
    }

    // MARK: Helpers

    private func progressState(
        message: String,
        fraction: Double?,
        cancel: @escaping () -> Void
    ) -> some View {
        VStack(spacing: Theme.Spacing.lg) {
            Spacer()
            if let fraction {
                ProgressView(value: fraction)
                    .progressViewStyle(.linear)
                    .tint(Theme.Palette.accent)
                    .frame(maxWidth: 260)
            } else {
                ProgressView()
            }
            Text(message)
                .font(.subheadline)
                .monospacedDigit()
                .multilineTextAlignment(.center)
            Button("Cancel", action: cancel)
                .buttonStyle(.bordered)
                .controlSize(.small)
            Spacer()
        }
        .padding(.horizontal, Theme.Spacing.xl)
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

import SwiftUI

/// The Video Cleanup screen — every video in the library in **one** list, sorted by
/// measured size, largest first (the Large Files shape, applied to videos).
///
/// - **Measured first.** Videos whose exact local file size is known are listed largest
///   first. Sizes come only from the shared size provider: nothing is inferred from
///   dimensions, duration, thumbnails, or any fabricated estimate.
/// - **Unknowns below, honestly labelled.** Videos whose size is unknown are listed after
///   every measured video — never ranked as zero. The section says "Sizes not measured yet"
///   until an attempt has actually failed, then "iCloud / size unavailable" for the ids the
///   run tried and could not measure — a row never claims a failure it has not earned.
/// - **Scans automatically, keeps its results.** Measurement starts when the screen
///   appears and continues from whatever is already measured — opening the screen never
///   re-measures known sizes, and the completed sizes are persisted (checkpoint) so they
///   survive leaving the screen and relaunching the app. Only the **Rescan** button
///   discards them and measures everything again, exactly like the Contacts screen's
///   Rescan.
///
/// Deletion goes through the existing review → confirmation → verification pipeline via
/// the `.videos` source, which is exactly the selection model this screen writes into —
/// nothing on this screen deletes anything.
struct VideoCleanupView: View {
    @Environment(AppEnvironment.self) private var env: AppEnvironment

    private var phase: VideosPhase {
        VideosPresentation.phase(
            permission: env.photoPermissionState,
            catalog: env.catalogState,
            resolution: env.videoSizeResolution,
            datasetSignature: env.videoDatasetSignature,
            settledRecords: env.videoRecordsForDisplay
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
        case .empty: return "empty"
        case .measuringVideos: return "measuringVideos"
        case .results: return "results"
        }
    }

    var body: some View {
        content
            .background(NettoColor.background.ignoresSafeArea())
            .navigationTitle("Video Cleanup")
            .nettoAppear()
            .nettoStateTransition(phaseID)
            .onAppear {
                env.refreshPermissions()
                env.synchronizeVideoDataset()
                env.startVideoSizeResolution()
            }
            .onChange(of: env.catalogState) { _, _ in
                env.synchronizeVideoDataset()
                env.startVideoSizeResolution()
            }
            .onChange(of: env.photoPermissionState) { _, _ in
                env.startVideoSizeResolution()
            }
            // Belt-and-braces: measurement no longer yields to analysis passes (it runs
            // alongside them), but if it was ever left paused, a pass finishing restarts
            // it without any user action.
            .onChange(of: env.analysisState.isRunning) { _, running in
                if !running { env.resumeVideoSizeMeasurement() }
            }
            .onChange(of: env.blurAnalysisState.isRunning) { _, running in
                if !running { env.resumeVideoSizeMeasurement() }
            }
            // Deliberately no cancel-on-disappear: the bounded measurement keeps filling
            // the shared size state while other screens are open (app backgrounding still
            // checkpoint-cancels it, and the next visit continues from what is measured).
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    switch phase {
                    case .measuringVideos, .results:
                        Button("Rescan") { env.rescanVideoSizes() }
                            .accessibilityIdentifier("videoRescanButton")
                    default:
                        EmptyView()
                    }
                }
            }
    }

    // MARK: Phase dispatch

    @ViewBuilder
    private var content: some View {
        switch phase {
        case .permissionRequired:
            PhaseMessage(
                systemImage: "internaldrive",
                title: "Photos access needed",
                message: "Netto reads your library's metadata on this iPhone and measures video sizes locally to list your largest videos. Nothing is deleted until you confirm it on the review screen.",
                buttonTitle: "Allow Photos Access"
            ) { Task { await env.requestPhotoAccess() } }

        case .permissionDenied:
            PhaseMessage(
                systemImage: "lock.fill",
                title: "Photos access is off",
                message: "Netto needs Photos access to measure your video sizes. Enable it in Settings to continue.",
                buttonTitle: "Open Settings"
            ) { openSettings() }

        case .scanRequired:
            PhaseMessage(
                systemImage: "internaldrive",
                title: "Find your largest videos",
                message: "Netto reads your library's metadata on this iPhone, measures video sizes locally, and shows everything largest first. Nothing is deleted until you confirm it on the review screen.",
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

        case .empty:
            PhaseMessage(
                systemImage: "checkmark.seal",
                title: "No videos found",
                message: env.photoPermissionState == .limited
                    ? "None of the photos you granted Netto are videos. If you granted limited access, add more in Settings."
                    : "Nothing in your library is a video."
            )

        case .measuringVideos(let measured, let total, let unavailable):
            // Enumeration is already complete: the full list renders immediately and the
            // measurement only fills sizes in — the screen never waits on it.
            inventoryContent(
                records: env.videoRecordsForDisplay,
                measured: measured,
                total: total,
                unavailable: unavailable
            )

        case .results(let records):
            let measurement = env.videoSizeResolution.measurement
            inventoryContent(
                records: records,
                measured: measurement?.measuredCount ?? records.count,
                total: measurement?.total ?? records.count,
                unavailable: measurement?.unavailableCount ?? 0
            )
        }
    }

    // MARK: Inventory (list first; measurement fills sizes in)

    private func inventoryContent(
        records: [PhotoAssetRecord],
        measured: Int,
        total: Int,
        unavailable: Int
    ) -> some View {
        // `records` already carries the dataset's order: known sizes largest-first, then
        // the unknowns (never zero, never ranked). The two sections below only label that
        // order — the counts all come from the same list.
        let known = records.filter(\.isSizeKnown)
        let unknown = records.filter { !$0.isSizeKnown }
        // Which unknowns were actually *attempted* (this dataset's failures) — unknowns
        // nothing has tried yet claim "not measured", never "unavailable".
        let attemptedIDs = env.videoSizeResolution.isCurrent(for: env.videoDatasetSignature)
            ? env.videoSizeResolution.measurement?.unavailableIDs ?? []
            : []
        let attemptedCount = unknown.filter { attemptedIDs.contains($0.localIdentifier) }.count
        return ScrollView {
            VStack(alignment: .leading, spacing: NettoLayout.Spacing.lg) {
                if VideosPresentation.showsLimitedAccessNotice(permission: env.photoPermissionState) {
                    limitedNotice
                }
                summaryHeader(known: known, unknown: unknown)

                if env.videoSizeResolution.isMeasuring {
                    NettoProgressPanel(
                        message: VideosPresentation.measuringMessage(
                            measured: measured,
                            total: total,
                            unavailable: unavailable,
                            isActive: true
                        ),
                        fraction: total > 0 ? Double(measured + unavailable) / Double(total) : nil,
                        cancel: { env.cancelVideoSizeResolution() }
                    )
                }

                if !known.isEmpty {
                    section("Largest first", records: known, attemptedIDs: [])
                }
                if !unknown.isEmpty {
                    section(
                        VideosPresentation.videoUnknownSectionTitle(attempted: attemptedCount),
                        records: unknown,
                        attemptedIDs: attemptedIDs
                    )
                    if attemptedCount > 0 {
                        cloudNote
                    }
                }
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

    /// Honest scope note for the unavailable group: Netto measures only what is stored on
    /// this iPhone, never downloads a video just to read its size, and names iCloud as the
    /// typical reason without claiming it as proven for every asset.
    private var cloudNote: some View {
        Text("Netto measures only videos stored on this iPhone — it never downloads a video just to read its size. These typically live in iCloud.")
            .font(NettoType.caption)
            .foregroundStyle(NettoColor.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func summaryHeader(known: [PhotoAssetRecord], unknown: [PhotoAssetRecord]) -> some View {
        let summaryLine = VideosPresentation.videoCleanupSummaryLine(
            known: known,
            unknown: unknown,
            resolution: env.videoSizeResolution,
            datasetSignature: env.videoDatasetSignature
        )
        return VStack(alignment: .leading, spacing: NettoLayout.Spacing.xxs) {
            Text("\(known.count + unknown.count) videos")
                .font(NettoType.metricNumber)
                .monospacedDigit()
                .foregroundStyle(NettoColor.textPrimary)
            Text(summaryLine)
                .font(NettoType.caption)
                .foregroundStyle(NettoColor.textSecondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("videoCleanupSummary")
    }

    private func section(
        _ title: String,
        records: [PhotoAssetRecord],
        attemptedIDs: Set<String>
    ) -> some View {
        VStack(alignment: .leading, spacing: NettoLayout.Spacing.sm) {
            Text(title)
                .font(NettoType.sectionTitle)
                .foregroundStyle(NettoColor.textPrimary)
            LazyVStack(spacing: NettoLayout.Spacing.sm) {
                ForEach(records, id: \.localIdentifier) { record in
                    VideoCleanupRow(
                        record: record,
                        attempted: attemptedIDs.contains(record.localIdentifier),
                        isSelected: env.videoSelection.isSelected(record.localIdentifier),
                        store: env.thumbnails,
                        toggle: {
                            env.mutateVideoSelection { $0.toggle(record.localIdentifier) }
                        }
                    )
                }
            }
        }
    }

    // MARK: Bottom bar

    private var selectionBar: some View {
        HStack(spacing: NettoLayout.Spacing.md) {
            VStack(alignment: .leading, spacing: 0) {
                Text("\(env.videoSelection.selectedCount) of \(env.videoSelection.datasetCount) selected")
                    .font(.subheadline.weight(.semibold))
                    .monospacedDigit()
                Text("Nothing is deleted yet")
                    .font(.caption2)
                    .foregroundStyle(Theme.Palette.secondaryLabel)
            }
            Spacer()
            NavigationLink {
                ReviewSelectionView(source: .videos)
            } label: {
                Text("Review").frame(maxWidth: .infinity)
            }
            .buttonStyle(NettoPrimaryButtonStyle())
            .disabled(env.videoSelection.selectedCount == 0)
            .opacity(env.videoSelection.selectedCount == 0 ? 0.45 : 1)
        }
        .nettoFloatingBar()
    }

    private func openSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }
}

/// One video row: thumbnail, duration, honest size, and the selection check. A measured
/// size shows its exact bytes; an attempted-but-unmeasurable one says so plainly (warning);
/// an untouched one says it has not been measured yet — never zero, never a failure it
/// has not earned.
private struct VideoCleanupRow: View {
    let record: PhotoAssetRecord
    let attempted: Bool
    let isSelected: Bool
    let store: ThumbnailStore
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: NettoLayout.Spacing.md) {
                PhotoThumbnailView(
                    assetID: record.localIdentifier,
                    pointSize: 72,
                    store: store
                )
                .frame(width: 72, height: 72)
                .clipShape(RoundedRectangle(cornerRadius: NettoLayout.Radius.control, style: .continuous))

                VStack(alignment: .leading, spacing: NettoLayout.Spacing.xxs) {
                    Text(VideosPresentation.durationText(record.duration))
                        .font(NettoType.secondaryBody.weight(.semibold))
                        .foregroundStyle(NettoColor.textPrimary)
                    Text(caption.text)
                        .font(NettoType.caption)
                        .foregroundStyle(caption.isWarning ? NettoColor.warning : NettoColor.textSecondary)
                    if let date = record.creationDate {
                        Text(date.formatted(date: .abbreviated, time: .omitted))
                            .font(NettoType.caption)
                            .foregroundStyle(NettoColor.textTertiary)
                    }
                }

                Spacer(minLength: NettoLayout.Spacing.md)

                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(isSelected ? NettoColor.brandIndicator : NettoColor.textTertiary)
            }
            .padding(NettoLayout.Spacing.md)
            .nettoSurface(.elevated, cornerRadius: NettoLayout.Radius.card)
            .overlay {
                RoundedRectangle(cornerRadius: NettoLayout.Radius.card, style: .continuous)
                    .stroke(isSelected ? NettoColor.brandIndicator : .clear, lineWidth: 2)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Video, \(VideosPresentation.durationText(record.duration))")
        .accessibilityValue(isSelected ? "Selected" : "Not selected")
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    private var caption: (text: String, isWarning: Bool) {
        VideosPresentation.videoCleanupSizeCaption(bytes: record.sizeInBytes, attempted: attempted)
    }
}

#Preview("Video Cleanup") {
    NavigationStack {
        VideoCleanupView()
    }
    .environment(
        PreviewData.environment(
            catalog: .completed(VideosFixture.completed),
            videoResolution: VideosFixture.settledPartial
        )
    )
}

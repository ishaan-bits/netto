import SwiftUI

/// The unified VIDEO CLEANUP inventory (M14): the video subset of the existing catalog,
/// rendered immediately and measured for size in the background — known sizes first
/// (largest to smallest), the size-unavailable group below them. One list; never split by
/// source. Feeds the shared review → confirmation → mutation → verification pipeline.
///
/// Video identity comes from the media type already bridged into `PhotoAssetRecord` during
/// enumeration — no filename, codec, or dimension heuristic exists here. Sizes are measured
/// automatically when the screen appears (bounded, cancellable, local-only) because the
/// largest-first ordering is the whole point: an unmeasured video is shown as *unknown*,
/// listed after every measured one, never ranked as the smallest, and never as zero. There
/// is no separate "Measure Sizes" button — measurement starts on appear and resumes when a
/// heavy pass finishes; the inventory itself never waits on it. All state is derived
/// through `VideosPresentation.phase`; the only writes this view makes are selection
/// changes and size-resolution start/cancel. Thumbnails come from the same bounded
/// `ThumbnailStore` as the review UI — poster frames via PhotoKit, never an
/// `AVAssetImageGenerator` per row.
struct VideosView: View {
    @Environment(AppEnvironment.self) private var env: AppEnvironment
    @State private var previewedVideo: PhotoAssetRecord?

    private var phase: VideosPhase {
        VideosPresentation.phase(
            permission: env.photoPermissionState,
            catalog: env.catalogState,
            resolution: env.videoSizeResolution,
            datasetSignature: env.videoDatasetSignature,
            settledRecords: env.videoRecordsForDisplay
        )
    }

    /// The state *category* on screen — never the payload, so a progress tick cannot remount
    /// the list.
    private var phaseID: String {
        switch phase {
        case .permissionRequired: return "permissionRequired"
        case .permissionDenied: return "permissionDenied"
        case .scanRequired: return "scanRequired"
        case .buildingCatalog: return "buildingCatalog"
        case .failed: return "failed"
        case .empty: return "empty"
        case .measuringVideos: return "measuringVideos"
        case .paused: return "paused"
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
            // Heavy passes suspend measurement while they run (the AppEnvironment guards
            // refuse the start); the moment either finishes, the kept progress continues —
            // without this observer, a measurement interrupted by a pass would sit settled
            // and partial until the screen was reopened.
            .onChange(of: env.analysisState.isRunning) { _, running in
                if !running { env.resumeVideoSizeMeasurement() }
            }
            .onChange(of: env.blurAnalysisState.isRunning) { _, running in
                if !running { env.resumeVideoSizeMeasurement() }
            }
            // Measurement is *not* cancelled on navigation (M15-R1): leaving for review or
            // another screen must not strand the inventory in a partial state — the bounded
            // pass keeps filling the shared size state while other consumers read it. The
            // app-backgrounding path checkpoint-cancels it as before, and re-entry resumes.
            .fullScreenCover(item: $previewedVideo) { record in
                VideoPreviewView(
                    assetID: record.localIdentifier,
                    duration: record.duration
                )
            }
    }

    // MARK: Phase dispatch

    @ViewBuilder
    private var content: some View {
        switch phase {
        case .permissionRequired:
            PhaseMessage(
                systemImage: "video",
                title: "Photos access needed",
                message: "Netto reads your photo library metadata on this iPhone to find videos. Images never leave your device, and nothing is deleted until you confirm it on the review screen.",
                buttonTitle: "Allow Photos Access"
            ) {
                Task { await env.requestPhotoAccess() }
            }

        case .permissionDenied:
            PhaseMessage(
                systemImage: "lock.fill",
                title: "Photos access is off",
                message: "Netto needs Photos access to show your videos. Enable it in Settings to continue.",
                buttonTitle: "Open Settings"
            ) {
                openSettings()
            }

        case .scanRequired:
            PhaseMessage(
                systemImage: "video",
                title: "Find your largest videos",
                message: "Netto reads your library's metadata on this iPhone, measures video sizes locally, and shows everything largest first. Nothing is deleted until you confirm it on the final review screen.",
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
                if VideosPresentation.showsLimitedAccessNotice(permission: env.photoPermissionState) {
                    limitedNotice
                }
                PhaseMessage(
                    systemImage: "checkmark.seal",
                    title: "No videos found",
                    message: env.photoPermissionState == .limited
                        ? "None of the photos you granted Netto are videos. If you granted limited access, add more photos in Settings."
                        : "Nothing in your library is a video.",
                    // The limited copy tells the user to act in Settings — offer the
                    // action (U2); the non-limited copy names no next step.
                    buttonTitle: env.photoPermissionState == .limited ? "Open Settings" : nil
                ) {
                    openSettings()
                }
            }

        case .measuringVideos(let measured, _, let unavailable):
            // Enumeration is already complete — the full inventory renders immediately and
            // measurement only fills sizes in; the screen never waits on measurement.
            // (The phase's `total` equals the display records' count — both are the
            // catalog's videos — so the list and the counts can never disagree.)
            inventoryContent(
                records: env.videoRecordsForDisplay,
                measured: measured,
                unavailable: unavailable,
                isActive: !env.videoSizeResolution.isIdle
            )

        case .paused(let stage):
            // A run feeding this screen was interrupted and saved its checkpoint; Resume
            // continues it from where it stopped.
            PhaseMessage(
                systemImage: "pause.circle",
                title: "Scan paused",
                message: "\(stage) Nothing was changed — resume to continue where it stopped.",
                buttonTitle: "Resume"
            ) {
                env.resumeInterruptedWork()
            }

        case .results(let records):
            let measurement = env.videoSizeResolution.measurement
            inventoryContent(
                records: records,
                measured: measurement?.measuredCount ?? records.count,
                unavailable: measurement?.unavailableCount ?? 0,
                isActive: false
            )
        }
    }

    // MARK: Inventory (list first; measurement fills sizes in)

    private func inventoryContent(
        records: [PhotoAssetRecord],
        measured: Int,
        unavailable: Int,
        isActive: Bool
    ) -> some View {
        // The catalog's ordering is preserved: known sizes largest-first, unknowns after
        // (VideoDataset.sorted). The two groups below only *label* that order — the total
        // and both counts come from the same records, so they can never disagree.
        let measuredRecords = records.filter(\.isSizeKnown)
        let unavailableRecords = records.filter { !$0.isSizeKnown }
        return List {
            if VideosPresentation.showsLimitedAccessNotice(permission: env.photoPermissionState) {
                Section {
                    limitedNotice
                }
            }

            Section {
                VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                    ForEach(
                        Array(
                            VideosPresentation.inventorySummary(
                                total: records.count,
                                measured: measured,
                                unavailable: unavailable
                            ).enumerated()
                        ),
                        id: \.offset
                    ) { _, line in
                        Text(line)
                            .font(.caption)
                            .foregroundStyle(NettoColor.textSecondary)
                    }

                    if isActive {
                        NettoProgressPanel(
                            message: VideosPresentation.measuringMessage(
                                measured: measured,
                                total: records.count,
                                unavailable: unavailable,
                                isActive: true
                            ),
                            fraction: records.count > 0
                                ? Double(measured + unavailable) / Double(records.count)
                                : nil,
                            cancel: { env.cancelVideoSizeResolution() }
                        )
                    }
                }
                .padding(.vertical, Theme.Spacing.xs)
            }

            // Measured first — largest to smallest — then the size-unavailable group.
            // No source split: every video the catalog holds is in this one list.
            if !measuredRecords.isEmpty {
                Section("Measured — largest first") {
                    ForEach(measuredRecords) { record in
                        row(for: record)
                    }
                }
            }

            if !unavailableRecords.isEmpty {
                Section {
                    ForEach(unavailableRecords) { record in
                        row(for: record)
                    }
                } header: {
                    Text("Size unavailable")
                } footer: {
                    Text("Sizes that were not measured locally are listed here — never guessed, never ranked as the smallest.")
                }
            }

            Section {
                EmptyView()
            } footer: {
                Text("Tap a video to preview it. Nothing is deleted until you confirm on the review screen.")
            }
        }
        .scrollContentBackground(.hidden)
        .background(NettoColor.background.ignoresSafeArea())
        .safeAreaInset(edge: .bottom) { selectionBar }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                selectAllButton
            }
        }
    }

    private func row(for record: PhotoAssetRecord) -> some View {
        VideoInventoryRow(
            record: record,
            isKnownUnavailable: env.videoSizeResolution.measurement?
                .unavailableIDs.contains(record.localIdentifier) ?? false,
            isBeingMeasured: env.videoSizeResolution.isMeasuring,
            isSelected: env.videoSelection.isSelected(record.localIdentifier),
            store: env.thumbnails,
            onPreview: { previewedVideo = record },
            toggle: { env.mutateVideoSelection { $0.toggle(record.localIdentifier) } }
        )
    }

    private var selectAllButton: some View {
        Button(env.videoSelection.isAllSelected ? "Deselect All" : "Select All") {
            env.mutateVideoSelection { model in
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
        .foregroundStyle(NettoColor.warning)
    }

    // MARK: Bottom bar

    private var selectionBar: some View {
        HStack(spacing: Theme.Spacing.md) {
            VStack(alignment: .leading, spacing: 0) {
                Text("\(env.videoSelection.selectedCount) of \(env.videoSelection.datasetCount) videos selected")
                    .font(.subheadline.weight(.semibold))
                    .monospacedDigit()
                    .nettoCount(env.videoSelection.selectedCount)
                Text("Nothing is deleted yet")
                    .font(.caption2)
                    .foregroundStyle(Theme.Palette.secondaryLabel)
            }

            Spacer()

            NavigationLink {
                ReviewSelectionView(source: .videos)
            } label: {
                Text("Review")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(NettoPrimaryButtonStyle())
            .disabled(env.videoSelection.selectedCount == 0)
            .opacity(env.videoSelection.selectedCount == 0 ? 0.45 : 1)
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

    private func openSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }
}

// MARK: - Previews

#Preview("Results") {
    NavigationStack {
        VideosView()
    }
    .environment(previewEnvironment(
        catalog: VideosFixture.completed,
        resolution: VideosFixture.settledPartial
    ))
}

#Preview("Measuring") {
    NavigationStack {
        VideosView()
    }
    .environment(previewEnvironment(
        catalog: VideosFixture.completed,
        resolution: .measuring(
            VideoSizeResolution.Measurement(
                datasetSignature: VideoDataset.signature(in: VideosFixture.completed),
                bytes: ["video-01": 240_000_000],
                total: VideosFixture.videos.count
            )
        )
    ))
}

#Preview("Scan Required") {
    NavigationStack {
        VideosView()
    }
    .environment(PreviewData.environment())
}

#Preview("Empty") {
    NavigationStack {
        VideosView()
    }
    .environment(previewEnvironment(
        catalog: VideosFixture.noVideosResult,
        resolution: .idle
    ))
}

#Preview("Permission") {
    NavigationStack {
        VideosView()
    }
    .environment(PreviewData.environment(permission: .notDetermined))
}

@MainActor
private func previewEnvironment(
    catalog: CatalogScanResult,
    resolution: VideoSizeResolution
) -> AppEnvironment {
    let env = PreviewData.environment(catalog: .completed(catalog))
    env.videoSizeResolution = resolution
    return env
}

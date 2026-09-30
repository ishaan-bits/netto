import SwiftUI

/// The LARGE VIDEOS cleanup screen: the video subset of the existing catalog, measured for
/// size and sorted largest first, feeding the shared review → confirmation → mutation →
/// verification pipeline.
///
/// Video identity comes from the media type already bridged into `PhotoAssetRecord` during
/// enumeration — no filename, codec, or dimension heuristic exists here. Sizes are measured
/// explicitly for this screen (bounded, cancellable, local-only) because the largest-first
/// ordering is the whole point: an unmeasured video is shown as *unknown*, listed after every
/// measured one, never ranked as the smallest. All state is derived through
/// `VideosPresentation.phase`; the only writes this view makes are selection changes and
/// size-resolution start/cancel. Thumbnails come from the same bounded `ThumbnailStore` as the
/// review UI — poster frames via PhotoKit, never an `AVAssetImageGenerator` per row.
struct VideosView: View {
    @EnvironmentObject private var env: AppEnvironment
    @State private var previewedVideo: PhotoAssetRecord?

    private var phase: VideosPhase {
        VideosPresentation.phase(
            permission: env.photoPermissionState,
            catalog: env.catalogState,
            resolution: env.videoSizeResolution
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
        case .results: return "results"
        }
    }

    var body: some View {
        content
            .background(NettoColor.background.ignoresSafeArea())
            .navigationTitle("Large Videos")
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
            // Leaving the screen during measurement cancels it: the progress kept so far is
            // kept (as a settled, possibly partial state), the rest is simply not measured.
            .onDisappear { env.cancelVideoSizeResolution() }
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
                        ? "None of the photos you granted Netto are videos. If you granted limited access, add more in Settings."
                        : "Nothing in your library is a video."
                )
            }

        case .measuringVideos(let measured, let total):
            progressState(
                message: total > 0
                    ? "Measuring video sizes… \(measured) of \(total) done"
                    : "Measuring video sizes…",
                fraction: total > 0 ? Double(measured) / Double(total) : nil,
                cancel: { env.cancelVideoSizeResolution() }
            )

        case .results(let records):
            resultsContent(records)
        }
    }

    // MARK: Results

    private func resultsContent(_ records: [PhotoAssetRecord]) -> some View {
        List {
            if VideosPresentation.showsLimitedAccessNotice(permission: env.photoPermissionState) {
                Section {
                    limitedNotice
                }
            }

            if let measurement = env.videoSizeResolution.measurement, measurement.isPartial {
                Section {
                    VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                        Label(
                            "\(measurement.measuredCount) of \(measurement.total) sizes measured. Videos with an unknown size are listed after every measured one.",
                            systemImage: "exclamationmark.circle"
                        )
                        .font(.caption)
                        .foregroundStyle(Theme.Palette.warning)
                        Button("Measure Sizes") {
                            env.resumeVideoSizeMeasurement()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                    .padding(.vertical, Theme.Spacing.xs)
                }
            }

            Section {
                ForEach(records) { record in
                    row(for: record)
                }
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
        let isSelected = env.videoSelection.isSelected(record.localIdentifier)
        return HStack(spacing: Theme.Spacing.md) {
            Button {
                previewedVideo = record
            } label: {
                HStack(spacing: Theme.Spacing.md) {
                    thumbnail(for: record)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(VideosPresentation.durationText(record.duration))
                            .font(.subheadline.weight(.semibold))
                            .monospacedDigit()
                        Text(metadataLine(for: record))
                            .font(.caption)
                            .foregroundStyle(Theme.Palette.secondaryLabel)
                            .lineLimit(1)
                        if let bytes = record.sizeInBytes {
                            Text(ByteFormat.string(bytes))
                                .font(.subheadline.weight(.medium))
                                .monospacedDigit()
                        } else {
                            Text("Size unavailable")
                                .font(.subheadline)
                                .foregroundStyle(Theme.Palette.warning)
                        }
                    }
                }
            }
            .nettoPress()
            .accessibilityLabel(previewAccessibilityLabel(for: record))
            .accessibilityHint("Opens the video preview")

            Spacer(minLength: Theme.Spacing.sm)

            Button {
                env.mutateVideoSelection { $0.toggle(record.localIdentifier) }
            } label: {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(
                        isSelected ? NettoColor.brand : Theme.Palette.secondaryLabel
                    )
            }
            .nettoPress()
            .nettoAnimate(.selection, value: isSelected)
            .accessibilityLabel("Select video")
            .accessibilityValue(isSelected ? "Selected" : "Not selected")
            .accessibilityAddTraits(isSelected ? [.isSelected] : [])
        }
        .contentShape(Rectangle())
    }

    /// Poster frame through the shared thumbnail store (PhotoKit delivers a still for videos;
    /// a cloud-only video degrades to the standard placeholder) with a play affordance on top.
    private func thumbnail(for record: PhotoAssetRecord) -> some View {
        ZStack {
            PhotoThumbnailView(
                assetID: record.localIdentifier,
                pointSize: 72,
                store: env.thumbnails
            )
            .clipShape(RoundedRectangle(cornerRadius: NettoLayout.Radius.control, style: .continuous))

            RoundedRectangle(cornerRadius: NettoLayout.Radius.control, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [.clear, .black.opacity(0.45)],
                        startPoint: .center,
                        endPoint: .bottom
                    )
                )

            Image(systemName: "play.fill")
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 34, height: 34)
                .background(.ultraThinMaterial, in: Circle())
                .environment(\.colorScheme, .dark)
                .shadow(radius: 3, y: 1)
        }
        .frame(width: 72, height: 72)
        .accessibilityHidden(true)
    }

    private func metadataLine(for record: PhotoAssetRecord) -> String {
        let resolution = "\(record.pixelWidth)×\(record.pixelHeight)"
        guard let date = record.creationDate else { return resolution }
        return "\(resolution) · \(date.formatted(date: .abbreviated, time: .omitted))"
    }

    private func previewAccessibilityLabel(for record: PhotoAssetRecord) -> String {
        let size = record.sizeInBytes.map(ByteFormat.string) ?? "size unavailable"
        return "Video, \(VideosPresentation.durationText(record.duration)), \(size)"
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
        .foregroundStyle(Theme.Palette.warning)
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
    .environmentObject(previewEnvironment(
        catalog: VideosFixture.completed,
        resolution: VideosFixture.settledPartial
    ))
}

#Preview("Measuring") {
    NavigationStack {
        VideosView()
    }
    .environmentObject(previewEnvironment(
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
    .environmentObject(PreviewData.environment())
}

#Preview("Empty") {
    NavigationStack {
        VideosView()
    }
    .environmentObject(previewEnvironment(
        catalog: VideosFixture.noVideosResult,
        resolution: .idle
    ))
}

#Preview("Permission") {
    NavigationStack {
        VideosView()
    }
    .environmentObject(PreviewData.environment(permission: .notDetermined))
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

import SwiftUI

/// One source-filtered slice of the shared video inventory — the screen behind each Video
/// Cleanup destination.
///
/// It reads the existing `videoRecordsForDisplay` inventory (already resolved against the
/// measurement and sorted largest-first) and filters to a single `VideoSourceClassification`.
/// Selection lives in the shared `videoSelection`, so the review → confirmation → mutation →
/// verification pipeline and its deletion-safety guarantees are exactly the ones every other
/// video surface already uses. No measurement is started on appear; the screen offers it.
struct VideoInventoryView: View {
    @Environment(AppEnvironment.self) private var env: AppEnvironment
    let source: VideoSourceClassification

    private var records: [PhotoAssetRecord] {
        switch source {
        case .recorded: return env.recordedVideosForDisplay
        case .downloaded: return env.downloadedVideosForDisplay
        case .other: return []
        }
    }

    private var measurementActive: Bool { env.videoSizeResolution.isMeasuring }

    private var title: String {
        switch source {
        case .recorded: return "Recorded Videos"
        case .downloaded: return "Downloaded Videos"
        case .other: return "Other Videos"
        }
    }

    var body: some View {
        Group {
            switch VideosPresentation.phase(
                permission: env.photoPermissionState,
                catalog: env.catalogState,
                resolution: env.videoSizeResolution,
                datasetSignature: env.videoDatasetSignature,
                settledRecords: env.videoRecordsForDisplay
            ) {
            case .permissionRequired:
                PhaseMessage(
                    systemImage: "video",
                    title: "Photos access needed",
                    message: "Netto reads your library's metadata on this iPhone to list videos. Nothing is downloaded, and nothing is deleted until you confirm it on the review screen.",
                    buttonTitle: "Allow Photos Access"
                ) { Task { await env.requestPhotoAccess() } }

            case .permissionDenied:
                PhaseMessage(
                    systemImage: "lock.fill",
                    title: "Photos access is off",
                    message: "Netto needs Photos access to show your videos. Enable it in Settings to continue.",
                    buttonTitle: "Open Settings"
                ) { openSettings() }

            case .scanRequired:
                PhaseMessage(
                    systemImage: "video",
                    title: "Find your videos",
                    message: "Netto reads your library's metadata on this iPhone and measures video sizes locally, largest first. Nothing is deleted until you confirm it on the review screen.",
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
                        : "Nothing in your library is flagged as a video."
                )

            case .measuringVideos, .results:
                inventoryContent
            }
        }
        .background(NettoColor.background.ignoresSafeArea())
        .navigationTitle(title)
        .nettoAppear()
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
        .onChange(of: env.analysisState.isRunning) { _, running in
            if !running { env.resumeVideoSizeMeasurement() }
        }
        .onChange(of: env.blurAnalysisState.isRunning) { _, running in
            if !running { env.resumeVideoSizeMeasurement() }
        }
        .onDisappear { env.cancelVideoSizeResolution() }
    }

    // MARK: Inventory

    @ViewBuilder
    private var inventoryContent: some View {
        let shown = records
        if shown.isEmpty {
            PhaseMessage(
                systemImage: "video.slash",
                title: "None found",
                message: emptyMessage
            )
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: NettoLayout.Spacing.md) {
                    if VideosPresentation.showsLimitedAccessNotice(permission: env.photoPermissionState) {
                        Label(
                            "Only the photos you selected for Netto are shown.",
                            systemImage: "info.circle"
                        )
                        .font(.caption)
                        .foregroundStyle(NettoColor.warning)
                    }

                    summaryHeader(shown)
                    sourceExplainer

                    if measurementActive {
                        measuringPanel(shown)
                    } else if case .measuringVideos = VideosPresentation.phase(
                        permission: env.photoPermissionState,
                        catalog: env.catalogState,
                        resolution: env.videoSizeResolution,
                        datasetSignature: env.videoDatasetSignature,
                        settledRecords: env.videoRecordsForDisplay
                    ) {
                        measurePrompt(shown)
                    }

                    videoList(shown)
                }
                .padding(NettoLayout.Spacing.lg)
            }
            .safeAreaInset(edge: .bottom) { selectionBar }
        }
    }

    private var emptyMessage: String {
        switch source {
        case .recorded:
            return "No videos from this device's library were found among the photos Netto can see."
        case .downloaded:
            return "No iTunes-synced video imports were found among the photos Netto can see."
        case .other:
            return "No videos with an unconfirmed source were found."
        }
    }

    private var sourceExplainer: some View {
        Text(explainerText)
            .font(NettoType.caption)
            .foregroundStyle(NettoColor.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var explainerText: String {
        switch source {
        case .recorded:
            return "Videos your library reports as local library assets. This includes camera recordings and screen recordings."
        case .downloaded:
            return "Videos your library reports as synced from iTunes. Netto never downloads cloud-only videos to measure or classify them."
        case .other:
            return "Videos whose source evidence is neither a plain library asset nor an iTunes-synced import. Shown honestly rather than guessed into a bucket."
        }
    }

    private func summaryHeader(_ shown: [PhotoAssetRecord]) -> some View {
        let measured = shown.filter(\.isSizeKnown).count
        let unavailable = shown.count - measured
        return VStack(alignment: .leading, spacing: NettoLayout.Spacing.xxs) {
            Text("\(shown.count) \(shown.count == 1 ? "video" : "videos")")
                .font(NettoType.metricNumber)
                .monospacedDigit()
                .foregroundStyle(NettoColor.textPrimary)
            Text("sorted by measured size · \(measured) measured · \(unavailable) size unavailable")
                .font(NettoType.caption)
                .foregroundStyle(NettoColor.textSecondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("videoInventorySummary")
    }

    private func measuringPanel(_ shown: [PhotoAssetRecord]) -> some View {
        let measured = shown.filter(\.isSizeKnown).count
        return NettoProgressPanel(
            message: VideosPresentation.measuringMessage(
                measured: measured,
                total: shown.count,
                unavailable: shown.count - measured,
                isActive: true
            ),
            fraction: shown.isEmpty ? nil : Double(measured) / Double(shown.count),
            cancel: { env.cancelVideoSizeResolution() }
        )
    }

    private func measurePrompt(_ shown: [PhotoAssetRecord]) -> some View {
        Button("Measure Sizes") { env.startVideoSizeResolution() }
            .buttonStyle(NettoPrimaryButtonStyle())
            .frame(maxWidth: .infinity)
    }

    private func videoList(_ shown: [PhotoAssetRecord]) -> some View {
        LazyVStack(spacing: NettoLayout.Spacing.sm) {
            ForEach(shown, id: \.localIdentifier) { record in
                VideoInventoryRow(
                    record: record,
                    isSelected: env.videoSelection.isSelected(record.localIdentifier),
                    store: env.thumbnails,
                    toggle: {
                        env.mutateVideoSelection { $0.toggle(record.localIdentifier) }
                    }
                )
            }
        }
    }

    // MARK: Selection bar

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

/// One video row: poster thumbnail, duration, honest size (measured bytes or an explicit
/// "size unavailable"), and the selection check. Reuses the shared thumbnail store.
private struct VideoInventoryRow: View {
    let record: PhotoAssetRecord
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
                    Text(sizeText)
                        .font(NettoType.caption)
                        .foregroundStyle(record.isSizeKnown ? NettoColor.textSecondary : NettoColor.warning)
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
        .accessibilityLabel("\(VideosPresentation.durationText(record.duration)) video")
        .accessibilityValue(isSelected ? "Selected" : "Not selected")
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    private var sizeText: String {
        if let bytes = record.sizeInBytes {
            return ByteFormat.string(bytes)
        }
        return "Size unavailable — stored in iCloud or not measured"
    }
}

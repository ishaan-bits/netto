import SwiftUI

/// The Large Files screen — the library's videos sorted by measured size, largest first.
///
/// Sizes come only from the shared size provider: nothing is inferred from dimensions,
/// thumbnails, or any fabricated estimate. An asset whose size could not be measured
/// (cloud-only, unreadable) is listed in its own clearly-labelled section after every
/// measured asset — never ranked as zero. Deletion goes through the existing review →
/// confirmation → verification pipeline via the `.videos` source, which is exactly the
/// selection model this screen writes into.
///
/// Photos are not listed here. A photo's size is only measurable one at a time through the
/// content-editing-input path, so ranking the whole library's photos by size would mean
/// eagerly measuring thousands of assets on every visit. That is not a safe, bounded thing
/// to do behind a navigation tap, so this screen does not fake it: it ranks what it can
/// measure honestly (videos), and photos keep their existing destinations (Similar Images,
/// Blurry Images, Screenshots), which resolve photo sizes only for the user's actual
/// selection at review time.
struct LargeFilesView: View {
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
            .navigationTitle("Large Files")
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
            .onChange(of: env.analysisState.isRunning) { _, running in
                if !running { env.resumeVideoSizeMeasurement() }
            }
            .onChange(of: env.blurAnalysisState.isRunning) { _, running in
                if !running { env.resumeVideoSizeMeasurement() }
            }
            .onDisappear { env.cancelVideoSizeResolution() }
    }

    // MARK: Phase dispatch

    @ViewBuilder
    private var content: some View {
        switch phase {
        case .permissionRequired:
            PhaseMessage(
                systemImage: "internaldrive",
                title: "Photos access needed",
                message: "Netto reads your library's metadata on this iPhone and measures video sizes locally to find your largest files. Nothing is deleted until you confirm it on the review screen.",
                buttonTitle: "Allow Photos Access"
            ) { Task { await env.requestPhotoAccess() } }

        case .permissionDenied:
            PhaseMessage(
                systemImage: "lock.fill",
                title: "Photos access is off",
                message: "Netto needs Photos access to measure your largest files. Enable it in Settings to continue.",
                buttonTitle: "Open Settings"
            ) { openSettings() }

        case .scanRequired:
            PhaseMessage(
                systemImage: "internaldrive",
                title: "Find your largest files",
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
                title: "No files found",
                message: env.photoPermissionState == .limited
                    ? "None of the photos you granted Netto are videos. If you granted limited access, add more in Settings."
                    : "Nothing in your library is a video Netto can measure."
            )

        case .measuringVideos(let measured, let total, let unavailable):
            measuringContent(measured: measured, total: total, unavailable: unavailable)

        case .results(let records):
            resultsContent(records)
        }
    }

    // MARK: Measuring

    private func measuringContent(measured: Int, total: Int, unavailable: Int) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: NettoLayout.Spacing.md) {
                if VideosPresentation.showsLimitedAccessNotice(permission: env.photoPermissionState) {
                    limitedNotice
                }
                NettoProgressPanel(
                    message: VideosPresentation.measuringMessage(
                        measured: measured,
                        total: total,
                        unavailable: unavailable,
                        isActive: env.videoSizeResolution.isMeasuring
                    ),
                    fraction: total > 0 ? Double(measured) / Double(total) : nil,
                    cancel: { env.cancelVideoSizeResolution() }
                )
                if measured == 0, unavailable == 0, !env.videoSizeResolution.isMeasuring {
                    Button("Measure Sizes") { env.startVideoSizeResolution() }
                        .buttonStyle(NettoPrimaryButtonStyle())
                        .frame(maxWidth: .infinity)
                }
            }
            .padding(NettoLayout.Spacing.lg)
        }
    }

    // MARK: Results

    private func resultsContent(_ records: [PhotoAssetRecord]) -> some View {
        let known = records.filter(\.isSizeKnown)
        let unknown = records.filter { !$0.isSizeKnown }
        return ScrollView {
            VStack(alignment: .leading, spacing: NettoLayout.Spacing.lg) {
                if VideosPresentation.showsLimitedAccessNotice(permission: env.photoPermissionState) {
                    limitedNotice
                }
                summaryHeader(known: known, unknown: unknown)
                photoNote

                if !known.isEmpty {
                    section("Largest files", records: known, unknownSize: false)
                }
                if !unknown.isEmpty {
                    section("Size not measured", records: unknown, unknownSize: true)
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

    /// Honest scope note: this screen ranks what it can measure without eager full-library
    /// photo measurement, and says so rather than implying a photo ranking it cannot back.
    private var photoNote: some View {
        Text("Largest videos, ranked by measured size. For large photos, use Similar Images, Blurry Images, or Screenshots — a photo's size is measured only for the photos you actually select.")
            .font(NettoType.caption)
            .foregroundStyle(NettoColor.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func summaryHeader(known: [PhotoAssetRecord], unknown: [PhotoAssetRecord]) -> some View {
        let totalBytes = known.reduce(Int64(0)) { $0 + ($1.sizeInBytes ?? 0) }
        return VStack(alignment: .leading, spacing: NettoLayout.Spacing.xxs) {
            Text("\(known.count + unknown.count) videos")
                .font(NettoType.metricNumber)
                .monospacedDigit()
                .foregroundStyle(NettoColor.textPrimary)
            Text("\(ByteFormat.string(totalBytes)) measured · \(unknown.count) size unavailable")
                .font(NettoType.caption)
                .foregroundStyle(NettoColor.textSecondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("largeFilesSummary")
    }

    private func section(_ title: String, records: [PhotoAssetRecord], unknownSize: Bool) -> some View {
        VStack(alignment: .leading, spacing: NettoLayout.Spacing.sm) {
            Text(title)
                .font(NettoType.sectionTitle)
                .foregroundStyle(NettoColor.textPrimary)
            LazyVStack(spacing: NettoLayout.Spacing.sm) {
                ForEach(records, id: \.localIdentifier) { record in
                    LargeFilesRow(
                        record: record,
                        unknownSize: unknownSize,
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

/// One large-file row: thumbnail, duration, honest size, and the selection check.
private struct LargeFilesRow: View {
    let record: PhotoAssetRecord
    let unknownSize: Bool
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
                        .foregroundStyle(unknownSize ? NettoColor.warning : NettoColor.textSecondary)
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

    private var sizeText: String {
        if let bytes = record.sizeInBytes {
            return ByteFormat.string(bytes)
        }
        return "Size unavailable — stored in iCloud or not measured"
    }
}

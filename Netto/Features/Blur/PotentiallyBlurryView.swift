import SwiftUI

/// The POTENTIALLY BLURRY cleanup screen: every photo that scored below the sharp
/// threshold in the on-device sharpness pass, in a selection grid that feeds the shared
/// review → confirmation → mutation → verification pipeline.
///
/// Candidates are *potentially* blurry — the classification is an on-device heuristic
/// (see `BlurThresholds` for its calibration and limits), so nothing here is preselected
/// and nothing is deleted without an explicit mark + review + confirmation. All state is
/// derived from `AppEnvironment` through `PotentiallyBlurryPresentation.phase`; the only
/// writes this view makes are selection changes. Thumbnails go through the same bounded
/// `ThumbnailStore` as every other review grid — never full-resolution pixels.
struct PotentiallyBlurryView: View {
    @EnvironmentObject private var env: AppEnvironment
    @State private var detailItem: BlurDetailItem?
    @State private var reviewTab: BlurReviewTab = .all

    private var phase: PotentiallyBlurryPhase {
        PotentiallyBlurryPresentation.phase(
            permission: env.photoPermissionState,
            catalog: env.catalogState,
            blur: env.blurAnalysisState
        )
    }

    private let columns = [
        GridItem(.adaptive(minimum: 100), spacing: Theme.Spacing.sm)
    ]

    /// The state *category* on screen — never the payload, so a progress tick or a
    /// threshold recount cannot remount the grid.
    private var phaseID: String {
        switch phase {
        case .permissionRequired: return "permissionRequired"
        case .permissionDenied: return "permissionDenied"
        case .scanRequired: return "scanRequired"
        case .buildingCatalog: return "buildingCatalog"
        case .catalogFailed: return "catalogFailed"
        case .notStarted: return "notStarted"
        case .analyzing: return "analyzing"
        case .cancelled: return "cancelled"
        case .failed: return "failed"
        case .emptyLibrary: return "emptyLibrary"
        case .noCandidates: return "noCandidates"
        case .results: return "results"
        }
    }

    var body: some View {
        content
            .background(NettoColor.background.ignoresSafeArea())
            .navigationTitle("Potentially Blurry")
            .nettoAppear()
            .nettoStateTransition(phaseID)
            .sheet(item: $detailItem) { item in
                BlurPhotoDetailView(
                    assetID: item.assetID,
                    candidate: candidate(for: item.assetID)
                )
            }
            .onAppear {
                env.refreshPermissions()
                env.synchronizeBlurDataset()
            }
            .onChange(of: env.catalogState) { _, _ in
                env.synchronizeBlurDataset()
            }
            .onChange(of: env.blurAnalysisState) { _, _ in
                env.synchronizeBlurDataset()
            }
    }

    // MARK: Phase dispatch

    @ViewBuilder
    private var content: some View {
        switch phase {
        case .permissionRequired:
            PhaseMessage(
                systemImage: "camera.metering.unknown",
                title: "Photos access needed",
                message: "Netto reads a small copy of each photo on this iPhone to check which ones look blurry. Images never leave your device, and nothing is deleted until you confirm it on the review screen.",
                buttonTitle: "Allow Photos Access"
            ) {
                Task { await env.requestPhotoAccess() }
            }

        case .permissionDenied:
            PhaseMessage(
                systemImage: "lock.fill",
                title: "Photos access is off",
                message: "Netto needs Photos access to check your photos for blur. Enable it in Settings to continue.",
                buttonTitle: "Open Settings"
            ) {
                openSettings()
            }

        case .scanRequired:
            PhaseMessage(
                systemImage: "photo.stack",
                title: "Find your blurry photos",
                message: "Netto reads your library's metadata on this iPhone, then checks each photo's sharpness on-device. Images never leave your device, and nothing is deleted until you confirm it on the review screen.",
                buttonTitle: "Build Catalog"
            ) {
                env.startCatalogBuild()
            }

        case .buildingCatalog(let progress):
            NettoProgressPanel(
                message: progress.totalCount > 0
                    ? "Reading \(progress.enumeratedCount) of \(progress.totalCount) assets…"
                    : "Counting assets…",
                fraction: progress.totalCount > 0 ? progress.fraction : nil,
                cancel: { env.cancelCatalogBuild() }
            )

        case .catalogFailed(let message):
            PhaseMessage(
                systemImage: "exclamationmark.triangle",
                title: "Scan failed",
                message: message,
                buttonTitle: "Try Again"
            ) {
                env.startCatalogBuild()
            }

        case .notStarted:
            PhaseMessage(
                systemImage: "camera.metering.unknown",
                title: "Check which photos look blurry",
                message: "Netto measures the sharpness of every photo in your scanned library on this iPhone. Photos that look blurry or soft show up here for review — nothing is preselected, and nothing is deleted until you confirm it.",
                buttonTitle: "Analyze Sharpness"
            ) {
                env.startBlurAnalysis()
            }

        case .analyzing(let progress):
            NettoProgressPanel(
                message: PotentiallyBlurryPresentation.analyzingMessage(progress),
                fraction: progress.fraction,
                cancel: { env.cancelBlurAnalysis() }
            )

        case .cancelled:
            PhaseMessage(
                systemImage: "stop.circle",
                title: "Analysis cancelled",
                message: "The sharpness check stopped before it finished. Nothing was changed.",
                buttonTitle: "Analyze Again"
            ) {
                env.startBlurAnalysis()
            }

        case .failed(let message):
            PhaseMessage(
                systemImage: "exclamationmark.triangle",
                title: "Analysis failed",
                message: message,
                buttonTitle: "Try Again"
            ) {
                env.startBlurAnalysis()
            }

        case .emptyLibrary:
            PhaseMessage(
                systemImage: "checkmark.seal",
                title: "No photos to check",
                message: env.photoPermissionState == .limited
                    ? "None of the photos you granted Netto are images. If you granted limited access, add more photos in Settings."
                    : "Your scanned library contains no photos.",
                // The limited copy tells the user to act in Settings — offer the
                // action (U2); the non-limited copy names no next step.
                buttonTitle: env.photoPermissionState == .limited ? "Open Settings" : nil
            ) {
                openSettings()
            }

        case .noCandidates(let result):
            VStack(spacing: Theme.Spacing.lg) {
                if PotentiallyBlurryPresentation.showsLimitedAccessNotice(permission: env.photoPermissionState) {
                    limitedNotice
                }
                PhaseMessage(
                    systemImage: "checkmark.seal",
                    title: "No blurry photos found",
                    message: noCandidatesMessage(result)
                )
            }

        case .results(let result):
            resultsContent(result)
        }
    }

    // MARK: Results

    private func resultsContent(_ result: BlurAnalysisResult) -> some View {
        let visibleIDs = Set(reviewTab.candidates(in: result).lazy.map(\.assetID))
        let records = BlurDataset.records(in: result, catalog: catalogResult)
            .filter { visibleIDs.contains($0.localIdentifier) }
        // One lookup table for the whole grid: the per-cell scan over every candidate was
        // O(catalog × candidates) on each render pass.
        let verdictsByID = Dictionary(
            result.candidates.map { ($0.assetID, $0.verdict) },
            uniquingKeysWith: { first, _ in first }
        )
        return ScrollView {
            if PotentiallyBlurryPresentation.showsLimitedAccessNotice(permission: env.photoPermissionState) {
                limitedNotice
                    .padding(.horizontal, Theme.Spacing.md)
                    .padding(.top, Theme.Spacing.md)
            }

            summaryHeader(result: result, showing: records.count)
                .padding(.horizontal, Theme.Spacing.md)
                .padding(.top, Theme.Spacing.md)

            reviewTabRow(result: result)
                .padding(.horizontal, Theme.Spacing.md)
                .padding(.top, Theme.Spacing.sm)

            if records.isEmpty {
                Text("No photos in this category.")
                    .font(NettoType.caption)
                    .foregroundStyle(NettoColor.textTertiary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, Theme.Spacing.xl)
            } else {
                LazyVGrid(columns: columns, spacing: Theme.Spacing.sm) {
                    ForEach(records, id: \.localIdentifier) { record in
                        cell(for: record, verdict: verdictsByID[record.localIdentifier])
                    }
                }
                .padding(Theme.Spacing.md)
            }
        }
        .background(NettoColor.background.ignoresSafeArea())
        .safeAreaInset(edge: .bottom) { selectionBar }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                selectAllButton(result: result)
            }
        }
    }

    /// The All / Likely / Borderline segmented row — counts derived live from the result.
    private func reviewTabRow(result: BlurAnalysisResult) -> some View {
        HStack(spacing: Theme.Spacing.xs) {
            ForEach(BlurReviewTab.allCases, id: \.self) { tab in
                let count = PotentiallyBlurryPresentation.tabCount(tab, result: result)
                let isSelected = reviewTab == tab
                Button {
                    reviewTab = tab
                } label: {
                    VStack(spacing: 2) {
                        Text(tab.title)
                            .font(.caption.weight(.semibold))
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                        Text("\(count)")
                            .font(.caption2.weight(.bold))
                            .monospacedDigit()
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, Theme.Spacing.sm)
                    .background(
                        RoundedRectangle(cornerRadius: Theme.Radius.sm)
                            .fill(isSelected ? NettoColor.brandIndicator : NettoColor.surfaceSecondary)
                    )
                    .foregroundStyle(isSelected ? NettoColor.onBrandIndicator : NettoColor.textSecondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(tab.title), \(count) \(count == 1 ? "photo" : "photos")")
                .accessibilityAddTraits(isSelected ? [.isSelected] : [])
            }
        }
    }

    /// Two sibling buttons inside a `ZStack` (never nested): tapping the photo opens the
    /// detail sheet, tapping the corner control toggles selection — the same shape
    /// `SimilarPhotoGroupRow` uses, so one gesture can never trigger the other.
    private func cell(for record: PhotoAssetRecord, verdict: BlurVerdict?) -> some View {
        let isSelected = env.blurSelection.isSelected(record.localIdentifier)
        return ZStack {
            Button {
                detailItem = BlurDetailItem(assetID: record.localIdentifier)
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
            }
            .buttonStyle(.plain)
            // U9: each sibling button carries its own label — combining them left
            // VoiceOver one fused element with no way to reach "mark for cleanup"
            // (mirrors `SimilarPhotoGroupRow`, which never combines).
            .accessibilityLabel("Photo details")
            .accessibilityValue(verdictAnnouncement(verdict) ?? "")

            // The stretching frame lives on this plain container, not on the Button, so
            // the toggle's hit region is exactly its label (≥44 pt below) and can never
            // cover the cell the detail button needs (U7d).
            Color.clear
                .allowsHitTesting(false)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                .overlay(alignment: .topTrailing) {
                    Button {
                        env.mutateBlurSelection { $0.toggle(record.localIdentifier) }
                    } label: {
                        Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                            .font(.subheadline.weight(.bold))
                            .foregroundStyle(isSelected ? NettoColor.onBrandIndicator : .white.opacity(0.9))
                            .padding(5)
                            .background(Circle().fill(isSelected ? NettoColor.brandIndicator : .black.opacity(0.55)))
                            .padding(6)
                            // The drawn disc is ~37 pt; grow the hit area to the 44 pt
                            // minimum without moving a pixel of the artwork.
                            .frame(minWidth: 44, minHeight: 44)
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(isSelected ? "Selected for cleanup" : "Not selected")
                    .accessibilityAddTraits(isSelected ? [.isSelected] : [])
                }

            if let verdict {
                Text(verdict == .likelyBlurry ? "Likely blurry" : "Borderline")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(verdict == .likelyBlurry ? .black.opacity(0.62) : .black.opacity(0.5), in: Capsule())
                    .padding(6)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true) // announced through the details button's value
            }
        }
        .nettoPress()
        .nettoAnimate(.selection, value: isSelected)
    }

    /// The badge text announced through the details button — `nil` (no value) when the
    /// run produced no verdict, instead of mis-reporting "Borderline".
    private func verdictAnnouncement(_ verdict: BlurVerdict?) -> String? {
        guard let verdict else { return nil }
        return verdict == .likelyBlurry ? "Likely blurry" : "Borderline"
    }

    /// Selects or deselects every candidate *currently visible under the selected tab* —
    /// the control matches what is on screen, so its label never overclaims.
    private func selectAllButton(result: BlurAnalysisResult) -> some View {
        let visibleIDs = reviewTab.candidates(in: result).lazy.map(\.assetID)
        let allSelected = !visibleIDs.isEmpty && visibleIDs.allSatisfy(env.blurSelection.isSelected)
        return Button(allSelected ? "Deselect All" : "Select All") {
            env.mutateBlurSelection { selection in
                for assetID in visibleIDs {
                    selection.setSelected(!allSelected, forAsset: assetID)
                }
            }
        }
        .disabled(visibleIDs.isEmpty)
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
                Text("\(env.blurSelection.selectedCount) of \(candidateCount) photos selected")
                    .font(.subheadline.weight(.semibold))
                    .monospacedDigit()
                    .nettoCount(env.blurSelection.selectedCount)
                Text("Nothing is deleted yet")
                    .font(.caption2)
                    .foregroundStyle(Theme.Palette.secondaryLabel)
            }

            Spacer()

            NavigationLink {
                ReviewSelectionView(source: .blurReview)
            } label: {
                Text("Review")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(NettoPrimaryButtonStyle())
            .disabled(env.blurSelection.selectedCount == 0)
            .opacity(env.blurSelection.selectedCount == 0 ? 0.45 : 1)
        }
        .nettoFloatingBar()
    }

    // MARK: Helpers

    /// Real, counted totals — nothing here is estimated.
    private func summaryHeader(result: BlurAnalysisResult, showing: Int) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: NettoLayout.Spacing.sm) {
                Text("\(showing)")
                    .font(NettoType.metricNumber)
                    .monospacedDigit()
                    .foregroundStyle(NettoColor.textPrimary)
                    .nettoCount(showing)
                Text(showing == 1 ? "photo flagged" : "photos flagged")
                    .font(NettoType.secondaryBody)
                    .foregroundStyle(NettoColor.textSecondary)
                Spacer(minLength: NettoLayout.Spacing.sm)
                Text("found on this iPhone")
                    .font(NettoType.caption)
                    .foregroundStyle(NettoColor.textTertiary)
            }
            if let counts = PotentiallyBlurryPresentation.countsMessage(for: result) {
                Text(counts)
                    .font(NettoType.caption)
                    .foregroundStyle(NettoColor.textSecondary)
            }
            if result.scannedAt != .distantPast {
                Text("Last checked \(result.scannedAt.formatted(.relative(presentation: .named)))")
                    .font(NettoType.caption)
                    .foregroundStyle(NettoColor.textTertiary)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(showing) \(reviewTab == .all ? "photos flagged as potentially blurry" : "photos shown in \(reviewTab.title)")")
    }

    private func noCandidatesMessage(_ result: BlurAnalysisResult) -> String {
        var message = "All \(result.judgedCount) \(result.judgedCount == 1 ? "photo" : "photos") Netto checked scored as sharp."
        if result.notJudgedCount > 0 {
            message += " \(result.notJudgedCount) more could not be checked."
        }
        if env.photoPermissionState == .limited {
            message += " If you granted limited access, add more photos in Settings to check those too."
        }
        return message
    }

    private var catalogResult: CatalogScanResult {
        if case .completed(let result) = env.catalogState { return result }
        return CatalogScanResult(records: [], libraryAssetCount: 0, accessLevel: .authorized)
    }

    private var candidateCount: Int {
        guard case .results(let result) = phase else { return 0 }
        return result.candidates.count
    }

    private func candidate(for assetID: String) -> BlurCandidate? {
        guard case .results(let result) = phase else { return nil }
        return result.candidates.first { $0.assetID == assetID }
    }

    private func openSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }
}

/// Sheet identity for the detail screen: `String` is not `Identifiable`, and the item
/// exists only to key the presentation.
private struct BlurDetailItem: Identifiable {
    let assetID: String
    var id: String { assetID }
}

// MARK: - Previews

#Preview("Results") {
    NavigationStack {
        PotentiallyBlurryView()
    }
    .environmentObject(
        PreviewData.environment(
            catalog: .completed(BlurFixture.completedCatalog),
            blur: .completed(BlurFixture.result)
        )
    )
}

#Preview("Analyze") {
    NavigationStack {
        PotentiallyBlurryView()
    }
    .environmentObject(
        PreviewData.environment(catalog: .completed(BlurFixture.completedCatalog))
    )
}

#Preview("Analyzing") {
    NavigationStack {
        PotentiallyBlurryView()
    }
    .environmentObject(
        PreviewData.environment(
            catalog: .completed(BlurFixture.completedCatalog),
            blur: .running(BlurAnalysisProgress(completedUnits: 12, totalUnits: 40))
        )
    )
}

#Preview("No candidates") {
    NavigationStack {
        PotentiallyBlurryView()
    }
    .environmentObject(
        PreviewData.environment(
            catalog: .completed(BlurFixture.completedCatalog),
            blur: .completed(BlurFixture.emptyResult)
        )
    )
}

#Preview("Scan Required") {
    NavigationStack {
        PotentiallyBlurryView()
    }
    .environmentObject(PreviewData.environment())
}

#Preview("Permission") {
    NavigationStack {
        PotentiallyBlurryView()
    }
    .environmentObject(PreviewData.environment(permission: .notDetermined))
}

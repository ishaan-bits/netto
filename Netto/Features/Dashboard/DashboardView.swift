import SwiftUI

/// The dashboard: identity, one honest headline, the storage hero, one scan surface, and the
/// "Clean up" grid.
///
/// Composition runs top to bottom in a single vertical stack with one spacing token, so every
/// block is laid out by normal container rules — no offsets, no fixed coordinates, no layer
/// drawn over another. Every value on screen comes from `DashboardPresentation`,
/// `StorageSnapshot`, or the phase enums of the four categories.
struct DashboardView: View {
    @EnvironmentObject private var env: AppEnvironment
    @State private var showPhotoPrePrompt = false
    @Namespace private var cardNamespace

    private let categoryColumns = [
        GridItem(.flexible(), spacing: NettoLayout.Spacing.md),
        GridItem(.flexible(), spacing: NettoLayout.Spacing.md)
    ]

    private var scanStatus: DashboardPresentation.ScanStatus {
        DashboardPresentation.scanStatus(
            permission: env.photoPermissionState,
            catalog: env.catalogState,
            analysis: env.analysisState,
            lastScannedAt: env.lastScanCompletedAt,
            eta: env.scanETA()
        )
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: NettoLayout.Spacing.xl) {
                    header
                        .nettoEntrance(step: 0)
                    heroCopy
                        .nettoEntrance(step: 1)
                    DashboardHeroView(snapshot: env.storageSnapshot)
                        .nettoEntrance(step: 2)
                    // Periodic re-render so the "Last scanned …" relative time keeps aging
                    // naturally while the dashboard sits open; the card's identity (and every
                    // control inside it) is unchanged between ticks.
                    TimelineView(.periodic(from: .now, by: 60)) { _ in
                        scanStatusCard
                    }
                    .nettoEntrance(step: 3)
                    categorySection
                }
                .padding(NettoLayout.Spacing.lg)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .nettoAtmosphere()
            .toolbar(.hidden, for: .navigationBar)
            .refreshable { await env.refreshStorage() }
            .task { env.refreshPermissions() }
            .sheet(isPresented: $showPhotoPrePrompt) {
                PermissionPrimingView(
                    kind: .photos,
                    onContinue: {
                        showPhotoPrePrompt = false
                        Task { await env.requestPhotoAccess() }
                    }
                )
                .presentationDetents([.medium])
            }
        }
    }

    // MARK: TOP — identity

    private var header: some View {
        HStack(spacing: NettoLayout.Spacing.sm) {
            NettoLogo()
                .frame(width: 26, height: 26)
                .accessibilityHidden(true)
            Text("Netto")
                .font(NettoType.sectionTitle)
                .foregroundStyle(NettoColor.textPrimary)
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("dashboardHeader")
    }

    // MARK: HERO — the one thing the screen is about

    private var heroCopy: some View {
        VStack(alignment: .leading, spacing: NettoLayout.Spacing.sm) {
            Text("Your iPhone has room to breathe")
                .font(NettoType.heroTitle)
                .foregroundStyle(NettoColor.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            Text("Scan → Review → Clean, entirely on this iPhone.")
                .font(NettoType.caption)
                .foregroundStyle(NettoColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("dashboardHeroCopy")
    }

    // MARK: SCAN STATUS

    private var scanStatusCard: DashboardScanStatusCard {
        DashboardScanStatusCard(
            status: scanStatus,
            onAllowPhotos: { showPhotoPrePrompt = true },
            onOpenSettings: openSettings,
            onAnalyze: { env.startSimilarityAnalysis() },
            onCancel: cancelScan,
            isLimitedAccess: env.photoPermissionState == .limited
        )
    }

    private func openSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }

    private func cancelScan() {
        if case .running = env.analysisState {
            env.cancelSimilarityAnalysis()
        } else {
            env.cancelCatalogBuild()
        }
    }

    // MARK: CLEANUP grid

    private var categorySection: some View {
        VStack(alignment: .leading, spacing: NettoLayout.Spacing.md) {
            Text("Clean up")
                .font(NettoType.sectionTitle)
                .foregroundStyle(NettoColor.textPrimary)
                .accessibilityIdentifier("cleanupSectionTitle")
                .nettoEntrance(step: 4)

            LazyVGrid(columns: categoryColumns, spacing: NettoLayout.Spacing.md) {
                categoryLink(
                    id: "similarPhotos",
                    identifier: "similarPhotosCard",
                    title: "Similar Photos",
                    icon: "photo.on.rectangle.angled",
                    status: similarPhotosStatusText,
                    assetID: similarPhotosResult.flatMap { Self.firstAssetID(in: $0) },
                    initials: nil,
                    step: 5,
                    destination: { SimilarPhotosView() }
                )

                categoryLink(
                    id: "screenshots",
                    identifier: "screenshotsCard",
                    title: "Screenshots",
                    icon: "rectangle.on.rectangle",
                    status: ScreenshotsPresentation.statusText(
                        permission: env.photoPermissionState,
                        catalog: env.catalogState
                    ),
                    assetID: screenshotsAssetID,
                    initials: nil,
                    step: 6,
                    destination: { ScreenshotsView() }
                )

                categoryLink(
                    id: "largeVideos",
                    identifier: "largeVideosCard",
                    title: "Large Videos",
                    icon: "video",
                    status: VideosPresentation.statusText(
                        permission: env.photoPermissionState,
                        catalog: env.catalogState,
                        resolution: env.videoSizeResolution
                    ),
                    assetID: videosAssetID,
                    initials: nil,
                    step: 7,
                    destination: { VideosView() }
                )

                categoryLink(
                    id: "duplicateContacts",
                    identifier: "duplicateContactsRow",
                    title: "Duplicate Contacts",
                    icon: "person.2",
                    status: ContactsPresentation.statusText(
                        permission: env.contactsPermissionState,
                        scan: env.contactScanState
                    ),
                    assetID: nil,
                    initials: contactsInitials,
                    step: 8,
                    destination: { DuplicateContactsView() }
                )

                // Top-level Swipe Review — a sibling of the photo features above, opening
                // the swipe session directly (no Similar Photos detour). Its deck is the
                // scanned catalog itself, so it needs analysis results only for the shared
                // review handoff, never to open or run.
                categoryLink(
                    id: "swipeReview",
                    identifier: SwipeReviewPresentation.entryAccessibilityID,
                    title: SwipeReviewPresentation.entryLabel,
                    icon: "arrow.left.and.right",
                    status: swipeReviewStatusText,
                    assetID: swipeReviewAssetID,
                    initials: nil,
                    step: 9,
                    destination: { SwipeReviewView(items: swipeReviewDeck) }
                )

                // The on-device sharpness pass (milestone 5B): its own analysis over the
                // completed catalog, its own grid, the same shared review handoff.
                categoryLink(
                    id: "potentiallyBlurry",
                    identifier: "potentiallyBlurryCard",
                    title: "Potentially Blurry",
                    icon: "camera.metering.unknown",
                    status: PotentiallyBlurryPresentation.statusText(
                        permission: env.photoPermissionState,
                        catalog: env.catalogState,
                        blur: env.blurAnalysisState
                    ),
                    assetID: potentiallyBlurryAssetID,
                    initials: nil,
                    step: 10,
                    destination: { PotentiallyBlurryView() }
                )
            }
        }
    }

    private func categoryLink<Destination: View>(
        id: String,
        identifier: String,
        title: String,
        icon: String,
        status: String,
        assetID: String?,
        initials: String?,
        step: Int,
        @ViewBuilder destination: () -> Destination
    ) -> some View {
        NavigationLink {
            destination()
                .nettoZoomDestination(id, in: cardNamespace)
        } label: {
            DashboardCategoryCard(
                title: title,
                icon: icon,
                status: status,
                assetID: assetID,
                initials: initials,
                store: env.thumbnails
            )
        }
        .buttonStyle(DashboardCardPressStyle())
        .nettoEntrance(step: step)
        .nettoZoomSource(id, in: cardNamespace)
        .accessibilityIdentifier(identifier)
    }

    // MARK: Real data (never fabricated — nil when there is nothing to show)

    private var similarPhotosResult: PhotoAnalysisResult? {
        guard case .results(let result) = similarPhotosPhase else { return nil }
        return result
    }

    private var similarPhotosPhase: SimilarPhotosPhase {
        SimilarPhotosPresentation.phase(
            permission: env.photoPermissionState,
            catalog: env.catalogState,
            analysis: env.analysisState
        )
    }

    private static func firstAssetID(in result: PhotoAnalysisResult) -> String? {
        for group in result.exactGroups + result.similarGroups {
            if let id = group.memberAssetIDs.first {
                return id
            }
        }
        return nil
    }

    private var screenshotsAssetID: String? {
        guard case .results(let records) = ScreenshotsPresentation.phase(
            permission: env.photoPermissionState,
            catalog: env.catalogState
        ) else { return nil }
        return records.first?.localIdentifier
    }

    private var videosAssetID: String? {
        guard case .results(let records) = VideosPresentation.phase(
            permission: env.photoPermissionState,
            catalog: env.catalogState,
            resolution: env.videoSizeResolution
        ) else { return nil }
        return records.first?.localIdentifier
    }

    /// First candidate's thumbnail for the Potentially Blurry card; nil when there is
    /// nothing to show (no candidates, or the pass has not completed).
    private var potentiallyBlurryAssetID: String? {
        guard case .results(let result) = PotentiallyBlurryPresentation.phase(
            permission: env.photoPermissionState,
            catalog: env.catalogState,
            blur: env.blurAnalysisState
        ) else { return nil }
        return result.candidates.first?.assetID
    }

    private var contactsInitials: String? {
        guard case .completed(let dataset) = env.contactScanState,
              let id = dataset.groups.first?.memberIDs.first,
              let record = dataset.record(for: id)
        else { return nil }
        return Self.initials(for: record)
    }

    private static func initials(for record: ContactRecord) -> String {
        let given = record.givenName.trimmingCharacters(in: .whitespaces)
        let family = record.familyName.trimmingCharacters(in: .whitespaces)
        let letters = [given.first, family.first].compactMap { $0 }
        if !letters.isEmpty {
            return String(letters).uppercased()
        }
        let organization = record.organizationName.trimmingCharacters(in: .whitespaces)
        guard let first = organization.first else { return "?" }
        return String(first).uppercased()
    }

    private var similarPhotosStatusText: String {
        switch similarPhotosPhase {
        case .permissionRequired:
            return "Photos access needed"
        case .permissionDenied:
            return "Photos access is off"
        case .idle:
            return "Not analyzed yet"
        case .buildingCatalog:
            return "Reading your library…"
        case .analyzing(let progress):
            return SimilarPhotosPresentation.stageMessage(for: progress)
        case .emptyLibrary:
            return "No photos visible to Netto"
        case .cancelled:
            return "Last run cancelled"
        case .failed(let message):
            return message
        case .results(let result):
            let summary = SimilarPhotosSummary(result: result)
            if summary.hasNoGroups {
                return summary.notAnalyzedCount > 0
                    ? "No duplicates found · \(summary.notAnalyzedCount) not analyzed"
                    : "Analyzed · no duplicates found"
            }
            let groups = summary.exactGroupCount + summary.similarGroupCount
            return "\(groups) \(groups == 1 ? "group" : "groups") ready to review"
        }
    }

    // MARK: Swipe Review (standalone)

    /// Swipe Review's card status — catalog-driven, because the feature reviews the scanned
    /// library itself, not the analysis. It only reflects Photos access and scan progress.
    private var swipeReviewStatusText: String {
        switch env.photoPermissionState {
        case .notDetermined:
            return "Photos access needed"
        case .denied, .restricted:
            return "Photos access is off"
        case .authorized, .limited:
            break
        }
        switch env.catalogState {
        case .notStarted:
            return "Not scanned yet"
        case .running:
            return "Reading your library…"
        case .cancelled:
            return "Last run cancelled"
        case .failed(let failure):
            return failure.userMessage
        case .completed(let catalog):
            let images = catalog.imageCount
            return images == 0
                ? "No photos visible to Netto"
                : "\(images.formatted()) photos"
        }
    }

    /// Thumbnail asset for the card: the library's first image; nil until a scan completes.
    private var swipeReviewAssetID: String? {
        guard case .completed(let catalog) = env.catalogState else { return nil }
        return catalog.records.first(where: \.isImage)?.localIdentifier
    }

    /// The deck the card pushes: every image in the scanned catalog, in catalog order.
    private var swipeReviewDeck: [SwipeReviewItem] {
        guard case .completed(let catalog) = env.catalogState else { return [] }
        return SwipeReviewPresentation.items(from: catalog)
    }
}

struct PermissionPrimingView: View {
    let kind: PermissionKind
    let onContinue: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: NettoLayout.Spacing.lg) {
            Spacer(minLength: NettoLayout.Spacing.lg)
            Image(systemName: kind == .photos ? "photo.on.rectangle.angled" : "person.2.badge.key")
                .font(.system(size: 44))
                .foregroundStyle(NettoColor.brandIndicator)

            Text(kind == .photos ? "Netto needs Photos access" : "Netto needs Contacts access")
                .font(NettoType.sectionTitle)
                .multilineTextAlignment(.center)
                .foregroundStyle(NettoColor.textPrimary)

            Text(kind == .photos
                 ? "Netto reads your photo library on this iPhone to find duplicates, similar shots, screenshots, and large videos. Images never leave your device, and nothing is deleted until you approve it on the review screen."
                 : "Netto reads your contacts on this iPhone to find entries that look like duplicates. Your contacts never leave your device, and no contact is merged or deleted until you approve it.")
                .font(NettoType.secondaryBody)
                .foregroundStyle(NettoColor.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, NettoLayout.Spacing.lg)

            Spacer()

            Button(action: onContinue) {
                Text("Continue")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(NettoPrimaryButtonStyle())

            Button("Not Now") { dismiss() }
                .buttonStyle(.plain)
                .font(NettoType.buttonLabel)
                .foregroundStyle(NettoColor.textSecondary)
        }
        .padding(NettoLayout.Spacing.xl)
        .nettoAppear()
    }
}

#if DEBUG
#Preview("Ready · Dark") {
    NavigationStack {
        DashboardView()
    }
    .environmentObject(PreviewData.environment())
    .preferredColorScheme(.dark)
}

#Preview("Ready · Light") {
    NavigationStack {
        DashboardView()
    }
    .environmentObject(PreviewData.environment())
    .preferredColorScheme(.light)
}

#Preview("Analyzed") {
    NavigationStack {
        DashboardView()
    }
    .environmentObject(PreviewData.environment(analysis: .completed(PreviewData.result)))
}

#Preview("Scanning") {
    NavigationStack {
        DashboardView()
    }
    .environmentObject(
        PreviewData.environment(
            analysis: .running(
                PhotoAnalysisProgress(stage: .extractingFeatures, completedUnits: 120, totalUnits: 480)
            )
        )
    )
}

#Preview("Photos access off") {
    NavigationStack {
        DashboardView()
    }
    .environmentObject(PreviewData.environment(permission: .denied))
}

#Preview("No results") {
    NavigationStack {
        DashboardView()
    }
    .environmentObject(PreviewData.environment(analysis: .completed(PreviewData.resultWithoutGroups)))
}

#Preview("Empty library") {
    NavigationStack {
        DashboardView()
    }
    .environmentObject(
        PreviewData.environment(
            catalog: .completed(
                CatalogScanResult(records: [], libraryAssetCount: 0, accessLevel: .authorized)
            )
        )
    )
}

#Preview("Storage unavailable") {
    let env = PreviewData.environment()
    env.storageSnapshot = StorageSnapshot(totalCapacity: 0, availableCapacity: 0)
    return NavigationStack {
        DashboardView()
    }
    .environmentObject(env)
}

#Preview("Storage loading") {
    let env = PreviewData.environment()
    env.storageSnapshot = nil
    return NavigationStack {
        DashboardView()
    }
    .environmentObject(env)
}

#Preview("Contacts · results") {
    let env = PreviewData.contactsEnvironment()
    env.photoPermissionState = .authorized
    return NavigationStack {
        DashboardView()
    }
    .environmentObject(env)
}
#endif

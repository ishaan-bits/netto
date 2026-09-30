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
            analysis: env.analysisState
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
                    scanStatusCard
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
            onCancel: cancelScan
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
                return summary.unavailableCount > 0
                    ? "No duplicates found · \(summary.unavailableCount) not analyzed"
                    : "Analyzed · no duplicates found"
            }
            let groups = summary.exactGroupCount + summary.similarGroupCount
            return "\(groups) \(groups == 1 ? "group" : "groups") ready to review"
        }
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
                .foregroundStyle(NettoColor.brand)

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

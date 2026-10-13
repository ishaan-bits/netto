import SwiftUI

/// The dashboard: identity, one honest headline, the storage hero, one scan surface, and the
/// four primary cleanup sections.
///
/// Composition runs top to bottom in a single vertical stack with one spacing token, so every
/// block is laid out by normal container rules — no offsets, no fixed coordinates, no layer
/// drawn over another. Every status line comes from `DashboardCleanupPresentation`, which
/// derives it from the same state machines the destination screens use.
struct DashboardView: View {
    @Environment(AppEnvironment.self) private var env: AppEnvironment
    @State private var showPhotoPrePrompt = false
    @Namespace private var cardNamespace

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
                    cleanupSection
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
            // The brand's two-leaf symbol as live vector geometry: it assembles on appear
            // (staggered leaf reveal) and drifts gently while the dashboard is up.
            NettoBrandSymbol(animateIdle: true)
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
            onAnalyze: { env.startImageAnalysis() },
            onCancel: cancelScan,
            onResume: { env.resumeInterruptedWork() },
            isLimitedAccess: env.photoPermissionState == .limited
        )
    }

    private func openSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }

    private func cancelScan() {
        // The unified session runs both pipelines over one shared read (M13), and the
        // dashboard card is the one control that owns the whole scan — so its cancel must
        // stop both. Cancelling only similarity would orphan the sharpness pass, and the
        // next Analyze would then be treated as a queued request behind that orphan instead
        // of a fresh scan. When neither pipeline is running but a standalone catalog build
        // is, cancel that instead.
        let similarityRunning = env.analysisState.isRunning
        let blurRunning = env.blurAnalysisState.isRunning
        if similarityRunning || blurRunning {
            if blurRunning { env.cancelBlurAnalysis() }
            if similarityRunning { env.cancelSimilarityAnalysis() }
        } else {
            env.cancelCatalogBuild()
        }
    }

    // MARK: CLEANUP — the four primary sections

    /// The four primary cleanup sections. Each row reports only what the app's current state
    /// can honestly back (a real count, real progress, or a real blocking reason) and routes
    /// into exactly one hub or feature screen. Nothing here starts an analysis on appear.
    private var cleanupSection: some View {
        VStack(alignment: .leading, spacing: NettoLayout.Spacing.md) {
            Text("Clean up")
                .font(NettoType.sectionTitle)
                .foregroundStyle(NettoColor.textPrimary)
                .accessibilityIdentifier("cleanupSectionTitle")
                .nettoEntrance(step: 4)

            VStack(spacing: NettoLayout.Spacing.md) {
                ForEach(DashboardCleanupSection.allCases, id: \.self) { section in
                    sectionLink(section)
                        .nettoEntrance(step: 5 + DashboardCleanupSection.allCases.firstIndex(of: section)!)
                }
            }
        }
    }

    @ViewBuilder
    private func sectionLink(_ section: DashboardCleanupSection) -> some View {
        CleanupSectionCard(
            title: section.title,
            subtitle: section.subtitle,
            icon: section.icon,
            status: DashboardCleanupPresentation.status(
                for: section,
                permission: env.photoPermissionState,
                contactsPermission: env.contactsPermissionState,
                catalog: env.catalogState,
                analysis: env.analysisState,
                blur: env.blurAnalysisState,
                pendingBehindOtherPass: env.pendingAnalysisRequest == .similarity,
                resolution: env.videoSizeResolution,
                videoSignature: env.videoDatasetSignature,
                videoRecords: env.videoRecordsForDisplay,
                recordedVideos: env.recordedVideosForDisplay,
                downloadedVideos: env.downloadedVideosForDisplay,
                otherVideoCount: env.otherVideosCount,
                contactScan: env.contactScanState
            ),
            accessibilityIdentifier: section.accessibilityIdentifier
        ) {
            destination(for: section)
                .nettoZoomDestination(section.title, in: cardNamespace)
        }
    }

    @ViewBuilder
    private func destination(for section: DashboardCleanupSection) -> some View {
        switch section {
        case .imageCleanup: ImageCleanupView()
        case .videoCleanup: VideoCleanupView()
        case .duplicateContacts: DuplicateContactsView()
        case .swipeCleanup: SwipeReviewView()
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
    .environment(PreviewData.environment())
    .preferredColorScheme(.dark)
}

#Preview("Ready · Light") {
    NavigationStack {
        DashboardView()
    }
    .environment(PreviewData.environment())
    .preferredColorScheme(.light)
}

#Preview("Analyzed") {
    NavigationStack {
        DashboardView()
    }
    .environment(PreviewData.environment(analysis: .completed(PreviewData.result)))
}

#Preview("Scanning") {
    NavigationStack {
        DashboardView()
    }
    .environment(
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
    .environment(PreviewData.environment(permission: .denied))
}

#Preview("No results") {
    NavigationStack {
        DashboardView()
    }
    .environment(PreviewData.environment(analysis: .completed(PreviewData.resultWithoutGroups)))
}

#Preview("Empty library") {
    NavigationStack {
        DashboardView()
    }
    .environment(
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
    .environment(env)
}

#Preview("Storage loading") {
    let env = PreviewData.environment()
    env.storageSnapshot = nil
    return NavigationStack {
        DashboardView()
    }
    .environment(env)
}

#Preview("Contacts · results") {
    let env = PreviewData.contactsEnvironment()
    env.photoPermissionState = .authorized
    return NavigationStack {
        DashboardView()
    }
    .environment(env)
}
#endif

import SwiftUI

struct DashboardView: View {
    @EnvironmentObject private var env: AppEnvironment
    @State private var showPhotoPrePrompt = false
    @State private var showContactsPrePrompt = false

    var body: some View {
        NavigationStack {
            List {
                storageSection
                permissionsSection
                catalogSection
                statusSection
            }
            .navigationTitle("Netto")
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
            .sheet(isPresented: $showContactsPrePrompt) {
                PermissionPrimingView(
                    kind: .contacts,
                    onContinue: {
                        showContactsPrePrompt = false
                        Task { await env.requestContactsAccess() }
                    }
                )
                .presentationDetents([.medium])
            }
            .onAppear { env.refreshPermissions() }
        }
    }

    private var storageSection: some View {
        Section("Storage") {
            if let snapshot = env.storageSnapshot {
                StorageCardView(snapshot: snapshot)
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
            } else {
                HStack {
                    ProgressView()
                    Text("Reading device storage…")
                        .foregroundStyle(Theme.Palette.secondaryLabel)
                }
            }
        }
    }

    private var permissionsSection: some View {
        Section("Permissions") {
            PermissionRow(
                kind: .photos,
                state: env.photoPermissionState,
                onRequest: {
                    if env.photoPermissionState == .notDetermined {
                        showPhotoPrePrompt = true
                    }
                }
            )
            PermissionRow(
                kind: .contacts,
                state: env.contactsPermissionState,
                onRequest: {
                    if env.contactsPermissionState == .notDetermined {
                        showContactsPrePrompt = true
                    }
                }
            )
        }
    }

    private var catalogSection: some View {
        Section("Catalog") {
            VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                Text("Metadata enumeration")
                    .font(.headline)
                Text("Reads asset metadata only — no image data is decoded and nothing is downloaded. Sizes stay unknown until you pick items for review.")
                    .font(.subheadline)
                    .foregroundStyle(Theme.Palette.secondaryLabel)

                catalogControls
            }
            .padding(.vertical, Theme.Spacing.xs)
        }
    }

    @ViewBuilder
    private var catalogControls: some View {
        switch env.catalogState {
        case .notStarted:
            Button("Build Catalog") { env.startCatalogBuild() }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)

        case .running(let progress):
            ProgressView(value: progress.fraction)
            Text(progress.totalCount > 0
                 ? "Reading \(progress.enumeratedCount) of \(progress.totalCount) assets…"
                 : "Counting assets…")
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(Theme.Palette.secondaryLabel)
            Button("Cancel") { env.cancelCatalogBuild() }
                .buttonStyle(.bordered)
                .controlSize(.small)

        case .completed(let result):
            Group {
                if result.isEmpty {
                    Text("No assets are visible to Netto.")
                        .font(.subheadline)
                        .foregroundStyle(Theme.Palette.warning)
                } else {
                    Text("\(result.scannedAssetCount) assets · \(result.imageCount) photos · \(result.videoCount) videos · \(result.screenshotCount) screenshots")
                        .font(.subheadline)
                        .monospacedDigit()
                    Text("Access: \(result.accessLevel.displayName) · sizes unknown until review")
                        .font(.caption)
                        .foregroundStyle(Theme.Palette.secondaryLabel)
                }
            }
            Button("Rebuild") { env.startCatalogBuild() }
                .buttonStyle(.bordered)
                .controlSize(.small)

        case .cancelled:
            Text("Catalog build cancelled.")
                .font(.subheadline)
                .foregroundStyle(Theme.Palette.secondaryLabel)
            Button("Resume") { env.startCatalogBuild() }
                .buttonStyle(.bordered)
                .controlSize(.small)

        case .failed(let failure):
            Text(failure.userMessage)
                .font(.subheadline)
                .foregroundStyle(Theme.Palette.danger)
            Button("Retry") { env.startCatalogBuild() }
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
    }

    private var statusSection: some View {
        Section("Scan") {
            VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                Text("Scan → Review → Clean")
                    .font(.headline)
                Text("Analysis pipeline lands in the next milestone. Nothing is ever deleted without your explicit confirmation on the review screen.")
                    .font(.subheadline)
                    .foregroundStyle(Theme.Palette.secondaryLabel)
            }
            .padding(.vertical, Theme.Spacing.xs)
        }
    }
}

struct StorageCardView: View {
    let snapshot: StorageSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Used")
                        .font(.caption)
                        .foregroundStyle(Theme.Palette.secondaryLabel)
                    Text(snapshot.formattedUsed())
                        .font(.title2.weight(.semibold))
                        .monospacedDigit()
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text("Free")
                        .font(.caption)
                        .foregroundStyle(Theme.Palette.secondaryLabel)
                    Text(snapshot.formattedFree())
                        .font(.title2.weight(.semibold))
                        .monospacedDigit()
                        .foregroundStyle(Theme.Palette.success)
                }
            }

            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Theme.Palette.tertiaryBackground)
                    Capsule()
                        .fill(Theme.Palette.accent)
                        .frame(width: proxy.size.width * snapshot.usedFraction)
                }
            }
            .frame(height: 8)

            Text("of \(snapshot.formattedTotal()) total")
                .font(.caption)
                .foregroundStyle(Theme.Palette.secondaryLabel)
        }
        .padding(Theme.Spacing.lg)
        .background(Theme.Palette.secondaryBackground, in: RoundedRectangle(cornerRadius: Theme.Radius.lg))
    }
}

struct PermissionRow: View {
    let kind: PermissionKind
    let state: PermissionState
    let onRequest: () -> Void

    var body: some View {
        HStack(spacing: Theme.Spacing.md) {
            Image(systemName: kind == .photos ? "photo.on.rectangle" : "person.crop.circle")
                .font(.title3)
                .foregroundStyle(Theme.Palette.accent)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 2) {
                Text(kind.displayName)
                    .font(.body.weight(.medium))
                Text(state.displayName)
                    .font(.caption)
                    .foregroundStyle(statusColor)
            }

            Spacer()

            switch state {
            case .notDetermined:
                Button("Allow", action: onRequest)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            case .denied, .restricted:
                Button("Open Settings") {
                    guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
                    UIApplication.shared.open(url)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            case .limited:
                Text("Limited")
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, Theme.Spacing.sm)
                    .padding(.vertical, Theme.Spacing.xs)
                    .background(Theme.Palette.warning.opacity(0.2), in: Capsule())
            case .authorized:
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(Theme.Palette.success)
            }
        }
    }

    private var statusColor: Color {
        switch state {
        case .authorized: return Theme.Palette.success
        case .limited: return Theme.Palette.warning
        case .denied, .restricted: return Theme.Palette.danger
        case .notDetermined: return Theme.Palette.secondaryLabel
        }
    }
}

struct PermissionPrimingView: View {
    let kind: PermissionKind
    let onContinue: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: Theme.Spacing.lg) {
            Spacer(minLength: Theme.Spacing.lg)
            Image(systemName: kind == .photos ? "photo.on.rectangle.angled" : "person.2.badge.key")
                .font(.system(size: 44))
                .foregroundStyle(Theme.Palette.accent)

            Text(kind == .photos ? "Netto needs Photos access" : "Netto needs Contacts access")
                .font(.title3.weight(.semibold))
                .multilineTextAlignment(.center)

            Text(kind == .photos
                 ? "Netto reads your photo library on this iPhone to find duplicates, similar shots, screenshots, and large videos. Images never leave your device, and nothing is deleted until you approve it on the review screen."
                 : "Netto reads your contacts on this iPhone to find entries that look like duplicates. Your contacts never leave your device, and no contact is merged or deleted until you approve it.")
                .font(.subheadline)
                .foregroundStyle(Theme.Palette.secondaryLabel)
                .multilineTextAlignment(.center)
                .padding(.horizontal, Theme.Spacing.lg)

            Spacer()

            Button(action: onContinue) {
                Text("Continue")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)

            Button("Not Now") { dismiss() }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.Palette.secondaryLabel)
        }
        .padding(Theme.Spacing.xl)
    }
}

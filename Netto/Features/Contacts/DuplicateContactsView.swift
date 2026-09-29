import SwiftUI

/// The DUPLICATE CONTACTS cleanup screen: likely-duplicate groups found by local detection
/// over a read-only enumeration, feeding the dedicated contacts review → confirmation →
/// mutation → verification pipeline.
///
/// This screen never mutates Contacts. All state is derived from `AppEnvironment` through
/// `ContactsPresentation.phase`; the only writes it makes are starting/cancelling the read-only
/// scan and opening a group. Detection runs entirely on-device — contact data never leaves
/// the process.
struct DuplicateContactsView: View {
    @EnvironmentObject private var env: AppEnvironment

    private var phase: ContactsPhase {
        ContactsPresentation.phase(
            permission: env.contactsPermissionState,
            scan: env.contactScanState
        )
    }

    var body: some View {
        content
            .navigationTitle("Duplicate Contacts")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear {
                env.refreshPermissions()
                env.synchronizeContactDataset()
                env.startContactScanIfNeeded()
            }
            .onChange(of: env.contactsPermissionState) { _, _ in
                env.startContactScanIfNeeded()
            }
            .safeAreaInset(edge: .top, spacing: 0) {
                // Only reachable in the usable phases (.limited maps to a data phase above), so
                // every count and "no duplicates" claim on screen carries the caveat.
                if ContactsPresentation.showsLimitedAccessNotice(permission: env.contactsPermissionState) {
                    limitedNotice
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    if case .results = phase {
                        Button("Rescan") { env.startContactScan() }
                    }
                }
            }
    }

    private var limitedNotice: some View {
        Label(
            "Only the contacts you selected for Netto are scanned.",
            systemImage: "info.circle"
        )
        .font(.caption)
        .foregroundStyle(Theme.Palette.warning)
        .padding(.horizontal, Theme.Spacing.lg)
        .padding(.top, Theme.Spacing.lg)
    }

    // MARK: Phase dispatch

    @ViewBuilder
    private var content: some View {
        switch phase {
        case .permissionRequired:
            PhaseMessage(
                systemImage: "person.2.badge.key",
                title: "Contacts access needed",
                message: "Netto reads your contacts on this iPhone to find entries that look like duplicates. Your contacts never leave your device, and nothing is merged or deleted until you confirm it on the review screen.",
                buttonTitle: "Allow Contacts Access"
            ) {
                Task { await env.requestContactsAccess() }
            }

        case .permissionDenied:
            PhaseMessage(
                systemImage: "lock.fill",
                title: "Contacts access is off",
                message: "Netto needs Contacts access to find duplicate contacts. Enable it in Settings to continue.",
                buttonTitle: "Open Settings"
            ) {
                openSettings()
            }

        case .scanRequired:
            PhaseMessage(
                systemImage: "person.2",
                title: "Find likely duplicates",
                message: "Netto reads your contacts on this iPhone and groups entries that look like the same person — by shared phone numbers, emails, and names. Everything is analyzed on-device.",
                buttonTitle: "Scan for Duplicates"
            ) {
                env.startContactScan()
            }

        case .scanning:
            VStack(spacing: Theme.Spacing.lg) {
                Spacer()
                ProgressView()
                Text("Reading contacts and looking for likely duplicates…")
                    .font(.subheadline)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(Theme.Palette.secondaryLabel)
                Button("Cancel") { env.cancelContactScan() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                Spacer()
            }
            .padding(.horizontal, Theme.Spacing.xl)

        case .failed(let message):
            PhaseMessage(
                systemImage: "exclamationmark.triangle",
                title: "Scan failed",
                message: message,
                buttonTitle: "Try Again"
            ) {
                env.startContactScan()
            }

        case .empty:
            PhaseMessage(
                systemImage: "person.crop.circle.badge.questionmark",
                title: "No contacts found",
                message: "Netto can’t see any contacts on this iPhone. Add contacts in the Contacts app, then scan again."
            )

        case .noDuplicates:
            PhaseMessage(
                systemImage: "checkmark.seal",
                title: "No likely duplicates",
                message: "Netto checked your contacts on this iPhone and found no entries that look like the same person. Nothing needs your review."
            )

        case .results(let groups):
            resultsContent(groups)
        }
    }

    // MARK: Results

    private func resultsContent(_ groups: [ContactDuplicateGroup]) -> some View {
        List {
            Section {
                ForEach(groups) { group in
                    NavigationLink {
                        ContactGroupDetailView(group: group)
                    } label: {
                        groupRow(group)
                    }
                    .accessibilityIdentifier("duplicateGroupRow-\(group.id)")
                }
            } header: {
                Text("\(groups.count) \(groups.count == 1 ? "group" : "groups") of likely duplicates")
            } footer: {
                Text("Likely duplicates are grouped by shared phone numbers, emails, and names — Netto can’t be certain they’re the same person. Nothing changes until you review and confirm.")
                    .font(.caption)
            }
        }
        .accessibilityIdentifier("duplicateContactsList")
    }

    private func groupRow(_ group: ContactDuplicateGroup) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(memberNames(for: group))
                .font(.body.weight(.medium))
                .lineLimit(2)
            Text(ContactsPresentation.reasonsText(group.reasons))
                .font(.caption)
                .foregroundStyle(Theme.Palette.secondaryLabel)
                .lineLimit(2)
            Text("\(group.memberCount) contacts")
                .font(.caption2)
                .foregroundStyle(Theme.Palette.secondaryLabel)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }

    /// First two member names plus a "+n more" suffix — identification aid only, always from
    /// the on-device dataset.
    private func memberNames(for group: ContactDuplicateGroup) -> String {
        guard case .completed(let dataset) = env.contactScanState else { return "" }
        let names = group.memberIDs.compactMap { dataset.record(for: $0)?.displayName }
        let shown = names.prefix(2).joined(separator: ", ")
        let remaining = names.count - min(names.count, 2)
        return remaining > 0 ? "\(shown) +\(remaining) more" : shown
    }

    private func openSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }
}

// MARK: - Previews

#if DEBUG
#Preview("Results") {
    NavigationStack {
        DuplicateContactsView()
    }
    .environmentObject(PreviewData.contactsEnvironment())
}

#Preview("Permission") {
    NavigationStack {
        DuplicateContactsView()
    }
    .environmentObject(PreviewData.contactsEnvironment(permission: .notDetermined))
}

#Preview("No Duplicates") {
    NavigationStack {
        DuplicateContactsView()
    }
    .environmentObject(PreviewData.contactsEnvironment(noDuplicates: true))
}
#endif

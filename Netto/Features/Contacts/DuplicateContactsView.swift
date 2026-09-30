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

    /// The state *category* on screen — never the payload, so a changing error string cannot
    /// remount the list.
    private var phaseID: String {
        switch phase {
        case .permissionRequired: return "permissionRequired"
        case .permissionDenied: return "permissionDenied"
        case .scanRequired: return "scanRequired"
        case .scanning: return "scanning"
        case .failed: return "failed"
        case .empty: return "empty"
        case .noDuplicates: return "noDuplicates"
        case .results: return "results"
        }
    }

    var body: some View {
        content
            .background(NettoColor.background.ignoresSafeArea())
            .navigationTitle("Duplicate Contacts")
            .nettoAppear()
            .nettoStateTransition(phaseID)
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
            NettoProgressPanel(
                message: "Reading contacts and looking for likely duplicates…",
                cancel: { env.cancelContactScan() }
            )

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
                    .nettoPress()
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
        .scrollContentBackground(.hidden)
        .background(NettoColor.background.ignoresSafeArea())
    }

    private func groupRow(_ group: ContactDuplicateGroup) -> some View {
        HStack(spacing: NettoLayout.Spacing.md) {
            avatar(for: group)

            VStack(alignment: .leading, spacing: 4) {
                Text(memberNames(for: group))
                    .font(.body.weight(.medium))
                    .foregroundStyle(NettoColor.textPrimary)
                    .lineLimit(2)
                Text(ContactsPresentation.reasonsText(group.reasons))
                    .font(.caption)
                    .foregroundStyle(NettoColor.textSecondary)
                    .lineLimit(2)
                Text("\(group.memberCount) contacts")
                    .font(.caption2)
                    .monospacedDigit()
                    .foregroundStyle(NettoColor.textTertiary)
            }

            Spacer(minLength: NettoLayout.Spacing.sm)

            NettoIcon(name: "chevron.right", size: NettoIconSize.control, weight: .semibold, tint: NettoColor.textTertiary)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }

    /// Initials of the group's first member — identification aid only, always from the
    /// on-device dataset. Falls back to a neutral glyph when the dataset is unavailable.
    private func avatar(for group: ContactDuplicateGroup) -> some View {
        ZStack {
            Circle()
                .fill(NettoColor.brand.opacity(0.16))
            Text(initials(for: group))
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .foregroundStyle(NettoColor.brandDeep)
                .minimumScaleFactor(0.6)
                .lineLimit(1)
        }
        .frame(width: 40, height: 40)
        .accessibilityHidden(true)
    }

    private func initials(for group: ContactDuplicateGroup) -> String {
        guard case .completed(let dataset) = env.contactScanState else { return "?" }
        guard let name = group.memberIDs.compactMap({ dataset.record(for: $0)?.displayName }).first
        else { return "?" }
        let parts = name.split(separator: " ").prefix(2)
        let letters = parts.compactMap(\.first).map(String.init).joined()
        return letters.isEmpty ? String(name.prefix(1)) : letters.uppercased()
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

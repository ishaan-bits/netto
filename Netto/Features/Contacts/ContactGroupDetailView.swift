import SwiftUI

/// One likely-duplicate group: inspect each contact, choose what to do, and hand an explicit
/// choice to the shared review → confirmation → mutation pipeline.
///
/// This screen never mutates Contacts. It writes only the group selection (checkboxes and the
/// merge destination) through `AppEnvironment.mutateContactSelection`, which stales any
/// prepared plan the moment the selection changes. Nothing is pre-selected, and no "master"
/// contact is chosen for the user.
struct ContactGroupDetailView: View {
    @EnvironmentObject private var env: AppEnvironment
    @Environment(\.dismiss) private var dismiss

    let group: ContactDuplicateGroup

    private var dataset: ContactDataset? {
        if case .completed(let completed) = env.contactScanState { return completed }
        return nil
    }

    /// The group as it exists in the *current* dataset — `nil` after a rescan removed it
    /// (e.g. the duplicates were already merged away).
    private var liveGroup: ContactDuplicateGroup? {
        dataset?.group(for: group.id)
    }

    var body: some View {
        Group {
            if let liveGroup, let dataset {
                content(liveGroup, dataset: dataset)
            } else {
                // The group vanished (rescan) — there is nothing to act on anymore.
                VStack(spacing: Theme.Spacing.lg) {
                    Spacer()
                    Image(systemName: "checkmark.circle")
                        .font(.system(size: 44))
                        .foregroundStyle(Theme.Palette.success)
                    Text("Group no longer exists")
                        .font(.title3.weight(.semibold))
                    Text("These contacts changed since you opened them. The list has the current groups.")
                        .font(.subheadline)
                        .foregroundStyle(Theme.Palette.secondaryLabel)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, Theme.Spacing.xl)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
                .onAppear { dismiss() }
            }
        }
        .navigationTitle("Likely Duplicates")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            guard let liveGroup else { return }
            // Rebind the selection to this group every time the screen appears, so a stale
            // selection from another group can never feed this group's plan.
            if env.contactSelection.groupID != liveGroup.id {
                env.openContactGroup(liveGroup)
            } else {
                env.synchronizeContactDataset()
            }
        }
        .onChange(of: env.contactScanState) { _, _ in
            env.synchronizeContactDataset()
        }
    }

    // MARK: Content

    private func content(_ group: ContactDuplicateGroup, dataset: ContactDataset) -> some View {
        List {
            Section {
                ForEach(group.reasons, id: \.rawValue) { reason in
                    Label(reason.rawValue, systemImage: icon(for: reason))
                        .font(.subheadline)
                }
            } header: {
                Text("Why these are grouped")
            } footer: {
                Text("Netto can’t be certain these are the same person — review each contact and decide what to keep.")
            }

            Section("Contacts") {
                ForEach(group.memberIDs, id: \.self) { memberID in
                    if let record = dataset.record(for: memberID) {
                        memberRow(record)
                    }
                }
            }
        }
        .safeAreaInset(edge: .bottom) { actionBar }
    }

    private func memberRow(_ record: ContactRecord) -> some View {
        let isSelected = env.contactSelection.isSelected(record.identifier)
        let isDestination = env.contactSelection.destinationID == record.identifier
        return HStack(spacing: Theme.Spacing.md) {
            Button {
                env.mutateContactSelection { $0.toggle(record.identifier) }
            } label: {
                HStack(spacing: Theme.Spacing.md) {
                    ZStack {
                        Circle()
                            .fill(hue(for: record.identifier).opacity(0.25))
                            .frame(width: 44, height: 44)
                        Text(initials(for: record))
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(hue(for: record.identifier))
                    }
                    .overlay {
                        Circle()
                            .stroke(isSelected ? Theme.Palette.accent : .clear, lineWidth: 2)
                    }

                    VStack(alignment: .leading, spacing: 2) {
                        Text(record.displayName)
                            .font(.body.weight(.medium))
                            .foregroundStyle(Theme.Palette.label)
                        if !record.organizationName.isEmpty {
                            Text(record.organizationName)
                                .font(.caption)
                                .foregroundStyle(Theme.Palette.secondaryLabel)
                                .lineLimit(1)
                        }
                        if let line = contactLine(for: record) {
                            Text(line)
                                .font(.caption)
                                .foregroundStyle(Theme.Palette.secondaryLabel)
                                .lineLimit(1)
                        }
                    }

                    Spacer(minLength: Theme.Spacing.sm)

                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.title3)
                        .foregroundStyle(isSelected ? Theme.Palette.accent : Theme.Palette.separator)
                }
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("contactRow-\(record.identifier)")
            .accessibilityValue(isSelected ? "Selected" : "Not selected")

            Button {
                env.mutateContactSelection { selection in
                    if !selection.isSelected(record.identifier) {
                        selection.toggle(record.identifier)
                    }
                    selection.setDestination(record.identifier)
                }
            } label: {
                VStack(spacing: 2) {
                    Image(systemName: isDestination ? "star.circle.fill" : "star.circle")
                        .font(.title3)
                        .foregroundStyle(isDestination ? Theme.Palette.warning : Theme.Palette.separator)
                    Text("Keep")
                        .font(.caption2)
                        .foregroundStyle(isDestination ? Theme.Palette.warning : Theme.Palette.secondaryLabel)
                }
            }
            .buttonStyle(.plain)
            .disabled(!isSelected)
            .accessibilityIdentifier("keepButton-\(record.identifier)")
            .accessibilityLabel("Keep \(record.displayName)")
        }
        .padding(.vertical, 2)
    }

    // MARK: Bottom bar

    private var actionBar: some View {
        HStack(spacing: Theme.Spacing.md) {
            VStack(alignment: .leading, spacing: 0) {
                Text("\(env.contactSelection.selectedCount) of \(env.contactSelection.datasetCount) selected")
                    .font(.subheadline.weight(.semibold))
                    .monospacedDigit()
                Text("Nothing is changed yet")
                    .font(.caption2)
                    .foregroundStyle(Theme.Palette.secondaryLabel)
            }

            Spacer()

            NavigationLink {
                ContactReviewView(choice: .merge)
            } label: {
                Text("Merge")
            }
            .buttonStyle(.bordered)
            .disabled(!canMerge)
            .accessibilityIdentifier("mergeSelectedButton")

            NavigationLink {
                ContactReviewView(choice: .delete)
            } label: {
                Text("Delete")
            }
            .buttonStyle(.borderedProminent)
            .tint(Theme.Palette.danger)
            .disabled(env.contactSelection.isEmpty)
            .accessibilityIdentifier("deleteSelectedButton")
        }
        .padding(Theme.Spacing.md)
        .background(.bar)
    }

    private var canMerge: Bool {
        env.contactSelection.selectedCount >= 2
            && env.contactSelection.destinationID != nil
    }

    // MARK: Helpers

    private func icon(for reason: ContactDuplicateReason) -> String {
        switch reason {
        case .sharedPhone: return "phone"
        case .sharedEmail: return "envelope"
        case .sharedNameOrganization: return "building.2"
        }
    }

    private func contactLine(for record: ContactRecord) -> String? {
        var parts: [String] = []
        if let phone = record.phoneNumbers.first?.value { parts.append(phone) }
        if let email = record.emailAddresses.first?.value { parts.append(email) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private func initials(for record: ContactRecord) -> String {
        let given = record.givenName.prefix(1)
        let family = record.familyName.prefix(1)
        let combined = "\(given)\(family)"
        if !combined.isEmpty { return String(combined).uppercased() }
        return String(record.displayName.prefix(1)).uppercased()
    }

    /// Deterministic accent per contact — visual identity only, never leaves the device.
    private func hue(for id: String) -> Color {
        var hash: UInt32 = 5381
        for byte in id.utf8 {
            hash = hash &* 33 &+ UInt32(byte)
        }
        return Color(hue: Double(hash % 360) / 360.0, saturation: 0.55, brightness: 0.85)
    }
}

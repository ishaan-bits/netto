import SwiftUI

/// The final review before a contacts change: exactly which contacts are involved, what a
/// merge will copy or keep, and the only place a destructive contacts action can be started.
///
/// This screen never mutates Contacts by itself. The destructive button only opens a system
/// confirmation dialog; the dialog's confirm action is the sole call path into
/// `AppEnvironment.confirmContactAction()`, and `ContactActionState.canTransition` refuses to
/// reach `.executing` from any state other than `.awaitingConfirmation`. Every count, merge
/// decision, and conflict shown here comes from the immutable `ContactActionPlan` — the view
/// stores nothing but the dialog flag.
struct ContactReviewView: View {
    @EnvironmentObject private var env: AppEnvironment
    @Environment(\.dismiss) private var dismiss
    @State private var showConfirmation = false

    /// Which action this review was opened with. The plan is always built for this choice — a
    /// prepared delete plan can never be presented under a merge review or vice versa.
    let choice: ContactActionChoice

    var body: some View {
        content
            .navigationTitle("Review")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear {
                env.contactReviewDidAppear(choice)
            }
    }

    // MARK: Phase dispatch

    @ViewBuilder
    private var content: some View {
        switch env.contactActionState {
        case .noSelection:
            if env.contactSelection.isEmpty {
                contactPhaseMessage(
                    systemImage: "checkmark.circle",
                    title: "Nothing is marked",
                    message: "No contacts are selected. Choose contacts in the duplicate group first, then come back to review them."
                )
            } else {
                buildingState
            }

        case .preparingPlan:
            buildingState

        case .readyForReview(let plan), .awaitingConfirmation(let plan):
            reviewContent(plan)

        case .planStale(let plan, let reasons):
            staleState(reasons, choice: contactReviewChoice(for: plan))

        case .executing(let plan):
            executingState(plan)

        case .succeeded(let success):
            resultState(success, isPartial: false)

        case .needsReview(let success):
            resultState(success, isPartial: true)

        case .failed(let message):
            failureState(message)

        case .permissionRequired(let state):
            permissionState(state)
        }
    }

    /// A stale review re-prepares the choice it was built for (never a different one).
    private func contactReviewChoice(for plan: ContactActionPlan) -> ContactActionChoice {
        if case .merge = plan.kind { return .merge }
        return .delete
    }

    // MARK: Review

    private func reviewContent(_ plan: ContactActionPlan) -> some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                    Text(ContactsPresentation.actionSummary(for: plan))
                        .font(.headline)
                    Text("\(plan.count) \(plan.count == 1 ? "contact" : "contacts") selected")
                        .font(.subheadline)
                        .foregroundStyle(Theme.Palette.secondaryLabel)
                }
                .padding(.vertical, Theme.Spacing.xs)
                .accessibilityIdentifier("contactReviewSummary")
            }

            Section(kindHeader(plan)) {
                ForEach(plan.items) { item in
                    itemRow(item, plan: plan)
                }
            }

            if case .merge(let merge) = plan.kind {
                mergeSections(merge)
            }

            Section {
                Label(
                    plan.isDelete
                        ? "Deleted contacts are removed immediately — this cannot be undone from Netto."
                        : "The contact you keep stays; the duplicate contacts are removed after their unique details are copied in.",
                    systemImage: plan.isDelete ? "trash" : "arrow.triangle.merge"
                )
                Label(
                    "Only the contacts listed above are touched; nothing else changes.",
                    systemImage: "checkmark.shield"
                )
            } footer: {
                Text("Detection and review are local to this iPhone. Nothing is merged or deleted until you confirm.")
            }
            .font(.caption)
            .foregroundStyle(Theme.Palette.secondaryLabel)
        }
        // Applied to the List itself — *before* `.safeAreaInset` — so it marks the list
        // without also overwriting the identifiers of the inset action buttons.
        .accessibilityIdentifier("contactReviewList")
        .safeAreaInset(edge: .bottom) {
            actionBar(plan)
        }
        .confirmationDialog(
            ContactsPresentation.confirmationTitle(for: plan),
            isPresented: $showConfirmation,
            titleVisibility: .visible
        ) {
            Button(role: .destructive) {
                env.beginContactConfirmation()
                Task { await env.confirmContactAction() }
            } label: {
                Text(ContactsPresentation.destructiveTitle(for: plan))
            }
            Button("Go Back", role: .cancel) {
                env.cancelContactConfirmation()
            }
        } message: {
            Text(ContactsPresentation.actionSummary(for: plan).capitalized
                 + (plan.isDelete
                    ? " — deleted contacts are removed immediately."
                    : " — the kept contact stays, duplicates are removed."))
        }
    }

    private func kindHeader(_ plan: ContactActionPlan) -> String {
        plan.isDelete ? "To be deleted" : "To be merged"
    }

    private func itemRow(_ item: ContactPlanItem, plan: ContactActionPlan) -> some View {
        let isDestination: Bool
        let roleText: String
        if case .merge(let merge) = plan.kind {
            isDestination = item.identifier == merge.destinationID
            roleText = isDestination ? "Kept" : "Merged into it"
        } else {
            isDestination = false
            roleText = "Deleted"
        }
        return HStack(spacing: Theme.Spacing.md) {
            ZStack {
                Circle()
                    .fill(Theme.Palette.accent.opacity(0.2))
                    .frame(width: 40, height: 40)
                Text(initials(item.displayName))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Theme.Palette.accent)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(item.displayName)
                    .font(.subheadline)
                Text(roleText
                     + " · \(item.phoneCount) \(item.phoneCount == 1 ? "number" : "numbers")"
                     + " · \(item.emailCount) \(item.emailCount == 1 ? "email" : "emails")")
                    .font(.caption)
                    .foregroundStyle(Theme.Palette.secondaryLabel)
            }

            Spacer()

            Image(systemName: isDestination ? "star.circle.fill" : (plan.isDelete ? "trash" : "arrow.right.circle"))
                .foregroundStyle(isDestination ? Theme.Palette.warning : Theme.Palette.danger)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("contactReviewItem-\(item.identifier)")
    }

    /// Merge transparency: exactly what will be copied in, and exactly what will be kept
    /// instead of copied. Nothing here is decided at execution time.
    @ViewBuilder
    private func mergeSections(_ merge: ContactMergePlan) -> some View {
        if !merge.appendedPhones.isEmpty || !merge.appendedEmails.isEmpty {
            Section("Added to the kept contact") {
                ForEach(merge.appendedPhones) { phone in
                    Label("\(phone.value) (\(phone.label))", systemImage: "phone")
                }
                ForEach(merge.appendedEmails) { email in
                    Label("\(email.value) (\(email.label))", systemImage: "envelope")
                }
            }
            .font(.subheadline)
        }

        Section("Kept as-is") {
            let kept = [merge.retainedGivenName, merge.retainedFamilyName]
                .filter { !$0.isEmpty }
                .joined(separator: " ")
            Text(kept.isEmpty ? "Name unchanged" : kept)
            if !merge.retainedOrganizationName.isEmpty {
                Text(merge.retainedOrganizationName)
            }
        }
        .font(.subheadline)

        if !merge.conflicts.isEmpty {
            Section {
                ForEach(merge.conflicts) { conflict in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(conflict.field.rawValue)
                            .font(.subheadline.weight(.medium))
                        Text("“\(conflict.kept)” is kept · “\(conflict.notCopied)” is not copied")
                            .font(.caption)
                            .foregroundStyle(Theme.Palette.secondaryLabel)
                    }
                }
            } header: {
                Text("Different values kept")
            } footer: {
                Text("The contact you keep wins: its values are not overwritten.")
            }
            .font(.subheadline)
        }
    }

    private func actionBar(_ plan: ContactActionPlan) -> some View {
        HStack(spacing: Theme.Spacing.md) {
            Button {
                dismiss()
            } label: {
                Text("Change Selection")
            }
            .buttonStyle(.bordered)

            Spacer()

            Button(role: .destructive) {
                showConfirmation = true
            } label: {
                Text(ContactsPresentation.destructiveTitle(for: plan))
            }
            .buttonStyle(.borderedProminent)
            .tint(Theme.Palette.danger)
            .accessibilityIdentifier("contactReviewActionButton")
        }
        .padding(Theme.Spacing.md)
        .background(.bar)
    }

    // MARK: Other states

    private var buildingState: some View {
        VStack(spacing: Theme.Spacing.lg) {
            Spacer()
            ProgressView()
            Text("Preparing your review…")
                .font(.subheadline)
                .foregroundStyle(Theme.Palette.secondaryLabel)
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, Theme.Spacing.xl)
    }

    private func executingState(_ plan: ContactActionPlan) -> some View {
        VStack(spacing: Theme.Spacing.lg) {
            Spacer()
            ProgressView()
            Text(plan.isDelete ? "Deleting contacts…" : "Merging contacts…")
                .font(.headline)
            Text("Netto is applying exactly the contacts you reviewed. Don’t switch away — the result is verified against Contacts before it is reported.")
                .font(.subheadline)
                .foregroundStyle(Theme.Palette.secondaryLabel)
                .multilineTextAlignment(.center)
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, Theme.Spacing.xl)
    }

    private func staleState(
        _ reasons: [ContactPlanStalenessReason],
        choice: ContactActionChoice
    ) -> some View {
        contactPhaseMessage(
            systemImage: "exclamationmark.arrow.circlepath",
            title: "Review out of date",
            message: ContactsPresentation.staleMessage(reasons),
            primaryTitle: "Review Again"
        ) {
            env.prepareContactAction(choice)
        }
    }

    private func resultState(_ success: ContactMutationSuccess, isPartial: Bool) -> some View {
        contactPhaseMessage(
            systemImage: isPartial ? "exclamationmark.circle" : "checkmark.circle.fill",
            title: isPartial ? "Some contacts remain" : (success.isMerge ? "Merged" : "Deleted"),
            message: ContactsPresentation.successMessage(for: success),
            primaryTitle: "Done"
        ) {
            env.dismissContactActionResult()
            dismiss()
        }
    }

    private func failureState(_ message: String) -> some View {
        contactPhaseMessage(
            systemImage: "exclamationmark.triangle",
            title: "Contacts could not be changed",
            message: message,
            primaryTitle: "Review Again"
        ) {
            env.prepareContactAction(choice)
        }
    }

    private func permissionState(_ state: PermissionState) -> some View {
        contactPhaseMessage(
            systemImage: "lock.fill",
            title: "Contacts access needed",
            message: ContactsPresentation.permissionMessage(for: state),
            primaryTitle: "Open Settings"
        ) {
            openSettings()
        }
    }

    private func openSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }

    private func initials(_ name: String) -> String {
        let parts = name.split(separator: " ").prefix(2)
        let letters = parts.compactMap { $0.first }
        return letters.isEmpty ? String(name.prefix(1)).uppercased() : String(letters).uppercased()
    }
}

/// Full-screen state view for the non-review phases of this screen.
private struct ContactReviewPhaseMessage: View {
    let systemImage: String
    let title: String
    let message: String
    var primaryTitle: String?
    var primaryAction: () -> Void = {}

    var body: some View {
        VStack(spacing: Theme.Spacing.lg) {
            Spacer(minLength: Theme.Spacing.xl)
            Image(systemName: systemImage)
                .font(.system(size: 44))
                .foregroundStyle(Theme.Palette.accent)
            Text(title)
                .font(.title3.weight(.semibold))
                .multilineTextAlignment(.center)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(Theme.Palette.secondaryLabel)
                .multilineTextAlignment(.center)
                .padding(.horizontal, Theme.Spacing.xl)
            if let primaryTitle {
                Button(primaryTitle, action: primaryAction)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
            }
            Spacer(minLength: Theme.Spacing.xl)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private extension ContactReviewView {
    func contactPhaseMessage(
        systemImage: String,
        title: String,
        message: String,
        primaryTitle: String? = nil,
        action: @escaping () -> Void = {}
    ) -> some View {
        ContactReviewPhaseMessage(
            systemImage: systemImage,
            title: title,
            message: message,
            primaryTitle: primaryTitle,
            primaryAction: action
        )
    }
}

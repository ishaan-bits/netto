import Foundation

// MARK: - Duplicate Contacts orchestration
//
// The contacts pipeline mirrors the Photos one: scan (read-only) → detect → select →
// immutable plan → review → confirmation → mutation → verification. Every state change goes
// through the guarded `applyContactAction`, every async completion re-checks its generation,
// and the only type that can reach Contacts writes is `ConfirmedContactActionPlan` handed to
// `contactMutationService`.
@MainActor
extension AppEnvironment {
    // MARK: Scan (read + detection)

    /// Starts a contacts scan if none is running and one is due (first appear, or the last
    /// scan was cancelled). Completed and failed states are left alone — those are explicit
    /// user actions (Retry / nothing).
    func startContactScanIfNeeded() {
        guard !contactScanState.isRunning else { return }
        switch contactScanState {
        case .notStarted, .cancelled:
            startContactScan()
        case .completed, .failed, .running:
            break
        }
    }

    /// Reads all visible contacts and runs local duplicate detection over them.
    ///
    /// Read-only: no Contacts mutation can happen from here (or anywhere outside
    /// `contactMutationService`). A fresh scan supersedes any prepared contacts plan and
    /// resets the group selection — plans are bound to the dataset they were built from.
    func startContactScan() {
        guard !contactScanState.isRunning else { return }
        // Never rebuild datasets underneath an in-flight contacts mutation.
        guard !contactActionState.isExecuting else { return }
        guard contactsPermissionState.isUsable else { return }

        applyContactAction(.noSelection)
        contactReviewChoice = nil
        contactSelection.reset()

        contactScanGeneration += 1
        let generation = contactScanGeneration
        contactScanTask?.cancel()
        contactScanState = .running

        let reader = makeContactReader()
        contactScanTask = Task { [weak self] in
            guard let self else { return }
            do {
                let dataset = try await Self.buildContactDataset(reader: reader)
                guard self.isCurrentContactScan(generation) else { return }
                self.contactScanState = .completed(dataset)
                self.synchronizeContactDataset()
            } catch is CancellationError {
                guard self.isCurrentContactScan(generation) else { return }
                self.contactScanState = .cancelled
            } catch ContactReadError.cancelled {
                guard self.isCurrentContactScan(generation) else { return }
                self.contactScanState = .cancelled
            } catch ContactReadError.accessDenied {
                guard self.isCurrentContactScan(generation) else { return }
                self.contactScanState = .failed(
                    "Contacts access is required to find duplicates. Enable it in Settings."
                )
            } catch ContactReadError.failed(let message) {
                guard self.isCurrentContactScan(generation) else { return }
                self.contactScanState = .failed(message)
            } catch {
                guard self.isCurrentContactScan(generation) else { return }
                self.contactScanState = .failed(
                    "Contacts could not be read on this iPhone. Try again in a moment."
                )
            }
        }
    }

    /// Cancels the in-flight scan. The generation bump makes any late completion a no-op, so
    /// the state can never flip back after this returns.
    func cancelContactScan() {
        contactScanGeneration += 1
        contactScanTask?.cancel()
        contactScanTask = nil
        if contactScanState.isRunning {
            contactScanState = .cancelled
        }
    }

    /// Read + detection off the main actor (the actor-bound caller hops here), returning only
    /// plain values. Cancellation is checked inside enumeration and after every await.
    nonisolated private static func buildContactDataset(
        reader: any ContactReading
    ) async throws -> ContactDataset {
        let records = try await reader.readContacts()
        let groups = ContactDuplicateDetector().findDuplicates(in: records)
        return ContactDataset(records: records, groups: groups)
    }

    private func isCurrentContactScan(_ generation: Int) -> Bool {
        contactScanGeneration == generation
    }

    // MARK: Dataset synchronization

    /// Reconciles the group selection with the current dataset and stales any prepared
    /// contacts plan whose selection or dataset no longer matches. Called whenever a scan
    /// completes and whenever the contacts screen appears.
    func synchronizeContactDataset() {
        switch contactScanState {
        case .completed(let dataset):
            let group = contactSelection.groupID.flatMap { dataset.group(for: $0) }
            contactSelection.reconcile(
                groupID: group?.id,
                memberIDs: Set(group?.memberIDs ?? [])
            )
        case .notStarted, .cancelled, .failed:
            contactSelection.reset()
        case .running:
            break // A rebuild is in flight; reconcile again when it completes.
        }

        switch contactActionState {
        case .readyForReview(let plan), .awaitingConfirmation(let plan):
            if contactSelection.selectedIDs != plan.selectionSnapshot {
                applyContactAction(.planStale(plan, [.selectionChanged]))
            } else if currentContactDatasetSignature != plan.datasetSignature {
                applyContactAction(.planStale(plan, [.datasetChanged]))
            }
        default:
            break
        }
    }

    /// Fingerprint a contacts plan must match at execution time; `""` when there is no
    /// completed dataset (never matches a real plan's stamp, so such a plan is stale).
    private var currentContactDatasetSignature: String {
        guard case .completed(let dataset) = contactScanState else { return "" }
        return ContactDataset.signature(in: dataset)
    }

    // MARK: Selection

    /// The user changed the group selection after a plan was shown — the plan is immediately
    /// stale. This mirrors `mutateVideoSelection`: only a plan that exists is affected.
    func mutateContactSelection(_ mutation: (inout ContactGroupSelection) -> Void) {
        mutation(&contactSelection)
        switch contactActionState {
        case .readyForReview(let plan), .awaitingConfirmation(let plan):
            applyContactAction(.planStale(plan, [.selectionChanged]))
        default:
            break
        }
    }

    /// A duplicate group was opened: bind the selection to its members (empty — nothing is
    /// ever pre-selected, and no "master" contact is ever pre-chosen).
    func openContactGroup(_ group: ContactDuplicateGroup) {
        contactSelection.begin(groupID: group.id, memberIDs: group.memberIDs)
    }

    // MARK: Plan → confirmation → mutation → verification

    /// A contact review screen appeared with the given choice. A plan built for the *other*
    /// choice can never be shown or confirmed under this screen, so foreign state is dropped
    /// first; a matching plan is kept so re-entering the same review is stable.
    func contactReviewDidAppear(_ choice: ContactActionChoice) {
        if contactReviewChoice != choice {
            if case .noSelection = contactActionState {
                // Already empty; nothing foreign to drop.
            } else {
                applyContactAction(.noSelection)
            }
            contactReviewChoice = nil
        }
        contactReviewChoice = choice
        if case .noSelection = contactActionState, !contactSelection.selectedIDs.isEmpty {
            prepareContactAction(choice)
        }
    }

    /// Builds an immutable contacts plan from the current group selection and `choice`.
    ///
    /// Synchronous by design (no size resolution is involved): the snapshot, the merge
    /// decisions, and the fresh authorization stamp are captured together, then immediately
    /// self-checked against the *current* context — a selection or dataset change lands the
    /// plan in `.planStale`, never in `.readyForReview`.
    func prepareContactAction(_ choice: ContactActionChoice) {
        switch contactActionState {
        case .preparingPlan, .awaitingConfirmation, .executing, .succeeded, .needsReview:
            return
        default:
            break
        }
        contactReviewChoice = choice

        guard !contactSelection.selectedIDs.isEmpty else {
            applyContactAction(.noSelection)
            return
        }
        applyContactAction(.preparingPlan)

        guard case .completed(let dataset) = contactScanState else {
            applyContactAction(
                .failed("Your contacts scan has not finished. Scan again, then review.")
            )
            return
        }

        let selectedIDs = contactSelection.selectedIDs
        let recordsByID = Dictionary(
            dataset.records.map { ($0.identifier, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let selectedRecords = selectedIDs
            .compactMap { recordsByID[$0] }
            .sorted { $0.identifier < $1.identifier }
        guard selectedRecords.count == selectedIDs.count else {
            applyContactAction(
                .failed("Some selected contacts are no longer available. Scan again, then review.")
            )
            return
        }

        // Kind + (for merge) every field decision, from the same snapshot.
        let kind: ContactActionKind
        switch choice {
        case .delete:
            kind = .delete
        case .merge:
            guard selectedIDs.count >= 2,
                  let destinationID = contactSelection.destinationID,
                  selectedIDs.contains(destinationID),
                  let destinationRecord = recordsByID[destinationID] else {
                applyContactAction(
                    .failed("Select at least two contacts and choose which one to keep.")
                )
                return
            }
            let sources = selectedRecords.filter { $0.identifier != destinationID }
            guard !sources.isEmpty else {
                applyContactAction(.failed("Choose which contacts to merge into it."))
                return
            }
            kind = .merge(
                ContactMergePlanner.decisions(destination: destinationRecord, sources: sources)
            )
        }

        let authorization = contactsPermission.currentStatus()
        let plan = ContactActionPlan(
            schemaVersion: ContactActionPlan.currentVersion,
            items: selectedRecords.map(ContactPlanItem.init(record:)),
            kind: kind,
            authorization: authorization,
            sessionToken: deletionSessionToken,
            datasetSignature: currentContactDatasetSignature
        )

        // Self-check against the context as it is *now* — synchronous build means the only
        // drift possible is between the snapshot above and this line (same run-loop turn).
        let reasons = ContactPlanValidator.stalenessReasons(
            plan: plan,
            context: contactPlanExecutionContext(),
            freshAuthorization: authorization
        )
        if reasons.isEmpty {
            applyContactAction(.readyForReview(plan))
        } else {
            applyContactAction(.planStale(plan, reasons))
        }
    }

    /// First step of the destructive confirmation — the only route to `.awaitingConfirmation`.
    func beginContactConfirmation() {
        guard case .readyForReview(let plan) = contactActionState else { return }
        applyContactAction(.awaitingConfirmation(plan))
    }

    /// The confirmation dialog was cancelled. No mutation has happened.
    func cancelContactConfirmation() {
        guard case .awaitingConfirmation(let plan) = contactActionState else { return }
        applyContactAction(.readyForReview(plan))
    }

    /// Executes a confirmed action. No confirmation ⇒ no mutation: the guard makes it
    /// impossible to reach the service from any state other than `.awaitingConfirmation`.
    func confirmContactAction() async {
        guard case .awaitingConfirmation(let plan) = contactActionState else { return }
        applyContactAction(.executing(plan))

        let confirmed: ConfirmedContactActionPlan
        do {
            confirmed = try plan.confirmed()
        } catch {
            await handleContactOutcome(.rejected(.emptyPlan))
            return
        }

        // The final context is read here — the same moment the service re-reads authorization —
        // so a selection/session/dataset change invalidates the plan before any mutation.
        let outcome = await contactMutationService.execute(
            confirmed,
            in: contactPlanExecutionContext()
        )
        await handleContactOutcome(outcome)
    }

    /// Leaves a terminal result state (also used to leave `.planStale`).
    func dismissContactActionResult() {
        applyContactAction(.noSelection)
    }

    private func contactPlanExecutionContext() -> ContactPlanExecutionContext {
        ContactPlanExecutionContext(
            selectionIDs: contactSelection.selectedIDs,
            sessionToken: deletionSessionToken,
            datasetSignature: currentContactDatasetSignature
        )
    }

    private func handleContactOutcome(_ outcome: ContactActionOutcome) async {
        switch outcome {
        case .succeeded(let success):
            if success.isFullyRemoved {
                applyContactAction(.succeeded(success))
            } else {
                applyContactAction(.needsReview(success))
            }
            // Contacts changed: drop every dataset-derived fact so nothing stale is shown again.
            resetContactsStateAfterMutation()

        case .stale(let reasons):
            if case .executing(let plan) = contactActionState {
                applyContactAction(.planStale(plan, reasons))
            } else {
                assertionFailure("stale contact outcome outside .executing")
            }

        case .permissionDenied(let state):
            applyContactAction(.permissionRequired(state))

        case .rejected:
            applyContactAction(.noSelection)

        case .mutationFailed:
            applyContactAction(.failed(ContactsPresentation.userFacingFailure(for: outcome)))

        case .verificationFailed(let message), .revalidationFailed(let message):
            applyContactAction(.failed(message))

        case .cancelled:
            if case .executing(let plan) = contactActionState {
                applyContactAction(.readyForReview(plan))
            } else {
                assertionFailure("cancelled contact outcome outside .executing")
            }
        }
    }

    /// Selection reset, in-flight scan invalidated, and the dataset marked for a fresh read —
    /// contacts changed, so nothing read before the mutation may be reused. The groups will
    /// be recomputed from the live store on the next scan.
    private func resetContactsStateAfterMutation() {
        contactReviewChoice = nil
        contactSelection.reset()
        contactScanGeneration += 1
        contactScanTask?.cancel()
        contactScanTask = nil
        contactScanState = .notStarted
    }

    /// Single gate for every contacts action state change: legal transitions are applied,
    /// illegal ones trip an assertion in debug instead of silently corrupting the machine.
    private func applyContactAction(_ target: ContactActionState) {
        guard ContactActionState.canTransition(from: contactActionState, to: target) else {
            assertionFailure("Illegal contact action transition \(contactActionState) -> \(target)")
            return
        }
        contactActionState = target
    }
}

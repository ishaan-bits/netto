import Foundation
import Testing
@testable import Netto

/// Records every save and reload request instead of touching the App Group container or
/// WidgetCenter. All mutation happens behind sync helpers so the async protocol
/// requirements never lock from an async context.
private final class RecordingWidgetSummaryStore: WidgetSummaryStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: WidgetSummary?
    private var saved: [WidgetSummary] = []
    private var reloads = 0

    init(preloaded: WidgetSummary? = nil) {
        stored = preloaded
    }

    func load() async -> WidgetSummary? { currentStored() }
    func save(_ summary: WidgetSummary) async throws { record(summary) }
    func requestWidgetReload() { recordReload() }

    private func currentStored() -> WidgetSummary? {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    private func record(_ summary: WidgetSummary) {
        lock.lock()
        defer { lock.unlock() }
        saved.append(summary)
        stored = summary
    }

    private func recordReload() {
        lock.lock()
        defer { lock.unlock() }
        reloads += 1
    }

    func recorded() -> (saves: [WidgetSummary], reloads: Int, latest: WidgetSummary?) {
        lock.lock()
        defer { lock.unlock() }
        return (saved, reloads, stored)
    }
}

/// Scan snapshot store that has never seen a scan — keeps launch tests independent of
/// any persisted scan file on the machine.
private struct NeverScanSnapshotStore: ScanSnapshotStore {
    func save(_ snapshot: ScanSnapshot) throws {}
    func loadLatest() -> ScanSnapshot? { nil }
    func clear() {}
}

// MARK: - The app's writes into the shared widget summary

@MainActor
struct AppEnvironmentWidgetSummaryTests {
    private func makeEnvironment(
        store: RecordingWidgetSummaryStore
    ) -> AppEnvironment {
        AppEnvironment(
            scanSnapshotStore: NeverScanSnapshotStore(),
            widgetSummaryStore: store
        )
    }

    private func summary(
        status: WidgetSummary.Status,
        estimateBytes: Int64? = nil,
        isEstimated: Bool = false
    ) throws -> WidgetSummary {
        try #require(WidgetSummary(
            schemaVersion: WidgetSummary.currentSchemaVersion,
            status: status,
            estimateBytes: estimateBytes,
            isEstimated: isEstimated,
            updatedAt: Date(timeIntervalSince1970: 1_759_000_000)
        ))
    }

    private func measuredCleanup(bytes: Int64) throws -> SpaceFreedSummary {
        let plan = DeletionPlan(
            schemaVersion: DeletionPlan.currentVersion,
            items: [
                DeletionPlanItem(
                    localIdentifier: "a", mediaType: .image, sizeInBytes: bytes, category: nil
                )
            ],
            authorization: .authorized,
            sessionToken: "s",
            analysisSignature: "sig"
        )
        let success = DeletionSuccess(
            plannedCount: 1, verifiedRemovedCount: 1, remainingIDs: []
        )
        return try #require(SpaceFreedSummary(plan: plan, success: success))
    }

    // MARK: Mandated area 9 — app writes update the shared summary (and reload)

    @Test func scanCompletionWritesScanReadyAndRequestsAReload() async throws {
        let store = RecordingWidgetSummaryStore()
        let env = makeEnvironment(store: store)
        let completedAt = Date(timeIntervalSince1970: 1_759_000_000)

        await env.writeWidgetSummaryAfterScanCompleted(at: completedAt)

        let recorded = store.recorded()
        #expect(recorded.saves.count == 1)
        #expect(recorded.reloads == 1)
        let written = try #require(recorded.saves.first)
        #expect(written.status == .scanReady)
        // A scan measures nothing — the widget gets a status, never a number.
        #expect(written.estimateBytes == nil)
        #expect(written.isEstimated == false)
        #expect(written.updatedAt == completedAt)
        #expect(recorded.latest?.status == .scanReady)
    }

    @Test func scanCompletionReplacesAnOlderCleanupFigure() async throws {
        // Most recent event wins: today's scan is newer information than an older
        // cleanup's figure, and its completion date is the honest timestamp for it.
        let store = RecordingWidgetSummaryStore(preloaded: try summary(
            status: .lastCleanup, estimateBytes: 2_500, isEstimated: true
        ))
        let env = makeEnvironment(store: store)

        await env.writeWidgetSummaryAfterScanCompleted(at: Date())

        let recorded = store.recorded()
        #expect(recorded.saves.count == 1)
        #expect(recorded.latest?.status == .scanReady)
        #expect(recorded.latest?.estimateBytes == nil)
        #expect(recorded.reloads == 1)
    }

    @Test func confirmedCleanupWritesTheMeasuredFigureAndRequestsAReload() async throws {
        let store = RecordingWidgetSummaryStore()
        let env = makeEnvironment(store: store)
        let freed = try measuredCleanup(bytes: 1_400_000_000)

        await env.writeWidgetSummaryAfterCleanup(freed)

        let recorded = store.recorded()
        #expect(recorded.saves.count == 1)
        #expect(recorded.reloads == 1)
        let written = try #require(recorded.saves.first)
        #expect(written.status == .lastCleanup)
        #expect(written.estimateBytes == freed.measuredBytes)
        #expect(written.isEstimated == true)
        #expect(abs(written.updatedAt.timeIntervalSinceNow) < 60)
    }

    @Test func cleanupWithoutMeasuredBytesWritesNothing() async throws {
        // Nothing was measured → `hasSpaceFigure` is false → the widget must keep its
        // previous state rather than receive a zero or an invented amount.
        let store = RecordingWidgetSummaryStore()
        let env = makeEnvironment(store: store)
        let unmeasuredPlan = DeletionPlan(
            schemaVersion: DeletionPlan.currentVersion,
            items: [
                DeletionPlanItem(
                    localIdentifier: "a", mediaType: .image, sizeInBytes: nil, category: nil
                )
            ],
            authorization: .authorized,
            sessionToken: "s",
            analysisSignature: "sig"
        )
        let success = DeletionSuccess(
            plannedCount: 1, verifiedRemovedCount: 1, remainingIDs: []
        )
        let freed = try #require(SpaceFreedSummary(plan: unmeasuredPlan, success: success))
        #expect(!freed.hasSpaceFigure)

        await env.writeWidgetSummaryAfterCleanup(freed)

        let recorded = store.recorded()
        #expect(recorded.saves.isEmpty)
        #expect(recorded.reloads == 0)
    }

    // MARK: The launch repair path

    @Test func launchWritesAnEmptySummaryOnlyWhenNoneExists() async throws {
        let store = RecordingWidgetSummaryStore()
        let env = makeEnvironment(store: store)

        await env.bootstrap()

        let recorded = store.recorded()
        #expect(recorded.saves.count == 1)
        #expect(recorded.saves.first?.status == .empty)
        #expect(recorded.reloads == 1)
        #expect(recorded.latest != nil)
    }

    @Test func launchNeverOverwritesAnExistingSummary() async throws {
        let existing = try summary(
            status: .lastCleanup, estimateBytes: 2_500, isEstimated: true
        )
        let store = RecordingWidgetSummaryStore(preloaded: existing)
        let env = makeEnvironment(store: store)

        await env.bootstrap()

        let recorded = store.recorded()
        #expect(recorded.saves.isEmpty)
        #expect(recorded.reloads == 0)
        #expect(recorded.latest == existing)
    }
}

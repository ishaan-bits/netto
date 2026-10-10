import Foundation
import Testing
@testable import Netto

// MARK: - File-backed store (temp directory only)

struct FileScanSnapshotStoreTests {
    private func makeStore() -> (store: FileScanSnapshotStore, directory: URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("netto-scan-state-\(UUID().uuidString)", isDirectory: true)
        return (FileScanSnapshotStore(directoryOverride: directory), directory)
    }

    @Test func roundTripPreservesTheCompletedResultExactly() throws {
        let (store, directory) = makeStore()
        let result = makeResult()
        let snapshot = ScanSnapshot(
            schemaVersion: ScanSnapshot.currentSchemaVersion,
            scanID: "scan-round-trip",
            completedAt: Date(timeIntervalSince1970: 1_759_000_000),
            result: result
        )

        try store.save(snapshot)
        let loaded = store.loadLatest()

        #expect(loaded == snapshot)
        // The full result — including the unavailable inventory — survives, so a relaunch
        // renders the same counts, groups, and placeholders the original scan produced.
        #expect(loaded?.result == result)
        try? FileManager.default.removeItem(at: directory)
    }

    @Test func firstLaunchWithoutASnapshotLoadsNil() {
        let (store, directory) = makeStore()
        #expect(store.loadLatest() == nil)
        try? FileManager.default.removeItem(at: directory)
    }

    @Test func corruptFileIsIgnoredWithoutThrowing() throws {
        let (store, directory) = makeStore()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("not json at all {{{".utf8).write(to: directory.appendingPathComponent("latest-scan.json"))

        #expect(store.loadLatest() == nil)
        try? FileManager.default.removeItem(at: directory)
    }

    @Test func incompatibleSchemaIsIgnoredInsteadOfCrashing() throws {
        let (store, directory) = makeStore()
        let future = ScanSnapshot(
            schemaVersion: ScanSnapshot.currentSchemaVersion + 98,
            scanID: "future",
            completedAt: Date(),
            result: makeResult()
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(future).write(
            to: directory.appendingPathComponent("latest-scan.json")
        )

        #expect(store.loadLatest() == nil)
        try? FileManager.default.removeItem(at: directory)
    }

    @Test func aNewSaveReplacesThePreviousSnapshot() throws {
        let (store, directory) = makeStore()
        let first = ScanSnapshot(
            schemaVersion: ScanSnapshot.currentSchemaVersion,
            scanID: "first",
            completedAt: Date(timeIntervalSince1970: 1_000),
            result: makeResult(total: 7)
        )
        let second = ScanSnapshot(
            schemaVersion: ScanSnapshot.currentSchemaVersion,
            scanID: "second",
            completedAt: Date(timeIntervalSince1970: 2_000),
            result: makeResult(total: 9)
        )

        try store.save(first)
        try store.save(second)

        let loaded = try #require(store.loadLatest())
        #expect(loaded.scanID == "second")
        #expect(loaded.result.totalRecordCount == 9)
        try? FileManager.default.removeItem(at: directory)
    }

    @Test func clearRemovesTheSnapshot() throws {
        let (store, directory) = makeStore()
        try store.save(makeSnapshot(scanID: "x"))
        store.clear()
        #expect(store.loadLatest() == nil)
        try? FileManager.default.removeItem(at: directory)
    }
}

// MARK: - Launch restoration through AppEnvironment

@MainActor
struct ScanSnapshotRestorationTests {
    @Test func firstRunStartsWithNoRestoredScan() async {
        let store = InMemoryScanSnapshotStore()
        let env = makeEnv(store: store)

        await env.bootstrap()

        #expect(env.analysisState == .notStarted)
        #expect(env.selection.selectedIDs.isEmpty)
        #expect(env.lastScanCompletedAt == nil)
        #expect(env.flowState == .dashboard)
        // Launch is read-only: bootstrap never writes a snapshot of its own.
        #expect(store.loadLatest() == nil)
        #expect(store.saveCount == 0)
    }

    @Test func restoredSnapshotRebuildsResultsSelectionAndDate() async {
        let store = InMemoryScanSnapshotStore()
        let seeded = makeSnapshot(scanID: "seeded-scan")
        try? store.save(seeded)
        let seededSaves = store.saveCount
        let env = makeEnv(store: store)

        await env.bootstrap()

        // Stale identifiers (never resolved against PhotoKit) restore without complaint:
        // same state path a fresh completion writes.
        #expect(env.analysisState == .completed(seeded.result))
        #expect(env.lastScanCompletedAt == seeded.completedAt)
        // Deterministic default selection over the restored groups: every member except
        // assets protected as a recommendation.
        #expect(env.selection.isSelected("stale-b"))
        #expect(!env.selection.isSelected("stale-a"))
        #expect(!env.selection.isSelected("stale-c"))
        #expect(env.selection.selectedIDs == ["stale-b"])
        // Restoring never mutates the persisted snapshot.
        #expect(store.saveCount == seededSaves)
        #expect(store.loadLatest() == seeded)
    }

    @Test func restoringNeverStartsANewAnalysis() async {
        let store = InMemoryScanSnapshotStore()
        try? store.save(makeSnapshot(scanID: "seeded-scan"))
        let calls = FactoryCallBox()
        let env = makeEnv(store: store) {
            calls.record()
            return FakeLibrary(records: [makeRecord(id: "x")])
        }

        await env.bootstrap()

        #expect(calls.count == 0)
        #expect(env.analysisState.isRunning == false)
    }

    @Test func restoredStateCannotPrepareADeletionPlan() async {
        let store = InMemoryScanSnapshotStore()
        try? store.save(makeSnapshot(scanID: "seeded-scan"))
        let env = makeEnv(store: store)

        await env.bootstrap()

        // The restored selection is reviewable, but the catalog was not rebuilt — plan
        // preparation stays fail-closed behind the existing completed-inputs guard.
        #expect(env.catalogState == .notStarted)
        env.prepareDeletionPlan()
        guard case .failed = env.deletionState else {
            Issue.record("expected failure without a completed catalog, got \(env.deletionState)")
            return
        }
    }

    @Test func cancelledRunLeavesThePersistedSnapshotUntouched() async {
        let store = InMemoryScanSnapshotStore()
        let seeded = makeSnapshot(scanID: "seeded-scan")
        try? store.save(seeded)
        let seededSaves = store.saveCount
        let env = makeEnv(store: store) {
            FakeLibrary(records: [makeRecord(id: "slow-1")], chunkDelay: 0.25)
        }
        // The app session opens on the restored snapshot, then the user scans and cancels.
        await env.bootstrap()
        #expect(env.lastScanCompletedAt == seeded.completedAt)

        env.startSimilarityAnalysis()
        #expect(env.analysisState.isRunning)
        env.cancelSimilarityAnalysis()
        #expect(env.analysisState == .cancelled)

        try? await Task.sleep(for: .milliseconds(800))
        #expect(env.analysisState == .cancelled)
        // Neither the store nor the in-memory date moved: only completions replace.
        #expect(store.saveCount == seededSaves)
        #expect(store.loadLatest() == seeded)
        #expect(env.lastScanCompletedAt == seeded.completedAt)
    }

    @Test func failedRunLeavesThePersistedSnapshotUntouched() async {
        let store = InMemoryScanSnapshotStore()
        let seeded = makeSnapshot(scanID: "seeded-scan")
        try? store.save(seeded)
        let seededSaves = store.saveCount
        let env = makeEnv(store: store) {
            throw PhotoLibraryReadError.accessDenied
        }
        await env.bootstrap()

        env.startSimilarityAnalysis()
        // Reader creation happens inside the task now — wait for the run to fail.
        let finalState = await waitForAnalysis(env)
        guard case .failed = finalState else {
            Issue.record("expected failed analysis, got \(finalState)")
            return
        }
        #expect(store.saveCount == seededSaves)
        #expect(store.loadLatest() == seeded)
        #expect(env.lastScanCompletedAt == seeded.completedAt)
    }

    @Test func successfulRunReplacesTheSnapshot() async throws {
        let store = InMemoryScanSnapshotStore()
        let seeded = makeSnapshot(scanID: "seeded-scan")
        try? store.save(seeded)
        let env = makeEnv(store: store) {
            FakeLibrary(records: [makeRecord(id: "r1"), makeRecord(id: "r2")])
        }

        env.startSimilarityAnalysis()
        let finalState = await waitForAnalysis(env)
        guard case .completed(let result) = finalState else {
            Issue.record("expected completion, got \(finalState)")
            return
        }

        let replaced = try #require(store.loadLatest())
        #expect(replaced.scanID != seeded.scanID)
        #expect(replaced.schemaVersion == ScanSnapshot.currentSchemaVersion)
        #expect(replaced.result.totalRecordCount == 2)
        #expect(replaced.result == result)
        #expect(env.lastScanCompletedAt == replaced.completedAt)
        // Exactly two writes ever: the seed, then this completion.
        #expect(store.saveCount == 2)
    }
}

// MARK: - Dashboard presentation of the persisted date

struct ScanSnapshotDashboardTests {
    @Test func relativeTextIsDerivedFromThePersistedDate() {
        let now = Date(timeIntervalSince1970: 1_759_000_000)
        let minutes = DashboardPresentation.relativeLastScanned(
            from: now.addingTimeInterval(-300),
            now: now
        )
        let hours = DashboardPresentation.relativeLastScanned(
            from: now.addingTimeInterval(-7_200),
            now: now
        )
        let yesterday = DashboardPresentation.relativeLastScanned(
            from: now.addingTimeInterval(-86_400),
            now: now
        )
        #expect(minutes.contains("5 minutes"))
        #expect(hours.contains("2 hours"))
        #expect(yesterday.localizedCaseInsensitiveContains("1 day"))
    }

    @Test func finishedStatusForwardsTheRestoredDate() {
        let completedAt = Date(timeIntervalSince1970: 1_759_000_000)
        let status = DashboardPresentation.scanStatus(
            permission: .authorized,
            catalog: .notStarted,
            analysis: .completed(makeResult(total: 42)),
            lastScannedAt: completedAt
        )
        guard case .finished(let analyzed, let total, let groups, let lastScannedAt) = status else {
            Issue.record("expected finished, got \(status)")
            return
        }
        // effectiveAnalyzedCount excludes the two unavailable assets in the fixture.
        #expect(analyzed == 40)
        #expect(total == 42)
        #expect(groups == 2)
        #expect(lastScannedAt == completedAt)
    }

    @Test func scanCopyShowsLastScannedWithRelativeTime() {
        let completedAt = Date(timeIntervalSince1970: 1_759_000_000)
        let status = DashboardPresentation.ScanStatus.finished(
            analyzed: 40,
            total: 42,
            groups: 3,
            lastScannedAt: completedAt
        )
        let copy = DashboardPresentation.scanCopy(for: status)
        #expect(copy.title == "Last scanned")
        // The body embeds whatever Foundation computes for the persisted Date at render time.
        #expect(copy.body.contains(DashboardPresentation.relativeLastScanned(from: completedAt)))
        #expect(copy.body.contains("40 of 42 items analyzed"))
        #expect(copy.body.contains("Results are ready to review."))
    }

    @Test func missingDateKeepsTheOriginalCopy() {
        let status = DashboardPresentation.ScanStatus.finished(
            analyzed: 40,
            total: 42,
            groups: 3,
            lastScannedAt: nil
        )
        let copy = DashboardPresentation.scanCopy(for: status)
        #expect(copy.title == "Last scan finished")
        #expect(copy.body.contains("40 of 42 items analyzed"))
    }
}

// MARK: - Shared in-memory store for the test module

/// Hermetic `ScanSnapshotStore` for tests that can reach a `.completed` analysis — keeps every
/// test off the app's real persisted snapshot. Lock-guarded because tests may await between
/// assertions while analysis tasks save in the background.
final class InMemoryScanSnapshotStore: ScanSnapshotStore, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: ScanSnapshot?
    private var saves = 0

    var saveCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return saves
    }

    func save(_ snapshot: ScanSnapshot) throws {
        lock.lock()
        defer { lock.unlock() }
        stored = snapshot
        saves += 1
    }

    func loadLatest() -> ScanSnapshot? {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    func clear() {
        lock.lock()
        defer { lock.unlock() }
        stored = nil
    }
}

// MARK: - Fixtures

private func makeSnapshot(scanID: String) -> ScanSnapshot {
    ScanSnapshot(
        schemaVersion: ScanSnapshot.currentSchemaVersion,
        scanID: scanID,
        completedAt: Date(timeIntervalSince1970: 1_758_999_000),
        result: makeResult()
    )
}

private func makeResult(total: Int = 42) -> PhotoAnalysisResult {
    let exact = PhotoSimilarityGroup(
        kind: .exactDuplicates,
        memberAssetIDs: ["stale-a", "stale-b"],
        evidence: .exactContent(fingerprint: "f1", byteLength: 100),
        recommendedBestAssetID: "stale-a",
        memberScores: [
            "stale-a": PhotoAssetQualityScore(
                localIdentifier: "stale-a",
                isFavorite: true,
                representsBurst: false,
                pixelCount: 4_000_000,
                hasAdjustments: false,
                creationDate: Date(timeIntervalSince1970: 1_750_000_000)
            ),
        ]
    )
    let near = PhotoSimilarityGroup(
        kind: .nearDuplicates,
        memberAssetIDs: ["stale-b", "stale-c"],
        evidence: .visualSimilarity(minDistance: 0.01, maxDistance: 0.02, threshold: 0.15),
        recommendedBestAssetID: "stale-c",
        memberScores: [:]
    )
    return PhotoAnalysisResult(
        exactGroups: [exact],
        similarGroups: [near],
        unavailableAssets: [
            PhotoAnalysisUnavailable(assetID: "stale-x", reason: .contentOnlyInICloud),
            PhotoAnalysisUnavailable(assetID: "stale-y", reason: .assetNotFound),
        ],
        descriptorKind: .visionFeaturePrint,
        visionAvailable: true,
        similarityThreshold: 0.15,
        totalRecordCount: total,
        candidateBucketCount: 3,
        candidatePairCount: 6,
        analyzedAssetCount: total - 2,
        skippedNoCandidateCount: 4
    )
}

@MainActor
private func makeEnv(
    store: InMemoryScanSnapshotStore,
    factory: @escaping @Sendable () throws -> any PhotoLibraryReading = {
        FakeLibrary(records: [makeRecord(id: "x")])
    }
) -> AppEnvironment {
    let env = AppEnvironment(
        storageProvider: FakeStorage(),
        makePhotoLibrary: factory,
        scanSnapshotStore: store
    )
    env.photoPermissionState = .authorized
    return env
}

@MainActor
private func waitForAnalysis(
    _ env: AppEnvironment,
    timeoutMilliseconds: Int = 20_000
) async -> PhotoAnalysisState {
    let deadline = ContinuousClock.now.advanced(by: .milliseconds(timeoutMilliseconds))
    while env.analysisState.isRunning, ContinuousClock.now < deadline {
        try? await Task.sleep(for: .milliseconds(20))
    }
    return env.analysisState
}

/// Call counter for the injected library factory. `record()` runs on the detached task that
/// creates the reader (off the main actor) while `count` is read from the test's actor — a
/// lock guards both.
private final class FactoryCallBox: @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0

    func record() {
        lock.lock()
        calls += 1
        lock.unlock()
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return calls
    }
}

private struct FakeLibrary: PhotoLibraryReading {
    let accessLevel: PermissionState = .authorized
    let records: [PhotoAssetRecord]
    var chunkDelay: TimeInterval = 0

    func assetCount() throws -> Int {
        records.count
    }

    func records(in range: Range<Int>) throws -> [PhotoAssetRecord] {
        if chunkDelay > 0 {
            Thread.sleep(forTimeInterval: chunkDelay)
        }
        let lower = max(0, range.lowerBound)
        let upper = min(range.upperBound, records.count)
        guard lower < upper else { return [] }
        return Array(records[lower..<upper])
    }
}

private struct FakeStorage: StorageProviding {
    func deviceStorage() async -> StorageSnapshot {
        StorageSnapshot(totalCapacity: 100, availableCapacity: 60)
    }
}

private func makeRecord(id: String, daysAgo: Double = 0) -> PhotoAssetRecord {
    PhotoAssetRecord(
        localIdentifier: id,
        mediaType: .image,
        mediaSubtypes: [],
        pixelWidth: 1000,
        pixelHeight: 1000,
        creationDate: Date(timeIntervalSince1970: 1_750_000_000 - daysAgo * 86_400),
        modificationDate: nil,
        duration: 0,
        isFavorite: false,
        isHidden: false,
        sourceType: .library,
        hasAdjustments: false,
        representsBurst: false,
        burstIdentifier: nil
    )
}

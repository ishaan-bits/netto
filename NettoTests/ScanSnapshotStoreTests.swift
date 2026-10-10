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

// MARK: - Interrupted-run checkpoint file (temp directory only)

struct FileScanCheckpointStoreTests {
    private func makeStore() -> (store: FileScanCheckpointStore, directory: URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("netto-checkpoint-\(UUID().uuidString)", isDirectory: true)
        return (FileScanCheckpointStore(directoryOverride: directory), directory)
    }

    @Test func roundTripPreservesEvidenceStagesAndDatesExactly() throws {
        let (store, directory) = makeStore()
        let modified = Date(timeIntervalSinceReferenceDate: 759_000_000.123456)
        let checkpoint = ScanCheckpoint(
            runSequence: 12,
            kind: .similarity,
            startedAt: Date(timeIntervalSinceReferenceDate: 759_000_000),
            updatedAt: Date(timeIntervalSinceReferenceDate: 759_000_100),
            stage: PhotoAnalysisStage.extractingFeatures.rawValue,
            completedUnits: 40,
            totalUnits: 100,
            perceptualHashes: [PerceptualHashEntry(assetID: "a", modified: modified, bits: 0xDEAD_BEEF)],
            byteKeys: [ContentByteKeyEntry(assetID: "b", modified: nil, imageBytes: 7, videoBytes: 9)],
            blurVerdicts: [
                BlurVerdictEntry(assetID: "c", modified: modified, verdict: .likelyBlurry, laplacianVariance: 0.0001),
            ],
            blurThresholds: .corpusCalibrated,
            videoSizes: [VideoSizeEntry(assetID: "v", modified: modified, bytes: 42)]
        )

        try store.save(checkpoint)
        let loaded = try #require(store.load())
        // Exact equality is the reconciliation contract: a modification date that drifts
        // through JSON round-trips would silently invalidate every saved entry on resume.
        #expect(loaded == checkpoint)
        #expect(loaded.perceptualHashes.first?.modified == modified)
        #expect(loaded.blurVerdicts.first?.modified == modified)
        try? FileManager.default.removeItem(at: directory)
    }

    @Test func firstLaunchHasNoCheckpoint() {
        let (store, directory) = makeStore()
        #expect(store.load() == nil)
        try? FileManager.default.removeItem(at: directory)
    }

    @Test func corruptFileLoadsAsNoCheckpointWithoutThrowing() throws {
        let (store, directory) = makeStore()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("{{{ not json".utf8).write(to: directory.appendingPathComponent("checkpoint.json"))

        #expect(store.load() == nil)
        try? FileManager.default.removeItem(at: directory)
    }

    @Test func incompatibleSchemaIsDiscardedInsteadOfResumed() throws {
        let (store, directory) = makeStore()
        let future = ScanCheckpoint(
            runSequence: 1,
            kind: .catalog,
            startedAt: Date(),
            updatedAt: Date()
        )
        var encoded = try JSONEncoder().encode(future)
        // Rewrite the schema field upward: a file from a future app version must degrade
        // to "no checkpoint", never to a resumed run against an unknown payload shape.
        let object = try #require(
            try JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        var mutated = object
        mutated["schemaVersion"] = ScanCheckpoint.currentSchemaVersion + 98
        encoded = try JSONSerialization.data(withJSONObject: mutated)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try encoded.write(to: directory.appendingPathComponent("checkpoint.json"))

        #expect(store.load() == nil)
        try? FileManager.default.removeItem(at: directory)
    }

    @Test func clearRemovesTheCheckpoint() throws {
        let (store, directory) = makeStore()
        try store.save(makeCheckpoint(runSequence: 1))
        store.clear()
        #expect(store.load() == nil)
        try? FileManager.default.removeItem(at: directory)
    }
}

// MARK: - Writer ordering (stale-run and resurrection protection)

struct ScanCheckpointWriterTests {
    private func makeWriter() -> (writer: ScanCheckpointWriter, store: InMemoryScanCheckpointStore) {
        let store = InMemoryScanCheckpointStore()
        return (ScanCheckpointWriter(store: store), store)
    }

    @Test func aNewerRunSequenceReplacesAnOlderCheckpoint() {
        let (writer, store) = makeWriter()
        writer.write(makeCheckpoint(runSequence: 5, updatedAt: 100))
        writer.write(makeCheckpoint(runSequence: 6, updatedAt: 50))

        #expect(store.load()?.runSequence == 6)
    }

    @Test func anOlderRunSequenceNeverOverwritesANewerCheckpoint() {
        let (writer, store) = makeWriter()
        writer.write(makeCheckpoint(runSequence: 6, updatedAt: 50))
        // A superseded run's late flush — lower sequence, even with a fresh timestamp.
        writer.write(makeCheckpoint(runSequence: 5, updatedAt: 500))

        #expect(store.load()?.runSequence == 6)
    }

    @Test func theSameSequenceNeedsAStrictlyNewerTimestamp() {
        let (writer, store) = makeWriter()
        writer.write(makeCheckpoint(runSequence: 5, updatedAt: 100))
        writer.write(makeCheckpoint(runSequence: 5, updatedAt: 100))
        #expect(store.load()?.updatedAt.timeIntervalSinceReferenceDate == 100)

        writer.write(makeCheckpoint(runSequence: 5, updatedAt: 99))
        #expect(store.load()?.updatedAt.timeIntervalSinceReferenceDate == 100)

        writer.write(makeCheckpoint(runSequence: 5, updatedAt: 101))
        #expect(store.load()?.updatedAt.timeIntervalSinceReferenceDate == 101)
    }

    @Test func clearBlocksEveryLateFlushFromTheClearedRunAndEarlier() {
        let (writer, store) = makeWriter()
        writer.write(makeCheckpoint(runSequence: 7, updatedAt: 10))
        writer.clear(through: 7)

        #expect(store.load() == nil)
        writer.write(makeCheckpoint(runSequence: 7, updatedAt: 11))
        #expect(store.load() == nil)
        writer.write(makeCheckpoint(runSequence: 3, updatedAt: 999))
        #expect(store.load() == nil)
        // A genuinely new run (above the blocked watermark) writes normally.
        writer.write(makeCheckpoint(runSequence: 8, updatedAt: 1))
        #expect(store.load()?.runSequence == 8)
    }

    @Test func kindAwareClearNeverRemovesAnotherPassesFile() {
        let (writer, store) = makeWriter()
        writer.write(makeCheckpoint(runSequence: 4, kind: .similarity, updatedAt: 10))
        // A catalog completion must not destroy the paused similarity run's resume info.
        writer.clear(owning: .catalog, through: 4)

        #expect(store.load()?.kind == .similarity)
        #expect(writer.allows(.similarity))
        #expect(!writer.allows(.videoSizes))
    }

    @Test func kindAwareClearRemovesTheOwnFilesCheckpoint() {
        let (writer, store) = makeWriter()
        writer.write(makeCheckpoint(runSequence: 4, kind: .similarity, updatedAt: 10))
        writer.clear(owning: .similarity, through: 4)

        #expect(store.load() == nil)
        #expect(writer.kind == nil)
        #expect(writer.allows(.videoSizes))
    }

    @Test func videoCheckpointsAreRefusedWhileAHeavierPassOwnsTheFile() {
        let (writer, _) = makeWriter()
        #expect(writer.allows(.videoSizes))

        writer.write(makeCheckpoint(runSequence: 2, kind: .blur, updatedAt: 10))
        #expect(!writer.allows(.videoSizes))
        #expect(writer.allows(.blur))

        writer.clear(owning: .blur, through: 2)
        #expect(writer.allows(.videoSizes))
    }

    @Test func adoptingARestoredFileSeedsItsKindAndOrdering() {
        let restored = makeCheckpoint(runSequence: 9, kind: .videoSizes, updatedAt: 40)
        let store = InMemoryScanCheckpointStore()
        // The restored session's file lives in the store; the new session's writer adopts
        // what it holds so kind-aware clears and ordering survive the relaunch.
        try? store.save(restored)
        let writer = ScanCheckpointWriter(store: store, adopting: restored)

        #expect(writer.kind == .videoSizes)
        // A previous session's straggler (below the restored sequence) stays out…
        writer.write(makeCheckpoint(runSequence: 8, kind: .videoSizes, updatedAt: 99))
        #expect(store.load()?.runSequence == 9)
        // …while this session's runs order strictly after the restored file.
        writer.write(makeCheckpoint(runSequence: 10, kind: .similarity, updatedAt: 1))
        #expect(store.load()?.runSequence == 10)
    }
}

// MARK: - Accumulator batching and kind tagging

struct ScanCheckpointAccumulatorTests {
    private func makeAccumulator(
        batchEntries: Int = ScanCheckpoint.flushEveryEntries,
        batchInterval: TimeInterval = ScanCheckpoint.flushEverySeconds
    ) -> (accumulator: ScanCheckpointAccumulator, writer: ScanCheckpointWriter, store: InMemoryScanCheckpointStore) {
        let store = InMemoryScanCheckpointStore()
        let writer = ScanCheckpointWriter(store: store)
        let accumulator = ScanCheckpointAccumulator(
            writer: writer,
            batchEntries: batchEntries,
            batchInterval: batchInterval
        )
        return (accumulator, writer, store)
    }

    @Test func beginCarryingAPausedRunRestoresItsPayload() {
        let (accumulator, _, _) = makeAccumulator()
        let carried = makeCheckpoint(
            runSequence: 3,
            kind: .similarity,
            stage: PhotoAnalysisStage.comparing.rawValue,
            completedUnits: 12,
            totalUnits: 48,
            perceptualHashes: [PerceptualHashEntry(assetID: "a", modified: nil, bits: 1)]
        )

        let sequence = accumulator.begin(kind: .similarity, runSequence: 42, carrying: carried)
        let snapshot = accumulator.snapshot()

        #expect(sequence == 42)
        #expect(snapshot?.perceptualHashes == carried.perceptualHashes)
        // Progress display resumes where it stopped; the run's own sequence is what its
        // future writes present.
        #expect(snapshot?.stage == PhotoAnalysisStage.comparing.rawValue)
        #expect(snapshot?.completedUnits == 12)
        #expect(snapshot?.runSequence == 42)
        #expect(snapshot?.startedAt == carried.startedAt)
    }

    @Test func evidenceFromAForeignRunSequenceIsIgnored() {
        let (accumulator, _, store) = makeAccumulator()
        accumulator.begin(kind: .similarity, runSequence: 10, carrying: nil)

        accumulator.record(
            .perceptualHash(assetID: "straggler", modified: nil, bits: 5),
            runSequence: 9
        )
        // Nothing was accepted, so there is nothing dirty to write — a straggler can
        // never be smuggled into the file, not even by a forced flush.
        #expect(accumulator.flushNowSync() == false)
        #expect(store.load() == nil)

        accumulator.record(
            .perceptualHash(assetID: "kept", modified: nil, bits: 5),
            runSequence: 10
        )
        accumulator.flushNowSync()
        #expect(store.load()?.perceptualHashes.map(\.assetID) == ["kept"])
    }

    @Test func aChainedCatalogRebuildCannotRewriteTheActiveRunsProgress() {
        let (accumulator, _, _) = makeAccumulator()
        accumulator.begin(kind: .similarity, runSequence: 4, carrying: nil)
        accumulator.setProgress(
            kind: .similarity,
            stage: PhotoAnalysisStage.extractingFeatures.rawValue,
            completed: 80,
            total: 100
        )
        accumulator.noteBlurThresholds(.corpusCalibrated)

        // A chained rebuild reports under its own kind — the active run's saved stage
        // (and its unrelated blur thresholds) must not move.
        accumulator.setProgress(kind: .catalog, stage: "catalog", completed: 5, total: 10)
        let snapshot = accumulator.snapshot()

        #expect(snapshot?.stage == PhotoAnalysisStage.extractingFeatures.rawValue)
        #expect(snapshot?.completedUnits == 80)
        #expect(snapshot?.totalUnits == 100)
        #expect(snapshot?.blurThresholds == nil)
    }

    @Test func blurThresholdsAreStampedOnlyDuringABlurRun() {
        let (accumulator, _, _) = makeAccumulator()
        accumulator.begin(kind: .similarity, runSequence: 1, carrying: nil)
        accumulator.noteBlurThresholds(.corpusCalibrated)
        #expect(accumulator.snapshot()?.blurThresholds == nil)

        accumulator.endRun()
        accumulator.begin(kind: .blur, runSequence: 2, carrying: nil)
        accumulator.noteBlurThresholds(.corpusCalibrated)
        #expect(accumulator.snapshot()?.blurThresholds == .corpusCalibrated)
    }

    @Test func snapshotIsNilWithoutAnActiveRun() {
        let (accumulator, _, _) = makeAccumulator()
        #expect(accumulator.snapshot() == nil)
        accumulator.begin(kind: .similarity, runSequence: 1, carrying: nil)
        #expect(accumulator.snapshot() != nil)
        accumulator.endRun()
        #expect(accumulator.snapshot() == nil)
        #expect(accumulator.activeKind == nil)
    }

    @Test func flushNowSyncWritesOnceThenReportsClean() {
        let (accumulator, _, store) = makeAccumulator()
        accumulator.begin(kind: .similarity, runSequence: 6, carrying: nil)
        accumulator.record(.perceptualHash(assetID: "a", modified: nil, bits: 1), runSequence: 6)

        #expect(accumulator.flushNowSync())
        #expect(store.load()?.perceptualHashes.map(\.assetID) == ["a"])
        // Nothing new accumulated → no second write.
        #expect(!accumulator.flushNowSync())
        #expect(store.saveCount == 1)
    }

    @Test func reachedBatchSizeFlushesToDiskWithoutAnExplicitFlush() async {
        let (accumulator, _, store) = makeAccumulator(batchEntries: 4)
        accumulator.begin(kind: .similarity, runSequence: 1, carrying: nil)
        for index in 0..<4 {
            accumulator.record(
                .perceptualHash(assetID: "asset-\(index)", modified: nil, bits: UInt64(index)),
                runSequence: 1
            )
        }

        // Batch flushes are detached (never on the caller's thread) — poll the store.
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while store.load() == nil, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(store.load()?.perceptualHashes.count == 4)
    }

    @Test func entriesStayBatchedBelowTheThreshold() async {
        let (accumulator, _, store) = makeAccumulator(batchEntries: 8)
        accumulator.begin(kind: .similarity, runSequence: 1, carrying: nil)
        for index in 0..<3 {
            accumulator.record(
                .perceptualHash(assetID: "asset-\(index)", modified: nil, bits: UInt64(index)),
                runSequence: 1
            )
        }
        try? await Task.sleep(for: .milliseconds(200))
        #expect(store.load() == nil)
    }
}

// MARK: - Shared in-memory checkpoint store for the test module

/// Hermetic `ScanCheckpointStore`: tests seed the checkpoint a relaunch would find, and
/// assert what a run persisted — never the app's real `checkpoint.json`.
final class InMemoryScanCheckpointStore: ScanCheckpointStore, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: ScanCheckpoint?
    private var saves = 0
    private var clears = 0

    var saveCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return saves
    }

    var clearCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return clears
    }

    func save(_ checkpoint: ScanCheckpoint) throws {
        lock.lock()
        defer { lock.unlock() }
        stored = checkpoint
        saves += 1
    }

    func load() -> ScanCheckpoint? {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    func clear() {
        lock.lock()
        defer { lock.unlock() }
        stored = nil
        clears += 1
    }
}

// MARK: - Shared background-task seam for the test module

/// Deterministic stand-in for `SystemBackgroundTaskScheduler`: tests arm the task exactly
/// as the environment does and fire expiration themselves — the only way to exercise the
/// pause-and-checkpoint path, since a simulator test cannot reproduce iOS suspension.
@MainActor
final class FakeBackgroundTaskScheduler: BackgroundTaskScheduling {
    private(set) var isHolding = false
    private var expiration: (@MainActor () -> Void)?
    private(set) var beginCount = 0
    private(set) var endCount = 0

    func begin(onExpiration: @escaping @MainActor () -> Void) {
        guard !isHolding else { return }
        isHolding = true
        expiration = onExpiration
        beginCount += 1
    }

    func end() {
        guard isHolding else { return }
        isHolding = false
        expiration = nil
        endCount += 1
    }

    /// The system reclaims the task: production ends the task *before* invoking the
    /// handler, so the handler runs with the task already gone.
    func fireExpiration() {
        guard isHolding, let handler = expiration else { return }
        isHolding = false
        expiration = nil
        endCount += 1
        handler()
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

private func makeCheckpoint(
    runSequence: Int,
    kind: ScanCheckpoint.Kind = .similarity,
    updatedAt: TimeInterval = 100,
    stage: String = PhotoAnalysisStage.fingerprinting.rawValue,
    completedUnits: Int = 1,
    totalUnits: Int = 10,
    perceptualHashes: [PerceptualHashEntry] = [],
    byteKeys: [ContentByteKeyEntry] = [],
    blurVerdicts: [BlurVerdictEntry] = [],
    blurThresholds: BlurThresholds? = nil,
    videoSizes: [VideoSizeEntry] = []
) -> ScanCheckpoint {
    ScanCheckpoint(
        runSequence: runSequence,
        kind: kind,
        startedAt: Date(timeIntervalSinceReferenceDate: max(updatedAt - 5, 0)),
        updatedAt: Date(timeIntervalSinceReferenceDate: updatedAt),
        stage: stage,
        completedUnits: completedUnits,
        totalUnits: totalUnits,
        perceptualHashes: perceptualHashes,
        byteKeys: byteKeys,
        blurVerdicts: blurVerdicts,
        blurThresholds: blurThresholds,
        videoSizes: videoSizes
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

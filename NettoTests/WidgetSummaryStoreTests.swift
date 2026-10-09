import Foundation
import Testing
@testable import Netto

// MARK: - The App Group file the app writes and the widget reads

struct WidgetSummaryStoreTests {
    /// Counts reload requests without touching the real WidgetCenter.
    private final class ReloadCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0

        func increment() {
            lock.lock()
            value += 1
            lock.unlock()
        }

        var count: Int {
            lock.lock()
            defer { lock.unlock() }
            return value
        }
    }

    private func makeStore() -> (store: FileWidgetSummaryStore, directory: URL, reloads: ReloadCounter) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("netto-widget-summary-\(UUID().uuidString)", isDirectory: true)
        let reloads = ReloadCounter()
        let store = FileWidgetSummaryStore(directoryOverride: directory) { reloads.increment() }
        return (store, directory, reloads)
    }

    private func cleanup(_ directory: URL) {
        try? FileManager.default.removeItem(at: directory)
    }

    private func makeSummary(status: WidgetSummary.Status = .scanReady) throws -> WidgetSummary {
        try #require(WidgetSummary(
            schemaVersion: WidgetSummary.currentSchemaVersion,
            status: status,
            estimateBytes: status == .lastCleanup ? 1_400_000_000 : nil,
            isEstimated: status == .lastCleanup,
            updatedAt: Date(timeIntervalSince1970: 1_759_000_000)
        ))
    }

    // MARK: Round trip and atomicity of the shared file

    @Test func saveThenLoadRoundTripsTheSummaryThroughTheSharedFile() async throws {
        let (store, directory, _) = makeStore()
        defer { cleanup(directory) }

        let summary = try makeSummary(status: .lastCleanup)
        try await store.save(summary)

        let loaded = await store.load()
        #expect(loaded == summary)
        // The file itself exists at the agreed path in the container.
        #expect(FileManager.default.fileExists(
            atPath: directory.appendingPathComponent(FileWidgetSummaryStore.fileName).path
        ))
    }

    @Test func saveCreatesTheContainerDirectoryWhenMissing() async throws {
        let (store, directory, _) = makeStore()
        defer { cleanup(directory) }
        // Note: the directory is deliberately never created first — save must make it.
        try await store.save(try makeSummary())

        #expect(await store.load() != nil)
    }

    @Test func requestingAReloadForwardsToTheInjectedHook() {
        let (store, directory, reloads) = makeStore()
        defer { cleanup(directory) }

        store.requestWidgetReload()
        store.requestWidgetReload()
        #expect(reloads.count == 2)
    }

    // MARK: Mandated areas 3–5: missing, corrupt, unsupported schema

    @Test func missingSharedSummaryLoadsNil() async {
        let (store, directory, _) = makeStore()
        defer { cleanup(directory) }

        #expect(await store.load() == nil)
    }

    @Test func corruptSharedFileLoadsNil() async throws {
        let (store, directory, _) = makeStore()
        defer { cleanup(directory) }

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("not json at all {{{".utf8).write(
            to: directory.appendingPathComponent(FileWidgetSummaryStore.fileName)
        )

        #expect(await store.load() == nil)
    }

    @Test func unsupportedSchemaFileLoadsNil() async throws {
        let (store, directory, _) = makeStore()
        defer { cleanup(directory) }

        // Structurally valid JSON, but written by a future schema — rejected on read.
        let future = #"{"schemaVersion":99,"status":"lastCleanup","estimateBytes":10,"isEstimated":true,"updatedAt":1759000000}"#
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(future.utf8).write(
            to: directory.appendingPathComponent(FileWidgetSummaryStore.fileName)
        )

        #expect(await store.load() == nil)
    }
}

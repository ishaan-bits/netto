import Foundation
import WidgetKit

/// Failures of the file-backed widget store. `noSharedContainer` only happens when the
/// App Group container cannot be resolved (missing entitlement or provisioning) — the
/// caller treats it as "no summary available", never as a crash.
enum WidgetSummaryStoreError: Error, Equatable {
    case noSharedContainer
}

/// The app-side seam for the widget's shared state: load what the widget should render,
/// save what it should render next, and ask WidgetKit to re-read. `async` so file I/O
/// never runs on the main actor; `requestWidgetReload` stays synchronous because it only
/// enqueues a system request.
protocol WidgetSummaryStoring: Sendable {
    func load() async -> WidgetSummary?
    func save(_ summary: WidgetSummary) async throws
    func requestWidgetReload()
}

/// The production store: one JSON file in the App Group container shared by the app and
/// the widget extension, written atomically. Tests inject `directoryOverride` (same seam
/// `FileScanSnapshotStore` uses) and `onReload` so no test ever touches the real
/// container or WidgetCenter.
struct FileWidgetSummaryStore: WidgetSummaryStoring {
    /// Shared container identifier — must match the App Group entitlement of *both*
    /// `Netto` and `NettoWidget` exactly.
    static let appGroupID = "group.com.ishaanparimal.netto"
    static let fileName = "widget-summary.json"

    private let directoryOverride: URL?
    private let onReload: @Sendable () -> Void

    init(
        directoryOverride: URL? = nil,
        onReload: @escaping @Sendable () -> Void = { WidgetCenter.shared.reloadAllTimelines() }
    ) {
        self.directoryOverride = directoryOverride
        self.onReload = onReload
    }

    /// The file lives directly in the shared container root so both processes agree on
    /// one path; without a usable container there is simply no summary.
    private func fileURL() throws -> URL {
        if let directoryOverride {
            return directoryOverride.appendingPathComponent(Self.fileName)
        }
        guard let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: Self.appGroupID
        ) else {
            throw WidgetSummaryStoreError.noSharedContainer
        }
        return container.appendingPathComponent(Self.fileName)
    }

    /// Missing file, unreadable file, corrupt JSON, or a rejected schema all load as
    /// `nil` — the widget's empty state, never a crash and never partial content.
    func load() async -> WidgetSummary? {
        guard let url = try? fileURL() else { return nil }
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(WidgetSummary.self, from: data)
    }

    /// Atomic replace: a crash mid-write can leave the old file or the new file, never a
    /// truncated one, so the widget never decodes a half-written summary.
    func save(_ summary: WidgetSummary) async throws {
        let url = try fileURL()
        let data = try JSONEncoder().encode(summary)
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    func requestWidgetReload() {
        onReload()
    }
}

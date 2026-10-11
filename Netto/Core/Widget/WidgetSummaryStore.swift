import Foundation
import os
import WidgetKit

/// Widget-pipeline diagnostics, shared by the app-side writer and the extension-side
/// reader. Content is category-only — status names, error names, counts — never photo
/// data, filenames, byte figures, or any other private content. On a physical device
/// these lines are what turn "the widget is blank" from a guess into a diagnosis
/// (`log stream --predicate 'subsystem == "com.ishaanparimal.netto"'`).
extension Logger {
    static let widget = Logger(subsystem: "com.ishaanparimal.netto", category: "widget")
}

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
    /// `nil` — the widget's empty state, never a crash and never partial content. Each
    /// outcome is logged by category (never content) so a device-side blank widget can
    /// be told apart from "the app never wrote".
    ///
    /// The file read itself runs on a detached utility task (M10): whatever actor
    /// context WidgetKit invoked the provider on — including a main-actor-isolated one
    /// in a future SDK — can never serialize this I/O against the provider's watchdog.
    /// A blocked read must cost the watchdog nothing; the watchdog's entire job is to
    /// outlast this.
    func load() async -> WidgetSummary? {
        let url: URL
        do {
            // Cheap path resolution (no I/O) — honors the injected `directoryOverride`.
            url = try fileURL()
        } catch {
            // The distinguishing line for a device-only blank widget: without the App
            // Group entitlement (or its provisioning), the extension can never see
            // what the app wrote.
            Logger.widget.error("summary load failed: shared container unavailable (check App Group entitlement)")
            return nil
        }
        return await Task.detached(priority: .utility) { () -> WidgetSummary? in
            guard let data = try? Data(contentsOf: url) else {
                Logger.widget.debug("summary absent: no file in shared container yet")
                return nil
            }
            guard let summary = try? JSONDecoder().decode(WidgetSummary.self, from: data) else {
                Logger.widget.error("summary rejected: corrupt or incompatible file")
                return nil
            }
            Logger.widget.info("summary loaded status=\(summary.status.rawValue, privacy: .public)")
            return summary
        }.value
    }

    /// Atomic replace: a crash mid-write can leave the old file or the new file, never a
    /// truncated one, so the widget never decodes a half-written summary. The write runs
    /// detached for the same reason as `load` (M10) — never on the caller's actor.
    func save(_ summary: WidgetSummary) async throws {
        let url: URL
        do {
            url = try fileURL()
        } catch {
            Logger.widget.error("summary save failed: shared container unavailable (check App Group entitlement)")
            throw error
        }
        let data = try JSONEncoder().encode(summary)
        try await Task.detached(priority: .utility) {
            let directory = url.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
        }.value
        Logger.widget.info("summary saved status=\(summary.status.rawValue, privacy: .public)")
    }

    func requestWidgetReload() {
        onReload()
    }
}

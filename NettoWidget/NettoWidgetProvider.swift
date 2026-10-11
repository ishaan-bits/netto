import Foundation
import WidgetKit
#if NETTO_WIDGET_TESTS
@testable import Netto
#endif

/// One rendered moment of the widget: when it applies, and the fully-formed display
/// model (never raw shared state) the views draw.
struct NettoWidgetEntry: TimelineEntry {
    let date: Date
    let model: WidgetDisplayModel
}

/// Loads the shared `WidgetSummary` from the App Group container and converts it to a
/// display model. Conservative by design: one entry per timeline, refreshed on a ~1 hour
/// cadence — the widget must be correct when read, never dependent on exact timing, and
/// it never touches PhotoKit, Vision, deletion, or any other subsystem.
///
/// The entry-building logic (`entry(for:now:)`, `placeholderEntry(now:)`,
/// `timeline(entries:now:)`) is context-free so the unit tests can exercise exactly the
/// mapping the WidgetKit callbacks use; only the callbacks themselves need the
/// `TimelineProviderContext` WidgetKit constructs and does not expose.
struct NettoWidgetProvider: TimelineProvider {
    /// One hour between refresh requests. Correctness never depends on this cadence:
    /// every render re-reads whatever the app last wrote, and staleness is handled by
    /// labelling the content, never by polling.
    static let reloadInterval: TimeInterval = 60 * 60

    private let store: any WidgetSummaryStoring

    init(store: any WidgetSummaryStoring = FileWidgetSummaryStore()) {
        self.store = store
    }

    /// The single mapping from a shared summary (or its absence) to a rendered moment —
    /// used by the placeholder, the snapshot, and the timeline alike, so every path
    /// renders exactly one shared interpretation of the data.
    static func entry(for summary: WidgetSummary?, now: Date) -> NettoWidgetEntry {
        NettoWidgetEntry(
            date: now,
            model: WidgetSummaryPresentation.model(for: summary, now: now)
        )
    }

    /// Gallery/preview content: a representative *status* before the app has ever written
    /// anything. It is a real `.scanReady` summary — no fabricated byte figure anywhere,
    /// keeping the "the widget never manufactures a number" invariant true even in the
    /// widget gallery.
    static func placeholderEntry(now: Date) -> NettoWidgetEntry {
        let summary = WidgetSummary(
            schemaVersion: WidgetSummary.currentSchemaVersion,
            status: .scanReady,
            estimateBytes: nil,
            isEstimated: false,
            updatedAt: now
        )
        return entry(for: summary, now: now)
    }

    /// One entry with a policy that only asks for a refresh well after the content
    /// could have gone stale — staleness is handled by labelling, not by polling.
    static func timeline(
        entries: [NettoWidgetEntry],
        now: Date
    ) -> Timeline<NettoWidgetEntry> {
        Timeline(
            entries: entries,
            policy: .after(now.addingTimeInterval(reloadInterval))
        )
    }

    func placeholder(in context: TimelineProviderContext) -> NettoWidgetEntry {
        Self.placeholderEntry(now: Date())
    }

    /// The pre-render snapshot: the gallery preview in preview contexts, otherwise the
    /// same store read as the timeline uses.
    func getSnapshot(
        in context: TimelineProviderContext,
        completion: @escaping @Sendable (NettoWidgetEntry) -> Void
    ) {
        if context.isPreview {
            completion(Self.placeholderEntry(now: Date()))
            return
        }
        loadEntry(completion: completion)
    }

    func getTimeline(
        in context: TimelineProviderContext,
        completion: @escaping @Sendable (Timeline<NettoWidgetEntry>) -> Void
    ) {
        let now = Date()
        loadEntry(now: now) { entry in
            completion(Self.timeline(entries: [entry], now: now))
        }
    }

    /// The store read is `async` (off the main actor by contract), so the completion is
    /// delivered from a task rather than blocking WidgetKit's calling thread.
    private func loadEntry(
        now: Date = Date(),
        completion: @escaping @Sendable (NettoWidgetEntry) -> Void
    ) {
        let store = self.store
        Task {
            let summary = await store.load()
            completion(Self.entry(for: summary, now: now))
        }
    }
}

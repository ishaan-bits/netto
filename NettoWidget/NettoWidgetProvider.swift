import Foundation
import WidgetKit

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
struct NettoWidgetProvider: TimelineProvider {
    private let store: any WidgetSummaryStoring

    init(store: any WidgetSummaryStoring = FileWidgetSummaryStore()) {
        self.store = store
    }

    /// Gallery/preview content: a representative *status* before the app has ever written
    /// anything. It is a real `.scanReady` summary — no fabricated byte figure anywhere,
    /// keeping the "the widget never manufactures a number" invariant true even in the
    /// widget gallery.
    func placeholder(in context: TimelineProviderContext) -> NettoWidgetEntry {
        let now = Date()
        let summary = WidgetSummary(
            schemaVersion: WidgetSummary.currentSchemaVersion,
            status: .scanReady,
            estimateBytes: nil,
            isEstimated: false,
            updatedAt: now
        )
        return NettoWidgetEntry(
            date: now,
            model: WidgetSummaryPresentation.model(for: summary, now: now)
        )
    }

    /// The pre-render snapshot: the gallery preview in preview contexts, otherwise the
    /// same store read as the timeline uses.
    func getSnapshot(
        in context: TimelineProviderContext,
        completion: @escaping @Sendable (NettoWidgetEntry) -> Void
    ) {
        if context.isPreview {
            completion(placeholder(in: context))
            return
        }
        loadEntry(completion: completion)
    }

    /// A single entry with a policy that only asks for a refresh well after the content
    /// could have gone stale — staleness is handled by labelling, not by polling.
    func getTimeline(
        in context: TimelineProviderContext,
        completion: @escaping @Sendable (Timeline<NettoWidgetEntry>) -> Void
    ) {
        let now = Date()
        loadEntry(now: now) { entry in
            completion(
                Timeline(
                    entries: [entry],
                    policy: .after(now.addingTimeInterval(60 * 60))
                )
            )
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
            completion(
                NettoWidgetEntry(
                    date: now,
                    model: WidgetSummaryPresentation.model(for: summary, now: now)
                )
            )
        }
    }
}

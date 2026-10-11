import Foundation
import os
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

    /// Watchdog for one store read. The read is a local file open in the App Group
    /// container — anything that has not answered within this window is a broken
    /// extension process, not a slow disk. WidgetKit's contract is that never calling
    /// the completion leaves the system rendering the blank skeleton, so a bounded
    /// fallback is the one mechanism that *guarantees* branded content appears even
    /// when the store read hangs.
    static let defaultLoadTimeoutNanos: UInt64 = 2_000_000_000

    private let store: any WidgetSummaryStoring
    private let loadTimeoutNanos: UInt64

    init(
        store: any WidgetSummaryStoring = FileWidgetSummaryStore(),
        loadTimeoutNanos: UInt64 = NettoWidgetProvider.defaultLoadTimeoutNanos
    ) {
        self.store = store
        self.loadTimeoutNanos = loadTimeoutNanos
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
    /// delivered from a task rather than blocking WidgetKit's calling thread. The read
    /// races a watchdog: whichever settles first delivers exactly once, and a hung read
    /// falls back to the empty-state entry — branded content the system can always
    /// render — instead of the blank skeleton WidgetKit shows when a completion never
    /// arrives. Both racers are *detached* (M10): neither may inherit whatever actor
    /// context WidgetKit invoked the provider on, so a blocked caller actor can never
    /// starve the watchdog into silence — that coupling was the one way the M8 design
    /// could still end with no completion and a blank skeleton. Each outcome is logged
    /// by category (never content) so a physical-device blank widget can be diagnosed
    /// from `log stream`.
    func loadEntry(
        now: Date = Date(),
        completion: @escaping @Sendable (NettoWidgetEntry) -> Void
    ) {
        let store = self.store
        let timeoutNanos = loadTimeoutNanos
        let gate = EntryDeliveryGate()
        Task.detached(priority: .utility) {
            let summary = await store.load()
            guard gate.deliver() else { return }
            Logger.widget.info("entry delivered status=\(summary?.status.rawValue ?? "none", privacy: .public)")
            completion(Self.entry(for: summary, now: now))
        }
        Task.detached(priority: .userInitiated) {
            do {
                try await Task.sleep(nanoseconds: timeoutNanos)
            } catch {
                return // watchdog cancelled by process teardown — nothing to deliver
            }
            guard gate.deliver() else { return }
            Logger.widget.error("store read timed out; delivering empty-state entry")
            completion(Self.entry(for: nil, now: now))
        }
    }
}

/// Exactly-once delivery for one widget load: the store read and the watchdog race,
/// whichever settles first wins, and the loser is a no-op — WidgetKit must never see
/// two completions (or none).
private final class EntryDeliveryGate: @unchecked Sendable {
    private let lock = NSLock()
    private var delivered = false

    /// Returns `true` exactly once; `false` means someone else already delivered.
    func deliver() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !delivered else { return false }
        delivered = true
        return true
    }
}

import Foundation

/// The user's last swipe decision for one photo in a review session. Persisted as a raw
/// string so an unknown future case fails decode (and is dropped as a whole session) instead
/// of silently reading as a different decision.
enum SwipeReviewDecision: String, Codable, Sendable, Equatable {
    case keep
    case delete
}

/// One swiped photo in the session's undo stack: the identifier, the shared-selection state
/// it had *before* the decision (so Undo is an exact restore), and the decision the asset
/// carried before this entry (`nil` when it was never decided — the normal within-pass case;
/// non-`nil` only when an earlier pass already decided it and a later pass overwrote it).
///
/// Deliberately free of pixels, thumbnails, and full-resolution content: asset identifiers
/// and review state only.
struct SwipeReviewHistoryEntry: Codable, Sendable, Equatable {
    let assetID: String
    let wasSelected: Bool
    var priorDecision: SwipeReviewDecision?
}

/// Everything a Swipe Review session needs to resume exactly where it left off: the deck in
/// review order, the cursor, the undo stack, and the per-asset decision log. Written as one
/// small JSON document (the deck dominates the size — one record per photo, no image data)
/// and restored on the next launch or navigation return.
///
/// `decisions` is the authoritative "what did the user mark in this session" log and is what
/// Review Cleanup scopes itself to; `history` exists for Undo only and is a stack over the
/// current pass's prefix (`history.count == cursor` by construction).
struct SwipeReviewSessionSnapshot: Codable, Sendable, Equatable {
    /// Bump only for incompatible shape changes; a foreign version is dropped on load.
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    /// The deck in the order it is being reviewed (a shuffled pass writes its order here).
    var items: [SwipeReviewItem]
    /// Index of the photo on screen; equals `items.count` once every photo has been swiped.
    var cursor: Int
    /// The undo stack, oldest first. Entries reference assets in the decided prefix.
    var history: [SwipeReviewHistoryEntry]
    /// Asset identifier → the decision last swiped for it in this session. Survives a new
    /// pass (which clears `history` and `cursor` but never what the user already marked).
    var decisions: [String: SwipeReviewDecision]

    init(
        schemaVersion: Int = SwipeReviewSessionSnapshot.currentSchemaVersion,
        items: [SwipeReviewItem] = [],
        cursor: Int = 0,
        history: [SwipeReviewHistoryEntry] = [],
        decisions: [String: SwipeReviewDecision] = [:]
    ) {
        self.schemaVersion = schemaVersion
        self.items = items
        self.cursor = cursor
        self.history = history
        self.decisions = decisions
    }
}

/// Persistence seam for Swipe Review sessions. Tests use an in-memory store so restoration
/// is deterministic; production uses the file-backed store below.
protocol SwipeReviewSessionStore: Sendable {
    /// The saved session, or `nil` when none exists, the file is corrupt, or the schema is
    /// not this version. Never throws, never crashes — an unusable file reads as "fresh".
    func load() -> SwipeReviewSessionSnapshot?
    /// Persists the session. Last write wins; ordering is the store's concern.
    func save(_ snapshot: SwipeReviewSessionSnapshot)
}

/// File-backed store: `<Application Support>/SwipeReview/session.json`, written atomically
/// (same directory and write rules as the scan-state files).
///
/// Writes are *eventual and ordered*: `save` hands the snapshot to a per-store drain that
/// encodes and writes off the main actor, coalescing bursts to the newest snapshot (a rapid
/// run of swipes results in one write, not one per swipe — the file only ever holds a state
/// that actually existed). The drain never runs two writes concurrently, so an older
/// snapshot can never land after a newer one.
struct FileSwipeReviewSessionStore: SwipeReviewSessionStore {
    private static let directoryName = "SwipeReview"
    private static let fileName = "session.json"

    /// Test seam: an explicit directory (e.g. a temporary one) instead of Application Support.
    private let directoryOverride: URL?
    /// Shared across struct copies (a struct, so two stores over one directory remain
    /// independent drains — the app has exactly one store instance).
    private let drain: SwipeSessionWriteDrain

    init(directoryOverride: URL? = nil) {
        self.directoryOverride = directoryOverride
        self.drain = SwipeSessionWriteDrain()
    }

    private func fileURL() throws -> URL {
        let base: URL
        if let directoryOverride {
            base = directoryOverride
        } else {
            base = try FileManager.default.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            ).appendingPathComponent(Self.directoryName, isDirectory: true)
        }
        return base.appendingPathComponent(Self.fileName)
    }

    func load() -> SwipeReviewSessionSnapshot? {
        guard let url = try? fileURL() else { return nil }
        guard let data = try? Data(contentsOf: url) else { return nil }
        guard let snapshot = try? JSONDecoder().decode(SwipeReviewSessionSnapshot.self, from: data)
        else { return nil }
        // Wrong/future schema: ignore safely — fall back to "no session", never resume.
        guard snapshot.schemaVersion == SwipeReviewSessionSnapshot.currentSchemaVersion else {
            return nil
        }
        return snapshot
    }

    func save(_ snapshot: SwipeReviewSessionSnapshot) {
        drain.enqueue(snapshot) { snapshot in
            guard let url = try? self.fileURL() else { return }
            try? FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            guard let data = try? JSONEncoder().encode(snapshot) else { return }
            try? data.write(to: url, options: .atomic)
        }
    }
}

/// Serializes session writes: newest snapshot wins, one write in flight at a time. An
/// enqueue while a write is running replaces the pending snapshot (coalescing), and the
/// running loop picks it up before stopping — so the last enqueued state is always the last
/// state written, and a burst of decisions costs one encode, not one per decision.
final class SwipeSessionWriteDrain: @unchecked Sendable {
    private let lock = NSLock()
    private var pending: SwipeReviewSessionSnapshot?
    private var running = false

    func enqueue(
        _ snapshot: SwipeReviewSessionSnapshot,
        write: @escaping @Sendable (SwipeReviewSessionSnapshot) -> Void
    ) {
        lock.lock()
        pending = snapshot
        if running {
            lock.unlock()
            return
        }
        running = true
        lock.unlock()

        Task.detached(priority: .utility) {
            while let next = self.takeNext() {
                write(next)
            }
        }
    }

    /// Hands the next snapshot to the drain loop and clears the slot. Synchronous so the
    /// lock is acquired in a plain (non-async) context — `NSLock` is unavailable from
    /// `async` contexts under Swift 6 — and always releases it before returning.
    private func takeNext() -> SwipeReviewSessionSnapshot? {
        lock.lock()
        defer { lock.unlock() }
        guard let next = pending else {
            running = false
            return nil
        }
        pending = nil
        return next
    }
}

import Foundation

/// The last **successfully completed** scan, persisted so a relaunch can restore the results
/// without re-running analysis.
///
/// Deliberately reference-only: groups carry `PHAsset.localIdentifier` strings and aggregate
/// counts — never image bytes, thumbnails, `PHAsset`/`PHImage` objects, or anything that would
/// go stale as raw data. The snapshot is written once per completed run (atomically), so an
/// interrupted, cancelled, or failed scan can never replace it.
struct ScanSnapshot: Codable, Equatable, Sendable {
    /// Bump when the persisted shape changes incompatibly; `loadLatest()` discards anything
    /// that does not match, so stale files degrade to "no snapshot", never to a crash.
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    /// Identity of the run that produced this snapshot (a fresh UUID per completion), so a
    /// replaced snapshot is provably a different scan.
    let scanID: String
    /// When the scan reached its terminal completed state. Persisted as a `Date`, never as
    /// preformatted text — the UI derives "Last scanned …" from it at render time.
    let completedAt: Date
    let result: PhotoAnalysisResult
}

/// Persistence seam for `ScanSnapshot` — isolated behind a protocol so tests inject temporary
/// storage instead of touching the app's real file.
protocol ScanSnapshotStore: Sendable {
    /// Replaces the latest snapshot. Only ever called after a scan reaches `.completed`.
    func save(_ snapshot: ScanSnapshot) throws
    /// The most recent completed snapshot, or `nil` when none exists, the data is corrupt, or
    /// the schema is incompatible. Must never throw and never crash.
    func loadLatest() -> ScanSnapshot?
    /// Removes the persisted snapshot (first-run state). No-op when nothing is stored.
    func clear()
}

/// File-backed store: `<Application Support>/ScanState/latest-scan.json`, written atomically.
///
/// Application Support is the app-private Foundation location for per-app documents; no path is
/// hard-coded — the directory comes from `FileManager.url(for:in:appropriateFor:create:)`.
struct FileScanSnapshotStore: ScanSnapshotStore {
    private static let fileName = "latest-scan.json"

    /// Test seam: an explicit directory (e.g. a temporary one) instead of Application Support.
    private let directoryOverride: URL?

    init(directoryOverride: URL? = nil) {
        self.directoryOverride = directoryOverride
    }

    private func directoryURL() throws -> URL {
        try ScanStateDirectory.url(override: directoryOverride)
    }

    private func fileURL() throws -> URL {
        try directoryURL().appendingPathComponent(Self.fileName)
    }

    func save(_ snapshot: ScanSnapshot) throws {
        let url = try fileURL()
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try JSONEncoder().encode(snapshot)
        try data.write(to: url, options: .atomic)
    }

    func loadLatest() -> ScanSnapshot? {
        guard let url = try? fileURL() else { return nil }
        guard let data = try? Data(contentsOf: url) else { return nil }
        guard let snapshot = try? JSONDecoder().decode(ScanSnapshot.self, from: data) else {
            return nil
        }
        // Wrong/future schema: ignore safely — fall back to the no-scan state, never rescan.
        guard snapshot.schemaVersion == ScanSnapshot.currentSchemaVersion else { return nil }
        return snapshot
    }

    func clear() {
        guard let url = try? fileURL() else { return }
        try? FileManager.default.removeItem(at: url)
    }
}

// MARK: - Interrupted-run checkpoints (Phase C)

/// One image's perceptual hash saved mid-run, with the modification date used to
/// re-validate it against a freshly read catalog before resume.
struct PerceptualHashEntry: Codable, Equatable, Sendable {
    let assetID: String
    let modified: Date?
    let bits: UInt64
}

/// One video's content-length key saved mid-run (the cheap exact-match pre-filter),
/// re-validated the same way as a perceptual hash.
struct ContentByteKeyEntry: Codable, Equatable, Sendable {
    let assetID: String
    let modified: Date?
    let imageBytes: Int64
    let videoBytes: Int64
}

/// One image's sharpness verdict saved mid-run. Verdicts — not pixels, not scores-then-
/// reclassify — are what resume trusts: the classification already happened under the
/// thresholds recorded alongside the entries, and resume discards them if the thresholds
/// differ. `laplacianVariance` rides along so a resumed run's candidates can still explain
/// themselves without re-measuring.
struct BlurVerdictEntry: Codable, Equatable, Sendable {
    let assetID: String
    let modified: Date?
    let verdict: BlurVerdict
    let laplacianVariance: Float?
}

/// One video's measured size saved mid-run, re-validated against the fresh catalog before
/// resume so bytes from a deleted or re-exported video are never mixed in.
struct VideoSizeEntry: Codable, Equatable, Sendable {
    let assetID: String
    let modified: Date?
    let bytes: Int64
}

/// Cheap evidence produced by an engine mid-run, reported to a checkpoint sink the moment
/// the evidence exists. Deliberately reference-only: identifiers, dates, and small derived
/// values — never pixels, thumbnails, or content bytes.
enum CheckpointEvidence: Sendable {
    case perceptualHash(assetID: String, modified: Date?, bits: UInt64)
    case contentByteKey(assetID: String, modified: Date?, imageBytes: Int64, videoBytes: Int64)
    case blurVerdict(assetID: String, modified: Date?, verdict: BlurVerdict, laplacianVariance: Float?)
}

/// The durable record of an **in-flight** pass, written in bounded batches so an
/// interruption — backgrounding, expiration, or process death — resumes instead of
/// starting over.
///
/// One file holds at most one checkpoint (see `ScanCheckpointWriter` for the ordering
/// rules), and the payload is strictly bounded: at most one compact entry per asset
/// (~100 bytes), never pixels or content. `runSequence` is a monotonic per-session
/// counter assigned when the run starts — the stale-run guard that keeps a superseded
/// run's late flush from overwriting a newer checkpoint.
struct ScanCheckpoint: Codable, Equatable, Sendable {
    /// Bump when the persisted shape changes incompatibly; `load()` discards anything that
    /// does not match, so a stale file degrades to "no checkpoint", never to a crash.
    static let currentSchemaVersion = 1

    /// Which pass the checkpoint belongs to. Also the priority order for writes: a single
    /// file can hold only one, and the heavier pass's resume info wins over video sizes.
    enum Kind: String, Codable, Sendable, CaseIterable {
        case catalog
        case similarity
        case blur
        case videoSizes

        /// Heavier pass first: when only one consumer asks for "the" checkpoint and several
        /// kinds are stored, the most expensive interrupted work wins the resume slot. A
        /// static on the enum (not the store protocol) so every caller — including ones
        /// holding only an `any ScanCheckpointStore` — can reach it.
        static let priorityOrder: [Kind] = [.similarity, .blur, .catalog, .videoSizes]
    }

    /// Entries accumulated before the next flush triggers — large enough that a 40k-library
    /// scan writes a few dozen times, small enough that each write stays a few milliseconds
    /// of off-main JSON IO.
    static let flushEveryEntries = 256
    /// Time-based flush bound: entry production can stall for long stretches (a slow
    /// stage-4/5 bucket), so progress reaches disk on the clock too.
    static let flushEverySeconds: TimeInterval = 3

    let schemaVersion: Int
    let runSequence: Int
    let kind: Kind
    let startedAt: Date
    let updatedAt: Date
    /// `PhotoAnalysisStage.rawValue` for a similarity run, `"catalog"` for a catalog build,
    /// empty for blur and video runs (single-stage passes report counts only).
    let stage: String
    let completedUnits: Int
    /// 0 = unknown (an indeterminate stage), matching the live progress structs.
    let totalUnits: Int
    let perceptualHashes: [PerceptualHashEntry]
    let byteKeys: [ContentByteKeyEntry]
    let blurVerdicts: [BlurVerdictEntry]
    /// The thresholds the saved verdicts were classified with. Resume compares it against
    /// the thresholds the next run will use and discards mismatched verdicts entirely —
    /// never a mixed-calibration result.
    let blurThresholds: BlurThresholds?
    let videoSizes: [VideoSizeEntry]

    init(
        runSequence: Int,
        kind: Kind,
        startedAt: Date,
        updatedAt: Date,
        stage: String = "",
        completedUnits: Int = 0,
        totalUnits: Int = 0,
        perceptualHashes: [PerceptualHashEntry] = [],
        byteKeys: [ContentByteKeyEntry] = [],
        blurVerdicts: [BlurVerdictEntry] = [],
        blurThresholds: BlurThresholds? = nil,
        videoSizes: [VideoSizeEntry] = []
    ) {
        self.schemaVersion = ScanCheckpoint.currentSchemaVersion
        self.runSequence = runSequence
        self.kind = kind
        self.startedAt = startedAt
        self.updatedAt = updatedAt
        self.stage = stage
        self.completedUnits = completedUnits
        self.totalUnits = totalUnits
        self.perceptualHashes = perceptualHashes
        self.byteKeys = byteKeys
        self.blurVerdicts = blurVerdicts
        self.blurThresholds = blurThresholds
        self.videoSizes = videoSizes
    }
}

/// Persistence seam for `ScanCheckpoint` — same injection rule as `ScanSnapshotStore`:
/// tests use temporary storage instead of the app's real file.
///
/// Kind-addressed (M13): the similarity and sharpness pipelines now run concurrently, so each
/// pass kind owns its own stored checkpoint. `save` routes by the checkpoint's own `kind`.
protocol ScanCheckpointStore: Sendable {
    func save(_ checkpoint: ScanCheckpoint) throws
    /// The stored checkpoint for a single-slot consumer. When several kinds are stored at
    /// once, returns the highest-priority resumable one (heavier pass first) — never nil
    /// merely because other kinds also have checkpoints.
    func load() -> ScanCheckpoint?
    /// Removes every stored kind.
    func clear()
    /// The stored checkpoint for one pass kind, or `nil` when that kind has none.
    func load(kind: ScanCheckpoint.Kind) -> ScanCheckpoint?
    /// Removes only one pass kind's checkpoint, leaving every other kind intact.
    func clear(kind: ScanCheckpoint.Kind)
    /// Every stored checkpoint, one per kind that has one. Bootstrap uses this so a relaunch
    /// restores *every* interrupted pass, not just one of them.
    func loadAll() -> [ScanCheckpoint]
}

extension ScanCheckpointStore {
    /// Heavier pass first (see `ScanCheckpoint.Kind.priorityOrder`, the single definition).
    static var priorityOrder: [ScanCheckpoint.Kind] {
        ScanCheckpoint.Kind.priorityOrder
    }
}

/// File-backed store: one file per pass kind under `<Application Support>/ScanState/`
/// (`checkpoint-similarity.json`, `checkpoint-blur.json`, …), each written atomically.
///
/// Application Support is the app-private Foundation location for per-app documents; no path
/// is hard-coded — the directory comes from `FileManager.url(for:in:appropriateFor:create:)`.
struct FileScanCheckpointStore: ScanCheckpointStore {
    /// Test seam: an explicit directory (e.g. a temporary one) instead of Application Support.
    private let directoryOverride: URL?

    init(directoryOverride: URL? = nil) {
        self.directoryOverride = directoryOverride
    }

    private func directoryURL() throws -> URL {
        try ScanStateDirectory.url(override: directoryOverride)
    }

    private func fileURL(for kind: ScanCheckpoint.Kind) throws -> URL {
        try directoryURL().appendingPathComponent("checkpoint-\(kind.rawValue).json")
    }

    func save(_ checkpoint: ScanCheckpoint) throws {
        let url = try fileURL(for: checkpoint.kind)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try JSONEncoder().encode(checkpoint)
        try data.write(to: url, options: .atomic)
    }

    func load() -> ScanCheckpoint? {
        for kind in Self.priorityOrder {
            if let checkpoint = load(kind: kind) { return checkpoint }
        }
        return nil
    }

    func load(kind: ScanCheckpoint.Kind) -> ScanCheckpoint? {
        guard let url = try? fileURL(for: kind) else { return nil }
        guard let data = try? Data(contentsOf: url) else { return nil }
        guard let checkpoint = try? JSONDecoder().decode(ScanCheckpoint.self, from: data) else {
            return nil
        }
        // Wrong/future schema, or a file that no longer matches its kind: ignore safely —
        // fall back to "no checkpoint", never resume.
        guard checkpoint.schemaVersion == ScanCheckpoint.currentSchemaVersion,
              checkpoint.kind == kind
        else { return nil }
        return checkpoint
    }

    func loadAll() -> [ScanCheckpoint] {
        ScanCheckpoint.Kind.allCases.compactMap { load(kind: $0) }
    }

    func clear() {
        for kind in ScanCheckpoint.Kind.allCases {
            clear(kind: kind)
        }
    }

    func clear(kind: ScanCheckpoint.Kind) {
        guard let url = try? fileURL(for: kind) else { return }
        try? FileManager.default.removeItem(at: url)
    }
}

/// Presents one pass kind's slice of a shared multi-kind store as a single-slot store, so
/// each concurrent pass owns an independent `ScanCheckpointWriter` (with its own write
/// ordering) while still persisting through the one injected seam. Without this, two
/// concurrent writers sharing a store would order-guard each other's flushes away.
struct KindScopedCheckpointStore: ScanCheckpointStore {
    private let base: any ScanCheckpointStore
    private let kind: ScanCheckpoint.Kind

    init(base: any ScanCheckpointStore, kind: ScanCheckpoint.Kind) {
        self.base = base
        self.kind = kind
    }

    func save(_ checkpoint: ScanCheckpoint) throws {
        // The base routes by the checkpoint's own kind; a scoped store never rewrites it.
        try base.save(checkpoint)
    }

    func load() -> ScanCheckpoint? {
        base.load(kind: kind)
    }

    func clear() {
        base.clear(kind: kind)
    }

    func load(kind requested: ScanCheckpoint.Kind) -> ScanCheckpoint? {
        requested == kind ? base.load(kind: kind) : nil
    }

    func clear(kind requested: ScanCheckpoint.Kind) {
        guard requested == kind else { return }
        base.clear(kind: kind)
    }

    func loadAll() -> [ScanCheckpoint] {
        base.load(kind: kind).map { [$0] } ?? []
    }
}

/// Per-kind checkpoint channels (M13): every pass kind owns its own writer and accumulator,
/// so the similarity and sharpness pipelines can run — and be interrupted — concurrently
/// without contending for a single checkpoint slot. Each channel persists through the one
/// injected store seam, scoped to its own kind.
final class CheckpointChannels: @unchecked Sendable {
    private var writers: [ScanCheckpoint.Kind: ScanCheckpointWriter] = [:]
    private var accumulators: [ScanCheckpoint.Kind: ScanCheckpointAccumulator] = [:]

    /// - Parameters:
    ///   - store: the injected persistence seam; each channel scopes it to its own kind.
    ///   - restored: every checkpoint a relaunch restored, so each channel's writer learns
    ///     its own kind's ordering before any new run claims the file.
    init(store: any ScanCheckpointStore, restored: [ScanCheckpoint] = []) {
        for kind in ScanCheckpoint.Kind.allCases {
            let scoped = KindScopedCheckpointStore(base: store, kind: kind)
            let writer = ScanCheckpointWriter(
                store: scoped,
                adopting: restored.first { $0.kind == kind }
            )
            writers[kind] = writer
            accumulators[kind] = ScanCheckpointAccumulator(writer: writer)
        }
    }

    func writer(for kind: ScanCheckpoint.Kind) -> ScanCheckpointWriter {
        // `allCases` populated every kind; the fallback keeps the accessor non-optional.
        writers[kind] ?? ScanCheckpointWriter(store: KindScopedCheckpointStore(base: FileScanCheckpointStore(), kind: kind))
    }

    func accumulator(for kind: ScanCheckpoint.Kind) -> ScanCheckpointAccumulator {
        accumulators[kind] ?? ScanCheckpointAccumulator(writer: writer(for: kind))
    }

    /// Teaches one kind's writer what its file already holds, so a kind-aware clear still
    /// works across a relaunch (e.g. a video-size settle must not remove a restored
    /// heavy pass's file — they are separate files, but the ordering seed matters).
    func adopt(_ checkpoint: ScanCheckpoint) {
        writer(for: checkpoint.kind).adopt(checkpoint)
    }
}

/// The on-disk location both scan-state files share (`latest-scan.json` and
/// `checkpoint.json`): Application Support's app-private directory, never a hard-coded path.
enum ScanStateDirectory {
    static let directoryName = "ScanState"

    static func url(override: URL?) throws -> URL {
        if let override { return override }
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return base.appendingPathComponent(directoryName, isDirectory: true)
    }
}

/// Serializes checkpoint writes so a superseded run can never overwrite a newer run's
/// checkpoint, and a cleared checkpoint can never be resurrected by a late flush.
///
/// Ordering rule, enforced under one lock: a write is accepted only when its
/// `(runSequence, updatedAt)` is strictly newer than the last accepted write, and only
/// when its sequence is above the highest cleared sequence. Completion, explicit cancel,
/// and supersession all clear *through* the current run's sequence, which permanently
/// blocks any straggler flush from that run or an earlier one.
final class ScanCheckpointWriter: @unchecked Sendable {
    private let store: any ScanCheckpointStore
    private let lock = NSLock()
    private var lastWritten: (sequence: Int, updatedAt: TimeInterval) =
        (Int.min, -TimeInterval.greatestFiniteMagnitude)
    private var blockedThroughSequence = Int.min
    /// What the single file currently holds (nil = no file). Seeded from a restored
    /// checkpoint at bootstrap so a previous session's kind is still known.
    private var currentKind: ScanCheckpoint.Kind?

    init(store: any ScanCheckpointStore, adopting restored: ScanCheckpoint? = nil) {
        self.store = store
        if let restored {
            adopt(restored)
        }
    }

    /// Learns what a restored file holds so kind-aware clears keep working across a
    /// relaunch (e.g. a video-size settle must not remove a previous session's file).
    func adopt(_ restored: ScanCheckpoint) {
        lock.lock()
        defer { lock.unlock() }
        currentKind = restored.kind
        lastWritten = (restored.runSequence, restored.updatedAt.timeIntervalSinceReferenceDate)
    }

    /// Best-effort write: a failed file write is dropped (the live run continues and the
    /// next flush retries), never surfaced as a run failure.
    func write(_ checkpoint: ScanCheckpoint) {
        lock.lock()
        defer { lock.unlock() }
        guard checkpoint.runSequence > blockedThroughSequence else { return }
        guard checkpoint.runSequence > lastWritten.sequence
            || (checkpoint.runSequence == lastWritten.sequence
                && checkpoint.updatedAt.timeIntervalSinceReferenceDate > lastWritten.updatedAt)
        else { return }
        guard (try? store.save(checkpoint)) != nil else { return }
        lastWritten = (
            checkpoint.runSequence,
            checkpoint.updatedAt.timeIntervalSinceReferenceDate
        )
        currentKind = checkpoint.kind
    }

    /// Unconditional clear (fresh run, explicit cancel, supersession): the file goes and
    /// every write at or below `sequence` is blocked from bringing it back.
    func clear(through sequence: Int) {
        lock.lock()
        defer { lock.unlock() }
        blockedThroughSequence = max(blockedThroughSequence, sequence)
        store.clear()
        currentKind = nil
    }

    /// Completion clear: removes the file only when it holds `kind` (another pass's
    /// resumable state is never destroyed by this run finishing), while still blocking
    /// this run's own late flushes.
    func clear(owning kind: ScanCheckpoint.Kind, through sequence: Int) {
        lock.lock()
        defer { lock.unlock() }
        blockedThroughSequence = max(blockedThroughSequence, sequence)
        guard currentKind == kind || currentKind == nil else { return }
        store.clear()
        currentKind = nil
    }

    /// Whether `kind` may replace the file right now — used by the video-size checkpoint,
    /// which must never overwrite a paused heavy pass's resume information.
    func allows(_ kind: ScanCheckpoint.Kind) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return currentKind == nil || currentKind == kind
    }

    var kind: ScanCheckpoint.Kind? {
        lock.lock()
        defer { lock.unlock() }
        return currentKind
    }
}

/// In-memory accumulation for one interrupted run, flushed to disk in bounded batches.
///
/// Entry producers (engine workers) call `record` off the main actor; the batch trigger
/// hands an immutable snapshot to a detached task, so a full-library flush never blocks
/// either the workers or the main actor. The only synchronous write is `flushNowSync`,
/// used at pause/expiration where determinism matters more than a few milliseconds.
final class ScanCheckpointAccumulator: @unchecked Sendable {
    private let lock = NSLock()
    private let writer: ScanCheckpointWriter
    private let batchEntries: Int
    private let batchInterval: TimeInterval
    private let now: @Sendable () -> Date

    private var kind: ScanCheckpoint.Kind?
    private var runSequence = Int.min
    private var startedAt = Date()
    private var stage = ""
    private var completedUnits = 0
    private var totalUnits = 0
    private var perceptualHashes: [PerceptualHashEntry] = []
    private var byteKeys: [ContentByteKeyEntry] = []
    private var blurVerdicts: [BlurVerdictEntry] = []
    private var blurThresholds: BlurThresholds?
    private var dirty = false
    private var entriesSinceFlush = 0
    private var lastFlushAt = Date.distantPast

    init(
        writer: ScanCheckpointWriter,
        batchEntries: Int = ScanCheckpoint.flushEveryEntries,
        batchInterval: TimeInterval = ScanCheckpoint.flushEverySeconds,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.writer = writer
        self.batchEntries = batchEntries
        self.batchInterval = batchInterval
        self.now = now
    }

    /// Starts accumulating for a run. `carrying` restores a previous checkpoint's payload
    /// (resume), so its evidence is never re-earned; `nil` starts empty (fresh run).
    /// Returns the run's sequence — the value sinks must present to be accepted (callers
    /// that already hold the sequence they passed in may ignore it).
    @discardableResult
    func begin(
        kind: ScanCheckpoint.Kind,
        runSequence: Int,
        carrying checkpoint: ScanCheckpoint?
    ) -> Int {
        lock.lock()
        defer { lock.unlock() }
        self.kind = kind
        self.runSequence = runSequence
        self.startedAt = checkpoint?.startedAt ?? now()
        self.stage = checkpoint?.stage ?? ""
        self.completedUnits = checkpoint?.completedUnits ?? 0
        self.totalUnits = checkpoint?.totalUnits ?? 0
        self.perceptualHashes = checkpoint?.perceptualHashes ?? []
        self.byteKeys = checkpoint?.byteKeys ?? []
        self.blurVerdicts = checkpoint?.blurVerdicts ?? []
        self.blurThresholds = checkpoint?.blurThresholds ?? nil
        self.entriesSinceFlush = checkpoint == nil ? 0 : ScanCheckpoint.flushEveryEntries
        self.lastFlushAt = now()
        self.dirty = checkpoint != nil
        return runSequence
    }

    /// Releases the run without writing: the caller has cleared the file (completion,
    /// cancel, supersession) or is about to rewrite it under a new run.
    func endRun() {
        lock.lock()
        defer { lock.unlock() }
        kind = nil
        runSequence = Int.min
        perceptualHashes = []
        byteKeys = []
        blurVerdicts = []
        blurThresholds = nil
        dirty = false
        entriesSinceFlush = 0
    }

    var currentRunSequence: Int {
        lock.lock()
        defer { lock.unlock() }
        return runSequence
    }

    /// What the active accumulation belongs to; nil between runs.
    var activeKind: ScanCheckpoint.Kind? {
        lock.lock()
        defer { lock.unlock() }
        return kind
    }

    var isActive: Bool {
        lock.lock()
        defer { lock.unlock() }
        return kind != nil
    }

    /// One piece of evidence from a run worker. Ignored when the sequence does not match
    /// the active run — a cancelled run's stragglers can never pollute the next run.
    func record(_ evidence: CheckpointEvidence, runSequence: Int) {
        lock.lock()
        guard kind != nil, runSequence == self.runSequence else {
            lock.unlock()
            return
        }
        switch evidence {
        case .perceptualHash(let assetID, let modified, let bits):
            perceptualHashes.append(PerceptualHashEntry(
                assetID: assetID, modified: modified, bits: bits
            ))
        case .contentByteKey(let assetID, let modified, let imageBytes, let videoBytes):
            byteKeys.append(ContentByteKeyEntry(
                assetID: assetID,
                modified: modified,
                imageBytes: imageBytes,
                videoBytes: videoBytes
            ))
        case .blurVerdict(let assetID, let modified, let verdict, let laplacianVariance):
            blurVerdicts.append(BlurVerdictEntry(
                assetID: assetID,
                modified: modified,
                verdict: verdict,
                laplacianVariance: laplacianVariance
            ))
        }
        dirty = true
        entriesSinceFlush += 1
        let shouldFlush = entriesSinceFlush >= batchEntries
            || now().timeIntervalSince(lastFlushAt) >= batchInterval
        guard shouldFlush else {
            lock.unlock()
            return
        }
        entriesSinceFlush = 0
        lastFlushAt = now()
        guard let state = flushStateLocked() else {
            lock.unlock()
            return
        }
        lock.unlock()
        // Detached: the identifier sorts (O(n log n) over every accumulated entry) and the
        // JSON write both leave the caller — engine workers, and the main actor through
        // `setProgress`, where a full-library sort every 3 s was a visible hitch.
        Task.detached(priority: .utility) { [writer] in
            writer.write(Self.checkpoint(from: state))
        }
    }

    /// Progress for the active run, tagged with its kind so a chained catalog rebuild
    /// (which never begins its own run) cannot rewrite a paused pass's saved stage.
    ///
    /// Also runs the time-based flush bound: a progress-only run (catalog) produces no
    /// evidence records, so without this its checkpoint would only reach disk at a
    /// lifecycle event — the 3 s clock bound must hold for it too.
    func setProgress(
        kind: ScanCheckpoint.Kind,
        stage: String,
        completed: Int,
        total: Int
    ) {
        lock.lock()
        guard self.kind == kind else {
            lock.unlock()
            return
        }
        self.stage = stage
        completedUnits = completed
        totalUnits = total
        dirty = true
        guard now().timeIntervalSince(lastFlushAt) >= batchInterval,
              let state = flushStateLocked()
        else {
            lock.unlock()
            return
        }
        entriesSinceFlush = 0
        lastFlushAt = now()
        lock.unlock()
        // Detached, same as `record`: this call runs on the main actor (every coalesced
        // progress write), so the O(evidence) identifier sort must not land there.
        Task.detached(priority: .utility) { [writer] in
            writer.write(Self.checkpoint(from: state))
        }
    }

    /// Stamps the calibration the blur run is classifying with, so an interruption
    /// persists it alongside the verdicts and resume can reject a stale calibration.
    func noteBlurThresholds(_ thresholds: BlurThresholds) {
        lock.lock()
        defer { lock.unlock() }
        guard kind == .blur else { return }
        blurThresholds = thresholds
        dirty = true
    }

    /// Best-effort snapshot of what is accumulated right now; nil when no run is active.
    func snapshot() -> ScanCheckpoint? {
        lock.lock()
        guard let state = flushStateLocked() else {
            lock.unlock()
            return nil
        }
        lock.unlock()
        return Self.checkpoint(from: state)
    }

    /// Writes any pending state synchronously and returns whether it wrote. Used at
    /// pause/expiration (deterministic) and inactive transitions (best-effort insurance).
    @discardableResult
    func flushNowSync() -> Bool {
        lock.lock()
        guard dirty, let state = flushStateLocked() else {
            lock.unlock()
            return false
        }
        dirty = false
        entriesSinceFlush = 0
        lastFlushAt = now()
        lock.unlock()
        writer.write(Self.checkpoint(from: state))
        return true
    }

    /// Immutable copy of the accumulated state, taken under the lock (so `updatedAt` orders
    /// against exactly the payload it stamps); nil when no writable run is active.
    private func flushStateLocked() -> FlushState? {
        guard let kind, kind != .videoSizes else { return nil }
        return FlushState(
            runSequence: runSequence,
            kind: kind,
            startedAt: startedAt,
            updatedAt: now(),
            stage: stage,
            completedUnits: completedUnits,
            totalUnits: totalUnits,
            perceptualHashes: perceptualHashes,
            byteKeys: byteKeys,
            blurVerdicts: blurVerdicts,
            blurThresholds: blurThresholds
        )
    }

    /// The sort-and-build step, extracted so the flush paths can run it *off* the caller
    /// (the identifier sorts are O(n log n) over every accumulated entry — engine-worker
    /// threads, and the main actor through `setProgress`). Ordering by identifier keeps a
    /// snapshot of the same evidence byte-identical regardless of worker completion order —
    /// determinism for tests and diffs, unchanged from the previous under-lock sort.
    private static func checkpoint(from state: FlushState) -> ScanCheckpoint {
        ScanCheckpoint(
            runSequence: state.runSequence,
            kind: state.kind,
            startedAt: state.startedAt,
            updatedAt: state.updatedAt,
            stage: state.stage,
            completedUnits: state.completedUnits,
            totalUnits: state.totalUnits,
            perceptualHashes: state.perceptualHashes.sorted { $0.assetID < $1.assetID },
            byteKeys: state.byteKeys.sorted { $0.assetID < $1.assetID },
            blurVerdicts: state.blurVerdicts.sorted { $0.assetID < $1.assetID },
            blurThresholds: state.blurThresholds
        )
    }

    /// Immutable snapshot inputs (arrays shared via copy-on-write — taking this is O(1)
    /// apart from the array headers, never a per-entry copy).
    private struct FlushState: Sendable {
        let runSequence: Int
        let kind: ScanCheckpoint.Kind
        let startedAt: Date
        let updatedAt: Date
        let stage: String
        let completedUnits: Int
        let totalUnits: Int
        let perceptualHashes: [PerceptualHashEntry]
        let byteKeys: [ContentByteKeyEntry]
        let blurVerdicts: [BlurVerdictEntry]
        let blurThresholds: BlurThresholds?
    }
}

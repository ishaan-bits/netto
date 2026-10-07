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
    private static let directoryName = "ScanState"

    /// Test seam: an explicit directory (e.g. a temporary one) instead of Application Support.
    private let directoryOverride: URL?

    init(directoryOverride: URL? = nil) {
        self.directoryOverride = directoryOverride
    }

    private func directoryURL() throws -> URL {
        if let directoryOverride { return directoryOverride }
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return base.appendingPathComponent(Self.directoryName, isDirectory: true)
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

import Foundation

/// The single shared value the app writes to the App Group container for the home screen
/// widget to read. Deliberately minimal — status, one optional byte figure, one timestamp,
/// one schema version — so the widget renders offline without PhotoKit, the scan snapshot,
/// or any other app-owned state.
///
/// The byte figure is always an *estimate*: it is the measured-bytes total of the latest
/// confirmed cleanup (see `SpaceFreedSummary.measuredBytes`), which the app itself still
/// documents as an estimate of reclaimed space. The architecture has no authoritative
/// "current reclaimable bytes" producer, so no such value may ever be invented here —
/// when there is no measured figure the status carries none (`estimateBytes == nil`).
///
/// Every value is validated on both write and read:
/// - A writer that passes an inconsistent combination gets `nil` back from `init?` and
///   simply does not write.
/// - A reader decodes through the same validation; an inconsistent or wrong-schema file
///   throws, so the store loads `nil` and the widget falls back to its empty state
///   instead of rendering fabricated content.
struct WidgetSummary: Codable, Equatable, Sendable {
    /// Schema of the shared JSON document. A reader rejects any other value, so a newer
    /// writer can never confuse an older widget — bump only with a migration story.
    static let currentSchemaVersion = 1

    /// What the widget is allowed to show. Kept small on purpose: the shared contract
    /// carries one status, one optional figure, and one timestamp — nothing else.
    enum Status: String, Codable, Sendable {
        /// Nothing trustworthy yet — first run, or no completed scan and no cleanup.
        case empty
        /// A completed scan exists; there is no measured byte figure to show.
        case scanReady
        /// The latest confirmed cleanup's measured figure (`estimateBytes` is set).
        case lastCleanup
    }

    /// Age past which the widget must flag the content as not recent, so an old figure is
    /// never implied to describe current reclaimable storage.
    static let staleAfter: TimeInterval = 7 * 24 * 60 * 60

    /// Schema this value was written under; must equal `currentSchemaVersion`.
    let schemaVersion: Int
    /// Which of the three allowed states the widget is in.
    let status: Status
    /// Measured-bytes estimate of the last confirmed cleanup — present only with
    /// `.lastCleanup`, always positive, always an estimate.
    let estimateBytes: Int64?
    /// Must be `true` whenever `estimateBytes` is present: the figure is an estimate.
    let isEstimated: Bool
    /// When this status was last truthfully observed — the scan's completion date for
    /// `.scanReady`, the cleanup moment for `.lastCleanup`.
    let updatedAt: Date

    /// Failable by design: `nil` means the value would be inconsistent (wrong schema,
    /// figure without a cleanup status, cleanup status without a positive figure, a
    /// non-estimate figure, or a pre-epoch timestamp) and must not be written.
    init?(
        schemaVersion: Int,
        status: Status,
        estimateBytes: Int64?,
        isEstimated: Bool,
        updatedAt: Date
    ) {
        guard Self.isConsistent(
            schemaVersion: schemaVersion,
            status: status,
            estimateBytes: estimateBytes,
            isEstimated: isEstimated,
            updatedAt: updatedAt
        ) else { return nil }
        self.schemaVersion = schemaVersion
        self.status = status
        self.estimateBytes = estimateBytes
        self.isEstimated = isEstimated
        self.updatedAt = updatedAt
    }

    /// True once the content is older than `staleAfter` at render time. A future
    /// timestamp (clock skew) reads as not stale — it is at worst unhelpfully recent.
    func isStale(relativeTo now: Date) -> Bool {
        now.timeIntervalSince(updatedAt) > Self.staleAfter
    }

    /// The one consistency rule, shared by the writer's `init?` and the reader's
    /// `init(from:)` so both sides of the file agree on what may exist in it.
    private static func isConsistent(
        schemaVersion: Int,
        status: Status,
        estimateBytes: Int64?,
        isEstimated: Bool,
        updatedAt: Date
    ) -> Bool {
        guard schemaVersion == currentSchemaVersion else { return false }
        // A pre-epoch timestamp is corruption, not history.
        guard updatedAt.timeIntervalSince1970 > 0 else { return false }
        switch status {
        case .lastCleanup:
            // A cleanup status without a positive, explicitly-estimated figure would let
            // the widget imply a number that was never measured.
            guard let estimateBytes, estimateBytes > 0, isEstimated else { return false }
        case .empty, .scanReady:
            // Conversely: no cleanup means no figure, and nothing to label as estimated.
            guard estimateBytes == nil, !isEstimated else { return false }
        }
        return true
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case status
        case estimateBytes
        case isEstimated
        case updatedAt
    }

    /// Decoding re-runs the write-side validation, so a hand-edited, truncated-then-
    /// repaired, or stale-schema file loads as `nil` instead of reaching the widget.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        let status = try container.decode(Status.self, forKey: .status)
        let estimateBytes = try container.decodeIfPresent(Int64.self, forKey: .estimateBytes)
        let isEstimated = try container.decodeIfPresent(Bool.self, forKey: .isEstimated) ?? false
        let updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        guard Self.isConsistent(
            schemaVersion: schemaVersion,
            status: status,
            estimateBytes: estimateBytes,
            isEstimated: isEstimated,
            updatedAt: updatedAt
        ) else {
            throw DecodingError.dataCorruptedError(
                forKey: .schemaVersion,
                in: container,
                debugDescription: "inconsistent or unsupported widget summary"
            )
        }
        self.schemaVersion = schemaVersion
        self.status = status
        self.estimateBytes = estimateBytes
        self.isEstimated = isEstimated
        self.updatedAt = updatedAt
    }
}

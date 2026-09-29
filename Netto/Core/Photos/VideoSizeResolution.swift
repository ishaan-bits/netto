import Foundation

/// Measured video sizes for the current video dataset — the video list's explicit size
/// resolution state, mirroring what photo sizes do implicitly at review time.
///
/// Sizes are *measured*, never estimated: `bytes` only ever contains identifiers the size
/// provider actually resolved, and an absent identifier stays unknown. The state carries the
/// dataset fingerprint the measurement ran over, so a rebuilt catalog invalidates the bytes
/// instead of silently mixing datasets.
enum VideoSizeResolution: Sendable, Equatable {
    /// No measurement has run (or a rebuilt dataset dropped the previous one).
    case idle
    /// Measurement in flight. `bytes` holds what has landed so far — batch by batch, so the
    /// screen can show honest progress and a cancel keeps everything measured up to that point.
    case measuring(Measurement)
    /// Measurement finished *or was cancelled*. `measuredCount < total` means the state is
    /// partial: some videos are still unknown, which is shown as unknown — never as zero.
    case settled(Measurement)

    /// One measurement attempt over one dataset identity.
    struct Measurement: Sendable, Equatable {
        /// `VideoDataset.signature` of the catalog the bytes were measured against.
        let datasetSignature: String
        /// Measured bytes by identifier. Absent → unknown, never zero.
        let bytes: [String: Int64]
        /// Videos in the dataset when this measurement started.
        let total: Int

        var measuredCount: Int { bytes.count }
        /// Some videos in this dataset were never measured (cancelled, or content unreadable).
        var isPartial: Bool { measuredCount < total }
    }

    /// Sequential batch size for resolution: at most this many identifiers are handed to the
    /// (internally 4-wide) size provider at once, so a large video list produces bounded,
    /// cancellable progress instead of one unbounded fan-out.
    static let measurementBatchSize = 32

    /// Measured bytes in any state (`[:]` while idle).
    var bytes: [String: Int64] {
        switch self {
        case .idle: return [:]
        case .measuring(let m), .settled(let m): return m.bytes
        }
    }

    var measurement: Measurement? {
        switch self {
        case .idle: return nil
        case .measuring(let m), .settled(let m): return m
        }
    }

    var isMeasuring: Bool {
        if case .measuring = self { return true }
        return false
    }

    /// Settled measurements whose fingerprint still matches this dataset are reusable;
    /// anything else must be dropped by the caller when the dataset changes.
    func isCurrent(for datasetSignature: String) -> Bool {
        measurement?.datasetSignature == datasetSignature
    }
}

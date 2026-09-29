import CryptoKit
import Foundation

/// Exact-content identity of one asset: byte lengths plus SHA-256 digests of the content files
/// that are actually on disk.
///
/// Design notes:
/// - **Lengths first, hashes second.** Byte-identical files necessarily have identical lengths,
///   so `(imageBytes, videoBytes)` is a complete pre-filter: assets whose length pair is unique
///   in the library are never read at all. Only length collisions cost a full file read — this is
///   what keeps exact-duplicate detection from becoming a whole-library content scan.
/// - **Never holds content.** Digests are computed by streaming 64 KB chunks; no asset's bytes
///   are ever resident beyond one chunk.
/// - **Videos included.** An exact duplicate video frees as much space as a photo; the video's
///   own file participates in the fingerprint alongside a Live Photo's still.
struct ContentFingerprint: Sendable, Hashable {
    let imageBytes: Int64
    let videoBytes: Int64
    /// `nil` when the asset has no image file (a video-only asset).
    let imageDigestHex: String?
    /// `nil` when the asset has no video file (a plain still).
    let videoDigestHex: String?

    /// Stable, collision-safe string for evidence and group ids: both digests, so an image and a
    /// video can never collapse onto the same evidence key.
    var combinedDigestHex: String {
        "\(imageDigestHex ?? "-")/\(videoDigestHex ?? "-")"
    }

    var totalBytes: Int64 { imageBytes + videoBytes }

    /// The cheap pre-filter key. Two assets with different keys are provably not byte-identical.
    var byteKey: ContentByteKey {
        ContentByteKey(imageBytes: imageBytes, videoBytes: videoBytes)
    }
}

/// Length-only identity: enough to prove two assets *cannot* be byte-identical, without reading
/// a single content byte.
struct ContentByteKey: Sendable, Hashable {
    let imageBytes: Int64
    let videoBytes: Int64
}

enum ContentLengthOutcome: Sendable, Equatable {
    case key(ContentByteKey)
    case unavailable(PhotoAnalysisUnavailableReason)
}

enum ContentFingerprintOutcome: Sendable, Equatable {
    case fingerprinted(ContentFingerprint)
    case unavailable(PhotoAnalysisUnavailableReason)
}

/// Seam over PhotoKit content access: the engine must be drivable from fakes that never touch a
/// photo library, and the two-phase (length, then hash) strategy must be expressible by fakes
/// without pretending to read files.
protocol ContentFingerprinting: Sendable {
    /// Phase 1: cheap stat-only length probe. Never reads content.
    func byteKey(for record: PhotoAssetRecord) async throws -> ContentLengthOutcome

    /// Phase 2: full SHA-256 over the asset's on-disk content. Only called for assets whose
    /// `ContentByteKey` collided with at least one other asset.
    func fingerprint(for record: PhotoAssetRecord) async throws -> ContentFingerprintOutcome
}

/// Streaming SHA-256 over a local file, 64 KB at a time.
///
/// Pure, synchronous, and cancellation-aware — the testable core of exact-duplicate detection,
/// usable against any `file://` URL without a photo library.
enum ContentHasher {
    static let chunkSize = 65_536

    static func sha256Hex(ofFileAt url: URL) async throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        var hasher = SHA256()
        while true {
            try Task.checkCancellation()
            guard let chunk = try handle.read(upToCount: chunkSize), !chunk.isEmpty else { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func fileSize(at url: URL) -> Int64? {
        guard let values = try? FileManager.default.attributesOfItem(atPath: url.path),
              let number = values[.size] as? NSNumber else { return nil }
        let bytes = number.int64Value
        return bytes > 0 ? bytes : nil
    }
}

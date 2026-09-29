import CoreGraphics
import Foundation

/// Bounded, request-coalescing cache for review thumbnails.
///
/// The review UI shows the same asset repeatedly (strip, detail, revisit), so every load goes
/// through this actor instead of straight to PhotoKit. Its guarantees:
/// - **Bounded.** At most `capacity` entries *and* at most `byteLimit` resident bytes; the
///   least-recently-used entry is evicted until both hold, so a scroll through a large library
///   (or a run of full-size detail previews) cannot grow memory without limit.
/// - **Coalesced.** Concurrent requests for the same key share one in-flight load.
/// - **Negatively cached.** A failed thumbnail (deleted asset, iCloud-only) is remembered as a
///   failure so scrolling does not hammer PhotoKit — except cancellation, which is never cached
///   because it says nothing about the asset.
/// - **Pixel-bounded.** Callers pass a `targetPixelSize`; full-resolution pixels never enter the
///   cache. Entries are keyed by size *and* asset, so the strip (small) and the detail sheet
///   (larger) never serve each other's bitmap.
actor ThumbnailStore {
    private let loader: any PhotoThumbnailLoading
    private let capacity: Int
    private let byteLimit: Int

    private enum Entry {
        case hit(CGImage)
        case miss(PhotoContentError)
    }

    /// Keys currently in `entries`, least-recently used first.
    private var order: [String] = []
    private var entries: [String: Entry] = [:]
    private var bytesByEntry: [String: Int] = [:]
    private var residentBytes: Int = 0
    /// Loads shared between concurrent requests. Deliberately not part of `order`.
    private var inFlight: [String: Task<CGImage, any Error>] = [:]

    init(
        loader: any PhotoThumbnailLoading = PhotoKitThumbnailLoader(),
        capacity: Int = 96,
        byteLimit: Int = 48 * 1024 * 1024
    ) {
        self.loader = loader
        self.capacity = max(1, capacity)
        self.byteLimit = max(1, byteLimit)
    }

    /// Returns a thumbnail of at most `targetPixelSize` on its longest side, or throws the
    /// loader's error on first failure and the cached failure afterwards.
    func image(for assetID: String, targetPixelSize: Int) async throws -> CGImage {
        let key = Self.key(assetID: assetID, targetPixelSize: targetPixelSize)

        if let cached = entries[key] {
            touch(key)
            switch cached {
            case .hit(let image):
                return image
            case .miss(let failure):
                throw failure
            }
        }

        if let existing = inFlight[key] {
            let image = try await existing.value
            touch(key)
            return image
        }

        let loader = self.loader
        let load = Task { try await loader.thumbnail(for: assetID, targetPixelSize: targetPixelSize) }
        inFlight[key] = load

        do {
            let image = try await load.value
            inFlight[key] = nil
            store(.hit(image), forKey: key)
            return image
        } catch {
            inFlight[key] = nil
            if let failure = Self.cachedFailure(for: error) {
                store(.miss(failure), forKey: key)
            }
            throw error
        }
    }

    // MARK: Cache mechanics

    private static func key(assetID: String, targetPixelSize: Int) -> String {
        "\(max(1, targetPixelSize))|\(assetID)"
    }

    /// Cancellation is a property of the caller, not of the asset: caching it would poison the
    /// entry for every later viewer.
    private static func cachedFailure(for error: any Error) -> PhotoContentError? {
        if error is CancellationError { return nil }
        if let content = error as? PhotoContentError { return content }
        return .unavailable
    }

    private func touch(_ key: String) {
        if let index = order.firstIndex(of: key) {
            order.remove(at: index)
        }
        order.append(key)
    }

    private func store(_ entry: Entry, forKey key: String) {
        remove(key)
        entries[key] = entry
        if case .hit(let image) = entry {
            let bytes = image.bytesPerRow * image.height
            bytesByEntry[key] = bytes
            residentBytes += bytes
        }
        touch(key)
        while entries.count > capacity || residentBytes > byteLimit {
            guard let oldest = order.first else { break }
            remove(oldest)
        }
    }

    /// Drops one key from every index and returns its resident bytes to the budget.
    private func remove(_ key: String) {
        if let index = order.firstIndex(of: key) {
            order.remove(at: index)
        }
        if let bytes = bytesByEntry.removeValue(forKey: key) {
            residentBytes -= bytes
        }
        entries.removeValue(forKey: key)
    }
}

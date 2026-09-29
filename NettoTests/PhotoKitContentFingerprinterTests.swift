import Foundation
import Photos
import Testing
@testable import Netto

// MARK: - Fixtures

private func temporaryFile(named name: String, bytes: Int) throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("netto-live-fp-\(name)-\(UUID().uuidString)")
    // Content is seeded by `name`, so two files with the *same length* have different bytes —
    // the exact setup the phase-2 collision tests need.
    var seed: UInt64 = 0xcbf2_9ce4_8422_2325
    for byte in name.utf8 {
        seed ^= UInt64(byte)
        seed = seed &* 0x0000_0100_0000_01b3
    }
    var payload = Data(count: bytes)
    payload.withUnsafeMutableBytes { raw in
        for index in 0..<raw.count {
            raw[index] = UInt8(truncatingIfNeeded: seed ^ UInt64(index))
        }
    }
    try payload.write(to: url)
    return url
}

private func cleanup(_ url: URL) {
    try? FileManager.default.removeItem(at: url)
}

private func makeRecord(
    id: String,
    mediaType: PhotoMediaType = .image,
    subtypes: PhotoMediaSubtypes = []
) -> PhotoAssetRecord {
    PhotoAssetRecord(
        localIdentifier: id,
        mediaType: mediaType,
        mediaSubtypes: subtypes,
        pixelWidth: 4032,
        pixelHeight: 3024,
        creationDate: Date(timeIntervalSince1970: 1_700_000_000),
        modificationDate: nil,
        duration: 0,
        isFavorite: false,
        isHidden: false,
        sourceType: [.library],
        hasAdjustments: false,
        representsBurst: false,
        burstIdentifier: nil
    )
}

private func photosError(_ code: PHPhotosError.Code) -> NSError {
    NSError(domain: PHPhotosErrorDomain, code: code.rawValue)
}

// MARK: - Fingerprinting behaviour

/// Tests for the live exact-duplicate path: the pure decision core (`resolveContent`) that says
/// what counts as complete, readable local content, the `PhotoContentError`/NSError mapping, and
/// the `ContentFingerprinting` outcome contract driven through an injected resolution — all
/// without a photo library.
struct PhotoKitContentFingerprinterTests {
    // MARK: Request options (the provenance + local-only policy)

    @Test func contentRequestOptionsAreLocalOnlyAndRenderEdits() {
        let options = PhotoKitContentFingerprinter.makeContentRequestOptions()
        #expect(options.isNetworkAccessAllowed == false)

        // Returning false for adjustment data is the whole visible-content provenance rule:
        // PhotoKit then hands us the *rendered* (edited) file instead of original + edits.
        let adjustment = PHAdjustmentData(
            formatIdentifier: "com.apple.photos",
            formatVersion: "1.0",
            data: Data([0x01])
        )
        #expect(options.canHandleAdjustmentData(adjustment) == false)
    }

    // MARK: resolveContent — the completeness decisions

    @Test func cancelledInfoThrowsCancellation() {
        let outcome = PhotoKitContentFingerprinter.resolveContent(
            info: [PHContentEditingInputCancelledKey: true],
            record: makeRecord(id: "photo-1"),
            imageURL: nil,
            videoURL: nil
        )
        #expect(throws: CancellationError.self) { try outcome.get() }
    }

    @Test func cloudOnlyInfoReportsContentOnlyInICloud() {
        let outcome = PhotoKitContentFingerprinter.resolveContent(
            info: [PHContentEditingInputResultIsInCloudKey: true],
            record: makeRecord(id: "photo-1"),
            imageURL: nil,
            videoURL: nil
        )
        #expect(throws: PhotoAnalysisUnavailableReason.contentOnlyInICloud) { try outcome.get() }
    }

    @Test func photoKitErrorInfoMapsToDistinguishableReasons() {
        func reason(_ error: any Error) -> any Error {
            let outcome = PhotoKitContentFingerprinter.resolveContent(
                info: [PHContentEditingInputErrorKey: error],
                record: makeRecord(id: "photo-1"),
                imageURL: nil,
                videoURL: nil
            )
            do {
                let content = try outcome.get()
                Issue.record("expected a failure, got a resolution: \(content)")
                return NSError(domain: "netto.tests", code: -1)
            } catch {
                return error
            }
        }

        #expect(
            reason(photosError(.accessUserDenied)) as? PhotoAnalysisUnavailableReason
                == .permissionUnavailable
        )
        #expect(
            reason(photosError(.identifierNotFound)) as? PhotoAnalysisUnavailableReason
                == .assetNotFound
        )
        #expect(
            reason(photosError(.networkAccessRequired)) as? PhotoAnalysisUnavailableReason
                == .contentOnlyInICloud
        )
        #expect(
            reason(photosError(.missingResource)) as? PhotoAnalysisUnavailableReason
                == .contentUnreadable
        )

        let foreign = NSError(domain: "com.example.foreign", code: 7)
        let foreignResult = reason(foreign)
        let bridged = foreignResult as NSError
        #expect(bridged.domain == "com.example.foreign")
        #expect(bridged.code == 7)
    }

    @Test func missingEverythingIsUnreadableNotUnique() {
        // The single most important honesty rule of exact detection: "could not read" must
        // never come back as a key (which would mean "unique") or as a fingerprint.
        let outcome = PhotoKitContentFingerprinter.resolveContent(
            info: [:],
            record: makeRecord(id: "photo-1"),
            imageURL: nil,
            videoURL: nil
        )
        #expect(throws: PhotoAnalysisUnavailableReason.contentUnreadable) { try outcome.get() }
    }

    @Test func livePhotoWithoutPairedVideoIsUnreadable() throws {
        let still = try temporaryFile(named: "live-still", bytes: 512)
        defer { cleanup(still) }

        let outcome = PhotoKitContentFingerprinter.resolveContent(
            info: [:],
            record: makeRecord(id: "live-1", subtypes: [.livePhoto]),
            imageURL: still,
            videoURL: nil
        )
        #expect(throws: PhotoAnalysisUnavailableReason.contentUnreadable) { try outcome.get() }
    }

    @Test func videoWithoutLocalURLIsUnreadable() {
        let outcome = PhotoKitContentFingerprinter.resolveContent(
            info: [:],
            record: makeRecord(id: "video-1", mediaType: .video),
            imageURL: nil,
            videoURL: nil
        )
        #expect(throws: PhotoAnalysisUnavailableReason.contentUnreadable) { try outcome.get() }
    }

    @Test func zeroByteFileIsUnreadable() throws {
        let empty = try temporaryFile(named: "empty", bytes: 0)
        defer { cleanup(empty) }

        let outcome = PhotoKitContentFingerprinter.resolveContent(
            info: [:],
            record: makeRecord(id: "photo-1"),
            imageURL: empty,
            videoURL: nil
        )
        #expect(throws: PhotoAnalysisUnavailableReason.contentUnreadable) { try outcome.get() }
    }

    @Test func plainImageResolvesWithExactByteCount() throws {
        let file = try temporaryFile(named: "plain", bytes: 4_096)
        defer { cleanup(file) }

        let outcome = PhotoKitContentFingerprinter.resolveContent(
            info: [:],
            record: makeRecord(id: "photo-1"),
            imageURL: file,
            videoURL: nil
        )
        let content = try outcome.get()
        #expect(content.image?.bytes == 4_096)
        #expect(content.video == nil)
        #expect(content.imageBytes == 4_096)
        #expect(content.videoBytes == 0)
    }

    @Test func livePhotoCountsBothResources() throws {
        let still = try temporaryFile(named: "lp-still", bytes: 2_048)
        let movie = try temporaryFile(named: "lp-movie", bytes: 8_192)
        defer {
            cleanup(still)
            cleanup(movie)
        }

        let outcome = PhotoKitContentFingerprinter.resolveContent(
            info: [:],
            record: makeRecord(id: "live-1", subtypes: [.livePhoto]),
            imageURL: still,
            videoURL: movie
        )
        let content = try outcome.get()
        #expect(content.imageBytes == 2_048)
        #expect(content.videoBytes == 8_192)
    }

    @Test func livePhotoIdentityRequiresBothComponents() throws {
        // Two Live Photos sharing a still but with different movies must not share a key —
        // a single-component match is exactly the false-duplicate this policy exists to stop.
        let sharedStill = try temporaryFile(named: "shared-still", bytes: 2_048)
        let movieA = try temporaryFile(named: "movie-a", bytes: 8_192)
        let movieB = try temporaryFile(named: "movie-b", bytes: 9_000)
        defer {
            cleanup(sharedStill)
            cleanup(movieA)
            cleanup(movieB)
        }

        let record = makeRecord(id: "live-1", subtypes: [.livePhoto])
        let first = try PhotoKitContentFingerprinter.resolveContent(
            info: [:], record: record, imageURL: sharedStill, videoURL: movieA
        ).get()
        let second = try PhotoKitContentFingerprinter.resolveContent(
            info: [:], record: record, imageURL: sharedStill, videoURL: movieB
        ).get()

        let firstKey = ContentByteKey(imageBytes: first.imageBytes, videoBytes: first.videoBytes)
        let secondKey = ContentByteKey(imageBytes: second.imageBytes, videoBytes: second.videoBytes)
        #expect(firstKey != secondKey)
    }

    // MARK: ContentFingerprinting outcomes through injected resolution

    @Test func identicalContentProducesIdenticalKeysAndFingerprints() async throws {
        let file = try temporaryFile(named: "dup", bytes: 3_000)
        defer { cleanup(file) }

        let fingerprinter = PhotoKitContentFingerprinter { _ in
            PhotoKitContentFingerprinter.ResolvedContent(
                image: (file, 3_000),
                video: nil
            )
        }

        let firstKey = try await fingerprinter.byteKey(for: makeRecord(id: "photo-a"))
        let secondKey = try await fingerprinter.byteKey(for: makeRecord(id: "photo-b"))
        #expect(firstKey == secondKey)
        #expect(
            firstKey == .key(ContentByteKey(imageBytes: 3_000, videoBytes: 0))
        )

        let firstPrint = try await fingerprinter.fingerprint(for: makeRecord(id: "photo-a"))
        let secondPrint = try await fingerprinter.fingerprint(for: makeRecord(id: "photo-b"))
        guard case .fingerprinted(let lhs) = firstPrint,
              case .fingerprinted(let rhs) = secondPrint else {
            Issue.record("expected both fingerprints")
            return
        }
        #expect(lhs == rhs)
        #expect(lhs.imageDigestHex != nil)
        #expect(lhs.videoDigestHex == nil)
    }

    @Test func differentContentProducesDifferentFingerprints() async throws {
        // The interesting case: two *different* files with identical lengths (so the phase-1
        // keys collide and phase 2 is the only thing that can tell them apart).
        let first = try temporaryFile(named: "a", bytes: 3_000)
        let second = try temporaryFile(named: "b", bytes: 3_000)
        defer {
            cleanup(first)
            cleanup(second)
        }

        let colliding = PhotoKitContentFingerprinter { record in
            let url = record.localIdentifier == "photo-a" ? first : second
            return PhotoKitContentFingerprinter.ResolvedContent(image: (url, 3_000), video: nil)
        }

        let keyA = try await colliding.byteKey(for: makeRecord(id: "photo-a"))
        let keyB = try await colliding.byteKey(for: makeRecord(id: "photo-b"))
        #expect(keyA == keyB) // lengths collide — the case phase 2 exists for

        let outcomeA = try await colliding.fingerprint(for: makeRecord(id: "photo-a"))
        let outcomeB = try await colliding.fingerprint(for: makeRecord(id: "photo-b"))
        guard case .fingerprinted(let printA) = outcomeA,
              case .fingerprinted(let printB) = outcomeB else {
            Issue.record("expected fingerprints for the colliding pair")
            return
        }
        #expect(printA != printB)
        #expect(printA.imageDigestHex != printB.imageDigestHex)
        #expect(printA.imageBytes == printB.imageBytes)
    }

    @Test func differentLengthsDifferAtTheKeyLevel() async throws {
        let first = try temporaryFile(named: "ka", bytes: 3_000)
        let second = try temporaryFile(named: "kb", bytes: 3_001)
        defer {
            cleanup(first)
            cleanup(second)
        }
        let fingerprinter = PhotoKitContentFingerprinter { record in
            let url = record.localIdentifier == "photo-a" ? first : second
            let size: Int64 = record.localIdentifier == "photo-a" ? 3_000 : 3_001
            return PhotoKitContentFingerprinter.ResolvedContent(image: (url, size), video: nil)
        }

        let keyA = try await fingerprinter.byteKey(for: makeRecord(id: "photo-a"))
        let keyB = try await fingerprinter.byteKey(for: makeRecord(id: "photo-b"))
        #expect(keyA != keyB)
    }

    @Test func largeContentStreamsToTheSameDigestAsDirectHashing() async throws {
        let file = try temporaryFile(named: "large", bytes: 400_000)
        defer { cleanup(file) }

        let fingerprinter = PhotoKitContentFingerprinter { _ in
            PhotoKitContentFingerprinter.ResolvedContent(image: (file, 400_000), video: nil)
        }

        let expected = try await ContentHasher.sha256Hex(ofFileAt: file)
        guard case .fingerprinted(let print) = try await fingerprinter.fingerprint(
            for: makeRecord(id: "photo-1")
        ) else {
            Issue.record("expected a fingerprint")
            return
        }
        #expect(print.imageDigestHex == expected)
        #expect(print.imageBytes == 400_000)
    }

    @Test func unreadableContentReportsUnavailableNotAUniqueKey() async throws {
        let fingerprinter = PhotoKitContentFingerprinter { _ in
            throw PhotoAnalysisUnavailableReason.contentUnreadable
        }

        // The distinction that matters: an asset we could not read must surface as
        // `.unavailable`, never as a `.key` (which would mean "unique, not a duplicate") and
        // never as a `.fingerprinted` result.
        let key = try await fingerprinter.byteKey(for: makeRecord(id: "photo-1"))
        #expect(key == .unavailable(.contentUnreadable))
        let print = try await fingerprinter.fingerprint(for: makeRecord(id: "photo-1"))
        #expect(print == .unavailable(.contentUnreadable))
    }

    @Test func permissionFailureFromResolutionMapsThrough() async throws {
        let fingerprinter = PhotoKitContentFingerprinter { _ in
            throw PhotoContentError.permissionDenied
        }
        let key = try await fingerprinter.byteKey(for: makeRecord(id: "photo-1"))
        #expect(key == .unavailable(.permissionUnavailable))

        let missing = PhotoKitContentFingerprinter { _ in
            throw PhotoContentError.assetNotFound
        }
        let print = try await missing.fingerprint(for: makeRecord(id: "photo-1"))
        #expect(print == .unavailable(.assetNotFound))
    }

    @Test func cancellationPropagatesRatherThanReportingUnavailability() async {
        let fingerprinter = PhotoKitContentFingerprinter { _ in
            try await Task.sleep(nanoseconds: 10_000_000_000)
            return PhotoKitContentFingerprinter.ResolvedContent(image: nil, video: nil)
        }

        let task = Task { () throws -> ContentLengthOutcome in
            withUnsafeCurrentTask { $0?.cancel() }
            return try await fingerprinter.byteKey(for: makeRecord(id: "photo-1"))
        }
        do {
            _ = try await task.value
            Issue.record("expected cancellation to propagate")
        } catch {
            #expect(error is CancellationError)
        }
    }
}

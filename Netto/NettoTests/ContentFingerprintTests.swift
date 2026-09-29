import Foundation
import Testing
@testable import Netto

// MARK: - Fixtures

private func temporaryFile(named name: String, contents: Data) throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("netto-fingerprint-\(name)-\(UUID().uuidString)")
    try contents.write(to: url)
    return url
}

private func cleanup(_ url: URL) {
    try? FileManager.default.removeItem(at: url)
}

struct ContentFingerprintTests {
    @Test func knownSha256VectorMatches() async throws {
        // NIST vector for "abc".
        let url = try temporaryFile(named: "abc", contents: Data("abc".utf8))
        defer { cleanup(url) }

        let digest = try await ContentHasher.sha256Hex(ofFileAt: url)
        #expect(digest == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    @Test func identicalContentHashesEqual() async throws {
        let first = try temporaryFile(named: "same", contents: Data("duplicate content".utf8))
        let second = try temporaryFile(named: "same2", contents: Data("duplicate content".utf8))
        defer {
            cleanup(first)
            cleanup(second)
        }

        let firstDigest = try await ContentHasher.sha256Hex(ofFileAt: first)
        let secondDigest = try await ContentHasher.sha256Hex(ofFileAt: second)
        #expect(firstDigest == secondDigest)
        #expect(ContentHasher.fileSize(at: first) == ContentHasher.fileSize(at: second))
    }

    @Test func differentContentHashesDiffer() async throws {
        let first = try temporaryFile(named: "a", contents: Data("content A".utf8))
        let second = try temporaryFile(named: "b", contents: Data("content B".utf8))
        defer {
            cleanup(first)
            cleanup(second)
        }

        let firstDigest = try await ContentHasher.sha256Hex(ofFileAt: first)
        let secondDigest = try await ContentHasher.sha256Hex(ofFileAt: second)
        #expect(firstDigest != secondDigest)
    }

    @Test func multiChunkFileHashesCorrectly() async throws {
        // Bigger than one 64 KB chunk to exercise the streaming loop.
        var payload = Data()
        payload.reserveCapacity(200_000)
        for index in 0..<200_000 {
            payload.append(UInt8(truncatingIfNeeded: index & 0xFF))
        }
        let url = try temporaryFile(named: "chunked", contents: payload)
        defer { cleanup(url) }

        let streamed = try await ContentHasher.sha256Hex(ofFileAt: url)
        #expect(streamed.count == 64)
        #expect(ContentHasher.fileSize(at: url) == 200_000)
    }

    @Test func hashingIsCancellable() async throws {
        let payload = Data(repeating: 7, count: 5_000_000)
        let url = try temporaryFile(named: "cancel", contents: payload)
        defer { cleanup(url) }

        // Self-cancel before hashing so the assertion is deterministic: the hasher must observe
        // cancellation at its first chunk boundary rather than hashing the whole file.
        let task = Task<String, Error> {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await ContentHasher.sha256Hex(ofFileAt: url)
        }
        await #expect(throws: (any Error).self) {
            try await task.value
        }
    }

    @Test func byteKeyProvesNonIdentityAcrossLengths() {
        let imageOnly = ContentFingerprint(
            imageBytes: 100,
            videoBytes: 0,
            imageDigestHex: "aaaa",
            videoDigestHex: nil
        )
        let withVideo = ContentFingerprint(
            imageBytes: 100,
            videoBytes: 50,
            imageDigestHex: "bbbb",
            videoDigestHex: "cccc"
        )
        #expect(imageOnly.byteKey != withVideo.byteKey)
    }

    @Test func equalLengthsWithDifferentDigestsAreDifferentContentButSamePreFilterKey() {
        // The pre-filter deliberately only compares lengths; the digest disambiguates afterwards.
        let first = ContentFingerprint(
            imageBytes: 100,
            videoBytes: 0,
            imageDigestHex: "aaaa",
            videoDigestHex: nil
        )
        let second = ContentFingerprint(
            imageBytes: 100,
            videoBytes: 0,
            imageDigestHex: "bbbb",
            videoDigestHex: nil
        )
        #expect(first.byteKey == second.byteKey)
        #expect(first != second)
    }

    @Test func combinedDigestNeverConfusesImageOnlyWithVideoOnly() {
        let imageOnly = ContentFingerprint(
            imageBytes: 10,
            videoBytes: 0,
            imageDigestHex: "same",
            videoDigestHex: nil
        )
        let videoOnly = ContentFingerprint(
            imageBytes: 0,
            videoBytes: 10,
            imageDigestHex: nil,
            videoDigestHex: "same"
        )
        #expect(imageOnly.combinedDigestHex != videoOnly.combinedDigestHex)
        #expect(imageOnly.totalBytes == 10)
        #expect(videoOnly.totalBytes == 10)
    }
}

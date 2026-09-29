import AVFoundation
import Foundation
import Photos
import Testing
@testable import Netto

// MARK: - Video preview: playback model lifecycle + loader result mapping
//
// The model owns the AVPlayer: created on open, released on close, and never installed by a
// stale (superseded) load. The loader seam is faked — no photo library, no playback — these
// tests prove state transitions, generation guarding, and resource release, not decoding.

@MainActor
struct VideoPreviewTests {
    // MARK: Model lifecycle

    @Test func openLoadsWithTheLoaderAndInstallsAPlayer() async {
        let loader = FakePreviewLoader(results: [
            "video-01": .success(URL(fileURLWithPath: "/tmp/netto-preview-01.mp4")),
        ])
        let model = VideoPreviewModel(loader: loader)

        model.open(assetID: "video-01")
        #expect(model.stage == .loading)
        await waitUntil { model.stage != .loading }

        #expect(model.stage == .ready)
        #expect(model.presentedAssetID == "video-01")
        #expect(model.player != nil)
        #expect(loader.requestedIDs == ["video-01"])
        assertPlayerURL(model.player, is: URL(fileURLWithPath: "/tmp/netto-preview-01.mp4"))
    }

    @Test func closeReleasesEveryPlaybackResource() async {
        let loader = FakePreviewLoader(results: [
            "video-01": .success(URL(fileURLWithPath: "/tmp/netto-preview-01.mp4")),
        ])
        let model = VideoPreviewModel(loader: loader)
        model.open(assetID: "video-01")
        await waitUntil { model.stage == .ready }
        #expect(model.player != nil)

        model.close()

        #expect(model.stage == .idle)
        #expect(model.player == nil) // paused, current item cleared, player dropped
        #expect(model.presentedAssetID == nil)
    }

    @Test func closeIsSafeBeforeAnyOpenAndRepeatedly() {
        let model = VideoPreviewModel(loader: FakePreviewLoader(results: [:]))
        model.close()
        model.close()
        #expect(model.stage == .idle)
        #expect(model.player == nil)
    }

    @Test func loaderFailureSurfacesAsUnavailableAndNeverInstallsAPlayer() async {
        let loader = FakePreviewLoader(results: [
            "video-02": .failure(PhotoContentError.onlyInICloud),
        ])
        let model = VideoPreviewModel(loader: loader)

        model.open(assetID: "video-02")
        await waitUntil { model.stage != .loading }

        #expect(model.stage == .unavailable(.onlyInICloud))
        #expect(model.player == nil)
    }

    @Test func unknownLoaderErrorsMapToUnavailable() async {
        let loader = FakePreviewLoader(results: [
            "video-03": .failure(SomeNestedError()),
        ])
        let model = VideoPreviewModel(loader: loader)

        model.open(assetID: "video-03")
        await waitUntil { model.stage != .loading }

        #expect(model.stage == .unavailable(.unavailable))
        #expect(model.player == nil)
    }

    // MARK: Generation guarding (stale loads can never win)

    @Test func aLateResponseForAPreviouslyOpenedVideoCannotOverwriteTheCurrentOne() async {
        let slowURL = URL(fileURLWithPath: "/tmp/netto-slow.mp4")
        let fastURL = URL(fileURLWithPath: "/tmp/netto-fast.mp4")
        let loader = FakePreviewLoader(results: [:])
        loader.hold("video-slow")
        let model = VideoPreviewModel(loader: loader)

        model.open(assetID: "video-slow") // never answers until released
        #expect(model.stage == .loading)
        model.open(assetID: "video-fast")
        loader.complete("video-fast", with: .success(fastURL))
        await waitUntil { model.stage == .ready }

        #expect(model.presentedAssetID == "video-fast")
        assertPlayerURL(model.player, is: fastURL)

        // The slow response lands *after* the fast one installed the player: discarded.
        loader.complete("video-slow", with: .success(slowURL))
        try? await Task.sleep(for: .milliseconds(50))

        #expect(model.presentedAssetID == "video-fast")
        #expect(model.stage == .ready)
        assertPlayerURL(model.player, is: fastURL)
    }

    @Test func aLateResponseAfterCloseIsDiscarded() async {
        let loader = FakePreviewLoader(results: [:])
        loader.hold("video-01")
        let model = VideoPreviewModel(loader: loader)

        model.open(assetID: "video-01")
        model.close()
        loader.complete("video-01", with: .success(URL(fileURLWithPath: "/tmp/netto-late.mp4")))
        try? await Task.sleep(for: .milliseconds(50))

        #expect(model.stage == .idle) // the late success must not resurrect the preview
        #expect(model.player == nil)
        #expect(model.presentedAssetID == nil)
    }

    @Test func aLateFailureAfterCloseIsDiscarded() async {
        let loader = FakePreviewLoader(results: [:])
        loader.hold("video-01")
        let model = VideoPreviewModel(loader: loader)

        model.open(assetID: "video-01")
        model.close()
        loader.complete("video-01", with: .failure(PhotoContentError.onlyInICloud))
        try? await Task.sleep(for: .milliseconds(50))

        #expect(model.stage == .idle)
        #expect(model.player == nil)
    }

    @Test func reopeningReplacesThePlayerInsteadOfStackingThem() async {
        let loader = FakePreviewLoader(results: [
            "a": .success(URL(fileURLWithPath: "/tmp/a.mp4")),
            "b": .success(URL(fileURLWithPath: "/tmp/b.mp4")),
        ])
        let model = VideoPreviewModel(loader: loader)

        model.open(assetID: "a")
        await waitUntil { model.stage == .ready }
        let firstPlayer = model.player

        model.open(assetID: "b")
        await waitUntil { model.presentedAssetID == "b" && model.stage == .ready }

        #expect(model.player !== firstPlayer)
        assertPlayerURL(model.player, is: URL(fileURLWithPath: "/tmp/b.mp4"))
    }

    // MARK: Loader result mapping (pure — no photo library)

    @Test func videoRequestOptionsAreLocalOnlyAndCurrent() {
        let options = PhotoKitVideoPreviewLoader.makeVideoRequestOptions()
        #expect(options.isNetworkAccessAllowed == false)
        #expect(options.version == .current)
        #expect(options.deliveryMode == .highQualityFormat)
    }

    @Test func resultMapsCancellationCloudAndErrors() {
        let cancelled = PhotoKitVideoPreviewLoader.result(
            avAsset: nil,
            info: [PHImageCancelledKey: true]
        )
        #expect(failure(of: cancelled) is CancellationError)

        let inCloud = PhotoKitVideoPreviewLoader.result(
            avAsset: nil,
            info: [PHImageResultIsInCloudKey: true]
        )
        #expect(failure(of: inCloud) as? PhotoContentError == .onlyInICloud)

        let photosError = NSError(
            domain: PHPhotosErrorDomain,
            code: PHPhotosError.Code.identifierNotFound.rawValue
        )
        let missing = PhotoKitVideoPreviewLoader.result(
            avAsset: nil,
            info: [PHImageErrorKey: photosError]
        )
        #expect(failure(of: missing) as? PhotoContentError == .assetNotFound)
    }

    @Test func resultRequiresAFileBackedAsset() {
        let nothing = PhotoKitVideoPreviewLoader.result(avAsset: nil, info: nil)
        #expect(failure(of: nothing) as? PhotoContentError == .unavailable)

        let url = URL(fileURLWithPath: "/tmp/netto-fixture.mp4")
        let fileBacked = PhotoKitVideoPreviewLoader.result(
            avAsset: AVURLAsset(url: url),
            info: nil
        )
        guard case .success(let resolved) = fileBacked else {
            Issue.record("expected a file-backed asset to resolve, got \(fileBacked)")
            return
        }
        #expect(resolved == url)
    }

    @Test func loaderSeamIsInvokedThroughTheRequestClosure() async throws {
        let expected = URL(fileURLWithPath: "/tmp/via-seam.mp4")
        let loader = PhotoKitVideoPreviewLoader { id in
            #expect(id == "seam-id")
            return expected
        }
        #expect(try await loader.playbackURL(for: "seam-id") == expected)
    }
}

// MARK: - Test doubles

private struct SomeNestedError: Error {}

private func failure(
    of result: Result<URL, any Error>,
    sourceLocation: SourceLocation = #_sourceLocation
) -> (any Error)? {
    switch result {
    case .failure(let error):
        return error
    case .success:
        Issue.record("expected a failure, got success", sourceLocation: sourceLocation)
        return nil
    }
}

/// Scripted preview loader: results per id, with per-id holds so tests can land responses
/// out of order and prove the generation guard discards stale ones.
private final class FakePreviewLoader: VideoPreviewLoading, @unchecked Sendable {
    private let lock = NSLock()
    private var results: [String: Result<URL, any Error>]
    private var held: Set<String> = []
    private var completions: [String: [CheckedContinuation<URL, any Error>]] = [:]
    private var recordedIDs: [String] = []

    init(results: [String: Result<URL, any Error>]) {
        self.results = results
    }

    /// Makes `id`'s next `playbackURL` suspend until `complete(id:with:)` is called.
    func hold(_ id: String) {
        lock.lock()
        held.insert(id)
        lock.unlock()
    }

    func complete(_ id: String, with result: Result<URL, any Error>) {
        lock.lock()
        results[id] = result
        held.remove(id)
        let waiting = completions[id] ?? []
        completions[id] = []
        lock.unlock()
        for continuation in waiting {
            continuation.resume(with: result)
        }
    }

    func playbackURL(for assetID: String) async throws -> URL {
        // NSLock is unavailable in async contexts, so every locked section is synchronous.
        switch nextDecision(for: assetID) {
        case .answer(let scripted):
            return try scripted.get()
        case .unknown:
            throw PhotoContentError.assetNotFound
        case .wait:
            return try await withCheckedThrowingContinuation { continuation in
                park(continuation, for: assetID)
            }
        }
    }

    private enum Decision {
        case answer(Result<URL, any Error>)
        case unknown
        case wait
    }

    private func nextDecision(for assetID: String) -> Decision {
        lock.lock()
        defer { lock.unlock() }
        recordedIDs.append(assetID)
        if let scripted = results[assetID], !held.contains(assetID) {
            return .answer(scripted)
        }
        return held.contains(assetID) ? .wait : .unknown
    }

    /// Re-checks under the lock so a completion that lands between the decision above and
    /// this closure can never strand the continuation.
    private func park(_ continuation: CheckedContinuation<URL, any Error>, for assetID: String) {
        lock.lock()
        if let scripted = results[assetID] {
            lock.unlock()
            continuation.resume(with: scripted)
        } else {
            completions[assetID, default: []].append(continuation)
            lock.unlock()
        }
    }

    var requestedIDs: [String] {
        lock.lock()
        defer { lock.unlock() }
        return recordedIDs
    }
}

// MARK: - Helpers

@MainActor
private func waitUntil(
    timeoutMilliseconds: Int = 3_000,
    _ condition: () -> Bool
) async {
    let deadline = ContinuousClock.now.advanced(by: .milliseconds(timeoutMilliseconds))
    while !condition(), ContinuousClock.now < deadline {
        try? await Task.sleep(for: .milliseconds(5))
    }
}

@MainActor
private func assertPlayerURL(_ player: AVPlayer?, is expected: URL) {
    guard let player else {
        Issue.record("expected a player")
        return
    }
    guard let urlAsset = player.currentItem?.asset as? AVURLAsset else {
        Issue.record("expected the player's item to be a file-backed AVURLAsset")
        return
    }
    #expect(urlAsset.url == expected)
}

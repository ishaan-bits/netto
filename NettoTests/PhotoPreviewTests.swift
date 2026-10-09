import CoreGraphics
import Foundation
import Photos
import Testing
import UIKit
@testable import Netto

// MARK: - Photo Details preview: loader policy + preview model lifecycle
//
// The model owns the large preview bitmap: requested on open, released on close, and never
// resurrected by a late frame for a superseded screen. The loader seam is faked — no photo
// library, no network — these tests prove state transitions, generation guarding, target-size
// selection, and the read-only guarantee (selection and analysis are never touched), not
// decoding. The option/outcome tests pin the *policy split*: the preview may use the network,
// the analysis passes may not.

@MainActor
struct PhotoPreviewTests {
    // MARK: Request policy (pure — no photo library)

    @Test func previewOptionsAllowTheNetworkAndDeliverInterimFrames() {
        let options = PhotoKitThumbnailLoader.makePreviewRequestOptions()
        // The one network-enabled request in the app: an explicitly opened Photo Details
        // preview may download its iCloud rendition. Nothing else calls this factory.
        #expect(options.isNetworkAccessAllowed == true)
        // Opportunistic → degraded frame first, final render second; `previewOutcome` routes
        // the first to the interim channel instead of settling.
        #expect(options.deliveryMode == .opportunistic)
        #expect(options.resizeMode == .exact)
        #expect(options.version == .current)
        #expect(options.isSynchronous == false)
    }

    @Test func analysisOptionsRemainLocalOnly() {
        // Scanner safety: this milestone must not change analysis policy — every analysis
        // pass (perceptual, verification, sharpness) keeps the local-only, single-callback
        // settings regardless of the preview exception.
        for mode in [PhotoThumbnailRequestMode.perceptual, .verification, .sharpness] {
            let options = PhotoKitThumbnailLoader.makeImageRequestOptions(mode: mode)
            #expect(options.isNetworkAccessAllowed == false)
            #expect(options.deliveryMode == .highQualityFormat)
        }
    }

    @Test func previewBudgetSitsBetweenOneAndFifteenHundredPixels() {
        let budget = SimilarPhotosPresentation.previewTargetPixelSize
        #expect((1_000...1_500).contains(budget))
    }

    @Test func degradedCallbacksAreInterimNeverTerminal() {
        let degradedWithoutPixels = PhotoKitThumbnailLoader.previewOutcome(
            image: nil,
            info: [PHImageResultIsDegradedKey: true]
        )
        guard case .interim = degradedWithoutPixels else {
            Issue.record("a degraded frame must keep the request waiting, got \(degradedWithoutPixels)")
            return
        }

        // Even a cloud-flagged degraded callback is progress, not a failure: the final
        // callback is what classifies the asset.
        let degradedInCloud = PhotoKitThumbnailLoader.previewOutcome(
            image: nil,
            info: [PHImageResultIsDegradedKey: true, PHImageResultIsInCloudKey: true]
        )
        guard case .interim = degradedInCloud else {
            Issue.record("a degraded iCloud frame must keep the request waiting, got \(degradedInCloud)")
            return
        }
    }

    @Test func terminalCallbacksClassifyCancellationCloudAndMissing() {
        let cancelled = PhotoKitThumbnailLoader.previewOutcome(
            image: nil,
            info: [PHImageCancelledKey: true, PHImageResultIsDegradedKey: true]
        )
        #expect(terminalFailure(cancelled) is CancellationError)

        let photosError = NSError(
            domain: PHPhotosErrorDomain,
            code: PHPhotosError.Code.identifierNotFound.rawValue
        )
        let missing = PhotoKitThumbnailLoader.previewOutcome(
            image: nil,
            info: [PHImageErrorKey: photosError]
        )
        #expect(terminalFailure(missing) as? PhotoContentError == .assetNotFound)

        let finalInCloud = PhotoKitThumbnailLoader.previewOutcome(
            image: nil,
            info: [PHImageResultIsInCloudKey: true]
        )
        #expect(terminalFailure(finalInCloud) as? PhotoContentError == .onlyInICloud)

        let finalWithoutPixels = PhotoKitThumbnailLoader.previewOutcome(image: nil, info: nil)
        #expect(terminalFailure(finalWithoutPixels) as? PhotoContentError == .unavailable)
    }

    @Test func finalFrameWithPixelsIsAcceptedEvenWhenICloudFlagged() {
        // The bug this pins: a delivered final image carrying `PHImageResultIsInCloudKey`
        // must settle as success — the pixels are present, so failing with onlyInICloud
        // blanked a working preview with "Photo unavailable".
        let pixels = UIImage(cgImage: solidImage(width: 6, height: 4, level: 200))
        let outcome = PhotoKitThumbnailLoader.previewOutcome(
            image: pixels,
            info: [PHImageResultIsInCloudKey: true]
        )
        guard case .terminal(let result) = outcome else {
            Issue.record("expected a terminal outcome, got \(outcome)")
            return
        }
        guard case .success(let frame) = result else {
            Issue.record("expected success, got \(result)")
            return
        }
        #expect(frame.width == 6)
        #expect(frame.height == 4)
    }

    @Test func degradedFramesWithPixelsStayInterim() {
        // Opportunistic delivery hands back a low-resolution frame first — pixels or not,
        // a degraded callback is progress, so the interim channel must win over the
        // accept-the-pixels rule.
        let pixels = UIImage(cgImage: solidImage(width: 3, height: 3, level: 64))
        let outcome = PhotoKitThumbnailLoader.previewOutcome(
            image: pixels,
            info: [PHImageResultIsDegradedKey: true, PHImageResultIsInCloudKey: true]
        )
        guard case .interim = outcome else {
            Issue.record("expected interim, got \(outcome)")
            return
        }
    }

    @Test func previewSeamForwardsIDSizeAndInterimFrames() async throws {
        let final = solidImage(width: 4, height: 4)
        let interim = solidImage(width: 3, height: 3, level: 64)
        let idBox = Box<String?>(nil)
        let sizeBox = Box<Int?>(nil)
        let interimBox = Box<CGImage?>(nil)

        let loader = PhotoKitThumbnailLoader(previewRequest: { assetID, targetPixelSize, onInterim in
            idBox.write(assetID)
            sizeBox.write(targetPixelSize)
            onInterim(interim)
            return final
        })

        let received = try await loader.previewImage(for: "photo-9", targetPixelSize: 1_400) {
            interimBox.write($0)
        }

        #expect(idBox.read() == "photo-9")
        #expect(sizeBox.read() == 1_400)
        #expect(interimBox.read() === interim)
        #expect(received === final)
    }

    // MARK: Automatic recovery (primary → local-rendition fallback)

    @Test func aFailedPrimaryFallsBackAndReturnsLocalPixels() async throws {
        let primaryBox = Box<Int>(0)
        let fallbackBox = Box<Int>(0)
        let local = solidImage(width: 5, height: 5, level: 90)
        let loader = PhotoKitThumbnailLoader(
            previewRequest: { _, _, _ in
                primaryBox.write(primaryBox.read() + 1)
                throw PhotoContentError.onlyInICloud
            },
            fallbackRequest: { _, _ in
                fallbackBox.write(fallbackBox.read() + 1)
                return local
            }
        )

        let received = try await loader.previewImage(for: "photo-7", targetPixelSize: 1_400) { _ in }

        #expect(primaryBox.read() == 1)
        #expect(fallbackBox.read() == 1)
        #expect(received === local)
    }

    @Test func aPersistentlyFailingPreviewSurfacesThePrimaryError() async {
        let fallbackBox = Box<Int>(0)
        let loader = PhotoKitThumbnailLoader(
            previewRequest: { _, _, _ in throw PhotoContentError.onlyInICloud },
            fallbackRequest: { _, _ in
                fallbackBox.write(fallbackBox.read() + 1)
                throw PhotoContentError.unavailable
            }
        )

        // The primary reason ("only in iCloud") explains the screen better than the ladder's
        // last miss, so it — not the fallback's error — is what reaches the user.
        await #expect(throws: PhotoContentError.onlyInICloud) {
            _ = try await loader.previewImage(for: "photo-8", targetPixelSize: 1_400) { _ in }
        }
        #expect(fallbackBox.read() == 1)
    }

    @Test func aCancelledPreviewIsNeverRetried() async {
        let fallbackBox = Box<Int>(0)
        let loader = PhotoKitThumbnailLoader(
            previewRequest: { _, _, _ in throw CancellationError() },
            fallbackRequest: { _, _ in
                fallbackBox.write(fallbackBox.read() + 1)
                return solidImage(width: 2, height: 2)
            }
        )

        await #expect(throws: CancellationError.self) {
            _ = try await loader.previewImage(for: "photo-10", targetPixelSize: 1_400) { _ in }
        }
        #expect(fallbackBox.read() == 0)
    }

    @Test func permanentFailuresSkipTheFallback() async {
        for permanent in [PhotoContentError.permissionDenied, .assetNotFound] {
            let fallbackBox = Box<Int>(0)
            let loader = PhotoKitThumbnailLoader(
                previewRequest: { _, _, _ in throw permanent },
                fallbackRequest: { _, _ in
                    fallbackBox.write(fallbackBox.read() + 1)
                    return solidImage(width: 2, height: 2)
                }
            )
            await #expect(throws: permanent) {
                _ = try await loader.previewImage(for: "photo-11", targetPixelSize: 1_400) { _ in }
            }
            #expect(fallbackBox.read() == 0)
        }
    }

    @Test func fallbackLadderWalksLargestFirstAndStopsAtTheFirstSuccess() async throws {
        let attempted = Box<[Int]>([])
        let local = solidImage(width: 4, height: 4)
        let image = try await PhotoKitThumbnailLoader.previewFallbackLadder(targetPixelSize: 1_400) { size in
            attempted.write(attempted.read() + [size])
            if size >= 512 { throw PhotoContentError.unavailable }
            return local
        }

        #expect(attempted.read() == [768, 512, 384])
        #expect(image === local)
    }

    @Test func fallbackLadderSkipsSizesThePrimaryRequestAlreadyCovered() async throws {
        let attempted = Box<[Int]>([])
        _ = try await PhotoKitThumbnailLoader.previewFallbackLadder(targetPixelSize: 300) { size in
            attempted.write(attempted.read() + [size])
            return solidImage(width: 2, height: 2)
        }
        #expect(attempted.read() == [256])
    }

    @Test func fallbackLadderNeverSwallowsCancellation() async {
        await #expect(throws: CancellationError.self) {
            _ = try await PhotoKitThumbnailLoader.previewFallbackLadder(targetPixelSize: 1_400) { _ in
                throw CancellationError()
            }
        }
    }

    @Test func fallbackPolicyKeepsTheScannerAndCopyContracts() {
        let sizes = PhotoKitThumbnailLoader.previewFallbackPixelSizes
        #expect(sizes == sizes.sorted(by: >))
        #expect(Set(sizes).count == sizes.count)
        #expect(sizes.last == 256)
        #expect(sizes.allSatisfy { $0 < SimilarPhotosPresentation.previewTargetPixelSize })

        // The ladder keeps the preview's network exception; the scanner policy is untouched.
        let fallback = PhotoKitThumbnailLoader.makePreviewFallbackRequestOptions()
        #expect(fallback.isNetworkAccessAllowed == true)
        #expect(fallback.deliveryMode == .highQualityFormat)
        #expect(fallback.version == .current)
        #expect(PhotoKitThumbnailLoader.makeImageRequestOptions().isNetworkAccessAllowed == false)

        // Cloud-download failures read as iCloud on the preview path only.
        let cloudDownload = NSError(domain: "CloudPhotoLibraryErrorDomain", code: 1006)
        #expect(PhotoKitThumbnailLoader.mapPreviewError(cloudDownload) as? PhotoContentError == .onlyInICloud)
        #expect(PhotoKitThumbnailLoader.mapPreviewError(PhotoContentError.unavailable) as? PhotoContentError == .unavailable)
    }

    // MARK: Model lifecycle

    @Test func openMovesFromLoadingToReadyWithTheFinalFrame() async {
        let final = solidImage(width: 4, height: 4)
        let loader = FakePreviewImageLoader(results: ["photo-01": [.success(final)]])
        let model = PhotoPreviewModel()

        model.open(assetID: "photo-01", using: loader)
        #expect(model.stage == .loading)
        #expect(model.image == nil)
        await waitUntil { model.stage != .loading }

        #expect(model.stage == .ready)
        #expect(model.image === final)
        #expect(model.presentedAssetID == "photo-01")
        // Appropriate target size: the model asked for the large preview budget, not a strip
        // size and not full resolution.
        #expect(loader.requestedSizes == [SimilarPhotosPresentation.previewTargetPixelSize])
        #expect(loader.requestedIDs == ["photo-01"])
    }

    @Test func interimFramesShowWhileLoadingWithoutSettlingTheStage() async {
        let interim = solidImage(width: 3, height: 3, level: 64)
        let final = solidImage(width: 5, height: 5)
        let loader = FakePreviewImageLoader(results: [:])
        loader.queueInterim(interim, for: "photo-02")
        loader.hold("photo-02")
        let model = PhotoPreviewModel()

        model.open(assetID: "photo-02", using: loader)
        await waitUntil { model.image != nil }

        // The degraded frame is visible but has not settled the load — the final render is
        // still what the request is waiting for.
        #expect(model.image === interim)
        #expect(model.stage == .loading)

        loader.complete("photo-02", with: .success(final))
        await waitUntil { model.stage == .ready }
        #expect(model.image === final)
    }

    @Test func failureWithoutAFinalFrameSurfacesItsSpecificReason() async {
        let loader = FakePreviewImageLoader(results: [
            "photo-03": [.failure(PhotoContentError.onlyInICloud)],
        ])
        let model = PhotoPreviewModel()

        model.open(assetID: "photo-03", using: loader)
        await waitUntil { model.stage != .loading }

        #expect(model.stage == .unavailable(.onlyInICloud))
        #expect(model.image == nil)
        #expect(model.presentedAssetID == "photo-03")
    }

    @Test func failureAfterAnInterimFrameKeepsTheUsablePixels() async {
        let interim = solidImage(width: 3, height: 3, level: 96)
        let loader = FakePreviewImageLoader(results: [:])
        loader.queueInterim(interim, for: "photo-04")
        loader.hold("photo-04")
        let model = PhotoPreviewModel()

        model.open(assetID: "photo-04", using: loader)
        await waitUntil { model.image != nil }
        loader.complete("photo-04", with: .failure(PhotoContentError.unavailable))
        await waitUntil { model.stage != .loading }

        // Pixels the user can already inspect win over an error page for the same asset.
        #expect(model.stage == .ready)
        #expect(model.image === interim)
    }

    @Test func closeCancelsTheLoadAndReleasesTheLargeImage() async {
        let final = solidImage(width: 6, height: 6)
        let loader = FakePreviewImageLoader(results: [:])
        loader.hold("photo-05")
        let model = PhotoPreviewModel()

        model.open(assetID: "photo-05", using: loader)
        #expect(model.stage == .loading)
        model.close()

        #expect(model.stage == .idle)
        #expect(model.image == nil)
        #expect(model.presentedAssetID == nil)
        #expect(model.isFullScreenPresented == false)

        // A frame that lands after close must not resurrect the preview.
        loader.complete("photo-05", with: .success(final))
        try? await Task.sleep(for: .milliseconds(60))
        #expect(model.stage == .idle)
        #expect(model.image == nil)
    }

    @Test func retryAfterFailureIssuesAFreshUncachedLoad() async {
        let final = solidImage(width: 4, height: 4)
        let loader = FakePreviewImageLoader(results: [
            "photo-06": [.failure(PhotoContentError.unavailable), .success(final)],
        ])
        let model = PhotoPreviewModel()

        model.open(assetID: "photo-06", using: loader)
        await waitUntil { model.stage != .loading }
        #expect(model.stage == .unavailable(.unavailable))

        model.retry()
        #expect(model.stage == .loading)
        await waitUntil { model.stage != .loading }

        // Two distinct requests for one asset — a failure is never a terminal, cached state.
        #expect(model.stage == .ready)
        #expect(model.image === final)
        #expect(loader.requestedIDs == ["photo-06", "photo-06"])
    }

    // MARK: Selection & scanner safety (read-only guarantees)

    @Test func openingAndClosingThePreviewPreservesTheSelection() async {
        let env = AppEnvironment(scanSnapshotStore: InMemoryScanSnapshotStore())
        // `toggle` only acts on members of known groups — build a real group first so the
        // selection being preserved is a selection that actually changed.
        env.selection = selectionFixture(members: ["asset-a", "asset-b"], recommended: "asset-a")
        env.mutateSelection {
            $0.toggle("asset-a") // recommended protectee → marked
            $0.toggle("asset-b") // default selection → cleared
        }
        let before = env.selection
        #expect(env.selection.isSelected("asset-a"))
        #expect(env.selection.isSelected("asset-b") == false)

        let loader = FakePreviewImageLoader(results: ["asset-a": [.success(solidImage(width: 4, height: 4))]])
        let model = PhotoPreviewModel()
        model.open(assetID: "asset-a", using: loader)
        await waitUntil { model.stage == .ready }
        model.close()

        #expect(env.selection == before)
        #expect(env.selection.isSelected("asset-a"))
        #expect(env.selection.isSelected("asset-b") == false)
    }

    @Test func presentingFullScreenDoesNotMutateTheSelection() async {
        let env = AppEnvironment(scanSnapshotStore: InMemoryScanSnapshotStore())
        env.selection = selectionFixture(members: ["asset-c"], recommended: "asset-c")
        env.mutateSelection { $0.toggle("asset-c") }
        let before = env.selection
        #expect(env.selection.isSelected("asset-c"))

        let loader = FakePreviewImageLoader(results: ["asset-c": [.success(solidImage(width: 4, height: 4))]])
        let model = PhotoPreviewModel()
        model.open(assetID: "asset-c", using: loader)
        await waitUntil { model.stage == .ready }

        model.setFullScreen(true)
        #expect(model.isFullScreenPresented)
        model.setFullScreen(false)
        #expect(model.isFullScreenPresented == false)

        #expect(env.selection == before)
        #expect(env.selection.isSelected("asset-c"))
    }

    @Test func openingPhotoDetailsNeverStartsAScan() async {
        let env = AppEnvironment(scanSnapshotStore: InMemoryScanSnapshotStore())
        env.photoPermissionState = .authorized
        // A resting analysis state: if opening the preview invoked the scanner in any way,
        // this would move (or at minimum report itself as running).
        env.analysisState = .cancelled
        let analysisBefore = env.analysisState

        let loader = FakePreviewImageLoader(results: ["asset-d": [.success(solidImage(width: 4, height: 4))]])
        let model = PhotoPreviewModel()
        model.open(assetID: "asset-d", using: loader)
        await waitUntil { model.stage == .ready }
        model.setFullScreen(true)
        model.setFullScreen(false)
        model.close()

        #expect(env.analysisState == analysisBefore)
        #expect(env.analysisState.isRunning == false)
    }

    // MARK: Copy (pure)

    @Test func previewMessagesDistinguishICloudPermissionAndMissing() {
        let iCloud = SimilarPhotosPresentation.previewUnavailableMessage(for: .onlyInICloud)
        let permission = SimilarPhotosPresentation.previewUnavailableMessage(for: .permissionDenied)
        let missing = SimilarPhotosPresentation.previewUnavailableMessage(for: .assetNotFound)
        let generic = SimilarPhotosPresentation.previewUnavailableMessage(for: .unavailable)

        #expect(iCloud.contains("iCloud"))
        #expect(permission.contains("Settings"))
        #expect(missing.contains("no longer in your library"))
        #expect(generic.contains("couldn't load this photo"))
        // Every state reads as its own problem, not one shared blob of text.
        #expect(Set([iCloud, permission, missing, generic]).count == 4)

        #expect(SimilarPhotosPresentation.previewUnavailableTitle == "Photo unavailable")
        #expect(SimilarPhotosPresentation.previewLoadingMessage == "Loading photo…")
        #expect(SimilarPhotosPresentation.previewFailureSymbol(for: .onlyInICloud) == "icloud.and.arrow.down")
    }
}

// MARK: - Test doubles

/// Scripted preview loader: FIFO outcomes per id, optional interim frames emitted before the
/// final result, and per-id holds so tests can land responses in a chosen order.
private final class FakePreviewImageLoader: PhotoThumbnailLoading, @unchecked Sendable {
    private let lock = NSLock()
    private var results: [String: [Result<CGImage, any Error>]]
    private var interims: [String: [CGImage]] = [:]
    private var held: Set<String> = []
    private var completions: [String: [CheckedContinuation<CGImage, any Error>]] = [:]
    private var recordedIDs: [String] = []
    private var recordedSizes: [Int] = []

    init(results: [String: [Result<CGImage, any Error>]]) {
        self.results = results
    }

    /// Frames delivered through `onInterim` at the start of the next request for `assetID`.
    func queueInterim(_ frame: CGImage, for assetID: String) {
        lock.lock()
        interims[assetID, default: []].append(frame)
        lock.unlock()
    }

    /// Makes the next request for `assetID` suspend until `complete(assetID:with:)`.
    func hold(_ assetID: String) {
        lock.lock()
        held.insert(assetID)
        lock.unlock()
    }

    func complete(_ assetID: String, with result: Result<CGImage, any Error>) {
        lock.lock()
        held.remove(assetID)
        let waiting = completions[assetID] ?? []
        completions[assetID] = []
        lock.unlock()
        for continuation in waiting {
            continuation.resume(with: result)
        }
    }

    func previewImage(
        for assetID: String,
        targetPixelSize: Int,
        onInterim: @escaping @Sendable (CGImage) -> Void
    ) async throws -> CGImage {
        for frame in beginRequest(assetID: assetID, targetPixelSize: targetPixelSize) {
            onInterim(frame)
        }
        return try await awaitFinal(assetID)
    }

    func thumbnail(
        for assetID: String,
        targetPixelSize: Int,
        mode: PhotoThumbnailRequestMode
    ) async throws -> CGImage {
        _ = beginRequest(assetID: assetID, targetPixelSize: targetPixelSize)
        return try await awaitFinal(assetID)
    }

    var requestedIDs: [String] {
        lock.lock()
        defer { lock.unlock() }
        return recordedIDs
    }

    var requestedSizes: [Int] {
        lock.lock()
        defer { lock.unlock() }
        return recordedSizes
    }

    /// Records the request and takes its queued interim frames (one shot).
    private func beginRequest(assetID: String, targetPixelSize: Int) -> [CGImage] {
        lock.lock()
        defer { lock.unlock() }
        recordedIDs.append(assetID)
        recordedSizes.append(targetPixelSize)
        let frames = interims[assetID] ?? []
        interims[assetID] = nil
        return frames
    }

    private func awaitFinal(_ assetID: String) async throws -> CGImage {
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
        case answer(Result<CGImage, any Error>)
        case unknown
        case wait
    }

    private func nextDecision(for assetID: String) -> Decision {
        lock.lock()
        defer { lock.unlock() }
        if held.contains(assetID) {
            return .wait
        }
        if var queue = results[assetID], !queue.isEmpty {
            let first = queue.removeFirst()
            results[assetID] = queue
            return .answer(first)
        }
        return .unknown
    }

    /// Re-checks under the lock so a completion that lands between the decision above and
    /// this closure can never strand the continuation.
    private func park(_ continuation: CheckedContinuation<CGImage, any Error>, for assetID: String) {
        lock.lock()
        if var queue = results[assetID], !queue.isEmpty {
            let first = queue.removeFirst()
            results[assetID] = queue
            lock.unlock()
            continuation.resume(with: first)
        } else if !held.contains(assetID) {
            lock.unlock()
            continuation.resume(throwing: PhotoContentError.assetNotFound)
        } else {
            completions[assetID, default: []].append(continuation)
            lock.unlock()
        }
    }
}

// MARK: - Helpers

/// A two-or-fewer-member group so the selection model has real membership to act on —
/// `PhotoSelectionModel` deliberately ignores toggles for assets outside any group.
private func selectionFixture(members: [String], recommended: String) -> PhotoSelectionModel {
    PhotoSelectionModel(groups: [
        PhotoSimilarityGroup(
            kind: .nearDuplicates,
            memberAssetIDs: members,
            evidence: .visualSimilarity(minDistance: 0.1, maxDistance: 0.4, threshold: 0.6),
            recommendedBestAssetID: recommended,
            memberScores: [:]
        ),
    ])
}

private func solidImage(width: Int, height: Int, level: Int = 128) -> CGImage {
    let clamped = UInt8(max(0, min(255, level)))
    var buffer = [UInt8](repeating: 255, count: width * height * 4)
    for index in stride(from: 0, to: buffer.count, by: 4) {
        buffer[index] = clamped
        buffer[index + 1] = clamped
        buffer[index + 2] = clamped
    }
    let provider = CGDataProvider(data: Data(buffer) as CFData)!
    return CGImage(
        width: width,
        height: height,
        bitsPerComponent: 8,
        bitsPerPixel: 32,
        bytesPerRow: width * 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
        provider: provider,
        decode: nil,
        shouldInterpolate: false,
        intent: .defaultIntent
    )!
}

private final class Box<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    init(_ value: Value) {
        self.value = value
    }

    func read() -> Value {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func write(_ newValue: Value) {
        lock.lock()
        value = newValue
        lock.unlock()
    }
}

private func terminalFailure(
    _ outcome: PhotoKitThumbnailLoader.PreviewOutcome,
    sourceLocation: SourceLocation = #_sourceLocation
) -> (any Error)? {
    switch outcome {
    case .interim:
        Issue.record("expected a terminal outcome, got interim", sourceLocation: sourceLocation)
        return nil
    case .terminal(let result):
        switch result {
        case .failure(let error):
            return error
        case .success:
            Issue.record("expected a failure, got success", sourceLocation: sourceLocation)
            return nil
        }
    }
}

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

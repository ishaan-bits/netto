import CoreGraphics
import Foundation
import Photos
import Testing
import UIKit
@testable import Netto

// MARK: - Fixtures

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

private func photosError(_ code: PHPhotosError.Code) -> NSError {
    NSError(domain: PHPhotosErrorDomain, code: code.rawValue)
}

// MARK: - Loader behaviour

/// Tests for the live thumbnail loader's *logic*: option policy, PhotoKit callback mapping,
/// orientation baking, permission/asset-error classification, and the success/failure/
/// cancellation behaviour of the request seam. Nothing here touches a user photo library —
/// the live request is exercised only through `fetchAsset`'s documented no-access outcome.
struct PhotoKitThumbnailLoaderTests {
    // MARK: Request options (the iCloud / quality policy)

    @Test func requestOptionsAreBoundedCurrentAndSingleShot() {
        // Milestone 4C policy change: analysis thumbnails now *may* fetch their iCloud
        // rendition (bounded by the request failsafe) instead of failing every cloud asset
        // up front; the local-only policy lives on the content-fingerprint path. Both modes
        // share the bounded single-callback settings and differ only in resize quality.
        let options = PhotoKitThumbnailLoader.makeImageRequestOptions()
        #expect(options.isNetworkAccessAllowed == false)
        #expect(options.deliveryMode == .highQualityFormat)
        #expect(options.resizeMode == .exact)
        #expect(options.version == .current)
        #expect(options.isSynchronous == false)
    }

    @Test func perceptualModeTradesExactnessForSpeed() {
        let perceptual = PhotoKitThumbnailLoader.makeImageRequestOptions(mode: .perceptual)
        #expect(perceptual.isNetworkAccessAllowed == false)
        #expect(perceptual.resizeMode == .fast)
        #expect(perceptual.deliveryMode == .highQualityFormat)

        let verification = PhotoKitThumbnailLoader.makeImageRequestOptions(mode: .verification)
        #expect(verification.isNetworkAccessAllowed == false)
        #expect(verification.resizeMode == .exact)
    }

    @Test func requestModeIsForwardedToTheSeam() async throws {
        // The engine's cheap-first distinction must survive the seam: `.perceptual` (96 px
        // gate) and `.verification` (256 px evidence) arrive at the request untouched.
        let recordedMode = Box<PhotoThumbnailRequestMode?>(nil)
        let loader = PhotoKitThumbnailLoader { _, _, mode in
            recordedMode.write(mode)
            return solidImage(width: 8, height: 8)
        }

        _ = try await loader.thumbnail(for: "photo-1", targetPixelSize: 96, mode: .perceptual)
        #expect(recordedMode.read() == .perceptual)

        _ = try await loader.thumbnail(for: "photo-1", targetPixelSize: 256, mode: .verification)
        #expect(recordedMode.read() == .verification)

        // The 2-arg convenience defaults to the accurate rendition.
        _ = try await loader.thumbnail(for: "photo-1", targetPixelSize: 256)
        #expect(recordedMode.read() == .verification)
    }

    // MARK: Injected request seam

    @Test func successfulImageIsReturnedUnchanged() async throws {
        let image = solidImage(width: 64, height: 48)
        let loader = PhotoKitThumbnailLoader { _, _, _ in image }

        let result = try await loader.thumbnail(for: "photo-1", targetPixelSize: 256)
        #expect(result === image)
    }

    @Test func targetPixelSizeIsClampedToAtLeastOne() async throws {
        let recordedSize = Box<Int?>(nil)
        let loader = PhotoKitThumbnailLoader { _, size, _ in
            recordedSize.write(size)
            return solidImage(width: 1, height: 1)
        }

        _ = try await loader.thumbnail(for: "photo-1", targetPixelSize: 0)
        #expect(recordedSize.read() == 1)

        _ = try await loader.thumbnail(for: "photo-1", targetPixelSize: 256)
        #expect(recordedSize.read() == 256)
    }

    @Test func explicitFailuresPropagateToTheCaller() async throws {
        let loader = PhotoKitThumbnailLoader { _, _, _ in
            throw PhotoContentError.onlyInICloud
        }
        await #expect(throws: PhotoContentError.onlyInICloud) {
            _ = try await loader.thumbnail(for: "photo-1", targetPixelSize: 64)
        }
    }

    @Test func cancellationPropagatesOutOfTheLoader() async {
        let loader = PhotoKitThumbnailLoader { _, _, _ in
            withUnsafeCurrentTask { $0?.cancel() }
            try await Task.sleep(nanoseconds: 10_000_000_000)
            return solidImage(width: 1, height: 1)
        }
        await #expect(throws: CancellationError.self) {
            _ = try await loader.thumbnail(for: "photo-1", targetPixelSize: 64)
        }
    }

    // MARK: PhotoKit callback mapping (`result(image:info:)`)

    @Test func cancelledCallbackMapsToCancellationError() {
        let outcome = PhotoKitThumbnailLoader.result(
            image: nil,
            info: [PHImageCancelledKey: true]
        )
        #expect(throws: CancellationError.self) { try outcome.get() }
    }

    @Test func cloudOnlyCallbackReportsOnlyInICloudNotFailure() {
        let outcome = PhotoKitThumbnailLoader.result(
            image: nil,
            info: [PHImageResultIsInCloudKey: true]
        )
        #expect(throws: PhotoContentError.onlyInICloud) { try outcome.get() }
    }

    @Test func nilImageWithoutKeysReportsUnavailable() {
        let outcome = PhotoKitThumbnailLoader.result(image: nil, info: [:])
        #expect(throws: PhotoContentError.unavailable) { try outcome.get() }
    }

    @Test func photoKitErrorCodesMapToDistinguishableReasons() {
        // Permission off, asset gone, and iCloud-needed must stay distinguishable so future UI
        // can explain *why* an asset produced no thumbnail (ARCHITECTURE §10).
        func failureCode(_ code: PHPhotosError.Code) -> any Error {
            let outcome = PhotoKitThumbnailLoader.result(
                image: nil,
                info: [PHImageErrorKey: photosError(code)]
            )
            do {
                let image = try outcome.get()
                Issue.record("expected a failure, got an image \(image.width)×\(image.height)")
                return NSError(domain: "netto.tests", code: -1)
            } catch {
                return error
            }
        }

        #expect(failureCode(.accessUserDenied) as? PhotoContentError == .permissionDenied)
        #expect(failureCode(.accessRestricted) as? PhotoContentError == .permissionDenied)
        #expect(failureCode(.identifierNotFound) as? PhotoContentError == .assetNotFound)
        #expect(failureCode(.networkAccessRequired) as? PhotoContentError == .onlyInICloud)
        #expect(failureCode(.missingResource) as? PhotoContentError == .unavailable)

        // Non-Photos errors pass through untouched for honest propagation.
        let foreign = NSError(domain: "com.example.foreign", code: 42)
        let outcome = PhotoKitThumbnailLoader.result(image: nil, info: [PHImageErrorKey: foreign])
        #expect(throws: NSError(domain: "com.example.foreign", code: 42)) { try outcome.get() }
    }

    @Test func successfulCallbackBakesOrientationIntoPixels() {
        // A 4×2 source presented with `.left` has UIImage size 2×4; the normalized CGImage must
        // come back upright at 2×4 — orientation lives in pixels, not in metadata downstream.
        let upright = solidImage(width: 4, height: 2, level: 200)
        let rotated = UIImage(cgImage: upright, scale: 1, orientation: .left)
        #expect(rotated.size == CGSize(width: 2, height: 4))

        let outcome = PhotoKitThumbnailLoader.result(image: rotated, info: [:])
        guard let normalized = try? outcome.get() else {
            Issue.record("expected a successful normalization")
            return
        }
        #expect(normalized.width == 2)
        #expect(normalized.height == 4)
    }

    @Test func alreadyUprightImagePassesThroughDirectly() {
        let upright = solidImage(width: 8, height: 6)
        let image = UIImage(cgImage: upright, scale: 1, orientation: .up)
        let normalized = PhotoKitThumbnailLoader.normalizedCGImage(from: image)
        #expect(normalized === upright)
    }

    // MARK: Asset fetch (permission status read — never a request)

    @Test func fetchAssetForAnUnknownIdentifierFailsWithPermissionOrNotFound() {
        // The test host has no Photos authorization and the identifier does not exist, so the
        // fetch must fail with one of the two *specific* reasons — never a generic error, and
        // never an empty result silently treated as success.
        do {
            _ = try PhotoKitThumbnailLoader.fetchAsset("netto-tests-missing-identifier")
            Issue.record("fetching a nonexistent asset must throw")
        } catch let error as PhotoContentError {
            #expect(error == .permissionDenied || error == .assetNotFound)
        } catch {
            Issue.record("unexpected error type: \(error)")
        }
    }

    @Test func analysisThumbnailRequestsSettleWithinTheFailsafeOnThisHost() async {
        // Milestone 4C probe: analysis thumbnails are local-only (network disabled); each
        // request must still settle inside the 15 s failsafe — local successes and immediate
        // local-only refusals alike, never riding the timeout. (With network allowed, every
        // non-local asset took ~2.5 s serialized on this host — the measurement that drove
        // the local-only policy.) Prints one line per request for the validation report and
        // asserts only the hard bound.
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard status == .authorized || status == .limited else { return }
        let fetch = PHAsset.fetchAssets(with: PHFetchOptions())
        guard fetch.count > 0 else { return }

        let loader = PhotoKitThumbnailLoader()
        for index in 0..<min(6, fetch.count) {
            let asset = fetch.object(at: index)
            let started = Date()
            func elapsed() -> String {
                String(format: "%.2f", Date().timeIntervalSince(started))
            }
            do {
                _ = try await loader.thumbnail(
                    for: asset.localIdentifier,
                    targetPixelSize: 96,
                    mode: .perceptual
                )
                print("PROBE perceptual-fetch #\(index) outcome=success duration=\(elapsed())s")
            } catch {
                print("PROBE perceptual-fetch #\(index) outcome=\(error) duration=\(elapsed())s")
            }
            let seconds = Date().timeIntervalSince(started)
            #expect(seconds < 17, "request \(index) overran the failsafe + margin: \(seconds)s")
        }
    }
}

/// Small reference box used by the seam tests. `@unchecked Sendable`: all access under `lock`.
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

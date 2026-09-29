import CoreGraphics
import Foundation
import Testing
@testable import Netto

private func makeTexture(seed: UInt32, base: (UInt8, UInt8, UInt8)) -> CGImage {
    var rng = seed
    func next() -> UInt32 { rng = rng &* 1_664_525 &+ 1_013_904_223; return rng }
    let width = 96
    let height = 72
    var buffer = [UInt8](repeating: 0, count: width * height * 4)
    for pixel in 0..<(width * height) {
        let offset = pixel * 4
        let noise = Int(next() % 60) - 30
        buffer[offset + 0] = UInt8(max(0, min(255, Int(base.0) + noise)))
        buffer[offset + 1] = UInt8(max(0, min(255, Int(base.1) + noise)))
        buffer[offset + 2] = UInt8(max(0, min(255, Int(base.2) + noise)))
        buffer[offset + 3] = 255
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

/// The live extractor must work on *whatever* backend this environment actually has.
///
/// Verified environment fact: Vision's inference stack is unavailable in this iOS Simulator
/// (`VNGenerateImageFeaturePrintRequest` fails with "Failed to create espresso context", face
/// detection with "Could not create inference context") while geometric Vision requests still
/// run. On real hardware Vision answers the probe and becomes the backend. Either way, one run
/// must latch exactly one descriptor family and every print must use it.
struct VisionPhotoFeatureExtractorTests {
    @Test func prepareLatchesOneBackendAndEveryPrintUsesIt() async throws {
        let extractor = VisionPhotoFeatureExtractor()
        await extractor.prepare()
        await extractor.prepare() // idempotent

        let kind = extractor.kind
        #expect(FeaturePrintKind.allCases.contains(kind))

        let first = try await extractor.featurePrint(for: makeTexture(seed: 7, base: (180, 90, 40)))
        let second = try await extractor.featurePrint(for: makeTexture(seed: 7, base: (180, 90, 40)))
        let unrelated = try await extractor.featurePrint(for: makeTexture(seed: 99, base: (20, 160, 200)))

        #expect(first.kind == kind)
        #expect(second.kind == kind)
        #expect(unrelated.kind == kind)
        #expect(!first.values.isEmpty)

        let identicalDistance = try first.distance(to: second)
        let unrelatedDistance = try first.distance(to: unrelated)
        #expect(identicalDistance == 0)
        #expect(unrelatedDistance > kind.defaultSimilarityThreshold)
    }

    @Test func backendKindIsEitherFamilyNeverSomethingElse() async {
        let extractor = VisionPhotoFeatureExtractor()
        await extractor.prepare()
        let kind = extractor.kind
        #expect(kind == .visionFeaturePrint || kind == .cpuGrid)
    }

    @Test func cpuGridFallbackProducesTheFullLengthDescriptor() async throws {
        // Environment-dependent branch, both sides must hold:
        // - simulator (Vision probe fails): the CPU path must produce all 771 values.
        // - device (Vision probe succeeds): the Vision path must produce a non-empty print.
        let extractor = VisionPhotoFeatureExtractor()
        await extractor.prepare()
        let kind = extractor.kind

        let print = try await extractor.featurePrint(
            for: makeTexture(seed: 3, base: (120, 60, 30))
        )
        #expect(print.kind == kind)
        if kind == .cpuGrid {
            #expect(print.values.count == 771)
        } else {
            #expect(!print.values.isEmpty)
            #expect(print.values.count > 768 - 1 && print.values.count < 2049)
        }
    }

    @Test func prepareWhileCancelledLatchesTheCpuFallback() async {
        // Cancellation during warm-up must not leave `kind` in a half-probed state: the
        // extractor reports the CPU family, which is fully functional, rather than Vision
        // prints it would never be asked to produce.
        let extractor = VisionPhotoFeatureExtractor()
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            await extractor.prepare()
        }
        await task.value
        #expect(extractor.kind == .cpuGrid)
    }

    @Test func distancesAreOnlyComparableWithinTheLatchedFamily() async throws {
        // Descriptor-kind isolation: a print from this extractor must refuse to compare
        // against a print from the other family — the guard that keeps Vision and CPU spaces
        // from ever mixing inside a run (Vision threshold vs CPU threshold).
        let extractor = VisionPhotoFeatureExtractor()
        await extractor.prepare()
        let kind = extractor.kind
        let print = try await extractor.featurePrint(
            for: makeTexture(seed: 11, base: (10, 200, 90))
        )

        let other: FeaturePrintKind = kind == .cpuGrid ? .visionFeaturePrint : .cpuGrid
        let foreign = FeaturePrint(kind: other, values: print.values)
        #expect(throws: FeaturePrint.FeaturePrintError.kindMismatch(kind, other)) {
            _ = try print.distance(to: foreign)
        }
    }
}

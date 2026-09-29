import CoreGraphics
import Foundation
import Testing
@testable import Netto

// MARK: - Synthetic image helpers

private func makeImage(
    seed: UInt32,
    base: (UInt8, UInt8, UInt8),
    variation: Int,
    brightnessDelta: Int = 0,
    contrastScale: Double = 1.0,
    width: Int = 120,
    height: Int = 90
) -> CGImage {
    var rng = seed
    func next() -> UInt32 { rng = rng &* 1_664_525 &+ 1_013_904_223; return rng }
    func clamp(_ value: Int) -> UInt8 { UInt8(max(0, min(255, value))) }

    var buffer = [UInt8](repeating: 0, count: width * height * 4)
    for y in 0..<height {
        for x in 0..<width {
            let offset = (y * width + x) * 4
            let noise = Int(next() % UInt32(max(1, variation))) - variation / 2
            let r = Double(base.0) + Double(noise) + Double(brightnessDelta)
            let g = Double(base.1) + Double(noise) + Double(brightnessDelta)
            let b = Double(base.2) + Double(noise) + Double(brightnessDelta)
            buffer[offset + 0] = clamp(Int((r - 128) * contrastScale + 128))
            buffer[offset + 1] = clamp(Int((g - 128) * contrastScale + 128))
            buffer[offset + 2] = clamp(Int((b - 128) * contrastScale + 128))
            buffer[offset + 3] = 255
        }
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

private func solidImage(red: Int, green: Int, blue: Int, size: Int = 32) -> CGImage {
    var buffer = [UInt8](repeating: 255, count: size * size * 4)
    for index in stride(from: 0, to: buffer.count, by: 4) {
        buffer[index] = UInt8(red)
        buffer[index + 1] = UInt8(green)
        buffer[index + 2] = UInt8(blue)
    }
    let provider = CGDataProvider(data: Data(buffer) as CFData)!
    return CGImage(
        width: size,
        height: size,
        bitsPerComponent: 8,
        bitsPerPixel: 32,
        bytesPerRow: size * 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
        provider: provider,
        decode: nil,
        shouldInterpolate: false,
        intent: .defaultIntent
    )!
}

// MARK: - Distance semantics

struct FeaturePrintTests {
    @Test func identicalImagesAreAtDistanceZero() throws {
        let first = try CPUFeatureDescriptor.make(from: makeImage(seed: 7, base: (180, 90, 40), variation: 60))
        let second = try CPUFeatureDescriptor.make(from: makeImage(seed: 7, base: (180, 90, 40), variation: 60))
        #expect(first.kind == .cpuGrid)
        #expect(try first.distance(to: second) == 0)
    }

    @Test func printsAreUnitNormalized() throws {
        let print = try CPUFeatureDescriptor.make(from: makeImage(seed: 3, base: (10, 200, 90), variation: 80))
        let norm = sqrt(print.values.reduce(0) { $0 + $1 * $1 })
        #expect(abs(norm - 1) < 0.0001)
    }

    @Test func brightnessShiftIsSmallerThanUnrelatedContent() throws {
        let original = try CPUFeatureDescriptor.make(from: makeImage(seed: 7, base: (180, 90, 40), variation: 60))
        let brighter = try CPUFeatureDescriptor.make(from: makeImage(seed: 7, base: (180, 90, 40), variation: 60, brightnessDelta: 30))
        let unrelated = try CPUFeatureDescriptor.make(from: makeImage(seed: 99, base: (20, 160, 200), variation: 200))

        let brightnessDistance = try original.distance(to: brighter)
        let unrelatedDistance = try original.distance(to: unrelated)

        print("[CALIBRATION] brightness=\(brightnessDistance) unrelated=\(unrelatedDistance)")
        #expect(brightnessDistance < unrelatedDistance)
    }

    @Test func contrastShiftIsSmallerThanUnrelatedContent() throws {
        let original = try CPUFeatureDescriptor.make(from: makeImage(seed: 11, base: (140, 120, 110), variation: 100))
        let contrasted = try CPUFeatureDescriptor.make(from: makeImage(seed: 11, base: (140, 120, 110), variation: 100, contrastScale: 1.25))
        let unrelated = try CPUFeatureDescriptor.make(from: makeImage(seed: 5, base: (220, 30, 60), variation: 150))

        let contrastDistance = try original.distance(to: contrasted)
        let unrelatedDistance = try original.distance(to: unrelated)

        print("[CALIBRATION] contrast=\(contrastDistance) unrelated=\(unrelatedDistance)")
        #expect(contrastDistance < unrelatedDistance)
    }

    @Test func solidColorsWithSamePatternButDifferentHuesStayDistant() throws {
        // Mean-centering removes per-channel brightness, so color identity must come from the
        // appended channel-mean tail — without it, every solid color would collapse together.
        let red = try CPUFeatureDescriptor.make(from: solidImage(red: 220, green: 30, blue: 30))
        let blue = try CPUFeatureDescriptor.make(from: solidImage(red: 30, green: 30, blue: 220))
        let sameRed = try CPUFeatureDescriptor.make(from: solidImage(red: 220, green: 30, blue: 30))

        let crossDistance = try red.distance(to: blue)
        let selfDistance = try red.distance(to: sameRed)

        print("[CALIBRATION] solidCross=\(crossDistance)")
        #expect(selfDistance == 0)
        #expect(crossDistance > FeaturePrintKind.cpuGrid.defaultSimilarityThreshold)
    }

    @Test func defaultThresholdSeparatesSimilarFromUnrelated() throws {
        let original = try CPUFeatureDescriptor.make(from: makeImage(seed: 7, base: (180, 90, 40), variation: 60))
        let brighter = try CPUFeatureDescriptor.make(from: makeImage(seed: 7, base: (180, 90, 40), variation: 60, brightnessDelta: 30))
        let unrelated = try CPUFeatureDescriptor.make(from: makeImage(seed: 99, base: (20, 160, 200), variation: 200))

        let threshold = FeaturePrintKind.cpuGrid.defaultSimilarityThreshold
        #expect(try original.distance(to: brighter) <= threshold)
        #expect(try original.distance(to: unrelated) > threshold)
    }

    @Test func distanceRefusesToMixDescriptorKinds() throws {
        let cpu = FeaturePrint(kind: .cpuGrid, values: [0, 1])
        let vision = FeaturePrint(kind: .visionFeaturePrint, values: [0, 1])
        #expect(throws: FeaturePrint.FeaturePrintError.kindMismatch(.cpuGrid, .visionFeaturePrint)) {
            try cpu.distance(to: vision)
        }
    }

    @Test func distanceRefusesMismatchedLengths() throws {
        let lhs = FeaturePrint(kind: .cpuGrid, values: [0, 1])
        let rhs = FeaturePrint(kind: .cpuGrid, values: [0, 1, 0])
        #expect(throws: FeaturePrint.FeaturePrintError.lengthMismatch(2, 3)) {
            try lhs.distance(to: rhs)
        }
    }

    @Test func knownThresholdsAreDocumentedPerKind() {
        #expect(FeaturePrintKind.visionFeaturePrint.defaultSimilarityThreshold == 0.2)
        #expect(FeaturePrintKind.cpuGrid.defaultSimilarityThreshold == 0.15)
    }
}

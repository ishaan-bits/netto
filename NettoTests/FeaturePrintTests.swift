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

// MARK: - Perceptual hash (the cheap-first gate)

/// Horizontal brightness ramp — `increasing` goes dark → bright so every 9×8 cell is dimmer
/// than its right neighbour (all-ones hash); the decreasing direction yields all zeroes.
/// Ramps survive any box filter, so the ordering — unlike fine stripes — cannot average away.
private func rampImage(increasing: Bool, size: Int) -> CGImage {
    var buffer = [UInt8](repeating: 255, count: size * size * 4)
    for y in 0..<size {
        for x in 0..<size {
            let t = Int(x) * 255 / max(1, size - 1)
            let value = UInt8(max(0, min(255, increasing ? t : 255 - t)))
            let offset = (y * size + x) * 4
            buffer[offset] = value
            buffer[offset + 1] = value
            buffer[offset + 2] = value
        }
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

/// `pattern.count` columns (expects exactly 9, the reduction width) repeated over `rows`
/// rows — a grid that maps 1:1 onto the reduction with no scaling.
private func columnPatternImage(pattern: [UInt8], rows: Int) -> CGImage {
    let width = pattern.count
    var buffer = [UInt8](repeating: 255, count: width * rows * 4)
    for y in 0..<rows {
        for x in 0..<width {
            let offset = (y * width + x) * 4
            buffer[offset] = pattern[x]
            buffer[offset + 1] = pattern[x]
            buffer[offset + 2] = pattern[x]
        }
    }
    let provider = CGDataProvider(data: Data(buffer) as CFData)!
    return CGImage(
        width: width,
        height: rows,
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

struct PerceptualHashTests {
    @Test func solidImagesProduceAnAllZeroHashAtAnyLevel() throws {
        // No edge anywhere → no comparison ever fires. Solid images of *different* brightness
        // therefore sit at hamming 0 — the gate only asks "structurally worth comparing?".
        let black = try PerceptualHasher.hash(of: solidImage(red: 0, green: 0, blue: 0))
        let mid = try PerceptualHasher.hash(of: solidImage(red: 128, green: 128, blue: 128))
        let bright = try PerceptualHasher.hash(of: solidImage(red: 255, green: 255, blue: 255))
        #expect(black.bits == 0)
        #expect(mid.bits == 0)
        #expect(bright.bits == 0)
        #expect(black.distance(to: mid) == 0)
        #expect(black.distance(to: bright) == 0)
    }

    @Test func identicalImagesHashIdentically() throws {
        let first = try PerceptualHasher.hash(of: rampImage(increasing: true, size: 32))
        let second = try PerceptualHasher.hash(of: rampImage(increasing: true, size: 32))
        #expect(first == second)
        #expect(first.distance(to: second) == 0)
    }

    @Test func oppositeRampsSitAtMaximumHammingDistance() throws {
        // Every one of the 64 brightness relations flips between a rising and a falling
        // ramp — the worst case the gate must be able to reject (tolerance is 16).
        let rising = try PerceptualHasher.hash(of: rampImage(increasing: true, size: 32))
        let falling = try PerceptualHasher.hash(of: rampImage(increasing: false, size: 32))
        #expect(rising.bits == UInt64.max)
        #expect(falling.bits == 0)
        #expect(rising.distance(to: falling) == 64)
    }

    @Test func craftedColumnPatternPinsBitLayout() throws {
        // Nine alternating columns, identical on every row (so a vertical flip in the bitmap
        // context cannot change the result): comparisons fire at columns 0, 2, 4, 6 of every
        // row — pinning both the bit index (row × 8 + column) and the comparison direction.
        let pattern: [UInt8] = [10, 200, 10, 200, 10, 200, 10, 200, 10]
        let hash = try PerceptualHasher.hash(of: columnPatternImage(pattern: pattern, rows: 8))
        #expect(hash.bits == 0x5555_5555_5555_5555)
    }

    @Test func emptyImageThrows() {
        // The guard exists so a degenerate request fails as a typed error, not a crash.
        guard let empty = CGImage(
            width: 0,
            height: 0,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
            provider: CGDataProvider(data: Data([0]) as CFData)!,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        ) else {
            return // platform refuses to build a zero-sized image — nothing to hash
        }
        #expect(throws: FeaturePrint.FeaturePrintError.empty) {
            try PerceptualHasher.hash(of: empty)
        }
    }
}

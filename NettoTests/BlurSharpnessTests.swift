import CoreGraphics
import Foundation
import Testing
@testable import Netto

// MARK: - Synthetic fixtures (measured during threshold calibration; see BlurThresholds)
//
// These builders reproduce the exact fixtures the synthetic calibration table in
// `BlurThresholds` was measured against, so every verdict asserted here is a verdict the
// documented numbers already support. Assertions are verdict-level (never exact floats) so
// an OS interpolation change cannot flip a test that has not genuinely regressed.

/// Grayscale-in-RGBA pixel canvas: `draw(x, y)` returns 0…255 gray.
func blurTestImage(size: Int, draw: (Int, Int) -> Int) -> CGImage {
    var buffer = [UInt8](repeating: 255, count: size * size * 4)
    for y in 0..<size {
        for x in 0..<size {
            let value = UInt8(max(0, min(255, draw(x, y))))
            let offset = (y * size + x) * 4
            buffer[offset] = value
            buffer[offset + 1] = value
            buffer[offset + 2] = value
            buffer[offset + 3] = 255
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

func blurTestChecker(size: Int, cell: Int) -> CGImage {
    blurTestImage(size: size) { x, y in
        ((x / cell) + (y / cell)) % 2 == 0 ? 235 : 20
    }
}

func blurTestSolid(level: Int, size: Int = 128) -> CGImage {
    blurTestImage(size: size) { _, _ in level }
}

/// Structured photo-like content: gradient bars, a dark block, fine text-like strokes.
func blurTestScene(size: Int) -> CGImage {
    blurTestImage(size: size) { x, y in
        var value = 150 + (x * 60) / size
        if y > size / 3 && y < (2 * size) / 3 && x > size / 6 && x < size / 2 { value = 35 }
        if (x % 17) < 2 && y > (2 * size) / 3 { value = 245 }
        if (y % 13) < 2 && x > size / 2 { value = 10 }
        if (x + y) % 97 == 0 { value = 250 }
        return value
    }
}

func blurTestNoise(size: Int, base: Int, spread: Int, seed: UInt64) -> CGImage {
    var state = seed
    return blurTestImage(size: size) { _, _ in
        state = state &* 6364136223846793005 &+ 1442695040888963407
        let noise = Int(state >> 33) % max(1, spread) - spread / 2
        return base + noise
    }
}

func blurTestGradient(size: Int) -> CGImage {
    blurTestImage(size: size) { x, _ in x * 255 / max(1, size - 1) }
}

/// Separable box blur with clamped (edge-extended) windows — the same treatment the
/// metric itself applies at the border, so blurring here only removes detail.
func blurTestBoxBlur(_ image: CGImage, radius: Int, passes: Int) -> CGImage {
    let width = image.width
    let height = image.height
    let pixelBytes = UnsafeMutablePointer<UInt8>.allocate(capacity: width * height * 4)
    defer { pixelBytes.deallocate() }
    guard let context = CGContext(
        data: pixelBytes,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: width * 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
    ) else {
        return image
    }
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    var source = [UInt8](repeating: 0, count: width * height * 4)
    for index in 0..<(width * height * 4) { source[index] = pixelBytes[index] }
    var destination = [UInt8](repeating: 0, count: source.count)
    for _ in 0..<passes {
        for y in 0..<height {
            let base = (y * width) * 4
            for x in 0..<width {
                let low = max(0, x - radius)
                let high = min(width - 1, x + radius)
                let count = high - low + 1
                for channel in 0..<3 {
                    var sum = 0
                    for index in low...high { sum += Int(source[base + index * 4 + channel]) }
                    destination[base + x * 4 + channel] = UInt8(sum / count)
                }
            }
        }
        swap(&source, &destination)
        for x in 0..<width {
            for y in 0..<height {
                let low = max(0, y - radius)
                let high = min(height - 1, y + radius)
                let count = high - low + 1
                for channel in 0..<3 {
                    var sum = 0
                    for index in low...high { sum += Int(source[(index * width + x) * 4 + channel]) }
                    destination[(y * width + x) * 4 + channel] = UInt8(sum / count)
                }
            }
        }
        swap(&source, &destination)
    }
    let provider = CGDataProvider(data: Data(source) as CFData)!
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

// Shared fixture images (lazy globals; built once for the suite).
let blurFixtureSharpChecker = blurTestChecker(size: 128, cell: 2)
let blurFixtureWideChecker = blurTestChecker(size: 128, cell: 8)
let blurFixtureStrongNoise = blurTestNoise(size: 128, base: 128, spread: 160, seed: 42)
let blurFixtureScene = blurTestScene(size: 256)
let blurFixtureBlurryScene = blurTestBoxBlur(blurTestScene(size: 256), radius: 6, passes: 3)
let blurFixtureFlat = blurTestSolid(level: 128)
let blurFixtureDarkNoise = blurTestNoise(size: 256, base: 16, spread: 20, seed: 99)

// MARK: - Sharpness metric

struct BlurSharpnessTests {
    private let thresholds = BlurThresholds.corpusCalibrated

    // MARK: Item 1 — sharp vs blurred synthetic content

    @Test func sharpSyntheticImagesClassifyAsSharp() throws {
        for image in [blurFixtureSharpChecker, blurFixtureWideChecker, blurFixtureScene, blurFixtureStrongNoise] {
            let score = try BlurSharpnessAnalyzer.measure(of: image)
            #expect(score.lumaMean >= thresholds.minLuma)
            #expect(score.lumaStdDev >= thresholds.minTextureStdDev)
            #expect(thresholds.classify(score) == .sharp)
        }
    }

    @Test func boxBlurredSceneClassifiesAsBlurry() throws {
        // A light box blur is honestly borderline: lap 4.5e-4 sits just under the
        // ceiling, but its residual slope energy (ten 0.081) is over the Tenengrad
        // gate — the two-signal band works as designed. A heavy blur clears both.
        let lightlyBlurred = blurTestBoxBlur(blurTestScene(size: 256), radius: 2, passes: 2)
        let lightScore = try BlurSharpnessAnalyzer.measure(of: lightlyBlurred)
        #expect(thresholds.classify(lightScore) == .borderline)

        let heavyScore = try BlurSharpnessAnalyzer.measure(of: blurFixtureBlurryScene)
        #expect(heavyScore.lumaMean >= thresholds.minLuma)
        #expect(heavyScore.lumaStdDev >= thresholds.minTextureStdDev)
        #expect(thresholds.classify(heavyScore) == .likelyBlurry)
    }

    // MARK: Item 2 — flat and low-light frames are refused, never judged

    @Test func flatFrameIsRefusedRatherThanCalledBlurry() throws {
        let score = try BlurSharpnessAnalyzer.measure(of: blurFixtureFlat)
        #expect(score.lumaStdDev < thresholds.minTextureStdDev)
        #expect(thresholds.classify(score) == .insufficientInformation)
    }

    @Test func lowLightFrameIsRefusedRatherThanCalledBlurry() throws {
        let score = try BlurSharpnessAnalyzer.measure(of: blurFixtureDarkNoise)
        // The reason for refusal is light, and it must be the gate that fired: the raw
        // texture is enough to judge, so only the luminance rule keeps this out of the grid.
        #expect(score.lumaMean < thresholds.minLuma)
        #expect(thresholds.classify(score) == .insufficientInformation)
    }

    // MARK: Item 3 — threshold boundaries and the uncertain band

    @Test func thresholdBoundariesClassifyExactly() {
        let t = thresholds
        func score(
            variance: Float,
            tenengrad: Float? = nil,
            lumaMean: Float = 0.5,
            lumaStdDev: Float = 0.3
        ) -> BlurSharpnessScore {
            BlurSharpnessScore(
                laplacianVariance: variance,
                // Default keeps the Tenengrad gate satisfied at the variance ceiling
                // (5e-4 × 100 = 5.0e-2 = blurryMaxTenengrad), so these assertions
                // probe the variance boundary itself.
                tenengradMean: tenengrad ?? variance * 100,
                lumaMean: lumaMean,
                lumaStdDev: lumaStdDev
            )
        }

        // At or above the sharp floor → sharp; one ulp below → the borderline band.
        #expect(t.classify(score(variance: t.sharpMinVariance)) == .sharp)
        #expect(t.classify(score(variance: t.sharpMinVariance.nextDown)) == .borderline)

        // At or below both blurry ceilings → likelyBlurry; one ulp above either → borderline.
        #expect(t.classify(score(variance: t.blurryMaxVariance)) == .likelyBlurry)
        #expect(t.classify(score(variance: t.blurryMaxVariance.nextUp)) == .borderline)
        #expect(t.classify(score(variance: t.blurryMaxVariance, tenengrad: t.blurryMaxTenengrad)) == .likelyBlurry)
        #expect(t.classify(score(variance: t.blurryMaxVariance, tenengrad: t.blurryMaxTenengrad.nextUp)) == .borderline)

        // Exactly at the information gates the frame is still judgeable…
        #expect(t.classify(score(variance: t.blurryMaxVariance, lumaMean: t.minLuma)) == .likelyBlurry)
        #expect(t.classify(score(variance: t.blurryMaxVariance, lumaStdDev: t.minTextureStdDev)) == .likelyBlurry)
        // …one ulp short of either gate and it is refused, despite a high-detail signal.
        #expect(t.classify(score(variance: 1.0, lumaMean: t.minLuma.nextDown)) == .insufficientInformation)
        #expect(t.classify(score(variance: 1.0, lumaStdDev: t.minTextureStdDev.nextDown)) == .insufficientInformation)
    }

    @Test func informationGatesRunBeforeTheSharpnessBands() {
        let t = thresholds
        // A dark or flat frame with textbook-sharp variance is still refused: an unreadable
        // image can never be reported as sharp (or as a cleanup candidate).
        let darkButDetailed = BlurSharpnessScore(
            laplacianVariance: t.sharpMinVariance * 10,
            lumaMean: t.minLuma.nextDown,
            lumaStdDev: 0.5
        )
        let flatButDetailed = BlurSharpnessScore(
            laplacianVariance: t.sharpMinVariance * 10,
            lumaMean: 0.5,
            lumaStdDev: t.minTextureStdDev.nextDown
        )
        #expect(t.classify(darkButDetailed) == .insufficientInformation)
        #expect(t.classify(flatButDetailed) == .insufficientInformation)
    }

    // MARK: Determinism and the documented limitations

    @Test func measurementIsDeterministic() throws {
        let first = try BlurSharpnessAnalyzer.measure(of: blurFixtureScene)
        let second = try BlurSharpnessAnalyzer.measure(of: blurFixtureScene)
        #expect(first == second)
    }

    @Test func smoothGradientThroughTheProductionPipelineIsPinnedLikelyBlurry() throws {
        // Pinned limitation (see BlurThresholds + corpus rule .pinnedLikelyBlurry):
        // a noise-free smooth field delivered through the production pipeline measures
        // below every absolute signal at some render scales and lands confidently in the
        // blurry band — indistinguishable from heavy defocus at the signal level. This
        // test pins that behavior at two scales so a silent threshold or kernel change
        // that flips it forces a deliberate recalibration.
        for size in [512, 640] {
            let delivered = try deliverForAnalysis(
                blurTestGradient(size: size),
                path: .sharpnessAspectFill
            )
            let score = try BlurSharpnessAnalyzer.measure(of: delivered)
            #expect(score.lumaMean >= thresholds.minLuma)
            #expect(score.lumaStdDev >= thresholds.minTextureStdDev)
            #expect(score.laplacianVariance < thresholds.sharpMinVariance)
            #expect(
                thresholds.classify(score) == .likelyBlurry,
                "gradient at \(size)² should stay pinned likelyBlurry"
            )
        }
    }

    // MARK: Items 4 — unavailable input vocabulary + candidate-only verdicts

    @Test func refusalErrorsMapToTheHonestUnavailableVocabulary() {
        #expect(BlurAnalysisEngine.unavailableReason(for: PhotoRequestTimeoutError()) == .timedOut)
        #expect(BlurAnalysisEngine.unavailableReason(for: PhotoContentError.permissionDenied) == .permissionUnavailable)
        #expect(BlurAnalysisEngine.unavailableReason(for: PhotoContentError.assetNotFound) == .assetNotFound)
        #expect(BlurAnalysisEngine.unavailableReason(for: PhotoContentError.onlyInICloud) == .contentOnlyInICloud)
        #expect(BlurAnalysisEngine.unavailableReason(for: PhotoContentError.unavailable) == .imageUnavailable)
        #expect(BlurAnalysisEngine.unavailableReason(for: BlurSharpnessError.emptyImage) == .imageUnavailable)
        // A reason thrown directly passes through untouched.
        #expect(BlurAnalysisEngine.unavailableReason(for: PhotoAnalysisUnavailableReason.contentUnreadable) == .contentUnreadable)
        // Anything unrecognized is reported as "could not measure" — never as a verdict.
        struct UnrecognizedFailure: Error {}
        #expect(BlurAnalysisEngine.unavailableReason(for: UnrecognizedFailure()) == .imageUnavailable)
    }

    @Test func onlyBlurryAndUncertainVerdictsAreCandidates() {
        #expect(BlurVerdict.likelyBlurry.isCandidate)
        #expect(BlurVerdict.borderline.isCandidate)
        #expect(!BlurVerdict.sharp.isCandidate)
        #expect(!BlurVerdict.insufficientInformation.isCandidate)
    }
}

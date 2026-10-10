import Accelerate
import CoreGraphics
import Foundation

/// A sharpness measurement that could not be produced — the image has zero dimensions or
/// cannot be rendered into the analysis bitmap. Callers report the asset as unavailable;
/// they never substitute a fabricated score.
enum BlurSharpnessError: Error, Sendable, Equatable {
    case emptyImage
}

/// One image's sharpness measurements, all in the analysis domain:
/// a 256×256 aspect-fill grayscale render, pixels normalized to 0…1 before filtering.
///
/// Deliberately *raw*: the numbers carry no policy. `BlurThresholds` turns them into a
/// verdict, so threshold changes never require re-measuring and tests can classify
/// boundary scores directly.
struct BlurSharpnessScore: Sendable, Equatable {
    /// Variance of the Laplacian response (3×3 kernel, edge-extended borders). The
    /// primary sharpness metric: high when edges are crisp, near zero when the image is
    /// smooth.
    let laplacianVariance: Float
    /// Mean Sobel gradient energy (Gx² + Gy², 0…1 domain). A second, differently-shaped
    /// detail signal: Laplacian emphasizes second derivatives (corners, thin lines),
    /// Tenengrad emphasizes slope (broader edges), so a signal present in both is much
    /// harder for a single artifact class to fake.
    let tenengradMean: Float
    /// 90th percentile of per-block gradient energy (16×16 blocks over the analysis
    /// bitmap). Together with `gradientEnergyMedian` this describes *where* detail
    /// lives: a uniformly weak frame (smooth subject, gradient, whole-frame defocus)
    /// has p90 ≈ median, while a frame with any sharp region has a heavy tail.
    let gradientEnergyP90: Float
    /// Median per-block gradient energy — the "background" detail level.
    let gradientEnergyMedian: Float
    /// Mean luminance (0…1). Near-black frames are unreadable by any sharpness metric.
    let lumaMean: Float
    /// Standard deviation of luminance (0…1). Near-zero means a flat frame (wall, sky,
    /// blank card) where "no detail" cannot be told from "blurry".
    let lumaStdDev: Float

    /// Spatial concentration of gradient energy: p90 ÷ median over blocks. ≈1.0 when
    /// weakness is uniform across the frame; ≫1 when a few blocks carry the edges.
    var gradientEnergySpikiness: Float {
        gradientEnergyP90 / max(gradientEnergyMedian, 1e-6)
    }

    /// Memberwise with defaults for the extra signals, so boundary tests that only pin
    /// the Laplacian dimension keep constructing scores without ceremony.
    init(
        laplacianVariance: Float,
        tenengradMean: Float = 0,
        gradientEnergyP90: Float = 0,
        gradientEnergyMedian: Float = 0,
        lumaMean: Float,
        lumaStdDev: Float
    ) {
        self.laplacianVariance = laplacianVariance
        self.tenengradMean = tenengradMean
        self.gradientEnergyP90 = gradientEnergyP90
        self.gradientEnergyMedian = gradientEnergyMedian
        self.lumaMean = lumaMean
        self.lumaStdDev = lumaStdDev
    }
}

/// How one score is classified. Four honest outcomes, never a binary good/bad claim:
/// - `.sharp`: confidently detailed — never a cleanup candidate.
/// - `.likelyBlurry`: confidently low detail (given enough light and texture) — a candidate.
/// - `.borderline`: between the thresholds — also surfaced as a candidate, because the
///   category is *Potentially* Blurry; the UI keeps it distinguishable from `.likelyBlurry`.
/// - `.insufficientInformation`: too dark or too flat to judge at all — never a candidate,
///   never silently counted as analyzed.
enum BlurVerdict: String, Sendable, Equatable, Codable {
    case sharp
    case borderline
    case likelyBlurry
    case insufficientInformation

    /// Whether the verdict may appear in the review grid. Only judged-and-not-sharp
    /// photos are candidates; nothing else can reach selection from here.
    var isCandidate: Bool {
        self == .likelyBlurry || self == .borderline
    }
}

/// Classification thresholds for `BlurSharpnessScore`.
///
/// ## Calibration status (read before changing a number)
/// The defaults are calibrated on the **labelled procedural corpus** in
/// `BlurCorpusTests` — camera-sized sources drawn through the production delivery and
/// measurement pipeline. The measured table (640×480, aspect-fill delivery; see
/// `blurCorpusMetricsReport` for the live table):
///
/// | category            | laplacian | tenengrad | lap/ten | luma  | std   |
/// |---------------------|-----------|-----------|---------|-------|-------|
/// | sharp text          | 1.4e-1    | 1.1       | 0.13    | 0.81  | 0.23  |
/// | sharp checker       | 1.2       | 3.5       | 0.34    | 0.50  | 0.30  |
/// | sharp foliage       | 2.0e-1    | 1.2       | 0.16    | 0.49  | 0.18  |
/// | sharp scene         | 1.1e-1    | 0.91      | 0.12    | 0.57  | 0.24  |
/// | defocus light (r2)  | 2.6e-3    | 0.17      | 0.015   | 0.57  | 0.20  |
/// | defocus mid (r5)    | 1.4e-4    | 1.6e-2    | 0.0086  | 0.57  | 0.18  |
/// | defocus heavy (r12) | 2.1e-5    | 5.1e-3    | 0.004   | 0.57  | 0.18  |
/// | motion blur         | 3.6e-3    | 0.15      | 0.024   | 0.57  | 0.20  |
/// | soft portrait       | 3.8e-3    | 0.16      | 0.024   | 0.57  | 0.20  |
/// | smooth gradient     | 1.1e-5    | 6.3e-4    | 0.017   | 0.50  | 0.22  |
/// | dark scene          | 6.9e-3    | 5.6e-2    | 0.12    | 0.14  | 0.06  |
/// | bokeh with subject  | 2.5e-2    | 2.0e-1    | 0.13    | 0.57  | 0.19  |
///
/// Two gates, each justified by a measured separation:
/// - **`blurryMaxVariance` (5e-4)** sits ~3.6× above mid defocus and ~5× below light
///   defocus — light defocus stays `.borderline`, mid/heavy enter the blurry band. The
///   tightening from the original 2e-3 is the false-positive fix: content in
///   [5e-4, 2e-3] (resampled-but-not-blurry photographs) now reads `.borderline`
///   instead of confidently `.likelyBlurry`.
/// - **`blurryMaxTenengrad` (5.0e-2)** is the second absolute-detail signal: ~3× above
///   mid defocus's gradient energy and ~3× below light defocus's, so an artifact that
///   depresses the Laplacian alone cannot cross the blurry band.
///
/// A concentration ratio (lap/ten) was measured as a smooth-subject separator and
/// **rejected**: a noise-free gradient's ratio swings two orders of magnitude with the
/// render scale (0.0002 at an exact 2:1 downscale vs 0.017 at 0.4×), overlapping the
/// defocus family — not a production rule. Gradient-family content therefore lands in
/// the blurry band (see the limitation below); it is a candidate for human review,
/// never an automatic action.
///
/// Known limitations, measured not guessed:
/// - **Intentional bokeh / shallow depth of field** with a sharp region scores sharp or
///   borderline (the sharp region dominates) — candidates are *potentially* blurry, for
///   a human to keep or drop.
/// - **Whole-frame artistic defocus** (no sharp region anywhere) is genuinely
///   indistinguishable from accidental defocus at this scale and is flagged — correct
///   behavior for a review category, never an automatic action.
/// - **Noise-free smooth fields** (blank skies, walls, mathematical gradients) measure
///   below every absolute signal and land `.likelyBlurry` — measured identically to
///   heavy defocus at exact render scales. Real photographs usually carry a sensor
///   noise floor above that, but this boundary is only verified on the procedural
///   corpus, never claimed for photographs.
/// - **Low light**: frames with mean luminance below `minLuma` are refused entirely
///   rather than mis-scored — the metric is not trustworthy there.
/// - The 256² analysis render destroys detail finer than ~1/256 of the frame regardless
///   of blur, so verdicts describe *thumbnail-scale* sharpness, never print-scale focus.
///
/// Real-device recalibration is required before these thresholds can be called accurate
/// for photographs; until then every candidate is presented for explicit human review.
struct BlurThresholds: Sendable, Equatable, Codable {
    /// Laplacian variance at or above this → `.sharp`.
    let sharpMinVariance: Float
    /// Laplacian variance at or below this (with the Tenengrad gate also satisfied)
    /// → `.likelyBlurry`. Between the bands → `.borderline`.
    let blurryMaxVariance: Float
    /// Tenengrad mean at or below this (with the variance gate also satisfied) →
    /// `.likelyBlurry`. The second absolute-detail signal, differently shaped from the
    /// Laplacian (slope energy vs second derivative).
    let blurryMaxTenengrad: Float
    /// Mean luminance below this → `.insufficientInformation` (too dark to judge).
    let minLuma: Float
    /// Luminance standard deviation below this → `.insufficientInformation` (flat frame).
    let minTextureStdDev: Float

    /// The corpus-calibrated defaults. See the type documentation before editing.
    static let corpusCalibrated = BlurThresholds(
        sharpMinVariance: 0.01,
        blurryMaxVariance: 5e-4,
        blurryMaxTenengrad: 5.0e-2,
        minLuma: 0.08,
        minTextureStdDev: 0.015
    )

    /// Classifies one score. Order matters: information gates first (an unreadable image
    /// can never be called blurry or sharp), then the confident sharp band, then the
    /// two-signal blurry band, then the honest borderline middle.
    func classify(_ score: BlurSharpnessScore) -> BlurVerdict {
        if score.lumaMean < minLuma || score.lumaStdDev < minTextureStdDev {
            return .insufficientInformation
        }
        if score.laplacianVariance >= sharpMinVariance {
            return .sharp
        }
        if score.laplacianVariance <= blurryMaxVariance,
           score.tenengradMean <= blurryMaxTenengrad {
            return .likelyBlurry
        }
        return .borderline
    }
}

/// On-device sharpness measurement: variance of the Laplacian over a bounded grayscale
/// render, using Accelerate/vImage for the pixel conversion and the convolution.
///
/// Contract:
/// - **Bounded input.** Works on the delivered thumbnail (≤ `targetPixelSize` on the
///   longest side), rendered aspect-fill into a fixed `analysisSide × analysisSide`
///   bitmap — full-resolution pixels are never decoded here.
/// - **Deterministic.** The same pixels always produce the same score: fixed render
///   size, fixed kernel, fixed edge handling (extended borders), population variance.
/// - **Pure.** No PhotoKit, no network, no selection/deletion knowledge. The engine that
///   fetches thumbnails owns unavailable-asset reporting; this type only measures pixels
///   it is handed, or throws `BlurSharpnessError.emptyImage`.
enum BlurSharpnessAnalyzer {
    /// Analysis bitmap side in pixels. All scores are comparable only within this size —
    /// the thresholds were calibrated against it.
    static let defaultAnalysisSide = 256

    /// Measures one image. `image` may be any size; it is scaled aspect-fill (center
    /// crop, no distortion) into the square analysis bitmap with high-quality
    /// interpolation — the same treatment every candidate receives, so scores compare.
    static func measure(
        of image: CGImage,
        analysisSide: Int = defaultAnalysisSide
    ) throws -> BlurSharpnessScore {
        let side = max(2, analysisSide)
        guard image.width > 0, image.height > 0 else {
            throw BlurSharpnessError.emptyImage
        }

        // Grayscale render buffer (owned here, released on every path).
        let gray = UnsafeMutablePointer<UInt8>.allocate(capacity: side * side)
        defer { gray.deallocate() }

        guard let context = CGContext(
            data: gray,
            width: side,
            height: side,
            bitsPerComponent: 8,
            bytesPerRow: side,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else {
            throw BlurSharpnessError.emptyImage
        }
        context.interpolationQuality = .high
        let sourceWidth = CGFloat(image.width)
        let sourceHeight = CGFloat(image.height)
        // Aspect-fill: scale so the square is fully covered, center it; pixels outside the
        // bitmap are never rasterized, which is exactly the crop.
        let scale = max(CGFloat(side) / sourceWidth, CGFloat(side) / sourceHeight)
        let drawWidth = sourceWidth * scale
        let drawHeight = sourceHeight * scale
        context.draw(
            image,
            in: CGRect(
                x: (CGFloat(side) - drawWidth) / 2,
                y: (CGFloat(side) - drawHeight) / 2,
                width: drawWidth,
                height: drawHeight
            )
        )

        let pixelCount = side * side
        let luma = UnsafeMutablePointer<Float>.allocate(capacity: pixelCount)
        let laplacian = UnsafeMutablePointer<Float>.allocate(capacity: pixelCount)
        let gradX = UnsafeMutablePointer<Float>.allocate(capacity: pixelCount)
        let gradY = UnsafeMutablePointer<Float>.allocate(capacity: pixelCount)
        let energy = UnsafeMutablePointer<Float>.allocate(capacity: pixelCount)
        defer {
            luma.deallocate()
            laplacian.deallocate()
            gradX.deallocate()
            gradY.deallocate()
            energy.deallocate()
        }

        var sourceBuffer = vImage_Buffer(
            data: gray,
            height: vImagePixelCount(side),
            width: vImagePixelCount(side),
            rowBytes: side
        )
        var lumaBuffer = vImage_Buffer(
            data: luma,
            height: vImagePixelCount(side),
            width: vImagePixelCount(side),
            rowBytes: side * MemoryLayout<Float>.size
        )
        var laplacianBuffer = vImage_Buffer(
            data: laplacian,
            height: vImagePixelCount(side),
            width: vImagePixelCount(side),
            rowBytes: side * MemoryLayout<Float>.size
        )
        var gradXBuffer = vImage_Buffer(
            data: gradX,
            height: vImagePixelCount(side),
            width: vImagePixelCount(side),
            rowBytes: side * MemoryLayout<Float>.size
        )
        var gradYBuffer = vImage_Buffer(
            data: gradY,
            height: vImagePixelCount(side),
            width: vImagePixelCount(side),
            rowBytes: side * MemoryLayout<Float>.size
        )

        // 0…1 normalization keeps the metric independent of integer encoding, so the
        // calibrated thresholds stay meaningful if the render path ever changes.
        let convertError = vImageConvert_Planar8toPlanarF(
            &sourceBuffer,
            &lumaBuffer,
            1.0,
            0.0,
            vImage_Flags(kvImageNoFlags)
        )
        guard convertError == kvImageNoError else {
            throw BlurSharpnessError.emptyImage
        }

        // Discrete Laplacian: neighbors summed, center × −4. Zero-sum kernel over an
        // edge-extended border, so a flat frame yields an all-zero response.
        var kernel: [Float] = [0, 1, 0, 1, -4, 1, 0, 1, 0]
        let convolveError = vImageConvolve_PlanarF(
            &lumaBuffer,
            &laplacianBuffer,
            nil,
            0,
            0,
            &kernel,
            3,
            3,
            0,
            vImage_Flags(kvImageEdgeExtend)
        )
        guard convolveError == kvImageNoError else {
            throw BlurSharpnessError.emptyImage
        }

        // Sobel gradients: the second detail signal. Same edge-extended borders, so a
        // flat frame yields an all-zero energy field and spikiness stays well-defined.
        var sobelX: [Float] = [-1, 0, 1, -2, 0, 2, -1, 0, 1]
        var sobelY: [Float] = [-1, -2, -1, 0, 0, 0, 1, 2, 1]
        let gradXError = vImageConvolve_PlanarF(
            &lumaBuffer,
            &gradXBuffer,
            nil,
            0,
            0,
            &sobelX,
            3,
            3,
            0,
            vImage_Flags(kvImageEdgeExtend)
        )
        guard gradXError == kvImageNoError else {
            throw BlurSharpnessError.emptyImage
        }
        let gradYError = vImageConvolve_PlanarF(
            &lumaBuffer,
            &gradYBuffer,
            nil,
            0,
            0,
            &sobelY,
            3,
            3,
            0,
            vImage_Flags(kvImageEdgeExtend)
        )
        guard gradYError == kvImageNoError else {
            throw BlurSharpnessError.emptyImage
        }
        for index in 0..<pixelCount {
            let gx = gradX[index]
            let gy = gradY[index]
            energy[index] = gx * gx + gy * gy
        }

        let lumaMean = mean(of: luma, count: pixelCount)
        let lumaVariance = variance(of: luma, count: pixelCount, mean: lumaMean)
        let laplacianMean = mean(of: laplacian, count: pixelCount)
        let laplacianVariance = variance(of: laplacian, count: pixelCount, mean: laplacianMean)
        let tenengradMean = mean(of: energy, count: pixelCount)
        let blockStats = blockEnergyPercentiles(energy: energy, side: side)

        return BlurSharpnessScore(
            laplacianVariance: laplacianVariance,
            tenengradMean: tenengradMean,
            gradientEnergyP90: blockStats.p90,
            gradientEnergyMedian: blockStats.median,
            lumaMean: lumaMean,
            lumaStdDev: max(0, lumaVariance).squareRoot()
        )
    }

    /// Median and p90 of per-block gradient energy over a 16×16 grid of square blocks.
    private static func blockEnergyPercentiles(
        energy: UnsafeMutablePointer<Float>,
        side: Int
    ) -> (median: Float, p90: Float) {
        let grid = 16
        let blockSize = max(1, side / grid)
        var blocks: [Float] = []
        blocks.reserveCapacity(grid * grid)
        for blockY in 0..<grid {
            for blockX in 0..<grid {
                var sum: Float = 0
                let yRange = (blockY * blockSize)..<((blockY + 1) * blockSize)
                let xRange = (blockX * blockSize)..<((blockX + 1) * blockSize)
                for y in yRange {
                    for x in xRange {
                        sum += energy[y * side + x]
                    }
                }
                let count = Float(blockSize * blockSize)
                blocks.append(count > 0 ? sum / count : 0)
            }
        }
        blocks.sort()
        let count = blocks.count
        let median = (blocks[count / 2 - 1] + blocks[count / 2]) / 2
        let p90 = blocks[min(count - 1, Int(Float(count - 1) * 0.9))]
        return (median, p90)
    }

    /// Population mean. Two passes instead of Welford: 256² Floats, no accumulation
    /// drift, and the same simple code shape the tests can reason about.
    private static func mean(of buffer: UnsafeMutablePointer<Float>, count: Int) -> Float {
        var sum: Float = 0
        for index in 0..<count {
            sum += buffer[index]
        }
        return sum / Float(count)
    }

    /// Population variance around a known mean.
    private static func variance(
        of buffer: UnsafeMutablePointer<Float>,
        count: Int,
        mean: Float
    ) -> Float {
        var sum: Float = 0
        for index in 0..<count {
            let delta = buffer[index] - mean
            sum += delta * delta
        }
        return sum / Float(count)
    }
}

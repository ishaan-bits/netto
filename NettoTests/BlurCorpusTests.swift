import CoreGraphics
import Foundation
import Testing
@testable import Netto

// MARK: - Labelled procedural corpus for honest threshold calibration
//
// Why this exists: the original thresholds were measured on a handful of square fixtures
// that never saw the *render path* real assets take (PhotoKit delivery + aspect-fill
// analysis). This corpus closes that gap with purpose-built, labelled content drawn
// through the exact production pipeline — camera-sized source → delivery emulation →
// `BlurSharpnessAnalyzer.measure` — so the confusion matrix a calibration run prints is
// the same matrix a device run would produce for these content classes.
//
// Honesty rules encoded here:
// - Labels are *expectations about content classes*, not claims about photographs. The
//   report must never present these numbers as production accuracy.
// - Every category declares the only verdicts that satisfy it; strong categories are
//   strict (sharp stays sharp, heavy defocus is flagged), the "must not falsely flag"
//   classes (smooth, dark, bokeh-with-subject) fail loudly if the pipeline calls them
//   likely blurry.
// - Both delivery paths are measured: the legacy verification path (aspect-fit box,
//   which forces the analysis to upscale non-square renditions) and the sharpness path
//   (native aspect-fill center-crop to the exact analysis side). "Resizing must not
//   flip a strong classification" is an acceptance rule, not a hope.

/// What a category's verdict must satisfy to count as correctly classified.
enum BlurCorpusRule: String, Sendable {
    case mustBeSharp
    case mustBeLikelyBlurry
    case mustBeBorderline
    /// Likely blurry or borderline — a family, for content that is genuinely soft but
    /// not confidently defocused.
    case mustBeInBlurryFamily
    case mustNotBeLikelyBlurry
    case mustBeInsufficient
    /// Pinned measured behavior: the content is confidently low-detail by every
    /// absolute signal at this scale (see the smooth-field limitation in
    /// `BlurThresholds`). The rule fails if the verdict changes — that is the signal
    /// to recalibrate, not to celebrate.
    case pinnedLikelyBlurry

    func isSatisfied(by verdict: BlurVerdict) -> Bool {
        switch self {
        case .mustBeSharp:
            return verdict == .sharp
        case .mustBeLikelyBlurry, .pinnedLikelyBlurry:
            return verdict == .likelyBlurry
        case .mustBeBorderline:
            return verdict == .borderline
        case .mustBeInBlurryFamily:
            return verdict == .likelyBlurry || verdict == .borderline
        case .mustNotBeLikelyBlurry:
            return verdict != .likelyBlurry
        case .mustBeInsufficient:
            return verdict == .insufficientInformation
        }
    }
}

/// Labelled content classes. Every case is deterministic and drawn at "camera" sizes so
/// the delivery path (fit-box or fill-crop) has a real aspect ratio to work with.
enum BlurCorpusCategory: String, CaseIterable, Sendable {
    case sharpText
    case sharpChecker
    case sharpFoliage
    case sharpScene
    case defocusLight
    case defocusMid
    case defocusHeavy
    case motionBlur
    case softPortrait
    case smoothGradient
    case smoothFlat
    case darkNoise
    case darkScene
    case bokehWithSubject

    var expectation: BlurCorpusRule {
        switch self {
        case .sharpText, .sharpChecker, .sharpFoliage, .sharpScene:
            return .mustBeSharp
        case .defocusMid, .defocusHeavy:
            return .mustBeLikelyBlurry
        case .defocusLight, .motionBlur:
            return .mustBeInBlurryFamily
        case .softPortrait:
            return .mustBeBorderline
        case .smoothGradient:
            // Pinned limitation: a noise-free smooth field is confidently low-detail
            // by every absolute signal at this scale — see BlurThresholds.
            return .pinnedLikelyBlurry
        case .smoothFlat, .darkNoise, .darkScene, .bokehWithSubject:
            return .mustNotBeLikelyBlurry
        }
    }

    /// One deterministic source rendition for the given "camera" dimensions. Memoized:
    /// the suite regenerates the same renditions across several tests (and blur passes
    /// dominate generation cost), and Swift Testing may run tests in parallel.
    func source(width: Int, height: Int) -> CGImage {
        let key = "\(rawValue)-\(width)x\(height)"
        if let cached = corpusSourceCache.read()[key] { return cached }
        let image = makeSource(width: width, height: height)
        // Two parallel tests may both generate; content is deterministic so last write wins.
        corpusSourceCache.mutate { $0[key] = image }
        return image
    }

    private func makeSource(width: Int, height: Int) -> CGImage {
        switch self {
        case .sharpText:
            return corpusTextPage(width: width, height: height)
        case .sharpChecker:
            return corpusImage(width: width, height: height) { x, y in
                ((x / 4) + (y / 4)) % 2 == 0 ? 235 : 20
            }
        case .sharpFoliage:
            return corpusImage(width: width, height: height) { x, y in
                30 + Int(corpusHash(x / 3, y / 3) % 190)
            }
        case .sharpScene, .softPortrait, .darkScene, .bokehWithSubject:
            let scene = corpusScene(width: width, height: height)
            switch self {
            case .softPortrait:
                return blurTestBoxBlur(scene, radius: 3, passes: 1)
            case .darkScene:
                return corpusScaleBrightness(scene, factor: 0.25)
            case .bokehWithSubject:
                let blurred = blurTestBoxBlur(scene, radius: 12, passes: 2)
                return corpusCompositeCenter(
                    sharp: scene,
                    blurred: blurred,
                    innerWidthFraction: 0.4,
                    innerHeightFraction: 0.4
                )
            default:
                return scene
            }
        case .defocusLight:
            return blurTestBoxBlur(corpusScene(width: width, height: height), radius: 2, passes: 2)
        case .defocusMid:
            return blurTestBoxBlur(corpusScene(width: width, height: height), radius: 5, passes: 2)
        case .defocusHeavy:
            return blurTestBoxBlur(corpusScene(width: width, height: height), radius: 12, passes: 2)
        case .motionBlur:
            // Real camera shake is rarely axis-pure: horizontal streak plus a milder
            // vertical component, so both gradient axes lose energy like a real shake.
            let shaken = corpusMotionBlur(
                corpusScene(width: width, height: height),
                radius: 6
            )
            return corpusMotionBlurVertical(shaken, radius: 3)
        case .smoothGradient:
            return corpusImage(width: width, height: height) { x, _ in
                x * 255 / max(1, width - 1)
            }
        case .smoothFlat:
            return corpusImage(width: width, height: height) { _, _ in 128 }
        case .darkNoise:
            return corpusImage(width: width, height: height) { x, y in
                16 + Int(corpusHash(x, y) % 20)
            }
        }
    }
}

/// The two delivery paths the matrix compares. `verificationAspectFit` reproduces what
/// a `.verification`-style aspect-fit request hands the analyzer for a non-square asset
/// (aspect-fit into the 256² box → e.g. 256×192, which `measure` then upscales — the
/// pre-M7 false-positive path, kept as a baseline); `sharpnessAspectFill` is the native
/// center-crop the `.sharpness` mode requests — the production path after this fix.
enum CorpusDeliveryPath: String, CaseIterable, Sendable {
    case verificationAspectFit
    case sharpnessAspectFill
}

/// One measured row of the confusion matrix.
struct BlurCorpusRow: Sendable {
    let category: BlurCorpusCategory
    let sourceWidth: Int
    let sourceHeight: Int
    let path: CorpusDeliveryPath
    let verdict: BlurVerdict
    let score: BlurSharpnessScore
    let deliveredWidth: Int
    let deliveredHeight: Int
}

// MARK: - Matrix runner

/// Memoized corpus renditions (see `BlurCorpusCategory.source`).
let corpusSourceCache = LockedBox<[String: CGImage]>([:])

/// Test-process stdout does not surface in the xcodebuild console log; the calibration
/// record is also written to the test host's temporary directory (pulled out of the
/// simulator container after the run — see the performance report workflow).
func writeCorpusReport(_ text: String, name: String = "blur-corpus-report.txt") {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
    try? text.data(using: .utf8)?.write(to: url)
}

/// Generates every category at every source size, delivers through `path`, measures, and
/// classifies with `thresholds` — the exact production pipeline in miniature.
func runBlurCorpus(
    thresholds: BlurThresholds,
    path: CorpusDeliveryPath,
    sizes: [(width: Int, height: Int)] = [(640, 480), (480, 640), (512, 512)]
) throws -> [BlurCorpusRow] {
    var rows: [BlurCorpusRow] = []
    for category in BlurCorpusCategory.allCases {
        for (width, height) in sizes {
            let source = category.source(width: width, height: height)
            let delivered = try deliverForAnalysis(source, path: path)
            let score = try BlurSharpnessAnalyzer.measure(of: delivered)
            rows.append(BlurCorpusRow(
                category: category,
                sourceWidth: width,
                sourceHeight: height,
                path: path,
                verdict: thresholds.classify(score),
                score: score,
                deliveredWidth: delivered.width,
                deliveredHeight: delivered.height
            ))
        }
    }
    return rows
}

/// Human-readable confusion matrix: one line per (category, size) plus the rule verdict.
func blurCorpusMatrixReport(_ rows: [BlurCorpusRow]) -> String {
    var lines: [String] = []
    lines.append("blur-corpus matrix (\(rows.map(\.path.rawValue).first ?? "?"))")
    for category in BlurCorpusCategory.allCases {
        let categoryRows = rows.filter { $0.category == category }
        let verdicts = categoryRows.map { row in
            "\(row.sourceWidth)x\(row.sourceHeight)→\(row.verdict.rawValue)"
        }.joined(separator: " ")
        let failures = categoryRows.filter { !category.expectation.isSatisfied(by: $0.verdict) }
        let mark = failures.isEmpty ? "OK  " : "FAIL"
        lines.append(
            "  [\(mark)] \(category.rawValue.padding(toLength: 16, withPad: " ", startingAt: 0)) " +
            "expect=\(category.expectation.rawValue.padding(toLength: 20, withPad: " ", startingAt: 0)) " +
            "\(verdicts)"
        )
    }
    return lines.joined(separator: "\n")
}

/// Per-row metric dump — the calibration table thresholds are chosen from. One line per
/// (category, size): every raw signal next to the verdict the current thresholds produce.
func blurCorpusMetricsReport(_ rows: [BlurCorpusRow]) -> String {
    var lines: [String] = []
    lines.append(
        "blur-corpus metrics (\(rows.map(\.path.rawValue).first ?? "?"), " +
        "\(rows.map { "\($0.sourceWidth)x\($0.sourceHeight)" }.first ?? "?"))"
    )
    lines.append(
        "  category            size      lap        ten        p90        med        spike     luma   std    verdict"
    )
    for row in rows {
        let score = row.score
        lines.append(
            String(
                format: "  %-19@ %-9@ %-10.3e %-10.3e %-10.3e %-10.3e %-9.2f %.2f  %.3f  %@",
                row.category.rawValue as NSString,
                "\(row.sourceWidth)x\(row.sourceHeight)" as NSString,
                score.laplacianVariance,
                score.tenengradMean,
                score.gradientEnergyP90,
                score.gradientEnergyMedian,
                score.gradientEnergySpikiness,
                score.lumaMean,
                score.lumaStdDev,
                row.verdict.rawValue as NSString
            )
        )
    }
    return lines.joined(separator: "\n")
}

// MARK: - Acceptance tests

@MainActor
struct BlurCorpusTests {
    /// The evidence generator: prints the confusion matrix for both delivery paths under
    /// the shipped thresholds. Asserts only that every row was measured — the *rules* are
    /// enforced by `calibratedThresholdsMeetTheCorpusAcceptanceRules`. This is the
    /// calibration record every run reproduces; the performance report quotes it.
    @Test func corpusMatrixIsPrintedForBothDeliveryPaths() throws {
        var report = ""
        for path in CorpusDeliveryPath.allCases {
            let rows = try runBlurCorpus(thresholds: .corpusCalibrated, path: path)
            #expect(rows.count == BlurCorpusCategory.allCases.count * 3)
            report += blurCorpusMatrixReport(rows) + "\n"
            print(blurCorpusMatrixReport(rows))
        }
        writeCorpusReport(report)
    }

    /// Calibration table: the raw signals every threshold choice is justified from
    /// (one camera size — signals are size-stable after the fixed 256² analysis render).
    /// Written to the container temp dir for the calibration workflow; the performance
    /// report quotes these numbers.
    @Test func corpusMetricsTableIsPrinted() throws {
        let rows = try runBlurCorpus(
            thresholds: .corpusCalibrated,
            path: .sharpnessAspectFill
        )
        let report = blurCorpusMetricsReport(rows)
        writeCorpusReport(report, name: "blur-corpus-metrics.txt")
        print(report)
        #expect(rows.count == BlurCorpusCategory.allCases.count * 3)
    }

    /// The acceptance rule: with the shipped thresholds, every labelled category is
    /// classified the way its rule requires, through the production delivery path.
    @Test func calibratedThresholdsMeetTheCorpusAcceptanceRules() throws {
        let rows = try runBlurCorpus(
            thresholds: .corpusCalibrated,
            path: .sharpnessAspectFill
        )
        writeCorpusReport(blurCorpusMatrixReport(rows), name: "blur-corpus-acceptance.txt")
        let failures = rows.filter { !$0.category.expectation.isSatisfied(by: $0.verdict) }
        if !failures.isEmpty {
            Issue.record(
                "\(failures.count) corpus rows violated their category rule:\n\(blurCorpusMatrixReport(rows))"
            )
        }
        #expect(failures.isEmpty)
    }

    /// "Resizing must not flip a strong classification": the two strongest categories
    /// keep their verdict on both delivery paths and every source size. Borderline-band
    /// content is deliberately excluded — it is *defined* as path-sensitive.
    @Test func resizingDoesNotFlipStrongVerdicts() throws {
        for path in CorpusDeliveryPath.allCases {
            let rows = try runBlurCorpus(thresholds: .corpusCalibrated, path: path)
            for strong in [BlurCorpusCategory.sharpText, .defocusHeavy] {
                let verdicts = Set(rows.filter { $0.category == strong }.map(\.verdict))
                #expect(
                    verdicts == [strong.expectation == .mustBeSharp ? BlurVerdict.sharp : .likelyBlurry],
                    "\(strong.rawValue) on \(path.rawValue): \(verdicts)"
                )
            }
        }
    }

    /// Orientation must not flip a strong classification either: rotating the source 90°
    /// (portrait↔landscape) preserves the verdict of strong categories.
    @Test func rotationDoesNotFlipStrongVerdicts() throws {
        for category in [BlurCorpusCategory.sharpText, .defocusHeavy] {
            let source = category.source(width: 640, height: 480)
            let rotated = try #require(corpusRotate90(source))
            let uprightVerdict = BlurThresholds.corpusCalibrated.classify(
                try BlurSharpnessAnalyzer.measure(
                    of: deliverForAnalysis(source, path: .sharpnessAspectFill)
                )
            )
            let rotatedVerdict = BlurThresholds.corpusCalibrated.classify(
                try BlurSharpnessAnalyzer.measure(
                    of: deliverForAnalysis(rotated, path: .sharpnessAspectFill)
                )
            )
            #expect(uprightVerdict == rotatedVerdict, "\(category.rawValue)")
        }
    }
}

// MARK: - Delivery emulation

/// Emulates what the given request mode hands `measure` for a camera-sized source.
/// Both paths use the same high-quality interpolation the production render uses.
func deliverForAnalysis(
    _ image: CGImage,
    path: CorpusDeliveryPath,
    side: Int = BlurSharpnessAnalyzer.defaultAnalysisSide
) throws -> CGImage {
    let sourceWidth = CGFloat(image.width)
    let sourceHeight = CGFloat(image.height)
    let target: (width: Int, height: Int)
    let scale: CGFloat
    switch path {
    case .verificationAspectFit:
        // PhotoKit aspect-fit into the side×side box: longest side lands on `side`,
        // the other side keeps the source aspect (e.g. 256×192 for 4:3).
        scale = min(CGFloat(side) / sourceWidth, CGFloat(side) / sourceHeight)
        target = (
            max(1, Int((sourceWidth * scale).rounded())),
            max(1, Int((sourceHeight * scale).rounded()))
        )
    case .sharpnessAspectFill:
        scale = max(CGFloat(side) / sourceWidth, CGFloat(side) / sourceHeight)
        target = (side, side)
    }
    let width = target.width
    let height = target.height
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
        throw BlurSharpnessError.emptyImage
    }
    context.interpolationQuality = .high
    switch path {
    case .verificationAspectFit:
        context.draw(
            image,
            in: CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height))
        )
    case .sharpnessAspectFill:
        // Same aspect-fill geometry as `measure`: scale to cover, center, crop by clipping.
        let drawWidth = sourceWidth * scale
        let drawHeight = sourceHeight * scale
        context.draw(
            image,
            in: CGRect(
                x: (CGFloat(width) - drawWidth) / 2,
                y: (CGFloat(height) - drawHeight) / 2,
                width: drawWidth,
                height: drawHeight
            )
        )
    }
    let provider = CGDataProvider(data: Data(
        UnsafeBufferPointer(start: pixelBytes, count: width * height * 4)
    ) as CFData)!
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

// MARK: - Generators

/// Rectangular grayscale-in-RGBA canvas: `draw(x, y)` returns 0…255 gray. The square
/// `blurTestImage` in BlurSharpnessTests cannot express portrait/landscape sources.
func corpusImage(width: Int, height: Int, draw: (Int, Int) -> Int) -> CGImage {
    var buffer = [UInt8](repeating: 255, count: width * height * 4)
    for y in 0..<height {
        for x in 0..<width {
            let value = UInt8(max(0, min(255, draw(x, y))))
            let offset = (y * width + x) * 4
            buffer[offset] = value
            buffer[offset + 1] = value
            buffer[offset + 2] = value
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

/// Pure 2D hash — deterministic regardless of iteration order, so rectangle draws are
/// reproducible pixel for pixel.
func corpusHash(_ x: Int, _ y: Int) -> UInt32 {
    var h = UInt32(truncatingIfNeeded: x &* 3_747_613_93 &+ y &* 668_265_263)
    h = (h ^ (h >> 13)) &* 1_274_126_177
    return h ^ (h >> 16)
}

/// Document-like hard content: dashed text lines, a dark block, rules. High-frequency
/// edges at multiple orientations — the "sharp text" class every scanner must keep.
func corpusTextPage(width: Int, height: Int) -> CGImage {
    corpusImage(width: width, height: height) { x, y in
        var value = 232
        if (y % 14) < 2, y > height / 8, y < (height * 7) / 8, (x / 7) % 3 != 0 {
            value = 25
        }
        if y > height / 3, y < (height * 2) / 3, x > width / 8, x < width / 4 {
            value = 40
        }
        if (x % 41) < 1, y > height / 6, y < (height * 5) / 6 { value = 15 }
        return value
    }
}

/// The structured scene every defocus category is derived from (mirrors the proven
/// `blurTestScene` ingredients, in rectangle form).
func corpusScene(width: Int, height: Int) -> CGImage {
    corpusImage(width: width, height: height) { x, y in
        var value = 140 + (x * 70) / width
        if y > height / 3, y < (height * 2) / 3, x > width / 6, x < width / 2 { value = 30 }
        if (x % 19) < 2, y > (height * 2) / 3 { value = 245 }
        if (y % 15) < 2, x > width / 2 { value = 12 }
        if corpusHash(x, y) % 211 == 0 { value = 250 }
        return value
    }
}

/// Horizontal-only box blur — a cheap, deterministic stand-in for camera shake.
func corpusMotionBlur(_ image: CGImage, radius: Int) -> CGImage {
    let width = image.width
    let height = image.height
    let source = corpusRGBABytes(of: image)
    var destination = [UInt8](repeating: 0, count: source.count)
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
            destination[base + x * 4 + 3] = 255
        }
    }
    return corpusCGImage(from: destination, width: width, height: height)
}

/// Vertical-only box blur — the milder second axis of a camera-shake pair.
func corpusMotionBlurVertical(_ image: CGImage, radius: Int) -> CGImage {
    let width = image.width
    let height = image.height
    let source = corpusRGBABytes(of: image)
    var destination = [UInt8](repeating: 0, count: source.count)
    for x in 0..<width {
        for y in 0..<height {
            let low = max(0, y - radius)
            let high = min(height - 1, y + radius)
            let count = high - low + 1
            for channel in 0..<3 {
                var sum = 0
                for index in low...high {
                    sum += Int(source[(index * width + x) * 4 + channel])
                }
                destination[(y * width + x) * 4 + channel] = UInt8(sum / count)
            }
            destination[(y * width + x) * 4 + 3] = 255
        }
    }
    return corpusCGImage(from: destination, width: width, height: height)
}

/// Scales every channel by `factor` (0…1) — the dark-content class.
func corpusScaleBrightness(_ image: CGImage, factor: CGFloat) -> CGImage {
    let width = image.width
    let height = image.height
    var bytes = corpusRGBABytes(of: image)
    for index in stride(from: 0, to: bytes.count, by: 4) {
        for channel in 0..<3 {
            bytes[index + channel] = UInt8(CGFloat(bytes[index + channel]) * factor)
        }
    }
    return corpusCGImage(from: bytes, width: width, height: height)
}

/// Hard-edged center composite: the inner rectangle keeps `sharp`, the surround is
/// `blurred` — a sharp subject in front of a defocused background.
func corpusCompositeCenter(
    sharp: CGImage,
    blurred: CGImage,
    innerWidthFraction: Double,
    innerHeightFraction: Double
) -> CGImage {
    let width = sharp.width
    let height = sharp.height
    let sharpBytes = corpusRGBABytes(of: sharp)
    let blurredBytes = corpusRGBABytes(of: blurred)
    let innerW = Int(CGFloat(width) * innerWidthFraction)
    let innerH = Int(CGFloat(height) * innerHeightFraction)
    let x0 = (width - innerW) / 2
    let y0 = (height - innerH) / 2
    var out = [UInt8](repeating: 0, count: sharpBytes.count)
    for y in 0..<height {
        for x in 0..<width {
            let offset = (y * width + x) * 4
            let inside = x >= x0 && x < x0 + innerW && y >= y0 && y < y0 + innerH
            let bytes = inside ? sharpBytes : blurredBytes
            for channel in 0..<4 { out[offset + channel] = bytes[offset + channel] }
        }
    }
    return corpusCGImage(from: out, width: width, height: height)
}

/// Rotates 90° clockwise (portrait↔landscape with transposed content).
func corpusRotate90(_ image: CGImage) -> CGImage? {
    let width = image.width
    let height = image.height
    let source = corpusRGBABytes(of: image)
    var out = [UInt8](repeating: 0, count: source.count)
    for y in 0..<height {
        for x in 0..<width {
            let src = (y * width + x) * 4
            let dstX = height - 1 - y
            let dstY = x
            let dst = (dstY * height + dstX) * 4
            for channel in 0..<4 { out[dst + channel] = source[src + channel] }
        }
    }
    return corpusCGImage(from: out, width: height, height: width)
}

private func corpusRGBABytes(of image: CGImage) -> [UInt8] {
    let width = image.width
    let height = image.height
    var bytes = [UInt8](repeating: 0, count: width * height * 4)
    guard let context = CGContext(
        data: &bytes,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: width * 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
    ) else {
        return bytes
    }
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    return bytes
}

private func corpusCGImage(from bytes: [UInt8], width: Int, height: Int) -> CGImage {
    let provider = CGDataProvider(data: Data(bytes) as CFData)!
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

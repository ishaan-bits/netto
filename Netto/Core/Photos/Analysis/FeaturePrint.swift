import CoreGraphics
import Foundation

/// Descriptor family behind a `FeaturePrint`.
///
/// Distances are only meaningful between prints of the same kind, which is why `distance(to:)`
/// refuses to mix them: the two families have different vector lengths and different calibration
/// scales, and silently comparing them would produce garbage groups.
enum FeaturePrintKind: String, Sendable, Equatable, CaseIterable {
    /// `VNGenerateImageFeaturePrintRequest` output (768 float32 elements, L2 distance). The
    /// production path on real hardware: learned features, robust to re-encodes and crops.
    case visionFeaturePrint
    /// CPU-drawn 16×16 RGB grid, mean-centered per channel with a color-bias tail, L2-normalized.
    /// Used whenever Vision's inference stack is unavailable — notably the iOS Simulator, where
    /// `VNGenerateImageFeaturePrintRequest` fails with "Failed to create espresso context."
    case cpuGrid
}

extension FeaturePrintKind {
    /// Provisional L2 thresholds per family. Neither number is a claim about real-world quality:
    /// they are calibrated against synthetic images in tests and explicitly flagged for
    /// recalibration on a real iPhone with a real library (device validation item).
    var defaultSimilarityThreshold: Float {
        switch self {
        case .visionFeaturePrint:
            // Synthetic calibration: identical 0.0, moderate brightness shift ≈0.05, unrelated
            // ≈0.55. 0.2 sits well between "same picture, re-encoded" and "different picture".
            return 0.2
        case .cpuGrid:
            // Calibrated in FeaturePrintTests against measured synthetic distances.
            return 0.15
        }
    }
}

/// A fixed-length float vector describing one thumbnail.
///
/// Holds only derived data (a few KB of floats) — never pixel bytes, never a `CGImage` — so
/// prints can be kept for a bounded bucket and discarded immediately afterwards.
struct FeaturePrint: Sendable, Equatable {
    let kind: FeaturePrintKind
    let values: [Float]

    enum FeaturePrintError: Error, Sendable, Equatable {
        case kindMismatch(FeaturePrintKind, FeaturePrintKind)
        case lengthMismatch(Int, Int)
        case empty
    }

    /// Euclidean L2 distance — exactly the metric `VNFeaturePrintObservation.computeDistance`
    /// uses (verified against Vision on macOS: vision distance == self-computed L2 to Float
    /// precision), so both descriptor families share one grouping code path.
    func distance(to other: FeaturePrint) throws -> Float {
        guard kind == other.kind else {
            throw FeaturePrintError.kindMismatch(kind, other.kind)
        }
        guard values.count == other.values.count else {
            throw FeaturePrintError.lengthMismatch(values.count, other.values.count)
        }
        guard !values.isEmpty else { throw FeaturePrintError.empty }

        var sum: Float = 0
        for index in values.indices {
            let delta = values[index] - other.values[index]
            sum += delta * delta
        }
        return Float(sqrt(Double(sum)))
    }
}

/// The CPU descriptor. Pure CoreGraphics, no Vision, no UIKit — which is what makes near-duplicate
/// detection testable and functional in environments where Vision's inference stack is missing.
///
/// Construction, step by step:
/// 1. Draw the thumbnail into a 16×16 RGB grid (`.scaleFill`, matching Vision's default
///    `imageCropAndScaleOption`, so both families see the same geometry).
/// 2. Mean-center each channel — makes the descriptor invariant to uniform brightness shifts.
/// 3. Append the three channel means at half weight — restores color identity that step 2 would
///    erase, so a solid red image and a solid blue image stay maximally distant.
/// 4. L2-normalize the whole vector — makes it invariant to uniform contrast scaling.
///
/// Cost is one 256-pixel draw plus 771 float ops per thumbnail: microseconds, on one worker.
enum CPUFeatureDescriptor {
    static let gridSize = 16

    static func make(from image: CGImage) throws -> FeaturePrint {
        let grid = try drawGrid(from: image)
        guard !grid.isEmpty else { throw FeaturePrint.FeaturePrintError.empty }

        let channels = 3
        let pixelsPerChannel = grid.count / channels
        guard pixelsPerChannel > 0, grid.count % channels == 0 else {
            throw FeaturePrint.FeaturePrintError.empty
        }

        var values: [Float] = []
        values.reserveCapacity(grid.count + channels)

        for channel in 0..<channels {
            var samples: [Float] = []
            samples.reserveCapacity(pixelsPerChannel)
            for pixel in 0..<pixelsPerChannel {
                samples.append(grid[pixel * channels + channel])
            }
            let mean = samples.reduce(0, +) / Float(pixelsPerChannel)
            for sample in samples {
                values.append(sample - mean)
            }
        }

        for channel in 0..<channels {
            var sum: Float = 0
            for pixel in 0..<pixelsPerChannel {
                sum += grid[pixel * channels + channel]
            }
            let mean = sum / Float(pixelsPerChannel)
            values.append(mean * 0.5)
        }

        let norm = sqrt(values.reduce(0) { $0 + $1 * $1 })
        guard norm > 0 else {
            // Degenerate (all-zero) vector: keep it canonical rather than dividing by zero.
            return FeaturePrint(kind: .cpuGrid, values: values)
        }
        let normalized = values.map { $0 / norm }
        return FeaturePrint(kind: .cpuGrid, values: normalized)
    }

    /// Draws into a 16×16 premultiplied RGBA buffer and returns interleaved RGB floats in 0...1.
    private static func drawGrid(from image: CGImage) throws -> [Float] {
        let size = gridSize
        var buffer = [UInt8](repeating: 0, count: size * size * 4)
        let drawn: Bool = buffer.withUnsafeMutableBytes { raw in
            guard let context = CGContext(
                data: raw.baseAddress,
                width: size,
                height: size,
                bitsPerComponent: 8,
                bytesPerRow: size * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else {
                return false
            }
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: 0, y: 0, width: size, height: size))
            return true
        }
        guard drawn else { throw FeaturePrint.FeaturePrintError.empty }

        var rgb: [Float] = []
        rgb.reserveCapacity(size * size * 3)
        for pixel in 0..<(size * size) {
            let base = pixel * 4
            rgb.append(Float(buffer[base]) / 255)
            rgb.append(Float(buffer[base + 1]) / 255)
            rgb.append(Float(buffer[base + 2]) / 255)
        }
        return rgb
    }
}

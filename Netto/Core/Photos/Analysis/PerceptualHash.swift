import CoreGraphics
import Foundation

/// 64-bit difference hash (dHash) of a thumbnail: perceptually similar images produce
/// nearby hashes, so a cheap XOR/`nonzeroBitCount` replaces an expensive descriptor
/// comparison for the *candidate filter*.
///
/// Why dHash and not the descriptor itself: this is the cheap-first gate. It runs on a
/// 9×8 luminance reduction of a small (96 px) thumbnail — no Vision session, no grid
/// descriptor, a few hundred nanoseconds per asset — and is only allowed to say "these
/// two are worth a real comparison". False positives are fine (the descriptor decides);
/// false negatives cost a missed candidate pair, which is why the engine keeps the
/// hamming tolerance deliberately generous (see `perceptualCandidateMaxHamming`).
///
/// Pairwise hamming distance is invariant under any transform applied to *both* images
/// (including a possible vertical flip in the bitmap context), so orientation handling
/// stays with the thumbnail loader exactly as it does for descriptors.
struct PerceptualHash: Sendable, Equatable {
    let bits: UInt64

    /// Bits that differ — the number of 9×8 cells whose brightness relation flipped.
    func distance(to other: PerceptualHash) -> Int {
        (bits ^ other.bits).nonzeroBitCount
    }
}

enum PerceptualHasher {
    /// Reduction grid: 8 comparison columns need 9 sample columns (adjacent pairs).
    static let width = 9
    static let height = 8

    /// Draws `image` into a 9×8 grayscale buffer and sets bit `row * 8 + column` when the
    /// cell is brighter than its right neighbour. Solid images produce all-zero hashes —
    /// identical images produce identical hashes, which is what lets the engine treat
    /// hamming-0 pairs as exact-duplicate candidates worth a content check.
    static func hash(of image: CGImage) throws -> PerceptualHash {
        guard image.width > 0, image.height > 0 else { throw FeaturePrint.FeaturePrintError.empty }
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else {
            throw FeaturePrint.FeaturePrintError.empty
        }
        context.interpolationQuality = .low
        context.draw(
            image,
            in: CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height))
        )
        guard let data = context.data else { throw FeaturePrint.FeaturePrintError.empty }
        let pixels = data.bindMemory(to: UInt8.self, capacity: width * height)

        var bits: UInt64 = 0
        for row in 0..<height {
            for column in 0..<(width - 1) {
                if pixels[row * width + column] < pixels[row * width + column + 1] {
                    bits |= UInt64(1) << UInt64(row * (width - 1) + column)
                }
            }
        }
        return PerceptualHash(bits: bits)
    }
}

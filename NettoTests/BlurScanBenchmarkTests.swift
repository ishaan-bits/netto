import Photos
import Testing
import UIKit
@testable import Netto

/// Seeded-simulator performance benchmark for the sharpness pass — the honest
/// before/after of the M7 render-path fix, measured on real PhotoKit requests over a
/// seeded library (1 000 synthetic photos). Not a classification-accuracy claim: the
/// labelled corpus (`BlurCorpusTests`) owns accuracy; this suite owns wall time and
/// stage breakdown.
///
/// Self-skips on an unseeded simulator (< 100 photos). Seed with:
/// `xcrun simctl addmedia booted <files>` + `xcrun simctl privacy booted grant photos
/// com.ishaanparimal.netto`. Run with the suite filter; the report is written to the
/// host container's tmp (`blur-benchmark.txt`) and printed.
struct BlurScanBenchmarkTests {
    /// Fetches up to 1 000 real image assets from the simulator library as records,
    /// newest first (self-seeded locals sort ahead of older placeholder imports).
    /// Skips the suite when the library is essentially empty after self-seeding.
    private func seededRecords(limit: Int = 1_000) throws -> [PhotoAssetRecord] {
        let options = PHFetchOptions()
        options.fetchLimit = limit
        options.predicate = NSPredicate(format: "mediaType == %d", PHAssetMediaType.image.rawValue)
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        let result = PHAsset.fetchAssets(with: options)
        var records: [PhotoAssetRecord] = []
        records.reserveCapacity(result.count)
        result.enumerateObjects { asset, _, _ in
            records.append(PhotoAssetRecord(
                localIdentifier: asset.localIdentifier,
                mediaType: .image,
                mediaSubtypes: [],
                pixelWidth: asset.pixelWidth,
                pixelHeight: asset.pixelHeight,
                creationDate: asset.creationDate,
                modificationDate: nil,
                duration: 0,
                isFavorite: false,
                isHidden: false,
                sourceType: .library,
                hasAdjustments: false,
                representsBurst: false,
                burstIdentifier: nil
            ))
        }
        return records
    }

    /// Creates `count` local images through PhotoKit itself — the only seeding path
    /// that guarantees locally-available renditions. (`simctl addmedia` imports land
    /// as cloud placeholders on this simulator: `PHPhotosErrorDomain:3164`, measured
    /// 792/1000 cloud-misses with network disabled.) One batched change request; runs
    /// only once per seeded library — later runs fetch instead of reseeding.
    private func selfSeed(count: Int) async throws {
        try await PHPhotoLibrary.shared().performChanges {
            for index in 0..<count {
                // Distinct creation timestamps so the newest-first fetch is stable.
                let image = Self.seedImage(index: index)
                let request = PHAssetChangeRequest.creationRequestForAsset(from: UIImage(cgImage: image))
                request.creationDate = Date(timeIntervalSince1970: 1_700_000_000 + Double(index))
            }
        }
    }

    /// Small distinct synthetic images (gradient + grid + stripes), raw-rgba fast path.
    private static func seedImage(index: Int) -> CGImage {
        let width = [640, 480, 800, 600, 1024, 300][index % 6]
        let height = [480, 640, 600, 800, 768, 300][index % 6]
        var state = UInt64(bitPattern: Int64(index)) &* 6364136223846793005 &+ 1442695040888963407
        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                state = state &* 6364136223846793005 &+ 1442695040888963407
                let noise = Int(state >> 33) % 24
                var r = (x * 200 / max(1, width - 1)) + noise
                let g = (y * 180 / max(1, height - 1)) + noise
                var b = ((x + y) * 120 / max(1, width + height - 2)) + noise
                if (x / 16 + y / 16) % 2 == 0 { r = 255 - r / 2 }
                if (y % 23) < 2 { b = 250 }
                let o = (y * width + x) * 4
                rgba[o] = UInt8(min(255, max(0, r)))
                rgba[o + 1] = UInt8(min(255, max(0, g)))
                rgba[o + 2] = UInt8(min(255, max(0, b)))
                rgba[o + 3] = 255
            }
        }
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let context = CGContext(
            data: &rgba, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width * 4, space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        return context.makeImage()!
    }

    @Test func seededLibraryBeforeAfterBenchmark() async throws {
        var records = try seededRecords()
        // A fetchable record is not a usable one: `simctl addmedia` placeholders return
        // metadata but no local rendition. Probe the newest asset; when its pixels are
        // unavailable, reseed through PhotoKit so every benchmark request is local.
        if let probeID = records.first?.localIdentifier {
            let probe = PhotoKitThumbnailLoader()
            let usable = (try? await probe.thumbnail(for: probeID, targetPixelSize: 96, mode: .perceptual)) != nil
            if !usable {
                try await selfSeed(count: 1_000)
                records = try seededRecords()
            }
        }
        try #require(
            records.count >= 100,
            "could not seed the simulator library (found \(records.count) usable photos)"
        )

        // BEFORE: the pre-M7 delivery path — the engine still requests `.sharpness`,
        // but the loader rewrites it to `.verification` (aspect-fit), reproducing the
        // analyzer-side upscale the thresholds used to be calibrated against.
        let beforeMetrics = BlurAnalysisMetrics()
        let beforeEngine = BlurAnalysisEngine(
            thumbnailLoader: ModeForcingLoader(base: PhotoKitThumbnailLoader(), forced: .verification),
            metrics: beforeMetrics
        )
        let beforeStart = DispatchTime.now().uptimeNanoseconds
        let beforeResult = try await beforeEngine.analyze(records: records)
        let beforeWall = Double(DispatchTime.now().uptimeNanoseconds - beforeStart) / 1_000_000_000

        // AFTER: the production path — `.sharpness` (aspect-fill exact 256²), the
        // corpus-calibrated thresholds, the multi-metric analyzer.
        let afterMetrics = BlurAnalysisMetrics()
        let afterEngine = BlurAnalysisEngine(
            thumbnailLoader: PhotoKitThumbnailLoader(),
            metrics: afterMetrics
        )
        let afterStart = DispatchTime.now().uptimeNanoseconds
        let afterResult = try await afterEngine.analyze(records: records)
        let afterWall = Double(DispatchTime.now().uptimeNanoseconds - afterStart) / 1_000_000_000

        let report = Self.formatReport(
            assetCount: records.count,
            before: (beforeWall, beforeMetrics.snapshot(), beforeResult),
            after: (afterWall, afterMetrics.snapshot(), afterResult)
        )
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("blur-benchmark.txt")
        try report.write(to: url, atomically: true, encoding: .utf8)
        print(report)

        // Sanity, not timing assertions (simulator timing is noisy by design): both
        // runs must have judged every image one way or another, and neither may time
        // out a single request on a fully-local seeded library.
        for (wall, snapshot, result) in [(beforeWall, beforeMetrics.snapshot(), beforeResult),
                                         (afterWall, afterMetrics.snapshot(), afterResult)] {
            #expect(wall > 0)
            #expect(result.judgedCount + result.notJudgedCount == records.count)
            #expect(snapshot.counters[.requestsTimedOut, default: 0] == 0)
        }
    }

    private static func formatReport(
        assetCount: Int,
        before: (wall: Double, snapshot: BlurAnalysisMetrics.Snapshot, result: BlurAnalysisResult),
        after: (wall: Double, snapshot: BlurAnalysisMetrics.Snapshot, result: BlurAnalysisResult)
    ) -> String {
        func breakdown(_ entries: [String: Int]) -> String {
            entries.isEmpty
                ? "-"
                : entries.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
                    .map { "\($0.key):\($0.value)" }
                    .joined(separator: ",")
        }
        func line(_ label: String, _ run: (wall: Double, snapshot: BlurAnalysisMetrics.Snapshot, result: BlurAnalysisResult)) -> String {
            let s = run.snapshot
            func seconds(_ d: BlurAnalysisMetrics.Duration) -> String {
                String(format: "%.3f", s.durations[d] ?? 0)
            }
            func count(_ c: BlurAnalysisMetrics.Counter) -> Int { s.counters[c] ?? 0 }
            return """
            [\(label)] assets=\(assetCount) wall=\(String(format: "%.2f", run.wall))s \
            request=\(seconds(.request))s measure=\(seconds(.measure))s \
            classify=\(seconds(.classify))s engineTotal=\(seconds(.total))s \
            ok=\(count(.requestsSucceeded)) fail=\(count(.requestsFailed)) \
            belowBudget=\(count(.renditionsBelowBudget)) \
            sharp=\(count(.judgedSharp)) borderline=\(count(.judgedBorderline)) \
            likely=\(count(.judgedLikelyBlurry)) insufficient=\(count(.judgedInsufficient)) \
            ticks=\(count(.progressTicks)) width=\(count(.workerWidth))
            reasons=\(breakdown(s.reasons)) failCodes=\(breakdown(s.failCodes))
            """
        }
        return """
        blur-scan benchmark (simulator, local-only PhotoKit)
        \(line("BEFORE", before))
        \(line("AFTER ", after))
        """
    }
}

/// Delivers every request in one forced mode — the test-side seam that reproduces the
/// pre-M7 render path without touching production code.
private struct ModeForcingLoader: PhotoThumbnailLoading {
    let base: any PhotoThumbnailLoading
    let forced: PhotoThumbnailRequestMode

    func thumbnail(
        for assetID: String,
        targetPixelSize: Int,
        mode: PhotoThumbnailRequestMode
    ) async throws -> CGImage {
        try await base.thumbnail(for: assetID, targetPixelSize: targetPixelSize, mode: forced)
    }
}

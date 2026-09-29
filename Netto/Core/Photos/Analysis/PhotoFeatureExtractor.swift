import CoreGraphics
import Foundation
import Vision

/// Turns a thumbnail into a `FeaturePrint`. Seams exists because Vision's inference stack is an
/// external system: tests inject deterministic fakes, and the live implementation adapts to
/// whether Vision actually works on the current device/simulator.
protocol PhotoFeatureExtracting: Sendable {
    /// Probes the backend once and latches `kind` for the whole run. Called by the engine before
    /// the first extraction so `kind` (and therefore the threshold) is known up front.
    func prepare() async

    /// Descriptor family this extractor will produce after `prepare()`.
    var kind: FeaturePrintKind { get }

    /// Extracts a print for one thumbnail. Throws only on per-asset failure; cancellation is
    /// observed by the caller through `Task.checkCancellation()` around the call.
    func featurePrint(for thumbnail: CGImage) async throws -> FeaturePrint
}

enum FeatureExtractionError: Error, Sendable, Equatable {
    case backendUnavailable
    case invalidImage
}

/// Live extractor: Vision on hardware that supports it, CPU grid everywhere else.
///
/// Simulator reality (verified by probe): `VNGenerateImageFeaturePrintRequest` fails with
/// `NSOSStatusErrorDomain -1 "Failed to create espresso context."` and face detection fails with
/// `com.apple.Vision 9 "Could not create inference context"` — Vision's *inference* stack is
/// unavailable in this environment while geometric requests still run. So the engine never
/// assumes Vision works: `prepare()` runs one tiny throwaway feature print, latches the outcome,
/// and every subsequent call uses that backend for the entire run — one descriptor family per
/// run, so distances inside a run are always comparable.
struct VisionPhotoFeatureExtractor: PhotoFeatureExtracting {
    private let state = State()

    func prepare() async {
        state.prepare { image in
            try Self.runVision(on: image)
        }
    }

    var kind: FeaturePrintKind { state.kind }

    func featurePrint(for thumbnail: CGImage) async throws -> FeaturePrint {
        switch state.kind {
        case .visionFeaturePrint:
            do {
                return try Self.runVision(on: thumbnail)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // Vision answered the warm-up probe but failed on this asset: report the asset,
                // never the whole run.
                throw FeatureExtractionError.backendUnavailable
            }
        case .cpuGrid:
            guard let print = try? CPUFeatureDescriptor.make(from: thumbnail) else {
                throw FeatureExtractionError.invalidImage
            }
            return print
        }
    }

    private static func runVision(on image: CGImage) throws -> FeaturePrint {
        try Task.checkCancellation()
        let request = VNGenerateImageFeaturePrintRequest()
        request.revision = VNGenerateImageFeaturePrintRequestRevision2
        request.imageCropAndScaleOption = .scaleFill
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        try handler.perform([request])
        guard let observation = request.results?.first else {
            throw FeatureExtractionError.backendUnavailable
        }
        guard observation.elementType == .float else {
            throw FeatureExtractionError.backendUnavailable
        }
        let count = observation.elementCount
        let data = observation.data
        guard count > 0, data.count >= count * MemoryLayout<Float>.size else {
            throw FeatureExtractionError.backendUnavailable
        }
        let values: [Float] = data.withUnsafeBytes { raw in
            (0..<count).map { index in
                raw.loadUnaligned(
                    fromByteOffset: index * MemoryLayout<Float>.size,
                    as: Float.self
                )
            }
        }
        guard values.count == count else {
            throw FeatureExtractionError.backendUnavailable
        }
        return FeaturePrint(kind: .visionFeaturePrint, values: values)
    }
}

/// Latches the probe result exactly once so every asset in a run uses the same backend.
/// `@unchecked Sendable` because all mutable state is guarded by `lock`.
private final class State: @unchecked Sendable {
    private let lock = NSLock()
    private var probed = false
    private var storedKind: FeaturePrintKind = .cpuGrid

    var kind: FeaturePrintKind {
        lock.lock()
        defer { lock.unlock() }
        return storedKind
    }

    func prepare(probe: (CGImage) throws -> FeaturePrint) {
        lock.lock()
        guard !probed else {
            lock.unlock()
            return
        }
        probed = true
        lock.unlock()

        let candidate: FeaturePrintKind
        if Task.isCancelled {
            candidate = .cpuGrid
        } else if let image = Self.probeImage(), (try? probe(image)) != nil {
            candidate = .visionFeaturePrint
        } else {
            candidate = .cpuGrid
        }

        lock.lock()
        storedKind = candidate
        lock.unlock()
    }

    /// A tiny synthetic image: enough for Vision to accept the request when its stack works.
    private static func probeImage() -> CGImage? {
        let width = 8
        let height = 8
        var buffer = [UInt8](repeating: 128, count: width * height * 4)
        for index in stride(from: 0, to: buffer.count, by: 4) {
            buffer[index] = 200
            buffer[index + 1] = 90
            buffer[index + 2] = 40
            buffer[index + 3] = 255
        }
        guard let provider = CGDataProvider(data: Data(buffer) as CFData) else { return nil }
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
        )
    }
}

import Foundation
import SwiftUI
import Testing
import UIKit
import WidgetKit
@testable import Netto

// MARK: - Provider: entries, placeholder, and the timeline policy

struct NettoWidgetProviderTests {
    @Test func placeholderIsARealScanReadyStatusWithNoFigure() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let entry = NettoWidgetProvider.placeholderEntry(now: now)

        #expect(entry.date == now)
        // The gallery preview must not manufacture a number before the app has written
        // anything: a status, its copy, and no figure at all. The headline carries no
        // digits; the detail is the day-labelled status line (the day label may itself
        // contain the date's digits, which is copy — never a byte figure).
        #expect(entry.model.figure == .none)
        #expect(entry.model.caption.isEmpty)
        #expect(!entry.model.isStale)
        #expect(containsAnyDigit(entry.model.headline) == false)
        #expect(entry.model.detail.hasPrefix("Last scan "))
    }

    @Test func entryMapsTheSummaryAndDateExactlyOnce() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let entry = NettoWidgetProvider.entry(for: nil, now: now)

        #expect(entry.date == now)
        #expect(entry.model == WidgetSummaryPresentation.model(for: nil, now: now))
    }

    @Test func timelineCarriesExactlyTheGivenEntryAndRefreshesAnHourLater() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let entry = NettoWidgetProvider.entry(for: nil, now: now)
        let timeline = NettoWidgetProvider.timeline(entries: [entry], now: now)

        #expect(timeline.entries.count == 1)
        #expect(timeline.entries[0].date == now)
        #expect(timeline.policy == .after(now.addingTimeInterval(NettoWidgetProvider.reloadInterval)))
        #expect(NettoWidgetProvider.reloadInterval == 60 * 60)
    }

    @Test func aStoredCleanupSummaryBecomesTheFigureEntryTheTimelineWouldRender() async throws {
        // The exact path getTimeline uses: real file store → load → entry(for:). A
        // measured cleanup written by the app must arrive as the labelled estimate.
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("netto-widget-provider-tests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = FileWidgetSummaryStore(directoryOverride: directory, onReload: {})
        let updatedAt = Date(timeIntervalSince1970: 1_700_000_000)
        try await store.save(try #require(WidgetSummary(
            schemaVersion: WidgetSummary.currentSchemaVersion,
            status: .lastCleanup,
            estimateBytes: 2_500_000_000,
            isEstimated: true,
            updatedAt: updatedAt
        )))

        let loaded = await store.load()
        let entry = NettoWidgetProvider.entry(for: loaded, now: updatedAt)

        #expect(entry.model.figure == .bytes(2_500_000_000))
        #expect(entry.model.caption == "Estimated space cleaned")
        #expect(!entry.model.isStale)
    }

    @Test func aMissingFileBecomesTheEmptyStateEntry() async {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("netto-widget-provider-empty-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = FileWidgetSummaryStore(directoryOverride: directory, onReload: {})

        let loaded = await store.load()
        let entry = NettoWidgetProvider.entry(for: loaded, now: Date())

        #expect(loaded == nil)
        #expect(entry.model == WidgetSummaryPresentation.model(for: nil, now: entry.date))
        #expect(entry.model.figure == .none)
    }

    private func containsAnyDigit(_ text: String) -> Bool {
        text.contains { $0.isNumber }
    }
}

// MARK: - Rendering: the real entry view must put real pixels on screen, in every state

/// Renders `NettoWidgetEntryView` — the exact view the widget configuration installs —
/// to a bitmap with `ImageRenderer` and asserts it is not blank. WidgetKit itself cannot
/// run in a unit test, but the failure this guards ("the widget shows an empty box")
/// is a property of the view's pixels, which are fully determined by the entry model.
@MainActor
struct NettoWidgetRenderingTests {
    // System family point sizes on a modern iPhone.
    private let smallSize = CGSize(width: 155, height: 155)
    private let mediumSize = CGSize(width: 329, height: 157)

    /// Every model the provider can produce (plus its stale variants — the styling
    /// branch changes with staleness, so both must be proven visible).
    private func allModels(now: Date) -> [WidgetDisplayModel] {
        let fresh = now
        let staleDate = now.addingTimeInterval(-WidgetSummary.staleAfter - 1)
        return [
            WidgetSummaryPresentation.model(for: nil, now: fresh),
            WidgetSummaryPresentation.model(for: scanReady(at: staleDate), now: fresh),
            WidgetSummaryPresentation.model(for: cleanup(bytes: 2_500_000_000, at: fresh), now: fresh),
            WidgetSummaryPresentation.model(for: cleanup(bytes: 999_000_000, at: staleDate), now: fresh),
        ]
    }

    @Test func smallFamilyRendersVisiblePixelsForEveryState() {
        let now = Date()
        for model in allModels(now: now) {
            let image = render(family: .systemSmall, model: model, size: smallSize)
            let ink = opaquePixelCount(in: image)
            #expect(ink > 50, "systemSmall rendered blank for \"\(model.headline)\"")
        }
    }

    @Test func mediumFamilyRendersVisiblePixelsForEveryState() {
        let now = Date()
        for model in allModels(now: now) {
            let image = render(family: .systemMedium, model: model, size: mediumSize)
            let ink = opaquePixelCount(in: image)
            #expect(ink > 50, "systemMedium rendered blank for \"\(model.headline)\"")
        }
    }

    @Test func theRenderedPixelsActuallyFollowTheModel() {
        // The view must draw the model, not something static: the empty state and the
        // figure state must produce different pixel buffers.
        let now = Date()
        let empty = WidgetSummaryPresentation.model(for: nil, now: now)
        let figure = WidgetSummaryPresentation.model(
            for: cleanup(bytes: 2_500_000_000, at: now), now: now
        )
        let emptyPixels = pixelBuffer(family: .systemSmall, model: empty, size: smallSize)
        let figurePixels = pixelBuffer(family: .systemSmall, model: figure, size: smallSize)

        #expect(emptyPixels != figurePixels)
    }

    // MARK: Fixtures

    private func scanReady(at date: Date) -> WidgetSummary {
        WidgetSummary(
            schemaVersion: WidgetSummary.currentSchemaVersion,
            status: .scanReady,
            estimateBytes: nil,
            isEstimated: false,
            updatedAt: date
        )!
    }

    private func cleanup(bytes: Int64, at date: Date) -> WidgetSummary {
        WidgetSummary(
            schemaVersion: WidgetSummary.currentSchemaVersion,
            status: .lastCleanup,
            estimateBytes: bytes,
            isEstimated: true,
            updatedAt: date
        )!
    }

    // MARK: Rendering helpers

    private func render(
        family: WidgetFamily,
        model: WidgetDisplayModel,
        size: CGSize
    ) -> UIImage {
        let entry = NettoWidgetEntry(date: Date(), model: model)
        let view = NettoWidgetEntryView(entry: entry)
            .content(for: family)
            .frame(width: size.width, height: size.height)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 1
        guard let image = renderer.uiImage else {
            Issue.record("ImageRenderer produced no image for \(family) \"\(model.headline)\"")
            return UIImage()
        }
        return image
    }

    private func pixelBuffer(
        family: WidgetFamily,
        model: WidgetDisplayModel,
        size: CGSize
    ) -> [UInt8] {
        let image = render(family: family, model: model, size: size)
        guard let cgImage = image.cgImage else { return [] }
        var pixels = [UInt8](repeating: 0, count: cgImage.width * cgImage.height * 4)
        guard let context = CGContext(
            data: &pixels,
            width: cgImage.width,
            height: cgImage.height,
            bitsPerComponent: 8,
            bytesPerRow: cgImage.width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return [] }
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: cgImage.width, height: cgImage.height))
        return pixels
    }

    /// Counts pixels with meaningful alpha in a normalized RGBA buffer. "Blank widget"
    /// means zero (or near-zero) ink: every state draws text, so a healthy render is
    /// well above this floor even at scale 1.
    private func opaquePixelCount(in image: UIImage) -> Int {
        guard let cgImage = image.cgImage else { return 0 }
        var pixels = [UInt8](repeating: 0, count: cgImage.width * cgImage.height * 4)
        guard let context = CGContext(
            data: &pixels,
            width: cgImage.width,
            height: cgImage.height,
            bitsPerComponent: 8,
            bytesPerRow: cgImage.width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return 0 }
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: cgImage.width, height: cgImage.height))
        var count = 0
        for index in stride(from: 3, to: pixels.count, by: 4) where pixels[index] > 8 {
            count += 1
        }
        return count
    }
}

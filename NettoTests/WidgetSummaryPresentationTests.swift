import Foundation
import Testing
@testable import Netto

// MARK: - What the widget is allowed to render, given a summary and the current date

struct WidgetSummaryPresentationTests {
    private let now = Date(timeIntervalSince1970: 1_760_000_000)

    private func summary(
        status: WidgetSummary.Status,
        estimateBytes: Int64? = nil,
        isEstimated: Bool = false,
        updatedAt: Date? = nil
    ) throws -> WidgetSummary {
        try #require(WidgetSummary(
            schemaVersion: WidgetSummary.currentSchemaVersion,
            status: status,
            estimateBytes: estimateBytes,
            isEstimated: isEstimated,
            updatedAt: updatedAt ?? now.addingTimeInterval(-3600)
        ))
    }

    private func model(_ summary: WidgetSummary?) -> WidgetDisplayModel {
        WidgetSummaryPresentation.model(for: summary, now: now)
    }

    /// "1 Oct" — the locale-fixed day shape the details use.
    private func containsDayLabel(_ text: String) -> Bool {
        text.range(of: #"[0-9]{1,2} [A-Z][a-z]{2}"#, options: .regularExpression) != nil
    }

    private func containsAnyDigit(_ text: String) -> Bool {
        text.range(of: #"[0-9]"#, options: .regularExpression) != nil
    }

    // MARK: Mandated area 8 — the empty state never fabricates a number

    @Test func absentSummaryRendersTheDesignedEmptyStateWithoutAnyNumber() {
        let display = model(nil)

        #expect(display.figure == .none)
        #expect(display.headline == "No estimate yet")
        #expect(display.caption.isEmpty)
        #expect(!display.isStale)
        // Not a single digit anywhere: no invented bytes, no dates, no counts.
        #expect(!containsAnyDigit(display.headline))
        #expect(!containsAnyDigit(display.detail))
        #expect(!containsAnyDigit(display.caption))
    }

    @Test func explicitEmptyStatusRendersTheSameEmptyState() throws {
        let display = model(try summary(status: .empty))

        #expect(display == model(nil))
    }

    // MARK: Mandated area 6 — an unavailable estimate shows no figure

    @Test func scanReadyShowsTheStatusAndNeverAFigure() throws {
        let display = model(try summary(status: .scanReady))

        #expect(display.figure == .none)
        #expect(display.headline == "Ready to clean")
        #expect(display.detail.hasPrefix("Last scan "))
        #expect(containsDayLabel(display.detail))
        #expect(display.caption.isEmpty)
        #expect(!display.isStale)
    }

    @Test func scanReadyWithoutARecentScanUsesTheNotRecentCopy() throws {
        let display = model(try summary(
            status: .scanReady,
            updatedAt: now.addingTimeInterval(-WidgetSummary.staleAfter - 60 * 60 * 24)
        ))

        #expect(display.figure == .none)
        #expect(display.headline == "No recent estimate")
        #expect(display.detail.contains("Open Netto"))
        #expect(display.isStale)
    }

    // MARK: The measured figure, always labelled an estimate

    @Test func measuredCleanupRendersTheFigureLabelledAsEstimate() throws {
        let display = model(try summary(
            status: .lastCleanup,
            estimateBytes: 1_400_000_000,
            isEstimated: true
        ))

        #expect(display.figure == .bytes(1_400_000_000))
        #expect(display.headline == "Last cleanup")
        #expect(display.caption.contains("Estimated"))
        #expect(display.detail.hasPrefix("Updated "))
        #expect(containsDayLabel(display.detail))
        #expect(!display.isStale)
    }

    // MARK: Mandated area 7 — stale content is flagged, not implied current

    @Test func cleanupOlderThanSevenDaysIsFlaggedAsOld() throws {
        let display = model(try summary(
            status: .lastCleanup,
            estimateBytes: 2_500,
            isEstimated: true,
            updatedAt: now.addingTimeInterval(-WidgetSummary.staleAfter - 60)
        ))

        #expect(display.isStale)
        #expect(display.headline == "Old cleanup estimate")
        #expect(display.detail.contains("Open Netto"))
        // The figure itself still stands — as an old, labelled estimate.
        #expect(display.figure == .bytes(2_500))
        #expect(display.caption.contains("Estimated"))
    }

    @Test func contentAtTheStalenessBoundaryIsStillFresh() throws {
        let atBoundary = try summary(
            status: .lastCleanup,
            estimateBytes: 2_500,
            isEstimated: true,
            updatedAt: now.addingTimeInterval(-WidgetSummary.staleAfter)
        )
        let display = model(atBoundary)

        #expect(!display.isStale)
        #expect(display.headline == "Last cleanup")
    }
}

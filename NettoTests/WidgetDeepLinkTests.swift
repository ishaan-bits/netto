import Foundation
import Testing
@testable import Netto

/// Minimal store double: deep-link tests must not write anything, so the env gets a
/// store whose writes are no-ops by construction.
private struct NoOpWidgetSummaryStore: WidgetSummaryStoring {
    func load() async -> WidgetSummary? { nil }
    func save(_ summary: WidgetSummary) async throws {}
    func requestWidgetReload() {}
}

// MARK: - Widget tap routing: where `netto://` links may and may not take the app

@MainActor
struct WidgetDeepLinkTests {
    private func makeEnvironment() -> AppEnvironment {
        AppEnvironment(widgetSummaryStore: NoOpWidgetSummaryStore())
    }

    // MARK: The parser

    @Test func dashboardURLRoutesToDashboard() throws {
        let url = try #require(WidgetDeepLink.dashboardURL)
        #expect(WidgetDeepLink.route(from: url) == .dashboard)
    }

    @Test func everyOtherURLRoutesToUnknown() throws {
        #expect(WidgetDeepLink.route(
            from: try #require(URL(string: "netto://cleanup"))
        ) == .unknown)
        // Host matching is case-insensitive and path-blind: any casing of `dashboard`
        // routes to the dashboard, and everything else under the scheme is unknown.
        #expect(WidgetDeepLink.route(
            from: try #require(URL(string: "netto://Dashboard/extra"))
        ) == .dashboard)
        #expect(WidgetDeepLink.route(
            from: try #require(URL(string: "netto:"))
        ) == .unknown)
        #expect(WidgetDeepLink.route(
            from: try #require(URL(string: "https://netto/dashboard"))
        ) == .unknown)
        #expect(WidgetDeepLink.route(
            from: try #require(URL(string: "otherapp://dashboard"))
        ) == .unknown)
    }

    // MARK: Mandated area 10 — the widget tap lands on the dashboard

    @Test func dashboardDeepLinkMovesTheFlowToTheDashboard() throws {
        let env = makeEnvironment()
        env.flowState = .review

        env.handleDeepLink(try #require(WidgetDeepLink.dashboardURL))

        #expect(env.flowState == .dashboard)
    }

    // MARK: Mandated area 11 — invalid links fall back safely, starting nothing

    @Test func invalidDeepLinkFallsBackToDashboardAndStartsNothing() throws {
        let env = makeEnvironment()
        env.flowState = .review

        env.handleDeepLink(try #require(URL(string: "netto://definitely-not-a-route")))

        #expect(env.flowState == .dashboard)
        // Nothing may have been started as a side effect of opening a link: no analysis,
        // no catalog build, no sharpness pass, no deletion, no scan state of any kind.
        #expect(isNotStarted(env.analysisState))
        #expect(isNotStarted(env.catalogState))
        #expect(isNotStarted(env.blurAnalysisState))
        guard case .noSelection = env.deletionState else {
            Issue.record("a deep link must never touch the deletion state machine")
            return
        }
        #expect(env.lastScanCompletedAt == nil)
        #expect(env.spaceFreedSummary == nil)
    }

    // MARK: Links never interrupt the flow that owns the screen

    @Test func deepLinkIsIgnoredDuringLaunch() throws {
        let env = makeEnvironment()
        #expect(env.flowState == .launching)

        env.handleDeepLink(try #require(WidgetDeepLink.dashboardURL))

        // The launch bootstrap converges to the dashboard on its own; a link that
        // arrives mid-launch changes nothing.
        #expect(env.flowState == .launching)
    }

    @Test func deepLinkIsIgnoredWhileADeletionIsRunning() throws {
        let env = makeEnvironment()
        let plan = DeletionPlan(
            schemaVersion: DeletionPlan.currentVersion,
            items: [
                DeletionPlanItem(
                    localIdentifier: "a", mediaType: .image, sizeInBytes: nil, category: nil
                )
            ],
            authorization: .authorized,
            sessionToken: "s",
            analysisSignature: "sig"
        )
        env.flowState = .deleting
        env.deletionState = .deleting(plan)

        env.handleDeepLink(try #require(WidgetDeepLink.dashboardURL))

        #expect(env.flowState == .deleting)
        guard case .deleting = env.deletionState else {
            Issue.record("a deep link must never interrupt a running deletion")
            return
        }
    }

    @Test func deepLinkIsIgnoredWhileTheSuccessSummaryIsOnScreen() throws {
        let env = makeEnvironment()
        env.flowState = .deletionCompleted

        env.handleDeepLink(try #require(WidgetDeepLink.dashboardURL))

        #expect(env.flowState == .deletionCompleted)
    }

    // MARK: State-shape helpers (pattern matching avoids requiring Equatable)

    private func isNotStarted(_ state: PhotoAnalysisState) -> Bool {
        if case .notStarted = state { true } else { false }
    }

    private func isNotStarted(_ state: CatalogScanState) -> Bool {
        if case .notStarted = state { true } else { false }
    }

    private func isNotStarted(_ state: BlurAnalysisState) -> Bool {
        if case .notStarted = state { true } else { false }
    }
}

import SwiftUI
import WidgetKit

/// The widget extension's entry point: one family-pair widget, one kind, one tap route.
@main
struct NettoWidgetBundle: WidgetBundle {
    var body: some Widget {
        NettoSummaryWidget()
    }
}

/// The home screen widget itself. Small and medium only; no lock-screen variants, no
/// interactive controls — tapping anywhere opens the app at the dashboard through the
/// `netto://` deep link. Correctness does not depend on the refresh cadence: every
/// render re-reads whatever the app last wrote (or the empty state, if nothing).
struct NettoSummaryWidget: Widget {
    /// Stable kind string — changing it would orphan already-placed widgets.
    static let kind = "com.ishaanparimal.netto.widget.summary"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: Self.kind, provider: NettoWidgetProvider()) { entry in
            NettoWidgetEntryView(entry: entry)
                .widgetURL(WidgetDeepLink.dashboardURL)
                .containerBackground(for: .widget) {
                    NettoColor.background
                }
        }
        .configurationDisplayName("Cleanup Estimate")
        .description("Netto's latest cleanup estimate and scan status.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

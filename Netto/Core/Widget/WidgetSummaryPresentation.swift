import Foundation

/// The widget's render model — a value the SwiftUI views can draw directly, produced only
/// from a validated `WidgetSummary` (or the complete absence of one) plus the current
/// date. Pure: no SwiftUI, no WidgetKit, no I/O, no clock of its own.
///
/// Two invariants the widget tests pin down:
/// - When there is no trustworthy summary (or no usable figure), `figure` is `.none`
///   and the copy contains no digits — the widget never manufactures a number.
/// - Staleness is decided here from `now`, so an old figure is always *labelled* old
///   rather than implied to describe current reclaimable storage.
struct WidgetDisplayModel: Equatable, Sendable {
    /// What the figure area shows. `.bytes` values are always estimates.
    enum Figure: Equatable, Sendable {
        case none
        case bytes(Int64)
    }

    /// The status line — the widget's headline ("Ready to clean", "No recent estimate"…).
    let headline: String
    /// Supporting line; carries the last-updated day when one exists.
    let detail: String
    /// The big number, or `.none` when nothing may be shown.
    let figure: Figure
    /// Label under the figure ("Estimated space cleaned"); empty when there is no figure.
    let caption: String
    /// Whether the content is older than `WidgetSummary.staleAfter` at render time.
    let isStale: Bool
}

enum WidgetSummaryPresentation {
    /// Builds the display model for the widget at `now`. `summary == nil` (no file, corrupt
    /// file, unsupported schema) renders exactly like an explicit `.empty` status.
    static func model(for summary: WidgetSummary?, now: Date) -> WidgetDisplayModel {
        guard let summary else { return emptyModel }
        switch summary.status {
        case .empty:
            return emptyModel
        case .scanReady:
            let stale = summary.isStale(relativeTo: now)
            return WidgetDisplayModel(
                headline: stale ? "No recent estimate" : "Ready to clean",
                detail: stale
                    ? "Last scan \(day(summary.updatedAt)) · Open Netto to scan again."
                    : "Last scan \(day(summary.updatedAt))",
                figure: .none,
                caption: "",
                isStale: stale
            )
        case .lastCleanup:
            // Validation guarantees a positive figure with `.lastCleanup`; if a summary
            // ever violates that, show the empty state rather than a fabricated number.
            guard let bytes = summary.estimateBytes, bytes > 0 else { return emptyModel }
            let stale = summary.isStale(relativeTo: now)
            return WidgetDisplayModel(
                headline: stale ? "Old cleanup estimate" : "Last cleanup",
                detail: stale
                    ? "Updated \(day(summary.updatedAt)) · Open Netto to refresh."
                    : "Updated \(day(summary.updatedAt))",
                figure: .bytes(bytes),
                caption: "Estimated space cleaned",
                isStale: stale
            )
        }
    }

    /// First run / nothing to show: prompts back into the app, and states no number at all.
    private static let emptyModel = WidgetDisplayModel(
        headline: "No estimate yet",
        detail: "Open Netto and scan your library to see cleanup estimates.",
        figure: .none,
        caption: "",
        isStale: false
    )

    /// Locale-fixed day label ("1 Oct") so the copy shape is stable regardless of the
    /// device locale; the actual timezone stays the user's, which is what a local day
    /// should be rendered in.
    private static func day(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "d MMM"
        return formatter.string(from: date)
    }
}

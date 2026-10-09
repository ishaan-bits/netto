import Foundation

/// Everything the Space Freed Summary screen renders, derived from the summary — never
/// stored, never re-derived elsewhere. Honest by construction:
/// - The byte figure is **always** labeled an estimate: Recently Deleted defers actual
///   reclamation, and partial measurement only makes the number a lower bound.
/// - When nothing was measured there is **no** space figure at all — the verified item count
///   stands alone rather than inventing a "0 GB".
/// - The partial-failure disclosure and the storage caveat are the same authoritative
///   wording the review screen already uses (`DeletionPresentation`).
enum SpaceFreedSummaryPresentation {
    static let headline = "Cleanup complete"
    static let movedToRecentlyDeleted = "Moved to Recently Deleted"
    static let spaceFigureLabel = "Estimated space freed"
    static let itemsMetricLabel = "Items removed"
    static let doneTitle = "Done"
    static let unknownSizeNote =
        "Size information wasn't available for these items, so no space estimate is shown."
    static let storageCaveat = DeletionPresentation.storageCaveat

    static let screenAccessibilityID = "spaceFreedSummaryScreen"
    static let metricAccessibilityID = "spaceFreedMetric"
    static let breakdownAccessibilityID = "spaceFreedBreakdown"
    static let failureAccessibilityID = "spaceFreedFailureNotice"
    static let doneAccessibilityID = "spaceFreedDoneButton"

    /// The hero figure: measured bytes when anything was measured, otherwise the verified
    /// item count — never a fabricated amount.
    static func metricValue(_ summary: SpaceFreedSummary) -> String {
        summary.hasSpaceFigure
            ? ByteFormat.string(summary.measuredBytes)
            : "\(summary.confirmedCount)"
    }

    static func metricLabel(_ summary: SpaceFreedSummary) -> String {
        summary.hasSpaceFigure ? spaceFigureLabel : itemsMetricLabel
    }

    /// The explicit item total — only when the hero figure is bytes. When the figure *is*
    /// the count, the metric label already states it and a second line would be noise.
    static func itemsRemovedLine(_ summary: SpaceFreedSummary) -> String? {
        guard summary.hasSpaceFigure else { return nil }
        return "\(summary.confirmedCount) \(plural(summary.confirmedCount, one: "item", many: "items")) removed"
    }

    /// Honesty notes under the figure: what could not be measured, or that nothing could be.
    static func sizeNote(_ summary: SpaceFreedSummary) -> String? {
        if !summary.hasSpaceFigure {
            return unknownSizeNote
        }
        guard summary.unresolvedCount > 0 else { return nil }
        return "Size information was unavailable for \(summary.unresolvedCount) "
            + "\(plural(summary.unresolvedCount, one: "item", many: "items")), "
            + "so this is a lower bound."
    }

    /// Partial-failure disclosure — `nil` for a fully successful run.
    static func failureDisclosure(_ summary: SpaceFreedSummary) -> String? {
        guard summary.isPartial else { return nil }
        return "\(summary.notRemovedCount) "
            + "\(plural(summary.notRemovedCount, one: "item", many: "items")) could not be removed."
    }

    static func breakdownLabel(_ category: SpaceFreedSummary.Category) -> String {
        switch category {
        case .videos: return "Videos"
        case .exactDuplicates: return "Exact duplicates"
        case .similarPhotos: return "Similar photos"
        case .photos: return "Photos"
        }
    }

    /// One VoiceOver announcement for the figure card, in reading order.
    static func metricAccessibilityLabel(_ summary: SpaceFreedSummary) -> String {
        var parts = ["\(metricValue(summary)), \(metricLabel(summary))"]
        if let line = itemsRemovedLine(summary) { parts.append(line) }
        if let note = sizeNote(summary) { parts.append(note) }
        parts.append(storageCaveat)
        return parts.joined(separator: ". ")
    }

    private static func plural(_ count: Int, one: String, many: String) -> String {
        count == 1 ? one : many
    }
}

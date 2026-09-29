import Foundation

/// The screenshot flow's selection is the shared dataset-bound selection model — screenshot
/// identity only depends on which filter the catalog is reconciled with (the PhotoKit subtype
/// recorded during enumeration), not on any special selection behaviour.
typealias ScreenshotSelectionModel = DatasetSelectionModel

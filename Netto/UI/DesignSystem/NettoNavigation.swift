import SwiftUI

/// Shared-element navigation between the dashboard tiles and the screens they open.
///
/// iOS 18+ zooms the tapped tile into the pushed screen; iOS 17 keeps the standard push, so
/// the same call sites work on every supported OS.
extension View {
    /// Marks the source of the zoom (the tappable tile).
    @ViewBuilder
    func nettoZoomSource<ID: Hashable>(_ id: ID, in namespace: Namespace.ID) -> some View {
        if #available(iOS 18.0, *) {
            matchedTransitionSource(id: id, in: namespace)
        } else {
            self
        }
    }

    /// Marks the destination of the zoom (the pushed screen).
    @ViewBuilder
    func nettoZoomDestination<ID: Hashable>(_ id: ID, in namespace: Namespace.ID) -> some View {
        if #available(iOS 18.0, *) {
            navigationTransition(.zoom(sourceID: id, in: namespace))
        } else {
            self
        }
    }
}

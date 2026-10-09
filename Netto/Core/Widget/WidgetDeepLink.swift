import Foundation

/// Where a `netto://` deep link routes. Two cases only: the one real destination, and
/// `unknown` for everything else — `unknown` still opens the app, it simply has no route
/// of its own and falls back to the dashboard (see `AppEnvironment.handleDeepLink`).
enum WidgetDeepLinkRoute: Equatable, Sendable {
    case dashboard
    case unknown
}

/// The deep links the widget (or anything else) may produce, and the parser the app uses
/// for them. Pure and total: every URL maps to exactly one route, malformed input is
/// `.unknown`, and nothing here ever starts a scan, a mutation, or any other work.
enum WidgetDeepLink: Sendable {
    /// Registered scheme (see `CFBundleURLTypes` in `Netto/Info.plist`).
    static let scheme = "netto"

    /// The widget's tap target: opens the app at the dashboard. Built by `URL(string:)`
    /// rather than a literal force-unwrap, so the optional is explicit everywhere.
    static let dashboardURL = URL(string: "netto://dashboard")

    /// Parses a URL into a route. Scheme and host must both match (case-insensitively);
    /// anything else — wrong scheme, missing host, unknown path-like host — is `.unknown`.
    static func route(from url: URL) -> WidgetDeepLinkRoute {
        guard url.scheme?.lowercased() == scheme else { return .unknown }
        guard let host = url.host?.lowercased() else { return .unknown }
        switch host {
        case "dashboard":
            return .dashboard
        default:
            return .unknown
        }
    }
}

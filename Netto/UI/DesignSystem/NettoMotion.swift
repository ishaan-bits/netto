import SwiftUI
import UIKit

/// The one place motion is defined.
///
/// Two axes: `Kind` is *how* something moves (curve + duration, plus a shorter Reduce Motion
/// variant); `Purpose` is *why* it moves. Screens pick a `Purpose` so the same intent always
/// produces the same curve — a selection toggle can never drift into a navigation curve.
enum NettoMotion {
    enum Kind: Equatable {
        case quick
        case standard
        case emphasized
        case spring
        case slow
        case ambient

        var animation: Animation {
            switch self {
            case .quick:
                return .easeOut(duration: 0.14)
            case .standard:
                return .easeInOut(duration: 0.26)
            case .emphasized:
                return .spring(response: 0.42, dampingFraction: 0.82)
            case .spring:
                return .spring(response: 0.32, dampingFraction: 0.70)
            case .slow:
                return .easeInOut(duration: 0.52)
            case .ambient:
                return .easeInOut(duration: 1.8).repeatForever(autoreverses: true)
            }
        }

        var reduced: Animation {
            switch self {
            case .quick, .standard:
                return .easeOut(duration: 0.14)
            case .emphasized, .spring, .slow:
                return .linear(duration: 0.2)
            case .ambient:
                return .linear(duration: 0.2)
            }
        }
    }

    /// Why something is moving. Raw values are the matching `Kind`, so the mapping is
    /// inspectable (and testable) without rendering anything.
    enum Purpose: CaseIterable, Equatable {
        /// Layered content revealing in order (staggered cards, hero, sections).
        case hierarchy
        /// Push, pop, sheet, cover — screen-to-screen movement.
        case navigation
        /// One screen swapping between its own states (phase, permission, error).
        case stateChange
        /// Selecting, toggling, checking, highlighting — the smallest possible response.
        case selection
        /// Numbers, bars, rings, counts changing value.
        case progress
        /// A completed, verified, positive outcome.
        case success
        /// Destruction, confirmation, irreversible change — deliberate and heavy.
        case destructive
        /// Indeterminate, continuous activity (scanning, measuring, ambient motion).
        case loading
        /// First appearance of a screen or its identity.
        case reveal

        var kind: Kind {
            switch self {
            case .hierarchy: return .standard
            case .navigation: return .emphasized
            case .stateChange: return .standard
            case .selection: return .quick
            case .progress: return .standard
            case .success: return .spring
            case .destructive: return .slow
            case .loading: return .ambient
            case .reveal: return .emphasized
            }
        }
    }

    static let quick = Kind.quick
    static let standard = Kind.standard
    static let emphasized = Kind.emphasized
    static let spring = Kind.spring
    static let slow = Kind.slow
    static let ambient = Kind.ambient

    @MainActor static var isReduceMotionEnabled: Bool {
        UIAccessibility.isReduceMotionEnabled
    }

    static func kind(for purpose: Purpose) -> Kind {
        purpose.kind
    }

    static func animation(for kind: Kind, reduceMotion: Bool) -> Animation {
        reduceMotion ? kind.reduced : kind.animation
    }

    /// The animation for an intent. Under Reduce Motion every purpose still animates — just
    /// shorter, linear, and never repeating — so state changes stay legible without movement.
    static func animation(for purpose: Purpose, reduceMotion: Bool) -> Animation {
        animation(for: purpose.kind, reduceMotion: reduceMotion)
    }
}

private struct NettoAnimateModifier<V: Equatable>: ViewModifier {
    let kind: NettoMotion.Kind
    let value: V
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .animation(NettoMotion.animation(for: kind, reduceMotion: reduceMotion), value: value)
    }
}

private struct NettoPurposeAnimateModifier<V: Equatable>: ViewModifier {
    let purpose: NettoMotion.Purpose
    let value: V
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .animation(
                NettoMotion.animation(for: purpose, reduceMotion: reduceMotion),
                value: value
            )
    }
}

extension View {
    func nettoAnimate<V: Equatable>(_ kind: NettoMotion.Kind, value: V) -> some View {
        modifier(NettoAnimateModifier(kind: kind, value: value))
    }

    func nettoAnimate<V: Equatable>(_ purpose: NettoMotion.Purpose, value: V) -> some View {
        modifier(NettoPurposeAnimateModifier(purpose: purpose, value: value))
    }
}

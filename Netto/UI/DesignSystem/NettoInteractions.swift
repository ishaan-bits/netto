import SwiftUI

private struct NettoAppearModifier: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shown = false

    func body(content: Content) -> some View {
        content
            .opacity(shown ? 1 : 0)
            .offset(y: shown || reduceMotion ? 0 : 8)
            .onAppear {
                withAnimation(NettoMotion.animation(for: .reveal, reduceMotion: reduceMotion)) { shown = true }
            }
    }
}

private struct NettoEntranceModifier: ViewModifier {
    let step: Int
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shown = false

    func body(content: Content) -> some View {
        content
            .opacity(shown ? 1 : 0)
            .offset(y: shown || reduceMotion ? 0 : 6)
            .onAppear {
                // Layered content reveals in order: one short delay per step, all of it
                // settled within a fraction of a second. Reduce Motion fades instead —
                // no travel and no waiting.
                let delay = reduceMotion ? 0 : Double(min(max(step, 0), 8)) * 0.05
                withAnimation(
                    NettoMotion.animation(for: .hierarchy, reduceMotion: reduceMotion).delay(delay)
                ) {
                    shown = true
                }
            }
    }
}

private struct NettoSelectedModifier: ViewModifier {
    let active: Bool
    var cornerRadius: CGFloat = NettoLayout.Radius.card
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .scaleEffect(active && !reduceMotion ? 1.02 : 1)
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(NettoColor.brand, lineWidth: active ? 2 : 0)
            }
            .animation(NettoMotion.animation(for: .selection, reduceMotion: reduceMotion), value: active)
    }
}

private struct NettoRevealTransitionModifier: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content.transition(
            reduceMotion
                ? .opacity
                : .asymmetric(
                    insertion: .opacity.combined(with: .offset(y: 8)),
                    removal: .opacity
                )
        )
    }
}

private struct NettoSuccessPopModifier: ViewModifier {
    let active: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .scaleEffect(active && !reduceMotion ? 1.04 : 1)
            .animation(NettoMotion.animation(for: .success, reduceMotion: reduceMotion), value: active)
    }
}

/// Press feedback for surfaces that are not `Button`-styled cards — tappable rows, tiles, and
/// navigation labels. Same response as `NettoPressEffect`, so a press feels identical
/// everywhere in the app.
private struct NettoPressableButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.975 : 1)
            .opacity(configuration.isPressed ? 0.86 : 1)
            .animation(NettoMotion.animation(for: .selection, reduceMotion: reduceMotion), value: configuration.isPressed)
    }
}

/// One screen swapping between its own states (permission, scanning, results, error).
/// `id` must be the *state category*, not the state's payload: progress ticks and error text
/// change constantly, and remounting the screen on every tick would restart its animation.
private struct NettoStateTransitionModifier: ViewModifier {
    let id: String
    let purpose: NettoMotion.Purpose
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .id(id)
            .transition(
                reduceMotion
                    ? .opacity
                    : .asymmetric(
                        insertion: .opacity.combined(with: .offset(y: 8)),
                        removal: .opacity
                    )
            )
            .animation(NettoMotion.animation(for: purpose, reduceMotion: reduceMotion), value: id)
    }
}

/// A count that rolls to its new value instead of jumping — applied to the `Text` so
/// `numericText` has a single source of truth. Still updates instantly under Reduce Motion.
private struct NettoCountModifier<V: BinaryInteger>: ViewModifier {
    let value: V
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .contentTransition(.numericText(value: Double(value)))
            .animation(NettoMotion.animation(for: .progress, reduceMotion: reduceMotion), value: value)
    }
}

extension View {
    func nettoAppear() -> some View {
        modifier(NettoAppearModifier())
    }

    /// Layered entrance for a block of dashboard content: `step` orders the blocks (0, 1, 2…)
    /// and each step is a short delay, so the screen resolves in one restrained sweep.
    func nettoEntrance(step: Int = 0) -> some View {
        modifier(NettoEntranceModifier(step: step))
    }

    func nettoSelected(_ active: Bool, cornerRadius: CGFloat = NettoLayout.Radius.card) -> some View {
        modifier(NettoSelectedModifier(active: active, cornerRadius: cornerRadius))
    }

    func nettoRevealTransition() -> some View {
        modifier(NettoRevealTransitionModifier())
    }

    func nettoSuccessPop(_ active: Bool) -> some View {
        modifier(NettoSuccessPopModifier(active: active))
    }

    /// Rows, tiles, and navigation labels get the standard press response.
    func nettoPress() -> some View {
        buttonStyle(NettoPressableButtonStyle())
    }

    /// Cross-fades this screen when its state category changes. Review screens pass
    /// `.destructive` so the path into a deletion or merge settles deliberately.
    func nettoStateTransition(
        _ id: String,
        purpose: NettoMotion.Purpose = .stateChange
    ) -> some View {
        modifier(NettoStateTransitionModifier(id: id, purpose: purpose))
    }

    /// Digits that roll when the value changes. Apply to the `Text` itself.
    func nettoCount<V: BinaryInteger>(_ value: V) -> some View {
        modifier(NettoCountModifier(value: value))
    }
}

extension ButtonStyle where Self == NettoPressableButtonStyle {
    static var nettoPressable: NettoPressableButtonStyle { NettoPressableButtonStyle() }
}

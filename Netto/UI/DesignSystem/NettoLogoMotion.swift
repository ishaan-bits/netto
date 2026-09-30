import SwiftUI

private struct NettoLogoRevealModifier: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shown = false

    func body(content: Content) -> some View {
        content
            .opacity(shown ? 1 : 0)
            .scaleEffect(shown || reduceMotion ? 1 : 0.94)
            .onAppear {
                withAnimation(NettoMotion.emphasized.animation) { shown = true }
            }
    }
}

private struct NettoLogoActivityModifier: ViewModifier {
    let active: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var breathing = false

    func body(content: Content) -> some View {
        content
            .scaleEffect(breathing ? 1.03 : 1)
            .opacity(breathing ? 0.92 : 1)
            .onAppear { update(active) }
            .onChange(of: active) { _, newValue in update(newValue) }
    }

    private func update(_ active: Bool) {
        guard !reduceMotion, active else {
            withAnimation(NettoMotion.quick.animation) { breathing = false }
            return
        }
        withAnimation(NettoMotion.ambient.animation) { breathing = true }
    }
}

extension View {
    func nettoLogoReveal() -> some View {
        modifier(NettoLogoRevealModifier())
    }

    func nettoLogoActivity(_ active: Bool) -> some View {
        modifier(NettoLogoActivityModifier(active: active))
    }
}

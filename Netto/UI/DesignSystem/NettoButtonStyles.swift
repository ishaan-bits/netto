import SwiftUI

private struct NettoPressEffect: ViewModifier {
    let isPressed: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .scaleEffect(isPressed && !reduceMotion ? 0.97 : 1)
            .opacity(isPressed ? 0.82 : 1)
            .animation(NettoMotion.quick.animation, value: isPressed)
    }
}

struct NettoPrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(NettoType.buttonLabel)
            .foregroundStyle(NettoColor.onBrand)
            .padding(.horizontal, NettoLayout.Spacing.xl)
            .padding(.vertical, NettoLayout.Spacing.md)
            .frame(minHeight: 44)
            .background(NettoColor.brand, in: RoundedRectangle(cornerRadius: NettoLayout.Radius.button, style: .continuous))
            .modifier(NettoPressEffect(isPressed: configuration.isPressed))
            .contentShape(Rectangle())
    }
}

struct NettoSecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(NettoType.buttonLabel)
            .foregroundStyle(NettoColor.textPrimary)
            .padding(.horizontal, NettoLayout.Spacing.xl)
            .padding(.vertical, NettoLayout.Spacing.md)
            .frame(minHeight: 44)
            .background(NettoColor.surfaceHighlight, in: RoundedRectangle(cornerRadius: NettoLayout.Radius.button, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: NettoLayout.Radius.button, style: .continuous)
                    .strokeBorder(NettoColor.separator, lineWidth: 1)
            }
            .modifier(NettoPressEffect(isPressed: configuration.isPressed))
            .contentShape(Rectangle())
    }
}

struct NettoTertiaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(NettoType.buttonLabel)
            .foregroundStyle(NettoColor.brandDeep)
            .padding(.horizontal, NettoLayout.Spacing.sm)
            .padding(.vertical, NettoLayout.Spacing.sm)
            .frame(minHeight: 44)
            .modifier(NettoPressEffect(isPressed: configuration.isPressed))
            .contentShape(Rectangle())
    }
}

struct NettoDestructiveButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(NettoType.buttonLabel)
            .foregroundStyle(.white)
            .padding(.horizontal, NettoLayout.Spacing.xl)
            .padding(.vertical, NettoLayout.Spacing.md)
            .frame(minHeight: 44)
            .background(NettoColor.destructive, in: RoundedRectangle(cornerRadius: NettoLayout.Radius.button, style: .continuous))
            .modifier(NettoPressEffect(isPressed: configuration.isPressed))
            .contentShape(Rectangle())
    }
}

struct NettoIconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: NettoIconSize.control, weight: .semibold))
            .foregroundStyle(NettoColor.textPrimary)
            .frame(width: 44, height: 44)
            .background(NettoColor.surfaceSecondary, in: Circle())
            .modifier(NettoPressEffect(isPressed: configuration.isPressed))
            .contentShape(Circle())
    }
}

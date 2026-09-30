import SwiftUI

enum NettoIconSize {
    static let control: CGFloat = 16
    static let metric: CGFloat = 18
    static let row: CGFloat = 20
    static let feature: CGFloat = 28
}

struct NettoIcon: View {
    let name: String
    var size: CGFloat = NettoIconSize.row
    var weight: Font.Weight = .semibold
    var tint: Color = NettoColor.brand

    var body: some View {
        Image(systemName: name)
            .font(.system(size: size, weight: weight))
            .foregroundStyle(tint)
            .accessibilityHidden(true)
    }
}

struct NettoIconBubble: View {
    let name: String
    var tint: Color = NettoColor.brand

    var body: some View {
        ZStack {
            Circle()
                .fill(tint.opacity(0.16))
            NettoIcon(name: name, size: NettoIconSize.row, weight: .semibold, tint: tint)
        }
        .frame(width: 40, height: 40)
        .accessibilityHidden(true)
    }
}

import SwiftUI

struct NettoLogo: View {
    var body: some View {
        Image("NettoLogo")
            .resizable()
            .aspectRatio(contentMode: .fit)
    }
}

private let previewSizes: [CGFloat] = [24, 32, 48, 64, 96, 128]

private func logoStack() -> some View {
    VStack(spacing: Theme.Spacing.lg) {
        ForEach(previewSizes, id: \.self) { size in
            NettoLogo()
                .frame(width: size)
        }
    }
    .padding(Theme.Spacing.xl)
}

#Preview("Sizes · Light") {
    logoStack()
        .background(Theme.Palette.background)
}

#Preview("Sizes · Dark") {
    logoStack()
        .background(.black)
}

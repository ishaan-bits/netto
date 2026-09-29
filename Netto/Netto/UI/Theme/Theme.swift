import SwiftUI

enum Theme {
    enum Palette {
        static let accent = Color("AccentColor", bundle: nil)
        static let background = Color(uiColor: .systemGroupedBackground)
        static let secondaryBackground = Color(uiColor: .secondarySystemGroupedBackground)
        static let tertiaryBackground = Color(uiColor: .tertiarySystemGroupedBackground)
        static let label = Color(uiColor: .label)
        static let secondaryLabel = Color(uiColor: .secondaryLabel)
        static let separator = Color(uiColor: .separator)
        static let success = Color.green
        static let warning = Color.orange
        static let danger = Color.red
    }

    enum Spacing {
        static let xs: CGFloat = 4
        static let sm: CGFloat = 8
        static let md: CGFloat = 12
        static let lg: CGFloat = 16
        static let xl: CGFloat = 24
        static let xxl: CGFloat = 32
    }

    enum Radius {
        static let sm: CGFloat = 8
        static let md: CGFloat = 12
        static let lg: CGFloat = 16
        static let pill: CGFloat = 999
    }
}

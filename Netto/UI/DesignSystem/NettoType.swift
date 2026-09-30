import SwiftUI

enum NettoType {
    static let heroTitle = Font.system(.largeTitle, design: .default).weight(.bold)
    static let navigationTitle = Font.system(.title2, design: .default).weight(.bold)
    static let sectionTitle = Font.system(.title3, design: .default).weight(.semibold)
    static let cardTitle = Font.system(.headline, design: .default)
    static let body = Font.system(.body, design: .default)
    static let secondaryBody = Font.system(.subheadline, design: .default)
    static let caption = Font.system(.footnote, design: .default)
    static let metricNumber = Font.system(.title, design: .rounded).weight(.bold).monospacedDigit()
    static let metricLabel = Font.system(.caption, design: .default).weight(.medium)
    static let buttonLabel = Font.system(.subheadline, design: .default).weight(.semibold)
}

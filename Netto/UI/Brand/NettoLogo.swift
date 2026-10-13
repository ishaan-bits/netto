import SwiftUI

// MARK: - Brand palette (logos/Netto-Brand-Assets/README.md)

/// The approved Netto brand colors — sampled stops of the two-leaf identity. Naming them
/// once here keeps every in-app surface (symbol, animations, previews) on the same values
/// the SVG assets use.
enum NettoBrandPalette {
    // Left leaf gradient: mint → deep.
    static let leafLeftStops: [Color] = [
        Color(red: 0xA3 / 255, green: 0xD2 / 255, blue: 0x9A / 255),
        Color(red: 0x6D / 255, green: 0xB2 / 255, blue: 0x83 / 255),
        Color(red: 0x3B / 255, green: 0x89 / 255, blue: 0x6A / 255),
        Color(red: 0x1F / 255, green: 0x67 / 255, blue: 0x56 / 255),
    ]
    /// Right leaf gradient: lime → teal.
    static let leafRightStops: [Color] = [
        Color(red: 0xCD / 255, green: 0xEA / 255, blue: 0xA1 / 255),
        Color(red: 0x9C / 255, green: 0xCB / 255, blue: 0x86 / 255),
        Color(red: 0x5D / 255, green: 0xAE / 255, blue: 0x88 / 255),
        Color(red: 0x2F / 255, green: 0x84 / 255, blue: 0x66 / 255),
    ]
    /// Gradient axis endpoints in the symbol's 512 box (SVG user-space coordinates).
    static let leftAxis: (start: UnitPoint, end: UnitPoint) = (
        UnitPoint(x: 110.0 / 512, y: 100.0 / 512),
        UnitPoint(x: 320.0 / 512, y: 432.0 / 512)
    )
    static let rightAxis: (start: UnitPoint, end: UnitPoint) = (
        UnitPoint(x: 392.0 / 512, y: 84.0 / 512),
        UnitPoint(x: 410.0 / 512, y: 388.0 / 512)
    )

    static let solidGreen = Color(red: 0x1F / 255, green: 0x7A / 255, blue: 0x55 / 255)
    static let inkDark = Color(red: 0x0B / 255, green: 0x2E / 255, blue: 0x21 / 255)
    static let wordmarkInk = Color(red: 0x09 / 255, green: 0x2F / 255, blue: 0x23 / 255)
}

// MARK: - Asset logo (kept for existing call sites)

/// The brand mark as an image asset — now the approved two-leaf symbol (SVG, so it stays
/// crisp at every size). For the animated, per-leaf vector rendering use `NettoBrandSymbol`.
struct NettoLogo: View {
    var body: some View {
        Image("NettoLogo")
            .resizable()
            .aspectRatio(contentMode: .fit)
    }
}

// MARK: - Vector symbol (exact brand geometry)

/// The left leaf of the two-leaf N, in the symbol's 512 box.
struct NettoLeafLeftShape: Shape {
    func path(in rect: CGRect) -> Path {
        let d = "M 101.0 131.7 Q 101.0 105.3 117.1 115.1 C 204.0 171.9 334.2 312.2 334.2 382.5 L 334.2 400.1 C 334.2 417.7 321.0 428.7 294.6 428.7 C 193.4 426.5 101.0 356.1 101.0 268.1 Z"
        return NettoSymbolGeometry.path(from: d, in: rect)
    }
}

/// The right leaf of the two-leaf N, in the symbol's 512 box.
struct NettoLeafRightShape: Shape {
    func path(in rect: CGRect) -> Path {
        let d = "M 411.2 369.3 L 411.2 105.3 Q 411.2 83.3 389.2 83.3 C 321.0 83.3 270.4 127.3 270.4 184.5 C 270.4 228.5 321.0 294.5 404.6 380.3 Q 411.2 384.7 411.2 369.3 Z"
        return NettoSymbolGeometry.path(from: d, in: rect)
    }
}

/// Scales the SVG-authored 512 box into the target rect (aspect-fit, centered) — the same
/// geometry the asset SVGs render, so vector and asset forms are identical.
enum NettoSymbolGeometry {
    static func path(from d: String, in rect: CGRect) -> Path {
        let scale = min(rect.width, rect.height) / 512
        let dx = rect.midX - 256 * scale
        let dy = rect.midY - 256 * scale
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: x * scale + dx, y: y * scale + dy)
        }
        var path = Path()
        let tokens = d.replacingOccurrences(of: ",", with: " ")
            .split(separator: " ").map(String.init)
        var i = 0
        var current = CGPoint.zero
        var start = CGPoint.zero
        func num() -> CGFloat { defer { i += 1 }; return CGFloat(Double(tokens[i])!) }
        while i < tokens.count {
            switch tokens[i] {
            case "M":
                i += 1
                current = point(num(), num())
                start = current
                path.move(to: current)
            case "L":
                i += 1
                current = point(num(), num())
                path.addLine(to: current)
            case "Q":
                i += 1
                let control = point(num(), num())
                current = point(num(), num())
                path.addQuadCurve(to: current, control: control)
            case "C":
                i += 1
                let c1 = point(num(), num())
                let c2 = point(num(), num())
                current = point(num(), num())
                path.addCurve(to: current, control1: c1, control2: c2)
            case "Z", "z":
                i += 1
                path.closeSubpath()
                current = start
            default:
                i += 1
            }
        }
        return path
    }
}

/// How the symbol is filled — mirrors the SVG variant files.
enum NettoBrandSymbolStyle: Sendable, Equatable {
    /// Primary identity: the two brand gradients (`netto-symbol.svg`).
    case gradient
    /// White mono (`netto-symbol-light.svg`) — dark or photographic backgrounds.
    case luminous
    /// Ink mono (`netto-symbol-dark.svg`) — light backgrounds, one-colour print.
    case dark
    /// Solid brand green (`netto-symbol-green.svg`) — gradient-free.
    case green
}

/// The approved two-leaf N symbol as live vector geometry, with the brand's motion:
/// a staggered leaf reveal on appear and a slow, gentle idle drift — both collapse to
/// simple fades under Reduce Motion.
///
/// The paths, gradients and scales are the exact ones in `logos/Netto-Brand-Assets`, so
/// this and the SVG assets are the same mark; this form just animates.
struct NettoBrandSymbol: View {
    var style: NettoBrandSymbolStyle = .gradient
    /// Plays the leaf-stagger reveal when the view appears.
    var animateReveal: Bool = true
    /// Plays the slow idle drift (float + breath). Kept opt-in: dashboards show it once,
    /// lists and small placements stay still.
    var animateIdle: Bool = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var leftShown = false
    @State private var rightShown = false
    @State private var drifting = false

    var body: some View {
        ZStack {
            leaf(NettoLeafLeftShape(), fill: leftFill)
                .opacity(leftShown || !animateReveal ? 1 : 0)
                .offset(y: leftShown || !animateReveal ? 0 : 10)
                .scaleEffect(leftShown || !animateReveal ? 1 : 0.92)
            leaf(NettoLeafRightShape(), fill: rightFill)
                .opacity(rightShown || !animateReveal ? 1 : 0)
                .offset(y: rightShown || !animateReveal ? 0 : 10)
                .scaleEffect(rightShown || !animateReveal ? 1 : 0.92)
        }
        .offset(y: drifting ? -1.5 : 1.5)
        .scaleEffect(drifting ? 1.02 : 1.0)
        .onAppear {
            if reduceMotion || !animateReveal {
                leftShown = true
                rightShown = true
            } else {
                // Left leaf first; the right leaf follows — the mark assembles itself.
                withAnimation(.easeOut(duration: 0.55)) { leftShown = true }
                withAnimation(.easeOut(duration: 0.55).delay(0.12)) { rightShown = true }
            }
            guard animateIdle, !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 3.2).repeatForever(autoreverses: true)) {
                drifting = true
            }
        }
    }

    /// Each leaf keeps its own brand gradient axis (exactly as authored); the mono styles
    /// fill both leaves with one colour.
    private var leftFill: AnyShapeStyle {
        switch style {
        case .gradient:
            AnyShapeStyle(LinearGradient(
                colors: NettoBrandPalette.leafLeftStops,
                startPoint: NettoBrandPalette.leftAxis.start,
                endPoint: NettoBrandPalette.leftAxis.end
            ))
        case .luminous:
            AnyShapeStyle(.white)
        case .dark:
            AnyShapeStyle(NettoBrandPalette.inkDark)
        case .green:
            AnyShapeStyle(NettoBrandPalette.solidGreen)
        }
    }

    private var rightFill: AnyShapeStyle {
        switch style {
        case .gradient:
            AnyShapeStyle(LinearGradient(
                colors: NettoBrandPalette.leafRightStops,
                startPoint: NettoBrandPalette.rightAxis.start,
                endPoint: NettoBrandPalette.rightAxis.end
            ))
        case .luminous:
            AnyShapeStyle(.white)
        case .dark:
            AnyShapeStyle(NettoBrandPalette.inkDark)
        case .green:
            AnyShapeStyle(NettoBrandPalette.solidGreen)
        }
    }

    private func leaf<S: Shape>(_ shape: S, fill: AnyShapeStyle) -> some View {
        shape.fill(fill)
    }
}

// MARK: - Previews

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

#Preview("Vector symbol · styles") {
    HStack(spacing: Theme.Spacing.xl) {
        NettoBrandSymbol(style: .gradient).frame(width: 64, height: 64)
        NettoBrandSymbol(style: .green).frame(width: 64, height: 64)
        NettoBrandSymbol(style: .dark).frame(width: 64, height: 64)
        NettoBrandSymbol(style: .luminous).frame(width: 64, height: 64)
    }
    .padding(Theme.Spacing.xl)
    .background(Theme.Palette.background)
}

#Preview("Vector symbol · animated") {
    NettoBrandSymbol(animateIdle: true)
        .frame(width: 96, height: 96)
        .padding(Theme.Spacing.xl)
        .background(Theme.Palette.background)
}

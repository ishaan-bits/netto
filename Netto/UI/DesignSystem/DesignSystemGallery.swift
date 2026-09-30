#if DEBUG
import SwiftUI

struct DesignSystemGallery: View {
    @State private var appearToken = 0
    @State private var selected = false
    @State private var logoActive = false
    @State private var logoToken = 0

    var body: some View {
        List {
            colorsSection
            typographySection
            layoutSection
            surfacesSection
            buttonsSection
            cardSection
            iconsSection
            motionSection
            logoSection
        }
        .navigationTitle("Netto Design System")
    }

    private var colorsSection: some View {
        Section("Colors") {
            swatch("Background", NettoColor.background)
            swatch("Surface", NettoColor.surface)
            swatch("Surface Secondary", NettoColor.surfaceSecondary)
            swatch("Surface Highlight", NettoColor.surfaceHighlight)
            swatch("Brand", NettoColor.brand)
            swatch("Brand Deep", NettoColor.brandDeep)
            swatch("Success", NettoColor.success)
            swatch("Warning", NettoColor.warning)
            swatch("Destructive", NettoColor.destructive)
            swatch("Separator", NettoColor.separator)
        }
    }

    private func swatch(_ name: String, _ color: Color) -> some View {
        HStack(spacing: NettoLayout.Spacing.md) {
            RoundedRectangle(cornerRadius: NettoLayout.Radius.control, style: .continuous)
                .fill(color)
                .frame(width: 44, height: 44)
                .overlay {
                    RoundedRectangle(cornerRadius: NettoLayout.Radius.control, style: .continuous)
                        .strokeBorder(NettoColor.separator, lineWidth: 1)
                }
            Text(name)
                .font(NettoType.body)
                .foregroundStyle(NettoColor.textPrimary)
        }
    }

    private var typographySection: some View {
        Section("Typography") {
            galleryRow("Hero", NettoType.heroTitle)
            galleryRow("Navigation", NettoType.navigationTitle)
            galleryRow("Section", NettoType.sectionTitle)
            galleryRow("Card", NettoType.cardTitle)
            galleryRow("Body", NettoType.body)
            galleryRow("Secondary", NettoType.secondaryBody)
            galleryRow("Caption", NettoType.caption)
            galleryRow("Metric", NettoType.metricNumber)
            galleryRow("Metric Label", NettoType.metricLabel)
            galleryRow("Button", NettoType.buttonLabel)
        }
    }

    private func galleryRow(_ name: String, _ font: Font) -> some View {
        VStack(alignment: .leading, spacing: NettoLayout.Spacing.xs) {
            Text(name)
                .font(NettoType.metricLabel)
                .foregroundStyle(NettoColor.textTertiary)
            Text("Netto 4.8 GB")
                .font(font)
                .foregroundStyle(NettoColor.textPrimary)
        }
        .padding(.vertical, NettoLayout.Spacing.xs)
    }

    private var layoutSection: some View {
        Section("Spacing & Radius") {
            HStack(spacing: NettoLayout.Spacing.sm) {
                spacingBar(NettoLayout.Spacing.xs, "xs")
                spacingBar(NettoLayout.Spacing.sm, "sm")
                spacingBar(NettoLayout.Spacing.md, "md")
                spacingBar(NettoLayout.Spacing.lg, "lg")
                spacingBar(NettoLayout.Spacing.xl, "xl")
                spacingBar(NettoLayout.Spacing.xxl, "xxl")
            }
            .frame(height: 64)
            HStack(spacing: NettoLayout.Spacing.md) {
                radiusBox(NettoLayout.Radius.control, "ctl")
                radiusBox(NettoLayout.Radius.button, "btn")
                radiusBox(NettoLayout.Radius.card, "card")
                radiusBox(NettoLayout.Radius.feature, "feat")
            }
            .frame(height: 72)
        }
    }

    private func spacingBar(_ value: CGFloat, _ name: String) -> some View {
        VStack(spacing: NettoLayout.Spacing.xs) {
            RoundedRectangle(cornerRadius: NettoLayout.Radius.control)
                .fill(NettoColor.brandDeep)
                .frame(width: 12, height: max(value, 4))
            Text(name)
                .font(.system(size: 10))
                .foregroundStyle(NettoColor.textTertiary)
        }
    }

    private func radiusBox(_ radius: CGFloat, _ name: String) -> some View {
        ZStack(alignment: .bottom) {
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .fill(NettoColor.surfaceHighlight)
                .frame(height: 56)
            Text(name)
                .font(.system(size: 10))
                .foregroundStyle(NettoColor.textTertiary)
                .padding(.bottom, NettoLayout.Spacing.xs)
        }
    }

    private var surfacesSection: some View {
        Section("Surfaces") {
            Text("Elevated surface")
                .font(NettoType.secondaryBody)
                .foregroundStyle(NettoColor.textSecondary)
                .padding(NettoLayout.Spacing.lg)
                .nettoSurface(.elevated)
            Text("Secondary surface")
                .font(NettoType.secondaryBody)
                .foregroundStyle(NettoColor.textSecondary)
                .padding(NettoLayout.Spacing.lg)
                .nettoSurface(.secondary)
            Text("Highlighted surface")
                .font(NettoType.secondaryBody)
                .foregroundStyle(NettoColor.textSecondary)
                .padding(NettoLayout.Spacing.lg)
                .nettoSurface(.highlighted)
            Text("Translucent surface")
                .font(NettoType.secondaryBody)
                .foregroundStyle(NettoColor.textSecondary)
                .padding(NettoLayout.Spacing.lg)
                .nettoSurface(.translucent)
            Text("Photo surface")
                .font(NettoType.secondaryBody)
                .foregroundStyle(NettoColor.textSecondary)
                .padding(NettoLayout.Spacing.lg)
                .nettoSurface(.photo)
        }
    }

    private var buttonsSection: some View {
        Section("Buttons") {
            Button("Primary") {}
                .buttonStyle(NettoPrimaryButtonStyle())
            Button("Secondary") {}
                .buttonStyle(NettoSecondaryButtonStyle())
            Button("Tertiary") {}
                .buttonStyle(NettoTertiaryButtonStyle())
            Button("Destructive") {}
                .buttonStyle(NettoDestructiveButtonStyle())
            Button {
            } label: {
                NettoIcon(name: "gearshape", size: NettoIconSize.row, weight: .semibold, tint: NettoColor.textPrimary)
            }
            .buttonStyle(NettoIconButtonStyle())
        }
    }

    private var cardSection: some View {
        Section("Cards") {
            NettoCard(
                title: "Similar Photos",
                subtitle: "124 items",
                metric: "1.8 GB",
                systemImage: "photo.on.rectangle"
            )
            .nettoAppear()
            .id(appearToken)
            NettoCard(
                title: "Scanning your library",
                subtitle: "2,641 of 8,214 items",
                systemImage: "sparkles",
                progress: 0.32
            )
            NettoCard(
                title: "Screenshots",
                subtitle: "Tap to review",
                systemImage: "camera.viewfinder",
                trailing: "620 MB",
                action: {}
            )
            Button("Replay appearance") {
                appearToken += 1
            }
            .buttonStyle(NettoSecondaryButtonStyle())
        }
    }

    private var iconsSection: some View {
        Section("Icons") {
            HStack(spacing: NettoLayout.Spacing.lg) {
                NettoIconBubble(name: "photo.on.rectangle")
                NettoIconBubble(name: "camera.viewfinder", tint: .blue)
                NettoIconBubble(name: "video.fill", tint: .orange)
                NettoIconBubble(name: "person.2.fill", tint: .purple)
            }
            .padding(.vertical, NettoLayout.Spacing.xs)
        }
    }

    private var motionSection: some View {
        Section("Motion") {
            Button(selected ? "Selected" : "Tap to select") {
                selected.toggle()
            }
            .buttonStyle(NettoPrimaryButtonStyle())
            .nettoSelected(selected, cornerRadius: NettoLayout.Radius.button)

            HStack(spacing: NettoLayout.Spacing.lg) {
                Label("Quick", systemImage: "bolt.fill")
                Label("Standard", systemImage: "arrow.left.arrow.right")
                Label("Spring", systemImage: "waveform.path")
            }
            .font(NettoType.metricLabel)
            .foregroundStyle(NettoColor.textSecondary)

            Text("Reduce Motion is respected: movement collapses to short opacity/color changes.")
                .font(NettoType.caption)
                .foregroundStyle(NettoColor.textTertiary)
        }
    }

    private var logoSection: some View {
        Section("Logo") {
            HStack(spacing: NettoLayout.Spacing.lg) {
                NettoLogo().frame(width: 24)
                NettoLogo().frame(width: 32)
                NettoLogo().frame(width: 48)
                NettoLogo().frame(width: 64)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, NettoLayout.Spacing.md)

            HStack(spacing: NettoLayout.Spacing.lg) {
                NettoLogo()
                    .frame(width: 96)
                    .nettoLogoActivity(logoActive)
                    .id(logoToken)
                Spacer()
                VStack(spacing: NettoLayout.Spacing.sm) {
                    Button(logoActive ? "Stop activity" : "Start activity") {
                        logoActive.toggle()
                    }
                    .buttonStyle(NettoSecondaryButtonStyle())
                    Button("Replay reveal") {
                        logoToken += 1
                    }
                    .buttonStyle(NettoSecondaryButtonStyle())
                }
            }
        }
    }
}

#Preview("Design System · Light") {
    NavigationStack {
        DesignSystemGallery()
    }
    .preferredColorScheme(.light)
}

#Preview("Design System · Dark") {
    NavigationStack {
        DesignSystemGallery()
    }
    .preferredColorScheme(.dark)
}
#endif

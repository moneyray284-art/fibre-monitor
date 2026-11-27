import SwiftUI
import UIKit

public enum LinkWaveSurfaceStyle: String, CaseIterable, Identifiable {
    case liquidGlass
    case frosted
    case cleanSolid

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .liquidGlass: "Liquid Glass"
        case .frosted: "Frosted"
        case .cleanSolid: "Clean Solid"
        }
    }
}

private struct LinkWaveSurfaceStyleKey: EnvironmentKey {
    static let defaultValue: LinkWaveSurfaceStyle = .liquidGlass
}

extension EnvironmentValues {
    var linkWaveSurfaceStyle: LinkWaveSurfaceStyle {
        get { self[LinkWaveSurfaceStyleKey.self] }
        set { self[LinkWaveSurfaceStyleKey.self] = newValue }
    }
}

private func linkWaveSolidSurfaceColor(_ palette: ThemePalette, colorScheme: ColorScheme) -> Color {
    colorScheme == .dark ? palette.backgroundElevated : .white
}

private func linkWaveSolidBorderColor(colorScheme: ColorScheme) -> Color {
    colorScheme == .dark ? Color.white.opacity(0.10) : Color.black.opacity(0.09)
}

// Liquid Glass styling.
//
// Native Liquid Glass remains on system navigation chrome. Scroll cards use static,
// theme-aware fills and rims to avoid per-card backdrop sampling.

/// Shared card surface for LinkWave's primary screens and supporting cards.
public struct LinkWaveGlassCard: ViewModifier {
    var padding: CGFloat = 16
    @Environment(\.linkWaveSurfaceStyle) private var surfaceStyle
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.linkWaveThemePalette) private var palette

    public init(padding: CGFloat = 16) {
        self.padding = padding
    }

    @ViewBuilder
    public func body(content: Content) -> some View {
        let padded = content.padding(padding)
        let shape = RoundedRectangle(cornerRadius: 22, style: .continuous)
        switch surfaceStyle {
        case .liquidGlass:
            if #available(iOS 26.0, *) {
                liquidGlass(padded, shape: shape)
            } else {
                frosted(padded, shape: shape)
            }
        case .frosted:
            frosted(padded, shape: shape)
        case .cleanSolid:
            cleanSolid(padded, shape: shape)
        }
    }

    @available(iOS 26.0, *)
    private func liquidGlass(_ content: some View, shape: RoundedRectangle) -> some View {
        let sheenColors = colorScheme == .dark
            ? [Color.white.opacity(0.08), Color.white.opacity(0.015)]
            : [Color.white.opacity(0.94), Color.white.opacity(0.82)]
        let rimColors = colorScheme == .dark
            ? [Color.white.opacity(0.18), Color.white.opacity(0.06)]
            : [Color.white.opacity(0.95), Color.black.opacity(0.11)]

        return content
            .background {
                if colorScheme == .dark {
                    ZStack {
                        shape.fill(palette.backgroundSecondary.opacity(0.82))
                        shape.fill(LinearGradient(colors: sheenColors, startPoint: .top, endPoint: .bottom))
                    }
                } else {
                    shape.fill(LinearGradient(colors: sheenColors, startPoint: .top, endPoint: .bottom))
                }
            }
            .overlay {
                shape.stroke(
                    LinearGradient(colors: rimColors, startPoint: .top, endPoint: .bottom),
                    lineWidth: colorScheme == .dark ? 0.85 : 0.8
                )
            }
    }

    private func frosted(_ content: some View, shape: RoundedRectangle) -> some View {
        content
            .background {
                ZStack {
                    if colorScheme == .dark {
                        shape.fill(palette.backgroundSecondary.opacity(0.96))
                        shape.fill(palette.textAccent.opacity(0.025))
                    } else {
                        shape.fill(Color.white.opacity(0.90))
                    }
                    shape.fill(LinearGradient(
                        colors: [Color.white.opacity(0.04), .clear],
                        startPoint: .top,
                        endPoint: .bottom
                    ))
                }
            }
            .overlay {
                shape.stroke(
                    LinearGradient(
                        colors: colorScheme == .dark
                            ? [Color.white.opacity(0.09), Color.white.opacity(0.05)]
                            : [Color.white.opacity(0.55), Color.black.opacity(0.09)],
                        startPoint: .top,
                        endPoint: .bottom
                    ),
                    lineWidth: 0.75
                )
            }
    }

    private func cleanSolid(_ content: some View, shape: RoundedRectangle) -> some View {
        content
            .background(colorScheme == .dark ? palette.backgroundElevated : Color.white, in: shape)
            .overlay(shape.stroke(linkWaveSolidBorderColor(colorScheme: colorScheme), lineWidth: 1))
            .shadow(
                color: Color.black.opacity(colorScheme == .dark ? 0 : 0.04),
                radius: 2,
                y: 1
            )
    }

}

/// A chip or inset field that sits inside a glass card.
public struct LiquidGlassPillModifier: ViewModifier {
    public func body(content: Content) -> some View { content }
}

/// Full-width action button. Scroll content uses a bordered control, not a second glass layer.
public struct LiquidGlassActionButtonModifier: ViewModifier {
    let tint: Color?
    @Environment(\.linkWaveThemePalette) private var palette

    @ViewBuilder
    public func body(content: Content) -> some View {
        let resolvedTint = tint ?? palette.textAccent
        content.buttonStyle(.borderedProminent).tint(resolvedTint).controlSize(.large)
    }
}

/// Small secondary button for scroll content, using a lightweight bordered control.
public struct LiquidGlassSmallButtonModifier: ViewModifier {
    public func body(content: Content) -> some View {
        content.buttonStyle(.bordered).controlSize(.small)
    }
}

/// Soft coloured light behind the glass so the material has something to refract.
public struct LiquidGlassBackground: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.linkWaveThemePalette) private var palette
    @Environment(\.linkWaveSurfaceStyle) private var surfaceStyle
    private let artVariant: AmbientWaveArtView.Variant

    public init(isSheet: Bool = false) {
        artVariant = isSheet ? .sheet : .canvas
    }

    public var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .top) {
                if colorScheme == .light {
                    Color(red: 0.91, green: 0.933, blue: 0.961)
                    palette.backgroundPrimary.opacity(0.08)
                } else {
                    palette.backgroundPrimary
                }

                AmbientWaveArtView(variant: artVariant)

                if surfaceStyle != .cleanSolid {
                    ZStack(alignment: .top) {
                        LinearGradient(
                            colors: [
                                palette.textAccent.opacity(colorScheme == .dark ? 0.13 : 0.075),
                                palette.textAccent.opacity(colorScheme == .dark ? 0.045 : 0.025),
                                .clear
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                        RadialGradient(
                            colors: [palette.textAccent.opacity(colorScheme == .dark ? 0.075 : 0.045), .clear],
                            center: .top,
                            startRadius: 0,
                            endRadius: geometry.size.width * 0.9
                        )
                    }
                    .frame(height: geometry.size.height * 0.42)
                }
            }
        }
        .ignoresSafeArea()
    }
}

struct LinkWaveHairlineDivider: View {
    @Environment(\.colorScheme) private var colorScheme
    var leading: CGFloat = 0

    var body: some View {
        Rectangle()
            .fill(colorScheme == .dark ? Color.white.opacity(0.10) : Color.black.opacity(0.09))
            .frame(height: 0.5)
            .padding(.leading, leading)
            .accessibilityHidden(true)
    }
}

private struct LinkWaveThemedListSurfaceModifier: ViewModifier {
    @Environment(\.linkWaveThemePalette) private var palette
    @Environment(\.linkWaveSurfaceStyle) private var surfaceStyle

    func body(content: Content) -> some View {
        content
            .scrollContentBackground(.hidden)
            .background { LiquidGlassBackground(isSheet: true) }
            .listRowBackground(rowBackground)
            .listRowSeparatorTint(colorScheme == .dark ? Color.white.opacity(0.10) : Color.black.opacity(0.09))
            .foregroundStyle(palette.textPrimary.color)
            .tint(palette.accent.color)
    }

    @Environment(\.colorScheme) private var colorScheme

    private var rowBackground: AnyView {
        switch surfaceStyle {
        case .liquidGlass:
            AnyView(Color.clear)
        case .frosted:
            AnyView(
                Rectangle()
                    .fill(palette.backgroundSecondary.opacity(colorScheme == .dark ? 0.88 : 0.92))
                    .overlay(palette.textAccent.opacity(colorScheme == .dark ? 0.025 : 0.01))
            )
        case .cleanSolid:
            AnyView(palette.backgroundSecondary)
        }
    }
}

public extension View {
    func linkWaveGlassCard(padding: CGFloat = 16) -> some View {
        modifier(LinkWaveGlassCard(padding: padding))
    }

    /// Inset chip inside a glass card.
    func liquidGlassPill() -> some View {
        modifier(LiquidGlassPillModifier())
    }

    func liquidGlassActionButton(tint: Color? = nil) -> some View {
        modifier(LiquidGlassActionButtonModifier(tint: tint))
    }

    func liquidGlassSmallButton() -> some View {
        modifier(LiquidGlassSmallButtonModifier())
    }

    func linkWaveInteractiveGlassCapsule() -> some View {
        modifier(LinkWaveInteractiveGlassCapsuleModifier())
    }

    /// Feather scrolling content beneath navigation and tab bars on iOS 26.
    func liquidGlassScrollEdges() -> some View {
        modifier(LiquidGlassScrollEdgeEffectModifier())
    }

    /// Keeps vertical pull-to-refresh available on short and initially empty scroll views.
    func alwaysScrollBounce() -> some View {
        modifier(AlwaysScrollBounceModifier())
    }

    /// A compact capsule surface for controls such as the Clients filter menu.
    func liquidGlassCapsule() -> some View {
        modifier(LiquidGlassCapsuleModifier())
    }

    func liquidGlassToolbarCapsule() -> some View {
        modifier(LiquidGlassToolbarCapsuleModifier())
    }

    func linkWaveThemedListSurface() -> some View {
        modifier(LinkWaveThemedListSurfaceModifier())
    }

    func linkWaveTabBarSurface() -> some View {
        modifier(LinkWaveTabBarSurfaceModifier())
    }
}

/// A standalone trailing control that does not share the system toolbar's glass background.
struct StandaloneTopBarTrailingItem: ToolbarContent {
    private let content: AnyView

    init(content: AnyView) {
        self.content = content
    }

    @ToolbarContentBuilder
    var body: some ToolbarContent {
        if #available(iOS 26.0, *) {
            ToolbarItem(placement: .topBarTrailing) {
                content
            }
            .sharedBackgroundVisibility(.hidden)
        } else {
            ToolbarItem(placement: .topBarTrailing) {
                content
            }
        }
    }
}

struct StandaloneTopBarLeadingItem: ToolbarContent {
    private let content: AnyView

    init(content: AnyView) {
        self.content = content
    }

    @ToolbarContentBuilder
    var body: some ToolbarContent {
        if #available(iOS 26.0, *) {
            ToolbarItem(placement: .topBarLeading) {
                content
            }
            .sharedBackgroundVisibility(.hidden)
        } else {
            ToolbarItem(placement: .topBarLeading) {
                content
            }
        }
    }
}

private struct AlwaysScrollBounceModifier: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 16.4, *) {
            content.scrollBounceBehavior(.always)
        } else {
            content
        }
    }
}

struct RouterRefreshToolbarButton: View {
    @ObservedObject var viewModel: MonitorViewModel
    var isEnabled = true

    var body: some View {
        Button {
            Task { await viewModel.refreshAll(forceReauthIfNeeded: true) }
        } label: {
            Group {
                if viewModel.isRefreshing {
                    ProgressView().controlSize(.mini)
                } else {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 15, weight: .semibold))
                }
            }
            .frame(width: 38, height: 38)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .modifier(LiquidGlassToolbarCircleModifier())
        .frame(width: 44, height: 44)
        .accessibilityLabel("Refresh router data")
        .disabled(viewModel.isRefreshing || !isEnabled)
    }
}

struct LinkWaveToolbarIconButton: View {
    let symbol: String
    let accessibilityLabel: String
    var isDisabled = false
    var isLoading = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Group {
                if isLoading {
                    ProgressView().controlSize(.mini)
                } else {
                    Image(systemName: symbol)
                        .font(.system(size: 15, weight: .semibold))
                }
            }
            .frame(width: 38, height: 38)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .modifier(LiquidGlassToolbarCircleModifier())
        .frame(width: 44, height: 44)
        .contentShape(Circle())
        .accessibilityLabel(accessibilityLabel)
        .disabled(isDisabled)
    }
}

struct LiquidGlassToolbarCircleModifier: ViewModifier {
    @Environment(\.linkWaveSurfaceStyle) private var surfaceStyle
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.linkWaveThemePalette) private var palette

    @ViewBuilder
    func body(content: Content) -> some View {
        switch surfaceStyle {
        case .liquidGlass:
            if #available(iOS 26.0, *) {
                content.glassEffect(.regular.interactive(), in: Circle())
            } else {
                content.background(.regularMaterial, in: Circle())
            }
        case .frosted:
            content
                .background {
                    ZStack {
                        Circle().fill(.thinMaterial)
                        Circle().fill(palette.accent.color.opacity(colorScheme == .dark ? 0.08 : 0.05))
                    }
                }
                .overlay(Circle().stroke(palette.textSecondary.color.opacity(colorScheme == .dark ? 0.30 : 0.23), lineWidth: 1))
        case .cleanSolid:
            content
                .background(linkWaveSolidSurfaceColor(palette, colorScheme: colorScheme), in: Circle())
                .overlay(Circle().stroke(linkWaveSolidBorderColor(colorScheme: colorScheme), lineWidth: 1))
        }
    }
}

private struct LiquidGlassToolbarCapsuleModifier: ViewModifier {
    @Environment(\.linkWaveSurfaceStyle) private var surfaceStyle
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.linkWaveThemePalette) private var palette

    @ViewBuilder
    func body(content: Content) -> some View {
        switch surfaceStyle {
        case .liquidGlass:
            if #available(iOS 26.0, *) { content.glassEffect(.regular.interactive(), in: Capsule()) }
            else { content.background(.regularMaterial, in: Capsule()) }
        case .frosted:
            content.background {
                ZStack {
                    Capsule().fill(.thinMaterial)
                    Capsule().fill(palette.accent.color.opacity(colorScheme == .dark ? 0.08 : 0.05))
                }
            }
                .overlay(Capsule().stroke(palette.textSecondary.color.opacity(colorScheme == .dark ? 0.30 : 0.23), lineWidth: 1))
        case .cleanSolid:
            content.background(linkWaveSolidSurfaceColor(palette, colorScheme: colorScheme), in: Capsule())
                .overlay(Capsule().stroke(linkWaveSolidBorderColor(colorScheme: colorScheme), lineWidth: 1))
        }
    }
}

private struct LinkWaveInteractiveGlassCapsuleModifier: ViewModifier {
    @Environment(\.linkWaveSurfaceStyle) private var surfaceStyle
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.linkWaveThemePalette) private var palette

    @ViewBuilder
    func body(content: Content) -> some View {
        switch surfaceStyle {
        case .liquidGlass:
            content
                .background(palette.backgroundSecondary.opacity(colorScheme == .dark ? 0.82 : 0.86), in: Capsule())
                .overlay {
                    Capsule().stroke(
                        LinearGradient(
                            colors: colorScheme == .dark
                                ? [Color.white.opacity(0.18), Color.white.opacity(0.06)]
                                : [Color.white.opacity(0.95), Color.black.opacity(0.11)],
                            startPoint: .top,
                            endPoint: .bottom
                        ),
                        lineWidth: 0.75
                    )
                }
        case .frosted:
            content
                .background(palette.backgroundSecondary.opacity(colorScheme == .dark ? 0.92 : 0.90), in: Capsule())
                .overlay(Capsule().stroke(colorScheme == .dark ? Color.white.opacity(0.09) : Color.black.opacity(0.09), lineWidth: 0.75))
        case .cleanSolid:
            content.background(linkWaveSolidSurfaceColor(palette, colorScheme: colorScheme), in: Capsule())
                .overlay(Capsule().stroke(linkWaveSolidBorderColor(colorScheme: colorScheme), lineWidth: 1))
        }
    }
}

private struct LinkWaveTabBarSurfaceModifier: ViewModifier {
    @Environment(\.linkWaveSurfaceStyle) private var surfaceStyle
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.linkWaveThemePalette) private var palette

    func body(content: Content) -> some View {
        content
            .toolbarBackground(AnyShapeStyle(tabBarBackground), for: .tabBar)
            .toolbarBackground(surfaceStyle == .liquidGlass ? .automatic : .visible, for: .tabBar)
            .onAppear(perform: applyTabBarAppearance)
            .onChange(of: palette) { _ in applyTabBarAppearance() }
            .onChange(of: colorScheme) { _ in applyTabBarAppearance() }
    }

    private var tabBarBackground: AnyShapeStyle {
        switch surfaceStyle {
        case .liquidGlass: AnyShapeStyle(.bar)
        case .frosted: AnyShapeStyle(.thinMaterial)
        case .cleanSolid: AnyShapeStyle(linkWaveSolidSurfaceColor(palette, colorScheme: colorScheme))
        }
    }

    private func applyTabBarAppearance() {
        let appearance = UITabBar.appearance()
        appearance.tintColor = UIColor(palette.textAccent)
        appearance.unselectedItemTintColor = UIColor(
            red: colorScheme == .dark ? 0.63 : 0.38,
            green: colorScheme == .dark ? 0.67 : 0.42,
            blue: colorScheme == .dark ? 0.74 : 0.49,
            alpha: 1
        )
        appearance.selectionIndicatorImage = selectionIndicatorImage()
    }

    private func selectionIndicatorImage() -> UIImage {
        let itemWidth = UIScreen.main.bounds.width / 4
        let size = CGSize(width: itemWidth, height: 38)
        let rendererFormat = UIGraphicsImageRendererFormat()
        rendererFormat.scale = UIScreen.main.scale
        rendererFormat.opaque = false
        let image = UIGraphicsImageRenderer(size: size, format: rendererFormat).image { _ in
            UIColor(palette.textAccent.opacity(0.12)).setFill()
            UIBezierPath(
                roundedRect: CGRect(x: 12, y: 2, width: max(0, itemWidth - 24), height: 34),
                cornerRadius: 17
            ).fill()
        }
        return image.withRenderingMode(.alwaysOriginal)
    }
}

private struct LiquidGlassScrollEdgeEffectModifier: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content
                .scrollEdgeEffectStyle(.soft, for: .top)
                .scrollEdgeEffectStyle(.soft, for: .bottom)
        } else {
            content
        }
    }
}

private struct LiquidGlassCapsuleModifier: ViewModifier {
    @Environment(\.linkWaveSurfaceStyle) private var surfaceStyle
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.linkWaveThemePalette) private var palette

    @ViewBuilder
    func body(content: Content) -> some View {
        switch surfaceStyle {
        case .liquidGlass:
            content
                .background(palette.backgroundSecondary.opacity(colorScheme == .dark ? 0.82 : 0.86), in: Capsule())
                .overlay {
                    Capsule().stroke(
                        LinearGradient(
                            colors: colorScheme == .dark
                                ? [Color.white.opacity(0.18), Color.white.opacity(0.06)]
                                : [Color.white.opacity(0.95), Color.black.opacity(0.11)],
                            startPoint: .top,
                            endPoint: .bottom
                        ),
                        lineWidth: 0.75
                    )
                }
        case .frosted:
            content
                .background(palette.backgroundSecondary.opacity(colorScheme == .dark ? 0.92 : 0.90), in: Capsule())
                .overlay(Capsule().stroke(colorScheme == .dark ? Color.white.opacity(0.09) : Color.black.opacity(0.09), lineWidth: 0.75))
        case .cleanSolid:
            content.background(linkWaveSolidSurfaceColor(palette, colorScheme: colorScheme), in: Capsule())
                .overlay(Capsule().stroke(linkWaveSolidBorderColor(colorScheme: colorScheme), lineWidth: 1))
        }
    }
}

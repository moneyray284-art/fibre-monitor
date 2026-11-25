import SwiftUI

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
// On iOS 26+ everything here uses the system Liquid Glass material (`glassEffect`,
// `.glass` button styles), so it refracts, adapts to light/dark and reacts to touch
// like the rest of the OS. Earlier iOS versions fall back to blur materials.
//
// Following Apple's guidance, glass is only used for surfaces floating over the
// background (cards, banners, buttons). Chips *inside* a card use a plain system
// fill instead, because glass on top of glass can't sample what's behind it.

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
            : [Color.white.opacity(0.92), Color.white.opacity(0.74)]
        let rimColors = colorScheme == .dark
            ? [Color.white.opacity(0.18), Color.white.opacity(0.06)]
            : [Color.white.opacity(0.95), Color.black.opacity(0.11)]

        return content
            .background {
                ZStack {
                    shape.fill(.ultraThinMaterial)
                    if colorScheme == .dark {
                        shape.fill(palette.backgroundSecondary.opacity(0.72))
                    }
                    shape.fill(LinearGradient(colors: sheenColors, startPoint: .top, endPoint: .bottom))
                }
            }
            .glassEffect(.regular, in: shape)
            .overlay {
                shape.stroke(
                    LinearGradient(colors: rimColors, startPoint: .top, endPoint: .bottom),
                    lineWidth: colorScheme == .dark ? 0.85 : 0.8
                )
            }
            .shadow(
                color: Color.black.opacity(colorScheme == .dark ? 0.28 : 0.07),
                radius: colorScheme == .dark ? 14 : 8,
                y: colorScheme == .dark ? 6 : 3
            )
    }

    private func frosted(_ content: some View, shape: RoundedRectangle) -> some View {
        content
            .background {
                ZStack {
                    shape.fill(.thinMaterial)
                    if colorScheme == .dark {
                        shape.fill(palette.backgroundSecondary.opacity(0.72))
                    } else {
                        shape.fill(Color.white.opacity(0.84))
                    }
                    shape.fill(palette.textAccent.opacity(colorScheme == .dark ? 0.025 : 0.012))
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
            .shadow(
                color: Color.black.opacity(colorScheme == .dark ? 0.22 : 0.06),
                radius: colorScheme == .dark ? 10 : 6,
                y: colorScheme == .dark ? 5 : 2
            )
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

/// Pre-iOS 26 approximation using regular material and a soft shadow.
private struct LegacyGlassModifier: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.linkWaveThemePalette) private var palette

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: 22, style: .continuous)
        content
            .background(.regularMaterial, in: shape)
            .overlay(shape.fill(palette.bgSecondary.color.opacity(colorScheme == .dark ? 0.07 : 0.045)))
            .shadow(color: .black.opacity(colorScheme == .dark ? 0.35 : 0.06), radius: 14, y: 6)
    }
}

/// Full-width action button: prominent Liquid Glass on iOS 26, bordered prominent before.
public struct LiquidGlassActionButtonModifier: ViewModifier {
    let tint: Color?
    @Environment(\.linkWaveSurfaceStyle) private var surfaceStyle
    @Environment(\.linkWaveThemePalette) private var palette

    @ViewBuilder
    public func body(content: Content) -> some View {
        let resolvedTint = tint ?? palette.textAccent
        if #available(iOS 26.0, *), surfaceStyle == .liquidGlass {
            content.buttonStyle(.glassProminent).tint(resolvedTint).controlSize(.large)
        } else {
            content.buttonStyle(.borderedProminent).tint(resolvedTint).controlSize(.large)
        }
    }
}

/// Small secondary button (presets, expand chevrons): glass on iOS 26, bordered before.
public struct LiquidGlassSmallButtonModifier: ViewModifier {
    @Environment(\.linkWaveSurfaceStyle) private var surfaceStyle

    @ViewBuilder
    public func body(content: Content) -> some View {
        if #available(iOS 26.0, *), surfaceStyle == .liquidGlass {
            content.buttonStyle(.glass).controlSize(.small)
        } else {
            content.buttonStyle(.bordered).controlSize(.small)
        }
    }
}

/// Soft coloured light behind the glass so the material has something to refract.
public struct LiquidGlassBackground: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.linkWaveThemePalette) private var palette
    @Environment(\.linkWaveSurfaceStyle) private var surfaceStyle

    public init() {}

    public var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .top) {
                if colorScheme == .light {
                    Color(red: 0.91, green: 0.933, blue: 0.961)
                    palette.backgroundPrimary.opacity(0.08)
                } else {
                    palette.backgroundPrimary
                }

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
            .background { LiquidGlassBackground() }
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
                    .fill(.thinMaterial)
                    .overlay(palette.backgroundSecondary.opacity(0.52))
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

private struct LinkWaveTabBarSurfaceModifier: ViewModifier {
    @Environment(\.linkWaveSurfaceStyle) private var surfaceStyle
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.linkWaveThemePalette) private var palette

    func body(content: Content) -> some View {
        content
            .toolbarBackground(AnyShapeStyle(tabBarBackground), for: .tabBar)
            .toolbarBackground(surfaceStyle == .liquidGlass ? .automatic : .visible, for: .tabBar)
    }

    private var tabBarBackground: AnyShapeStyle {
        switch surfaceStyle {
        case .liquidGlass: AnyShapeStyle(.bar)
        case .frosted: AnyShapeStyle(.thinMaterial)
        case .cleanSolid: AnyShapeStyle(linkWaveSolidSurfaceColor(palette, colorScheme: colorScheme))
        }
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

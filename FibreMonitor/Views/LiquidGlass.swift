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
                padded
                    .glassEffect(.regular, in: shape)
                    .overlay(shape.stroke(Color.white.opacity(colorScheme == .dark ? 0.13 : 0.42), lineWidth: 0.7))
            } else {
                frosted(padded, shape: shape)
            }
        case .frosted:
            frosted(padded, shape: shape)
        case .cleanSolid:
            padded
                .background(palette.backgroundElevated, in: shape)
                .overlay(shape.stroke(palette.backgroundTertiary, lineWidth: 1))
        }
    }

    private func frosted(_ content: some View, shape: RoundedRectangle) -> some View {
        content
            .background {
                ZStack {
                    shape.fill(.thinMaterial)
                    shape.fill(palette.backgroundSecondary.opacity(colorScheme == .dark ? 0.20 : 0.38))
                    shape.fill(palette.textAccent.opacity(colorScheme == .dark ? 0.025 : 0.018))
                }
            }
            .overlay(shape.stroke(palette.textSecondary.color.opacity(colorScheme == .dark ? 0.30 : 0.23), lineWidth: 1))
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
        ZStack {
            palette.backgroundPrimary

            if surfaceStyle != .cleanSolid {
                GeometryReader { geo in
                    ZStack {
                        Circle()
                            .fill(palette.textAccent.opacity(colorScheme == .dark ? 0.08 : 0.055))
                            .frame(width: geo.size.width * 0.85)
                            .blur(radius: 70)
                            .offset(x: -geo.size.width * 0.22, y: -geo.size.height * 0.18)

                        Circle()
                            .fill(palette.textAccent.opacity(colorScheme == .dark ? 0.06 : 0.04))
                            .frame(width: geo.size.width * 0.75)
                            .blur(radius: 80)
                            .offset(x: geo.size.width * 0.32, y: geo.size.height * 0.12)

                        Circle()
                            .fill(palette.textAccent.opacity(colorScheme == .dark ? 0.045 : 0.04))
                            .frame(width: geo.size.width * 0.7)
                            .blur(radius: 75)
                            .offset(x: -geo.size.width * 0.1, y: geo.size.height * 0.42)
                    }
                }
            }
        }
        .ignoresSafeArea()
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
            .foregroundStyle(palette.textPrimary.color)
            .tint(palette.accent.color)
    }

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
                .background(linkWaveSolidSurfaceColor(colorScheme), in: Circle())
                .overlay(Circle().stroke(linkWaveSolidBorderColor(colorScheme), lineWidth: 1))
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
            content.background(linkWaveSolidSurfaceColor(colorScheme), in: Capsule())
                .overlay(Capsule().stroke(linkWaveSolidBorderColor(colorScheme), lineWidth: 1))
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
            content.background(linkWaveSolidSurfaceColor(colorScheme), in: Capsule())
                .overlay(Capsule().stroke(linkWaveSolidBorderColor(colorScheme), lineWidth: 1))
        }
    }
}

private struct LinkWaveTabBarSurfaceModifier: ViewModifier {
    @Environment(\.linkWaveSurfaceStyle) private var surfaceStyle
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        content
            .toolbarBackground(AnyShapeStyle(tabBarBackground), for: .tabBar)
            .toolbarBackground(surfaceStyle == .liquidGlass ? .automatic : .visible, for: .tabBar)
    }

    private var tabBarBackground: AnyShapeStyle {
        switch surfaceStyle {
        case .liquidGlass: AnyShapeStyle(.bar)
        case .frosted: AnyShapeStyle(.thinMaterial)
        case .cleanSolid: AnyShapeStyle(linkWaveSolidSurfaceColor(colorScheme))
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
            content.background(linkWaveSolidSurfaceColor(colorScheme), in: Capsule())
                .overlay(Capsule().stroke(linkWaveSolidBorderColor(colorScheme), lineWidth: 1))
        }
    }
}

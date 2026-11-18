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
                .background(colorScheme == .dark ? Color(red: 14.0 / 255.0, green: 19.0 / 255.0, blue: 29.0 / 255.0) : .white, in: shape)
                .overlay(shape.stroke(palette.textSecondary.color.opacity(colorScheme == .dark ? 0.28 : 0.16), lineWidth: 1))
        }
    }

    private func frosted(_ content: some View, shape: RoundedRectangle) -> some View {
        content
            .background(.ultraThinMaterial, in: shape)
            .overlay(shape.stroke(Color.white.opacity(colorScheme == .dark ? 0.16 : 0.56), lineWidth: 1))
            .overlay(shape.inset(by: 1).stroke(Color.white.opacity(colorScheme == .dark ? 0.045 : 0.20), lineWidth: 0.7))
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
    let tint: Color

    @ViewBuilder
    public func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.buttonStyle(.glassProminent).tint(tint).controlSize(.large)
        } else {
            content.buttonStyle(.borderedProminent).tint(tint).controlSize(.large)
        }
    }
}

/// Small secondary button (presets, expand chevrons): glass on iOS 26, bordered before.
public struct LiquidGlassSmallButtonModifier: ViewModifier {
    @ViewBuilder
    public func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
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
            colorScheme == .dark
                ? Color(red: 7.0 / 255.0, green: 9.0 / 255.0, blue: 14.0 / 255.0)
                : Color(red: 244.0 / 255.0, green: 246.0 / 255.0, blue: 250.0 / 255.0)

            if surfaceStyle != .cleanSolid {
                GeometryReader { geo in
                    ZStack {
                        Circle()
                            .fill(palette.accent.color.opacity(colorScheme == .dark ? 0.08 : 0.055))
                            .frame(width: geo.size.width * 0.85)
                            .blur(radius: 70)
                            .offset(x: -geo.size.width * 0.22, y: -geo.size.height * 0.18)

                        Circle()
                            .fill(palette.accent.color.opacity(colorScheme == .dark ? 0.06 : 0.04))
                            .frame(width: geo.size.width * 0.75)
                            .blur(radius: 80)
                            .offset(x: geo.size.width * 0.32, y: geo.size.height * 0.12)

                        Circle()
                            .fill(palette.accent.color.opacity(colorScheme == .dark ? 0.045 : 0.04))
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

public extension View {
    func linkWaveGlassCard(padding: CGFloat = 16) -> some View {
        modifier(LinkWaveGlassCard(padding: padding))
    }

    /// Inset chip inside a glass card.
    func liquidGlassPill() -> some View {
        modifier(LiquidGlassPillModifier())
    }

    func liquidGlassActionButton(tint: Color = .accentColor) -> some View {
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
                .background(.ultraThinMaterial, in: Circle())
                .overlay(Circle().stroke(Color.white.opacity(colorScheme == .dark ? 0.16 : 0.55), lineWidth: 1))
        case .cleanSolid:
            content
                .background(colorScheme == .dark ? Color(red: 14.0 / 255.0, green: 19.0 / 255.0, blue: 29.0 / 255.0) : .white, in: Circle())
                .overlay(Circle().stroke(palette.textSecondary.color.opacity(0.2), lineWidth: 1))
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
            content.background(.ultraThinMaterial, in: Capsule())
                .overlay(Capsule().stroke(Color.white.opacity(colorScheme == .dark ? 0.16 : 0.55), lineWidth: 1))
        case .cleanSolid:
            content.background(colorScheme == .dark ? Color(red: 14.0 / 255.0, green: 19.0 / 255.0, blue: 29.0 / 255.0) : .white, in: Capsule())
                .overlay(Capsule().stroke(palette.textSecondary.color.opacity(0.2), lineWidth: 1))
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
            content.background(.ultraThinMaterial, in: Capsule())
                .overlay(Capsule().stroke(Color.white.opacity(colorScheme == .dark ? 0.16 : 0.55), lineWidth: 1))
        case .cleanSolid:
            content.background(colorScheme == .dark ? Color(red: 14.0 / 255.0, green: 19.0 / 255.0, blue: 29.0 / 255.0) : .white, in: Capsule())
                .overlay(Capsule().stroke(palette.textSecondary.color.opacity(0.2), lineWidth: 1))
        }
    }
}

private struct LinkWaveTabBarSurfaceModifier: ViewModifier {
    @Environment(\.linkWaveSurfaceStyle) private var surfaceStyle
    @Environment(\.colorScheme) private var colorScheme

    @ViewBuilder
    func body(content: Content) -> some View {
        switch surfaceStyle {
        case .liquidGlass:
            content
        case .frosted:
            content
                .toolbarBackground(.ultraThinMaterial, for: .tabBar)
                .toolbarBackground(.visible, for: .tabBar)
        case .cleanSolid:
            content
                .toolbarBackground(colorScheme == .dark ? Color(red: 14.0 / 255.0, green: 19.0 / 255.0, blue: 29.0 / 255.0) : .white, for: .tabBar)
                .toolbarBackground(.visible, for: .tabBar)
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
            content.background(.ultraThinMaterial, in: Capsule())
                .overlay(Capsule().stroke(Color.white.opacity(colorScheme == .dark ? 0.16 : 0.55), lineWidth: 1))
        case .cleanSolid:
            content.background(colorScheme == .dark ? Color(red: 14.0 / 255.0, green: 19.0 / 255.0, blue: 29.0 / 255.0) : .white, in: Capsule())
                .overlay(Capsule().stroke(palette.textSecondary.color.opacity(0.2), lineWidth: 1))
        }
    }
}

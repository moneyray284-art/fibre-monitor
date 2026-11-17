import SwiftUI

// Liquid Glass styling.
//
// On iOS 26+ everything here uses the system Liquid Glass material (`glassEffect`,
// `.glass` button styles), so it refracts, adapts to light/dark and reacts to touch
// like the rest of the OS. Earlier iOS versions fall back to blur materials.
//
// Following Apple's guidance, glass is only used for surfaces floating over the
// background (cards, banners, buttons). Chips *inside* a card use a plain system
// fill instead, because glass on top of glass can't sample what's behind it.

/// A floating glass surface with padding, e.g. a dashboard card.
public struct LiquidGlassCardModifier: ViewModifier {
    var cornerRadius: CGFloat = 22
    var tint: Color? = nil
    var padding: CGFloat = 16

    @ViewBuilder
    public func body(content: Content) -> some View {
        let padded = content.padding(padding)
        if #available(iOS 26.0, *) {
            padded.glassEffect(
                tint.map { Glass.regular.tint($0.opacity(0.18)) } ?? .regular,
                in: .rect(cornerRadius: cornerRadius, style: .continuous)
            )
        } else {
            padded.modifier(LegacyGlassModifier(cornerRadius: cornerRadius, tint: tint))
        }
    }
}

/// A chip or inset field that sits inside a glass card.
public struct LiquidGlassPillModifier: ViewModifier {
    var cornerRadius: CGFloat = 12

    @ViewBuilder
    public func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        if #available(iOS 26.0, *) {
            content.background(.fill.tertiary, in: shape)
        } else {
            content
                .background(.thinMaterial, in: shape)
                .overlay(shape.stroke(Color.white.opacity(0.15), lineWidth: 0.8))
        }
    }
}

/// Pre-iOS 26 approximation: regular blur material with a hairline edge and soft shadow.
private struct LegacyGlassModifier: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme
    let cornerRadius: CGFloat
    let tint: Color?

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        content
            .background {
                ZStack {
                    if let tint { shape.fill(tint.opacity(colorScheme == .dark ? 0.08 : 0.04)) }
                    shape.fill(.regularMaterial)
                }
            }
            .overlay(
                shape.stroke(
                    LinearGradient(
                        colors: colorScheme == .dark
                            ? [.white.opacity(0.30), .white.opacity(0.08), .white.opacity(0.12)]
                            : [.white.opacity(0.85), .white.opacity(0.35), .white.opacity(0.55)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1
                )
            )
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

    public init() {}

    public var body: some View {
        ZStack {
            Color(colorScheme == .dark ? UIColor.systemBackground : UIColor.systemGroupedBackground)

            GeometryReader { geo in
                ZStack {
                    Circle()
                        .fill(Color(red: 0.90, green: 0.15, blue: 0.20).opacity(colorScheme == .dark ? 0.16 : 0.09))
                        .frame(width: geo.size.width * 0.85)
                        .blur(radius: 70)
                        .offset(x: -geo.size.width * 0.22, y: -geo.size.height * 0.18)

                    Circle()
                        .fill(Color.blue.opacity(colorScheme == .dark ? 0.14 : 0.08))
                        .frame(width: geo.size.width * 0.75)
                        .blur(radius: 80)
                        .offset(x: geo.size.width * 0.32, y: geo.size.height * 0.12)

                    Circle()
                        .fill(Color.purple.opacity(colorScheme == .dark ? 0.12 : 0.06))
                        .frame(width: geo.size.width * 0.7)
                        .blur(radius: 75)
                        .offset(x: -geo.size.width * 0.1, y: geo.size.height * 0.42)
                }
            }
        }
        .ignoresSafeArea()
    }
}

public extension View {
    /// Floating glass card with 16pt padding.
    func liquidGlassCard(tint: Color? = nil) -> some View {
        modifier(LiquidGlassCardModifier(tint: tint))
    }

    /// Floating glass surface with custom padding and corner radius (banners, chips on the background).
    func liquidGlassPanel(cornerRadius: CGFloat = 16, padding: CGFloat = 0) -> some View {
        modifier(LiquidGlassCardModifier(cornerRadius: cornerRadius, padding: padding))
    }

    /// Inset chip inside a glass card.
    func liquidGlassPill(cornerRadius: CGFloat = 12) -> some View {
        modifier(LiquidGlassPillModifier(cornerRadius: cornerRadius))
    }

    func liquidGlassActionButton(tint: Color = .accentColor) -> some View {
        modifier(LiquidGlassActionButtonModifier(tint: tint))
    }

    func liquidGlassSmallButton() -> some View {
        modifier(LiquidGlassSmallButtonModifier())
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
            Task { await viewModel.refreshAll() }
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
        .frame(width: 38, height: 38)
        .accessibilityLabel("Refresh router data")
        .disabled(viewModel.isRefreshing || !isEnabled)
    }
}

struct LiquidGlassToolbarCircleModifier: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.glassEffect(.regular, in: Circle())
        } else {
            content
                .background(.regularMaterial, in: Circle())
                .overlay(Circle().stroke(Color.primary.opacity(0.1), lineWidth: 0.8))
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
    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.glassEffect(.regular, in: .capsule)
        } else {
            content
                .background(.regularMaterial, in: Capsule())
                .overlay(Capsule().stroke(Color.white.opacity(0.16), lineWidth: 0.8))
        }
    }
}

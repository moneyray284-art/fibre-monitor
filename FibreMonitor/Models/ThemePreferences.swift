import SwiftUI
import UIKit

public struct CodableColor: Codable, Equatable {
    public var red: Double
    public var green: Double
    public var blue: Double
    public var alpha: Double

    public init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = Self.normalized(red)
        self.green = Self.normalized(green)
        self.blue = Self.normalized(blue)
        self.alpha = Self.normalized(alpha)
    }

    @MainActor
    public init(color: Color) {
        let uiColor = UIColor(color)
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 1
        if uiColor.getRed(&red, green: &green, blue: &blue, alpha: &alpha) {
            self.init(red: Double(red), green: Double(green), blue: Double(blue), alpha: Double(alpha))
        } else {
            self.init(red: 0.5, green: 0.5, blue: 0.5)
        }
    }

    public var color: Color {
        Color(.sRGB, red: red, green: green, blue: blue, opacity: alpha)
    }

    private static func normalized(_ value: Double) -> Double {
        guard value.isFinite else { return 0.5 }
        return min(max(value, 0), 1)
    }
}

public struct ThemePalette: Codable, Equatable {
    public var bgPrimary: CodableColor
    public var bgSecondary: CodableColor
    public var bgTertiary: CodableColor
    public var bgElevated: CodableColor
    public var textPrimary: CodableColor
    public var textSecondary: CodableColor
    public var textTertiary: CodableColor
    public var accent: CodableColor

    public init(
        bgPrimary: CodableColor,
        bgSecondary: CodableColor,
        bgTertiary: CodableColor,
        bgElevated: CodableColor,
        textPrimary: CodableColor,
        textSecondary: CodableColor,
        textTertiary: CodableColor,
        accent: CodableColor
    ) {
        self.bgPrimary = bgPrimary
        self.bgSecondary = bgSecondary
        self.bgTertiary = bgTertiary
        self.bgElevated = bgElevated
        self.textPrimary = textPrimary
        self.textSecondary = textSecondary
        self.textTertiary = textTertiary
        self.accent = accent
    }
}

public enum AppThemePreset: String, CaseIterable, Identifiable, Codable {
    case linkWaveDefault
    case midnight
    case emerald
    case sunset
    case luna

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .linkWaveDefault: "LinkWave Default"
        case .midnight: "Midnight"
        case .emerald: "Emerald"
        case .sunset: "Sunset"
        case .luna: "Luna"
        }
    }

    public var symbolName: String {
        switch self {
        case .linkWaveDefault: "waveform.path.ecg"
        case .midnight: "moon.stars.fill"
        case .emerald: "leaf.fill"
        case .sunset: "sun.horizon.fill"
        case .luna: "moon.fill"
        }
    }

    public var lightPalette: ThemePalette {
        switch self {
        case .linkWaveDefault:
            ThemePalette(bgPrimary: .init(red: 0.965, green: 0.969, blue: 0.976), bgSecondary: .init(red: 1, green: 1, blue: 1), bgTertiary: .init(red: 0.935, green: 0.942, blue: 0.955), bgElevated: .init(red: 0.985, green: 0.988, blue: 0.994), textPrimary: .init(red: 0.08, green: 0.09, blue: 0.11), textSecondary: .init(red: 0.36, green: 0.39, blue: 0.44), textTertiary: .init(red: 0.55, green: 0.58, blue: 0.63), accent: .init(red: 0.008, green: 0.518, blue: 0.78))
        case .midnight:
            ThemePalette(bgPrimary: .init(red: 0.948, green: 0.962, blue: 0.986), bgSecondary: .init(red: 0.985, green: 0.991, blue: 1), bgTertiary: .init(red: 0.912, green: 0.934, blue: 0.972), bgElevated: .init(red: 0.968, green: 0.978, blue: 0.996), textPrimary: .init(red: 0.075, green: 0.095, blue: 0.14), textSecondary: .init(red: 0.34, green: 0.385, blue: 0.47), textTertiary: .init(red: 0.53, green: 0.575, blue: 0.655), accent: .init(red: 0.145, green: 0.388, blue: 0.922))
        case .emerald:
            ThemePalette(bgPrimary: .init(red: 0.948, green: 0.978, blue: 0.962), bgSecondary: .init(red: 0.986, green: 0.998, blue: 0.991), bgTertiary: .init(red: 0.91, green: 0.958, blue: 0.932), bgElevated: .init(red: 0.968, green: 0.99, blue: 0.978), textPrimary: .init(red: 0.075, green: 0.125, blue: 0.1), textSecondary: .init(red: 0.335, green: 0.435, blue: 0.385), textTertiary: .init(red: 0.52, green: 0.615, blue: 0.565), accent: .init(red: 0.063, green: 0.725, blue: 0.506))
        case .sunset:
            ThemePalette(bgPrimary: .init(red: 0.986, green: 0.96, blue: 0.948), bgSecondary: .init(red: 1, green: 0.99, blue: 0.985), bgTertiary: .init(red: 0.968, green: 0.928, blue: 0.908), bgElevated: .init(red: 0.995, green: 0.976, blue: 0.966), textPrimary: .init(red: 0.145, green: 0.09, blue: 0.075), textSecondary: .init(red: 0.46, green: 0.365, blue: 0.335), textTertiary: .init(red: 0.64, green: 0.545, blue: 0.515), accent: .init(red: 0.945, green: 0.39, blue: 0.22))
        case .luna:
            ThemePalette(bgPrimary: .init(red: 0.964, green: 0.952, blue: 0.986), bgSecondary: .init(red: 0.992, green: 0.988, blue: 1), bgTertiary: .init(red: 0.936, green: 0.916, blue: 0.972), bgElevated: .init(red: 0.98, green: 0.972, blue: 0.996), textPrimary: .init(red: 0.105, green: 0.085, blue: 0.145), textSecondary: .init(red: 0.4, green: 0.36, blue: 0.475), textTertiary: .init(red: 0.585, green: 0.545, blue: 0.655), accent: .init(red: 0.545, green: 0.361, blue: 0.965))
        }
    }

    public var darkPalette: ThemePalette {
        switch self {
        case .linkWaveDefault:
            ThemePalette(bgPrimary: .init(red: 0.055, green: 0.06, blue: 0.072), bgSecondary: .init(red: 0.095, green: 0.102, blue: 0.12), bgTertiary: .init(red: 0.135, green: 0.145, blue: 0.168), bgElevated: .init(red: 0.165, green: 0.178, blue: 0.205), textPrimary: .init(red: 0.965, green: 0.97, blue: 0.98), textSecondary: .init(red: 0.64, green: 0.665, blue: 0.715), textTertiary: .init(red: 0.44, green: 0.465, blue: 0.515), accent: .init(red: 0.133, green: 0.827, blue: 0.933))
        case .midnight:
            ThemePalette(bgPrimary: .init(red: 0.048, green: 0.06, blue: 0.088), bgSecondary: .init(red: 0.082, green: 0.1, blue: 0.142), bgTertiary: .init(red: 0.118, green: 0.142, blue: 0.195), bgElevated: .init(red: 0.148, green: 0.176, blue: 0.238), textPrimary: .init(red: 0.955, green: 0.97, blue: 0.995), textSecondary: .init(red: 0.61, green: 0.655, blue: 0.745), textTertiary: .init(red: 0.415, green: 0.46, blue: 0.55), accent: .init(red: 0.231, green: 0.51, blue: 0.965))
        case .emerald:
            ThemePalette(bgPrimary: .init(red: 0.048, green: 0.075, blue: 0.064), bgSecondary: .init(red: 0.082, green: 0.122, blue: 0.105), bgTertiary: .init(red: 0.118, green: 0.168, blue: 0.146), bgElevated: .init(red: 0.148, green: 0.205, blue: 0.18), textPrimary: .init(red: 0.955, green: 0.985, blue: 0.972), textSecondary: .init(red: 0.615, green: 0.715, blue: 0.675), textTertiary: .init(red: 0.42, green: 0.52, blue: 0.48), accent: .init(red: 0.204, green: 0.827, blue: 0.6))
        case .sunset:
            ThemePalette(bgPrimary: .init(red: 0.08, green: 0.056, blue: 0.05), bgSecondary: .init(red: 0.128, green: 0.092, blue: 0.084), bgTertiary: .init(red: 0.175, green: 0.13, blue: 0.118), bgElevated: .init(red: 0.212, green: 0.16, blue: 0.146), textPrimary: .init(red: 0.988, green: 0.965, blue: 0.958), textSecondary: .init(red: 0.735, green: 0.64, blue: 0.618), textTertiary: .init(red: 0.535, green: 0.445, blue: 0.425), accent: .init(red: 0.984, green: 0.573, blue: 0.235))
        case .luna:
            ThemePalette(bgPrimary: .init(red: 0.066, green: 0.054, blue: 0.088), bgSecondary: .init(red: 0.108, green: 0.09, blue: 0.142), bgTertiary: .init(red: 0.15, green: 0.126, blue: 0.195), bgElevated: .init(red: 0.185, green: 0.156, blue: 0.238), textPrimary: .init(red: 0.972, green: 0.96, blue: 0.995), textSecondary: .init(red: 0.665, green: 0.625, blue: 0.745), textTertiary: .init(red: 0.465, green: 0.425, blue: 0.55), accent: .init(red: 0.655, green: 0.545, blue: 0.98))
        }
    }

    public func previewDots(for scheme: ColorScheme) -> [Color] {
        let palette = scheme == .dark ? darkPalette : lightPalette
        return [palette.bgPrimary.color, palette.bgSecondary.color, palette.bgTertiary.color, palette.accent.color]
    }
}

public enum HapticLevel: String, CaseIterable, Identifiable, Codable {
    case off
    case light
    case medium
    case heavy

    public var id: String { rawValue }
    public var title: String { rawValue.capitalized }

    public var symbolName: String {
        switch self {
        case .off: "speaker.slash"
        case .light: "waveform.path"
        case .medium: "waveform"
        case .heavy: "waveform.badge.plus"
        }
    }

    public var impactStyle: UIImpactFeedbackGenerator.FeedbackStyle? {
        switch self {
        case .off: nil
        case .light: .light
        case .medium: .medium
        case .heavy: .heavy
        }
    }
}

extension AppAccentColor {
    @MainActor
    static func closest(to color: Color) -> AppAccentColor {
        let target = CodableColor(color: color)
        return allCases.min { lhs, rhs in
            Self.distance(CodableColor(color: lhs.color), target)
                < Self.distance(CodableColor(color: rhs.color), target)
        } ?? .blue
    }

    private static func distance(_ lhs: CodableColor, _ rhs: CodableColor) -> Double {
        let red = lhs.red - rhs.red
        let green = lhs.green - rhs.green
        let blue = lhs.blue - rhs.blue
        return red * red + green * green + blue * blue
    }
}

enum LinkWaveTextTone {
    case primary
    case secondary
    case tertiary
}

private struct LinkWaveThemePaletteKey: EnvironmentKey {
    static let defaultValue = AppThemePreset.linkWaveDefault.lightPalette
}

extension EnvironmentValues {
    var linkWaveThemePalette: ThemePalette {
        get { self[LinkWaveThemePaletteKey.self] }
        set { self[LinkWaveThemePaletteKey.self] = newValue }
    }
}

private struct LinkWaveForegroundModifier: ViewModifier {
    @Environment(\.linkWaveThemePalette) private var palette
    let tone: LinkWaveTextTone

    @ViewBuilder
    func body(content: Content) -> some View {
        switch tone {
        case .primary: content.foregroundStyle(palette.textPrimary.color)
        case .secondary: content.foregroundStyle(palette.textSecondary.color)
        case .tertiary: content.foregroundStyle(palette.textTertiary.color)
        }
    }
}

extension View {
    func linkWaveText(_ tone: LinkWaveTextTone) -> some View {
        modifier(LinkWaveForegroundModifier(tone: tone))
    }
}

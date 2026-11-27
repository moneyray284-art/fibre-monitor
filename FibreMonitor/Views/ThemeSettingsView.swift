import SwiftUI

struct ThemeSettingsView: View {
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject var settings: SettingsStore
    @AppStorage("linkwave_bg_pattern") private var backgroundPatternRawValue = BackgroundPatternID.waves.rawValue
    @State private var activeResetAlert: ResetAlertType?

    private enum ResetAlertType {
        case light
        case dark
        case everything

        var title: String {
            switch self {
            case .light: "Reset Light Theme?"
            case .dark: "Reset Dark Theme?"
            case .everything: "Reset Theme and Haptics?"
            }
        }

        var message: String {
            switch self {
            case .light: "Restore the Light palette to LinkWave defaults?"
            case .dark: "Restore the Dark palette to LinkWave defaults?"
            case .everything: "Restore both palettes and haptics to LinkWave defaults?"
            }
        }
    }

    private var palette: ThemePalette { settings.themePalette(for: colorScheme) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                themesSection
                accentColorSection
                backgroundPatternSection
                backgroundsSection
                textColorsSection
                resetSection
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
        }
        .background { LiquidGlassBackground(isSheet: true) }
        .environment(\.linkWaveThemePalette, palette)
        .linkWaveText(.primary)
        .navigationTitle("Theme & Colors")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)
        .alert(
            activeResetAlert?.title ?? "Reset Theme?",
            isPresented: Binding(
                get: { activeResetAlert != nil },
                set: { if !$0 { activeResetAlert = nil } }
            ),
            presenting: activeResetAlert
        ) { alertType in
            Button("Reset", role: .destructive) {
                Haptics.impact(.medium)
                switch alertType {
                case .light: settings.resetLightTheme()
                case .dark: settings.resetDarkTheme()
                case .everything: settings.resetEverything()
                }
                activeResetAlert = nil
            }
            Button("Cancel", role: .cancel) { activeResetAlert = nil }
        } message: { alertType in
            Text(alertType.message)
        }
    }

    private var backgroundsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("BACKGROUNDS", badge: colorScheme == .dark ? "DARK" : "LIGHT")
            cardContainer {
                colorPickerRow("Primary", keyPath: \.bgPrimary)
                divider
                colorPickerRow("Secondary", keyPath: \.bgSecondary)
                divider
                colorPickerRow("Tertiary", keyPath: \.bgTertiary)
                divider
                colorPickerRow("Elevated", keyPath: \.bgElevated)
            }
        }
    }

    private var textColorsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("TEXT COLORS", badge: colorScheme == .dark ? "DARK" : "LIGHT")
            cardContainer {
                colorPickerRow("Primary", keyPath: \.textPrimary)
                divider
                colorPickerRow("Secondary", keyPath: \.textSecondary)
                divider
                colorPickerRow("Tertiary", keyPath: \.textTertiary)
            }
        }
    }

    private var backgroundPatternSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("BACKGROUND PATTERN")
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                ForEach(BackgroundPatternID.allCases) { pattern in
                    let isSelected = backgroundPatternRawValue == pattern.rawValue
                    Button {
                        Haptics.impact(.light)
                        backgroundPatternRawValue = pattern.rawValue
                    } label: {
                        VStack(alignment: .leading, spacing: 8) {
                            ZStack(alignment: .topTrailing) {
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .fill(palette.backgroundTertiary.opacity(colorScheme == .dark ? 0.48 : 0.52))
                                BackgroundPatternPreview(pattern: pattern, accentColor: palette.textAccent)
                                    .padding(3)
                                if isSelected {
                                    Image(systemName: "checkmark.circle.fill")
                                        .font(.system(size: 17, weight: .semibold))
                                        .foregroundStyle(palette.textAccent)
                                        .padding(5)
                                        .background(palette.backgroundSecondary.opacity(0.9), in: Circle())
                                        .padding(6)
                                }
                            }
                            .frame(height: 68)

                            Text(pattern.title)
                                .font(.caption.weight(isSelected ? .semibold : .medium))
                                .foregroundStyle(palette.textPrimary.color)
                                .lineLimit(1)
                                .minimumScaleFactor(0.85)
                        }
                        .padding(9)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            isSelected ? palette.textAccent.opacity(0.09) : palette.backgroundSecondary.opacity(0.38),
                            in: RoundedRectangle(cornerRadius: 15, style: .continuous)
                        )
                        .overlay {
                            RoundedRectangle(cornerRadius: 15, style: .continuous)
                                .stroke(
                                    isSelected ? palette.textAccent.opacity(0.42) : palette.textTertiary.color.opacity(0.18),
                                    lineWidth: isSelected ? 1 : 0.7
                                )
                        }
                        .contentShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(isSelected ? .isSelected : [])
                }
            }
        }
    }

    private var accentColorSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("ACCENT COLOR", badge: colorScheme == .dark ? "DARK" : "LIGHT")
            cardContainer {
                HStack(spacing: 12) {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(palette.accent.color)
                        .frame(width: 26, height: 26)
                        .overlay {
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .strokeBorder(palette.textTertiary.color.opacity(0.25), lineWidth: 1)
                        }
                    Text("Accent Color")
                        .font(.system(size: 16))
                        .foregroundStyle(palette.textPrimary.color)
                    Spacer()
                    ColorPicker(
                        "Accent Color",
                        selection: colorBinding(\.accent),
                        supportsOpacity: false
                    )
                    .labelsHidden()
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
            }
        }
    }

    private var themesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("PRESET THEMES")
            cardContainer {
                Toggle("Auto-Match Accent Theme", isOn: Binding(
                    get: { settings.autoMatchAppIconToAccentColor },
                    set: { settings.setAutoMatchAccentTheme($0, sourceScheme: colorScheme) }
                ))
                .accessibilityHint("Keeps the Light and Dark accent colors in sync. The app icon and Logo Color remain independent.")
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                divider

                ForEach(Array(AppThemePreset.allCases.enumerated()), id: \.element.id) { index, preset in
                    let isActivePreset = settings.activePreset(for: colorScheme) == preset
                    Button {
                        Haptics.impact(.light)
                        settings.applyThemePreset(preset, for: colorScheme)
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: preset.symbolName)
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundStyle(palette.accent.color)
                                .frame(width: 24)

                            HStack(spacing: -6) {
                                ForEach(Array(preset.previewDots(for: colorScheme).enumerated()), id: \.offset) { _, color in
                                    Circle()
                                        .fill(color)
                                        .frame(width: 16, height: 16)
                                        .overlay(Circle().strokeBorder(Color.primary.opacity(0.18), lineWidth: 1))
                                }
                            }
                            .id("\(preset.id)-\(colorScheme == .dark ? "dark" : "light")")

                            Text(preset.title)
                                .font(.system(size: 16, weight: isActivePreset ? .semibold : .regular))
                                .foregroundStyle(palette.textPrimary.color)

                            Spacer()

                            if isActivePreset {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 14, weight: .bold))
                                    .foregroundStyle(palette.accent.color)
                            }
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 13)
                        .background(isActivePreset ? palette.accent.color.opacity(0.08) : .clear)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    if index < AppThemePreset.allCases.count - 1 { divider }
                }
            }
        }
    }

    private var resetSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("RESET")
            cardContainer {
                resetRow("Reset Light Theme", icon: "sun.max.fill", color: .orange) {
                    Haptics.impact(.light)
                    activeResetAlert = .light
                }
                divider
                resetRow("Reset Dark Theme", icon: "moon.fill", color: .purple) {
                    Haptics.impact(.light)
                    activeResetAlert = .dark
                }
                divider
                resetRow("Reset Everything", icon: "arrow.counterclockwise.circle.fill", color: .red) {
                    Haptics.impact(.medium)
                    activeResetAlert = .everything
                }
            }
            Text("Resetting restores LinkWave's default colors. Reset Everything also restores Light haptics.")
                .font(.footnote)
                .linkWaveText(.tertiary)
                .padding(.horizontal, 6)
        }
    }

    private func sectionHeader(_ title: String, badge: String? = nil) -> some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.caption.weight(.semibold))
                .linkWaveText(.secondary)
            if let badge {
                Text(badge)
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(palette.accent.color)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(palette.accent.color.opacity(0.12), in: Capsule())
            }
            Spacer()
        }
        .padding(.horizontal, 6)
    }

    private func cardContainer<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(spacing: 0, content: content)
            .linkWaveGlassCard(padding: 0)
    }

    private var divider: some View {
        LinkWaveHairlineDivider()
            .padding(.leading, 50)
    }

    private func colorPickerRow(
        _ title: String,
        keyPath: WritableKeyPath<ThemePalette, CodableColor>
    ) -> some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(palette[keyPath: keyPath].color)
                .frame(width: 26, height: 26)
                .overlay {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(palette.textTertiary.color.opacity(0.25), lineWidth: 1)
                }
            Text(title)
                .font(.system(size: 16))
                .foregroundStyle(palette.textPrimary.color)
            Spacer()
            ColorPicker("", selection: colorBinding(keyPath), supportsOpacity: false)
                .labelsHidden()
                .accessibilityLabel("\(title) color")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private func resetRow(_ title: String, icon: String, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(color)
                    .frame(width: 24)
                Text(title)
                    .font(.system(size: 16))
                    .foregroundStyle(palette.textPrimary.color)
                Spacer()
                Image(systemName: "arrow.counterclockwise")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(palette.textTertiary.color)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 13)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func colorBinding(_ keyPath: WritableKeyPath<ThemePalette, CodableColor>) -> Binding<Color> {
        Binding(
            get: { settings.themePalette(for: colorScheme)[keyPath: keyPath].color },
            set: { settings.setThemeColor($0, for: keyPath, scheme: colorScheme) }
        )
    }
}

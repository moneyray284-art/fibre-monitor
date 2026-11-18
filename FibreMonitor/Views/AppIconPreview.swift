import SwiftUI

struct AppIconPickerTile: View {
    let choice: AppIconChoice
    let isSelected: Bool
    let accent: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 7) {
                LinkWaveAppIconPreview(choice: choice, accent: accent)
                    .frame(width: 66, height: 66)

                Text(choice.title)
                    .font(.caption.weight(isSelected ? .semibold : .medium))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)

                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(isSelected ? accent : .secondary.opacity(0.55))
                    .accessibilityHidden(true)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 9)
            .background(
                isSelected ? accent.opacity(0.09) : Color.clear,
                in: RoundedRectangle(cornerRadius: 16, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(isSelected ? accent.opacity(0.45) : Color.primary.opacity(0.08), lineWidth: 1)
            }
            .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(choice.title) app icon\(isSelected ? ", selected" : "")")
    }
}

private struct LinkWaveAppIconPreview: View {
    let choice: AppIconChoice
    let accent: Color

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(backgroundGradient)

            artwork
                .padding(13)
        }
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.white.opacity(0.22), lineWidth: 0.8)
        }
        .shadow(color: .black.opacity(0.17), radius: 5, y: 3)
    }

    private var backgroundGradient: LinearGradient {
        let colors: [Color] = choice == .classic
            ? [Color(red: 0.18, green: 0.47, blue: 0.94), Color(red: 0.055, green: 0.15, blue: 0.38)]
            : [Color(red: 0.09, green: 0.20, blue: 0.32), Color(red: 0.025, green: 0.045, blue: 0.09)]
        return LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    @ViewBuilder
    private var artwork: some View {
        switch choice {
        case .launchArcs:
            LinkWaveIconArcMark().stroke(accent, style: StrokeStyle(lineWidth: 3.4, lineCap: .round, lineJoin: .round))
                .frame(width: 39, height: 40)
        case .monogramI:
            HarmonicNodeIPreview(color: accent, stem: .white)
                .frame(width: 16, height: 40)
        case .arcsI:
            HStack(spacing: 2) {
                LinkWaveIconArcMark().stroke(accent, style: StrokeStyle(lineWidth: 3.2, lineCap: .round, lineJoin: .round))
                    .frame(width: 31, height: 38)
                HarmonicNodeIPreview(color: .white, stem: .white)
                    .frame(width: 13, height: 38)
            }
        case .linkRing:
            LinkWaveLinkRing(accent: accent)
                .frame(width: 43, height: 40)
        case .wavefrontW:
            LinkWaveWaveW().stroke(accent, style: StrokeStyle(lineWidth: 4.2, lineCap: .round, lineJoin: .round))
                .frame(width: 43, height: 35)
        case .classic, .orange, .blue, .purple, .green:
            ClassicWiFiPreviewMark()
                .frame(width: 38, height: 38)
        }
    }
}

private struct ClassicWiFiPreviewMark: View {
    private let blue = Color(red: 93.0 / 255.0, green: 205.0 / 255.0, blue: 226.0 / 255.0)

    var body: some View {
        GeometryReader { geometry in
            let center = CGPoint(x: geometry.size.width / 2, y: geometry.size.height * 0.73)
            ZStack {
                Path { path in
                    for fraction in [0.44, 0.31, 0.18] {
                        path.addArc(
                            center: center,
                            radius: geometry.size.width * fraction,
                            startAngle: .degrees(225),
                            endAngle: .degrees(315),
                            clockwise: false
                        )
                    }
                }
                .stroke(blue, style: StrokeStyle(lineWidth: 2.8, lineCap: .round, lineJoin: .round))

                Circle()
                    .fill(blue)
                    .frame(width: 5, height: 5)
                    .position(center)
            }
        }
    }
}

private struct HarmonicNodeIPreview: View {
    let color: Color
    let stem: Color

    var body: some View {
        GeometryReader { geometry in
            let scale = geometry.size.height / 31
            ZStack(alignment: .top) {
                Circle()
                    .stroke(color.opacity(0.72), lineWidth: max(1, scale))
                    .frame(width: 6 * scale, height: 6 * scale)
                    .position(x: geometry.size.width / 2, y: 5.5 * scale)
                Circle()
                    .fill(color)
                    .frame(width: 4.5 * scale, height: 4.5 * scale)
                    .position(x: geometry.size.width / 2, y: 7.75 * scale)
                Capsule()
                    .fill(stem)
                    .frame(width: 3.2 * scale, height: 17 * scale)
                    .position(x: geometry.size.width / 2, y: 21.5 * scale)
            }
        }
    }
}

/// Uses the same three bezier arcs and proportions as the launch mark.
private struct LinkWaveIconArcMark: Shape {
    func path(in rect: CGRect) -> Path {
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + x * rect.width, y: rect.minY + y * rect.height)
        }

        var path = Path()
        path.move(to: point(0.61, 0.04))
        path.addCurve(to: point(0.61, 0.96), control1: point(1.02, 0.24), control2: point(1.02, 0.76))
        path.move(to: point(0.39, 0.20))
        path.addCurve(to: point(0.39, 0.80), control1: point(0.72, 0.34), control2: point(0.72, 0.66))
        path.move(to: point(0.18, 0.35))
        path.addCurve(to: point(0.18, 0.65), control1: point(0.39, 0.43), control2: point(0.39, 0.57))
        return path
    }
}

private struct LinkWaveLinkRing: View {
    let accent: Color

    var body: some View {
        ZStack {
            Circle()
                .trim(from: 0.04, to: 0.46)
                .stroke(accent, style: StrokeStyle(lineWidth: 4.2, lineCap: .round))
                .rotationEffect(.degrees(42))
            Circle()
                .trim(from: 0.54, to: 0.96)
                .stroke(.white, style: StrokeStyle(lineWidth: 4.2, lineCap: .round))
                .rotationEffect(.degrees(42))
            Circle().fill(accent).frame(width: 5, height: 5).offset(x: 15, y: -14)
            Circle().fill(.white).frame(width: 5, height: 5).offset(x: -15, y: 14)
        }
    }
}

private struct LinkWaveWaveW: Shape {
    func path(in rect: CGRect) -> Path {
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + x * rect.width, y: rect.minY + y * rect.height)
        }

        var path = Path()
        path.move(to: point(0.04, 0.18))
        path.addCurve(to: point(0.27, 0.78), control1: point(0.13, 0.18), control2: point(0.16, 0.78))
        path.addCurve(to: point(0.50, 0.30), control1: point(0.35, 0.78), control2: point(0.41, 0.30))
        path.addCurve(to: point(0.73, 0.78), control1: point(0.59, 0.30), control2: point(0.65, 0.78))
        path.addCurve(to: point(0.96, 0.18), control1: point(0.84, 0.78), control2: point(0.87, 0.18))
        return path
    }
}

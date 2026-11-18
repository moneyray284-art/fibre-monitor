import SwiftUI

/// Lightweight, one-shot LinkWave launch mark.
/// MainTabView removes this view after its 1.8 second presentation and short fade.
struct LinkWaveLaunchAnimation: View {
    let onFinished: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var waveProgress: CGFloat = 0
    @State private var logoIsVisible = false
    @State private var nodesArePulsing = false
    @State private var didFinish = false

    private let brandCyan = Color(
        red: 34.0 / 255.0,
        green: 211.0 / 255.0,
        blue: 238.0 / 255.0
    )
    private let backgroundColor = Color(
        red: 7.0 / 255.0,
        green: 9.0 / 255.0,
        blue: 14.0 / 255.0
    )

    var body: some View {
        ZStack {
            backgroundColor
                .ignoresSafeArea()

            Circle()
                .fill(
                    RadialGradient(
                        colors: [brandCyan.opacity(0.2), brandCyan.opacity(0.035), .clear],
                        center: .center,
                        startRadius: 0,
                        endRadius: 140
                    )
                )
                .frame(width: 280, height: 280)
                .scaleEffect(nodesArePulsing ? 1.08 : 0.92)
                .opacity(logoIsVisible ? 1 : 0.42)
                .animation(
                    reduceMotion ? nil : .easeInOut(duration: 0.78).repeatForever(autoreverses: true),
                    value: nodesArePulsing
                )

            HStack(spacing: 14) {
                HarmonicWaveMark(
                    progress: waveProgress,
                    nodesArePulsing: nodesArePulsing,
                    color: brandCyan
                )
                .frame(width: 58, height: 70)
                .accessibilityHidden(true)

                LinkWaveWordmark(
                    nodesArePulsing: nodesArePulsing,
                    white: .white,
                    cyan: brandCyan,
                    stemColor: brandCyan
                )
            }
            .opacity(logoIsVisible ? 1 : 0)
            .scaleEffect(logoIsVisible ? 1 : 0.94)
            .animation(
                reduceMotion ? nil : .easeOut(duration: 0.34),
                value: logoIsVisible
            )
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("LinkWave")
        }
        .task {
            guard !didFinish else { return }

            if reduceMotion {
                waveProgress = 1
                logoIsVisible = true
            } else {
                withAnimation(.easeInOut(duration: 0.78)) { waveProgress = 1 }
                withAnimation(.easeOut(duration: 0.38).delay(0.18)) { logoIsVisible = true }
                do { try await Task.sleep(nanoseconds: 480_000_000) } catch { return }
                guard !Task.isCancelled else { return }
                nodesArePulsing = true
            }
            do {
                let remainingDuration: UInt64 = reduceMotion ? 1_800_000_000 : 1_320_000_000
                try await Task.sleep(nanoseconds: remainingDuration)
            } catch { return }
            guard !Task.isCancelled, !didFinish else { return }
            didFinish = true
            onFinished()
        }
        .allowsHitTesting(false)
        .accessibilityAddTraits(.isModal)
    }
}

struct LinkWaveWordmark: View {
    let nodesArePulsing: Bool
    let white: Color
    let cyan: Color

    var fontSize: CGFloat = 33
    var stemColor: Color = .white

    var body: some View {
        let glyphScale = fontSize / 33
        HStack(spacing: -0.35) {
            Text("L")
                .foregroundStyle(white)

            HarmonicNodeI(isPulsing: nodesArePulsing, color: cyan, stemColor: stemColor)
                .frame(width: 11, height: 31)
                .scaleEffect(glyphScale)
                .frame(width: 11 * glyphScale, height: 31 * glyphScale)
                .padding(.horizontal, 0.5 * glyphScale)

            Text("nk")
                .foregroundStyle(white)

            Text("Wave")
                .foregroundStyle(cyan)
        }
        .font(.custom("Outfit", size: fontSize, relativeTo: .largeTitle).weight(.semibold))
        .tracking(-0.55)
        .fixedSize()
    }
}

/// A custom lowercase “i”: its node breathes while its stem remains steady.
private struct HarmonicNodeI: View {
    let isPulsing: Bool
    let color: Color
    let stemColor: Color

    var body: some View {
        ZStack(alignment: .top) {
            Circle()
                .stroke(color.opacity(isPulsing ? 0.15 : 0.55), lineWidth: 1)
                .frame(width: isPulsing ? 11 : 6, height: isPulsing ? 11 : 6)
                .offset(y: isPulsing ? 0 : 2.5)

            Circle()
                .fill(color)
                .frame(width: 4.5, height: 4.5)
                .offset(y: 5.5)

            Capsule()
                .fill(stemColor)
                .frame(width: 3.2, height: 17)
                .offset(y: 13)
        }
        .frame(width: 11, height: 31)
        .animation(.easeInOut(duration: 0.68).repeatForever(autoreverses: true), value: isPulsing)
        .accessibilityHidden(true)
    }
}

private struct HarmonicWaveMark: View {
    let progress: CGFloat
    let nodesArePulsing: Bool
    let color: Color

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                HarmonicWavePaths()
                    .trim(from: 0, to: progress)
                    .stroke(
                        color,
                        style: StrokeStyle(lineWidth: 3.4, lineCap: .round, lineJoin: .round)
                    )

                HarmonicPulseNode(isPulsing: nodesArePulsing, color: color)
                    .position(x: geometry.size.width * 0.61, y: geometry.size.height * 0.50)
                HarmonicPulseNode(isPulsing: nodesArePulsing, color: color)
                    .position(x: geometry.size.width * 0.39, y: geometry.size.height * 0.20)
                HarmonicPulseNode(isPulsing: nodesArePulsing, color: color)
                    .position(x: geometry.size.width * 0.39, y: geometry.size.height * 0.80)
            }
        }
        .animation(.easeOut(duration: 0.78), value: progress)
    }
}

private struct HarmonicPulseNode: View {
    let isPulsing: Bool
    let color: Color

    var body: some View {
        ZStack {
            Circle()
                .stroke(color.opacity(isPulsing ? 0.12 : 0.5), lineWidth: 1)
                .scaleEffect(isPulsing ? 1.65 : 0.78)
                .opacity(isPulsing ? 0.28 : 0.72)
            Circle()
                .fill(color)
                .frame(width: 4.5, height: 4.5)
        }
        .frame(width: 16, height: 16)
        .animation(.easeInOut(duration: 0.68).repeatForever(autoreverses: true), value: isPulsing)
        .accessibilityHidden(true)
    }
}

private struct HarmonicWavePaths: Shape {
    func path(in rect: CGRect) -> Path {
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + x * rect.width, y: rect.minY + y * rect.height)
        }

        var path = Path()
        path.move(to: point(0.61, 0.04))
        path.addCurve(
            to: point(0.61, 0.96),
            control1: point(1.02, 0.24),
            control2: point(1.02, 0.76)
        )
        path.move(to: point(0.39, 0.20))
        path.addCurve(
            to: point(0.39, 0.80),
            control1: point(0.72, 0.34),
            control2: point(0.72, 0.66)
        )
        path.move(to: point(0.18, 0.35))
        path.addCurve(
            to: point(0.18, 0.65),
            control1: point(0.39, 0.43),
            control2: point(0.39, 0.57)
        )
        return path
    }
}

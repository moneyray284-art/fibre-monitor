import Foundation
import SwiftUI

struct LinkWaveLaunchAnimation: View {
    let onFinished: () -> Void

    @State private var logoIsVisible = false

    private let brandCyan = Color(red: 0.365, green: 0.882, blue: 1)
    private let backgroundColor = Color(red: 0.105, green: 0.15, blue: 0.20)

    var body: some View {
        ZStack {
            backgroundColor
                .ignoresSafeArea()

            RadialGradient(
                colors: [
                    brandCyan.opacity(logoIsVisible ? 0.16 : 0.03),
                    backgroundColor.opacity(0.48),
                    .clear
                ],
                center: .center,
                startRadius: 0,
                endRadius: 230
            )
            .ignoresSafeArea()
            .animation(.easeOut(duration: 0.55), value: logoIsVisible)

            LinkWaveLaunchLogo(brandCyan: brandCyan)
                .opacity(logoIsVisible ? 1 : 0)
                .scaleEffect(logoIsVisible ? 1 : 0.96)
                .shadow(color: brandCyan.opacity(logoIsVisible ? 0.16 : 0), radius: 26)
                .animation(.easeOut(duration: 0.22), value: logoIsVisible)
                .accessibilityLabel("LinkWave")

            Text("v\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "2.3.0")")
                .font(.system(size: 13, weight: .regular, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.white.opacity(0.42))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                .padding(.bottom, 42)
                .opacity(logoIsVisible ? 1 : 0)
                .animation(.easeOut(duration: 0.22), value: logoIsVisible)
        }
        .task {
            withAnimation {
                logoIsVisible = true
            }
            do {
                try await Task.sleep(nanoseconds: 680_000_000)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            onFinished()
        }
        .accessibilityAddTraits(.isModal)
    }
}

private struct LinkWaveLaunchLogo: View {
    let brandCyan: Color

    var body: some View {
        HStack(spacing: 7) {
            LinkWaveSignalMark()
                .stroke(
                    brandCyan,
                    style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round)
                )
                .frame(width: 54, height: 64)
                .accessibilityHidden(true)

            HStack(spacing: -0.6) {
                Text("Link")
                    .foregroundStyle(.white)
                Text("Wave")
                    .foregroundStyle(brandCyan)
            }
            .font(.system(size: 31, weight: .semibold, design: .rounded))
            .tracking(-0.55)
            .fixedSize()
        }
        .padding(.horizontal, 20)
    }
}

private struct LinkWaveSignalMark: Shape {
    func path(in rect: CGRect) -> Path {
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + x * rect.width, y: rect.minY + y * rect.height)
        }

        var path = Path()
        path.move(to: point(0.60, 0.06))
        path.addCurve(to: point(0.60, 0.94), control1: point(0.98, 0.23), control2: point(0.98, 0.77))
        path.move(to: point(0.39, 0.20))
        path.addCurve(to: point(0.39, 0.80), control1: point(0.67, 0.34), control2: point(0.67, 0.66))
        path.move(to: point(0.18, 0.35))
        path.addCurve(to: point(0.18, 0.65), control1: point(0.36, 0.43), control2: point(0.36, 0.57))
        return path
    }
}

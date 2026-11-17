import SwiftUI

struct LinkWaveLaunchAnimation: View {
    let onFinished: () -> Void

    @State private var logoIsVisible = false

    var body: some View {
        ZStack {
            Color.black
                .ignoresSafeArea()

            RadialGradient(
                colors: [
                    Color.cyan.opacity(logoIsVisible ? 0.18 : 0.04),
                    Color(red: 0.01, green: 0.06, blue: 0.08).opacity(0.36),
                    .clear
                ],
                center: .center,
                startRadius: 0,
                endRadius: 230
            )
            .ignoresSafeArea()
            .animation(.easeOut(duration: 0.55), value: logoIsVisible)

            LinkWaveLaunchLogo()
                .opacity(logoIsVisible ? 1 : 0)
                .scaleEffect(logoIsVisible ? 1 : 0.96)
                .shadow(color: .cyan.opacity(logoIsVisible ? 0.2 : 0), radius: 28)
                .animation(.easeOut(duration: 0.32), value: logoIsVisible)
                .accessibilityLabel("LinkWave")
        }
        .task {
            withAnimation {
                logoIsVisible = true
            }
            do {
                try await Task.sleep(nanoseconds: 1_050_000_000)
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
    var body: some View {
        HStack(spacing: 9) {
            LinkWaveSignalMark()
                .stroke(
                    Color.cyan,
                    style: StrokeStyle(lineWidth: 3.2, lineCap: .round, lineJoin: .round)
                )
                .overlay {
                    Circle()
                        .fill(Color.cyan)
                        .frame(width: 7, height: 7)
                        .offset(y: 22)
                }
                .frame(width: 58, height: 56)
            .accessibilityHidden(true)

            Text("LinkWave")
                .font(.system(size: 27, weight: .semibold, design: .rounded))
                .tracking(-0.7)
                .foregroundStyle(.white)
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
        path.move(to: point(0.08, 0.57))
        path.addCurve(to: point(0.92, 0.57), control1: point(0.25, 0.09), control2: point(0.75, 0.09))
        path.move(to: point(0.21, 0.70))
        path.addCurve(to: point(0.79, 0.70), control1: point(0.35, 0.36), control2: point(0.65, 0.36))
        path.move(to: point(0.36, 0.82))
        path.addCurve(to: point(0.64, 0.82), control1: point(0.43, 0.64), control2: point(0.57, 0.64))
        return path
    }
}

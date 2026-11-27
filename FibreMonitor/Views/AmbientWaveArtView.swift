import SwiftUI

struct AmbientWaveArtView: View {
    enum Variant {
        case canvas
        case sheet
    }

    let variant: Variant

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.linkWaveThemePalette) private var palette
    @Environment(\.linkWaveSurfaceStyle) private var surfaceStyle

    private var lineColor: Color {
        colorScheme == .dark
            ? Color.white.opacity(0.055)
            : Color(red: 15.0 / 255.0, green: 23.0 / 255.0, blue: 42.0 / 255.0).opacity(0.055)
    }

    private var accentColor: Color {
        palette.textAccent.opacity(colorScheme == .dark ? 0.12 : 0.095)
    }

    private var darkBaseTintOpacity: Double {
        guard colorScheme == .dark else { return 0 }
        switch surfaceStyle {
        case .liquidGlass: return 0.20
        case .frosted: return 0.14
        case .cleanSolid: return 0.08
        }
    }

    var body: some View {
        Canvas { context, size in
            if colorScheme == .dark {
                context.fill(
                    Path(CGRect(origin: .zero, size: size)),
                    with: .color(palette.backgroundPrimary.opacity(darkBaseTintOpacity))
                )
            }

            switch variant {
            case .canvas:
                drawCanvasArt(in: &context, size: size)
            case .sheet:
                drawSheetArt(in: &context, size: size)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func drawCanvasArt(in context: inout GraphicsContext, size: CGSize) {
        let w = size.width
        let h = size.height
        drawRings(context: &context, center: CGPoint(x: w * 0.91, y: h * 0.12), count: 5, radius: min(w, h) * 0.22, color: lineColor)
        drawRings(context: &context, center: CGPoint(x: w * 0.08, y: h * 0.83), count: 3, radius: min(w, h) * 0.13, color: lineColor, dashed: true)

        drawWave(context: &context, size: size, y: h * 0.43, amplitude: h * 0.10, color: accentColor, width: 1.15)
        drawWave(context: &context, size: size, y: h * 0.46, amplitude: h * 0.10, color: lineColor, width: 0.9, dashed: true)
        drawWave(context: &context, size: size, y: h * 0.49, amplitude: h * 0.10, color: lineColor, width: 0.8)
        drawWave(context: &context, size: size, y: h * 0.70, amplitude: h * 0.045, color: lineColor.opacity(0.8), width: 0.8)
        drawWave(context: &context, size: size, y: h * 0.73, amplitude: h * 0.04, color: lineColor.opacity(0.72), width: 0.8, dashed: true)

        drawNode(context: &context, at: CGPoint(x: w * 0.28, y: h * 0.40), radius: 2.2, color: accentColor)
        drawNode(context: &context, at: CGPoint(x: w * 0.66, y: h * 0.46), radius: 1.7, color: lineColor)
        drawNode(context: &context, at: CGPoint(x: w * 0.77, y: h * 0.49), radius: 1.6, color: lineColor)
        drawNode(context: &context, at: CGPoint(x: w * 0.28, y: h * 0.40), radius: 6, color: accentColor, strokeOnly: true)
    }

    private func drawSheetArt(in context: inout GraphicsContext, size: CGSize) {
        let w = size.width
        let h = size.height
        drawRings(context: &context, center: CGPoint(x: w * 0.90, y: h * 0.10), count: 4, radius: min(w, h) * 0.15, color: lineColor)
        drawWave(context: &context, size: size, y: h * 0.25, amplitude: h * 0.06, color: accentColor, width: 1)
        drawWave(context: &context, size: size, y: h * 0.28, amplitude: h * 0.06, color: lineColor, width: 0.85, dashed: true)
        drawWave(context: &context, size: size, y: h * 0.70, amplitude: h * 0.035, color: lineColor, width: 0.75)
        drawWave(context: &context, size: size, y: h * 0.73, amplitude: h * 0.032, color: lineColor, width: 0.75, dashed: true)
        drawNode(context: &context, at: CGPoint(x: w * 0.22, y: h * 0.25), radius: 1.8, color: accentColor)
        drawNode(context: &context, at: CGPoint(x: w * 0.72, y: h * 0.28), radius: 1.6, color: lineColor)
        drawNode(context: &context, at: CGPoint(x: w * 0.36, y: h * 0.70), radius: 1.5, color: lineColor)
    }

    private func drawRings(
        context: inout GraphicsContext,
        center: CGPoint,
        count: Int,
        radius: CGFloat,
        color: Color,
        dashed: Bool = false
    ) {
        for index in 0..<count {
            let ringRadius = radius * CGFloat(index + 1) / CGFloat(count)
            let rect = CGRect(x: center.x - ringRadius, y: center.y - ringRadius, width: ringRadius * 2, height: ringRadius * 2)
            let ring = Path(ellipseIn: rect)
            let useDash = dashed || index.isMultiple(of: 2)
            context.stroke(
                ring,
                with: .color(color.opacity(index.isMultiple(of: 2) ? 1 : 0.76)),
                style: StrokeStyle(lineWidth: 0.8, dash: useDash ? [2, 4] : [])
            )
        }
    }

    private func drawWave(
        context: inout GraphicsContext,
        size: CGSize,
        y: CGFloat,
        amplitude: CGFloat,
        color: Color,
        width: CGFloat,
        dashed: Bool = false
    ) {
        var path = Path()
        path.move(to: CGPoint(x: 0, y: y))
        path.addCurve(
            to: CGPoint(x: size.width, y: y + amplitude * 0.12),
            control1: CGPoint(x: size.width * 0.28, y: y - amplitude),
            control2: CGPoint(x: size.width * 0.64, y: y + amplitude * 1.1)
        )
        context.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: width, dash: dashed ? [3, 5] : []))
    }

    private func drawNode(
        context: inout GraphicsContext,
        at point: CGPoint,
        radius: CGFloat,
        color: Color,
        strokeOnly: Bool = false
    ) {
        let rect = CGRect(x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2)
        let node = Path(ellipseIn: rect)
        if strokeOnly {
            context.stroke(node, with: .color(color), lineWidth: 0.9)
        } else {
            context.fill(node, with: .color(color))
        }
    }
}

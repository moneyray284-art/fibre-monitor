import SwiftUI

struct AmbientWaveArtView: View {
    enum Variant: Equatable {
        case canvas
        case sheet
    }

    private struct PatternStroke {
        var path: Path
        var isPrimary: Bool = false
        var lineWidth: CGFloat = 0.9
        var dash: [CGFloat] = []
    }

    private struct PatternNode {
        var point: CGPoint
        var radius: CGFloat
        var isPrimary: Bool
        var isFocal: Bool = false
    }

    let variant: Variant
    let pattern: BackgroundPatternID
    let accentColor: Color
    let isPulsing: Bool

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.linkWaveThemePalette) private var palette
    @Environment(\.linkWaveSurfaceStyle) private var surfaceStyle
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var isSheet: Bool { variant == .sheet }
    private var effectivePulse: Bool { isPulsing && !reduceMotion }

    private var baseStrokeColor: Color {
        if isSheet {
            return colorScheme == .dark
                ? Color.white.opacity(0.065)
                : Color(red: 15.0 / 255.0, green: 23.0 / 255.0, blue: 42.0 / 255.0).opacity(0.065)
        }
        return colorScheme == .dark
            ? Color.white.opacity(0.075)
            : Color(red: 15.0 / 255.0, green: 23.0 / 255.0, blue: 42.0 / 255.0).opacity(0.08)
    }

    private var darkBaseTintOpacity: Double {
        guard colorScheme == .dark else { return 0 }
        switch surfaceStyle {
        case .liquidGlass: return 0.20
        case .frosted: return 0.14
        case .cleanSolid: return 0.08
        }
    }

    @ViewBuilder
    var body: some View {
        if pattern == .none {
            EmptyView()
        } else if effectivePulse {
            TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: false)) { timeline in
                artwork(at: timeline.date)
            }
        } else {
            artwork(at: nil)
        }
    }

    private func artwork(at date: Date?) -> some View {
        Canvas { context, size in
            if colorScheme == .dark {
                context.fill(
                    Path(CGRect(origin: .zero, size: size)),
                    with: .color(palette.backgroundPrimary.opacity(darkBaseTintOpacity))
                )
            }

            let nodes = patternNodes(in: size)
            let strokes = patternStrokes(in: size) + focalRingStrokes(for: nodes)
            drawAmbientTints(nodes: nodes, in: size, elapsed: date?.timeIntervalSinceReferenceDate ?? 0, context: &context)
            draw(strokes: strokes, nodes: nodes, in: &context, at: date)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func draw(
        strokes: [PatternStroke],
        nodes: [PatternNode],
        in context: inout GraphicsContext,
        at date: Date?
    ) {
        let elapsed = date?.timeIntervalSinceReferenceDate ?? 0
        let pulseAmount = (sin(elapsed * 2 * .pi / 1.6) + 1) / 2
        let secondaryPulseOpacity = isSheet ? 0.19 : 0.25
        let primaryPulseOpacity = isSheet ? 0.28 : 0.36
        let haloOpacity = effectivePulse ? 0.042 + 0.038 * pulseAmount : 0.042

        for (index, stroke) in strokes.enumerated() {
            if stroke.isPrimary {
                context.stroke(
                    stroke.path,
                    with: .color(accentColor.opacity(haloOpacity)),
                    style: StrokeStyle(
                        lineWidth: isSheet ? 5.8 : 6.5,
                        lineCap: .round,
                        lineJoin: .round,
                        dash: stroke.dash
                    )
                )
            }
            let restingColor = stroke.isPrimary ? accentColor.opacity(0.135) : baseStrokeColor
            context.stroke(
                stroke.path,
                with: .color(restingColor),
                style: StrokeStyle(
                    lineWidth: restingLineWidth(for: stroke),
                    lineCap: .round,
                    lineJoin: .round,
                    dash: stroke.dash
                )
            )

            guard effectivePulse, date != nil else { continue }
            let delay = -0.3 - Double(index) / Double(max(strokes.count - 1, 1)) * 1.55
            let cycle = (elapsed + delay).truncatingRemainder(dividingBy: 2.1)
            let phase = (cycle + 2.1).truncatingRemainder(dividingBy: 2.1) / 2.1
            let start = CGFloat(phase)
            let pulseColor = accentColor.opacity(stroke.isPrimary ? primaryPulseOpacity : secondaryPulseOpacity)
            let pulseWidth: CGFloat = stroke.isPrimary
                ? (isSheet ? 2.25 : 2.35)
                : (isSheet ? 1.55 : 1.7)
            let pulseStyle = StrokeStyle(lineWidth: pulseWidth, lineCap: .round, lineJoin: .round)
            if start + 0.24 <= 1 {
                context.stroke(
                    stroke.path.trimmedPath(from: start, to: start + 0.24),
                    with: .color(pulseColor),
                    style: pulseStyle
                )
            } else {
                context.stroke(
                    stroke.path.trimmedPath(from: start, to: 1),
                    with: .color(pulseColor),
                    style: pulseStyle
                )
                context.stroke(
                    stroke.path.trimmedPath(from: 0, to: start + 0.24 - 1),
                    with: .color(pulseColor),
                    style: pulseStyle
                )
            }
        }

        let nodePulse = CGFloat(0.96 + 0.28 * pulseAmount)
        let nodeOpacity = 0.65 + 0.35 * pulseAmount
        for node in nodes {
            drawNode(
                node,
                radius: node.radius,
                opacity: node.isPrimary ? 0.18 : 1,
                in: &context
            )
            if effectivePulse && node.isFocal {
                drawNode(node, radius: node.radius * nodePulse, opacity: nodeOpacity, in: &context)
            }
        }
    }

    private func restingLineWidth(for stroke: PatternStroke) -> CGFloat {
        if stroke.isPrimary {
            return isSheet ? 1.4 : 1.65
        }
        return min(max(stroke.lineWidth, 0.85), 1.2)
    }

    private func focalRingStrokes(for nodes: [PatternNode]) -> [PatternStroke] {
        nodes.filter(\.isFocal).map { node in
            let radius = node.radius * 2.4
            let rect = CGRect(
                x: node.point.x - radius,
                y: node.point.y - radius,
                width: radius * 2,
                height: radius * 2
            )
            return PatternStroke(path: Path(ellipseIn: rect), isPrimary: true, lineWidth: isSheet ? 1.4 : 1.65)
        }
    }

    private func drawAmbientTints(
        nodes: [PatternNode],
        in size: CGSize,
        elapsed: TimeInterval,
        context: inout GraphicsContext
    ) {
        let pulseAmount = (sin(elapsed * 2 * .pi / 1.6) + 1) / 2
        let cornerOpacity = effectivePulse ? 0.10 + 0.02 * pulseAmount : 0.10
        let corners = [
            CGPoint(x: size.width * 0.98, y: size.height * 0.06),
            CGPoint(x: size.width * 0.04, y: size.height * 0.92)
        ]
        for (index, point) in corners.enumerated() {
            let radius = min(size.width, size.height) * (index == 0 ? 0.34 : 0.28)
            context.fill(
                Path(ellipseIn: CGRect(x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2)),
                with: .radialGradient(
                    Gradient(colors: [accentColor.opacity(cornerOpacity), .clear]),
                    center: point,
                    startRadius: 0,
                    endRadius: radius
                )
            )
        }

        let nodeGlowOpacity = effectivePulse ? 0.038 + 0.034 * pulseAmount : 0.038
        for node in nodes where node.isPrimary || node.isFocal {
            let radius: CGFloat = isSheet ? 18 : 22
            context.fill(
                Path(ellipseIn: CGRect(
                    x: node.point.x - radius,
                    y: node.point.y - radius,
                    width: radius * 2,
                    height: radius * 2
                )),
                with: .radialGradient(
                    Gradient(colors: [accentColor.opacity(nodeGlowOpacity), .clear]),
                    center: node.point,
                    startRadius: 0,
                    endRadius: radius
                )
            )
        }
    }

    private func drawNode(
        _ node: PatternNode,
        radius: CGFloat,
        opacity: Double,
        in context: inout GraphicsContext
    ) {
        let rect = CGRect(
            x: node.point.x - radius,
            y: node.point.y - radius,
            width: radius * 2,
            height: radius * 2
        )
        let color = node.isPrimary
            ? accentColor.opacity(opacity)
            : baseStrokeColor
        context.fill(Path(ellipseIn: rect), with: .color(color))
    }

    private func patternStrokes(in size: CGSize) -> [PatternStroke] {
        return switch pattern {
        case .waves: waveStrokes(in: size)
        case .mesh: meshStrokes(in: size)
        case .rings: ringStrokes(in: size)
        case .none: []
        }
    }

    private func patternNodes(in size: CGSize) -> [PatternNode] {
        return switch pattern {
        case .waves: waveNodes(in: size)
        case .mesh: meshNodes(in: size)
        case .rings: ringNodes(in: size)
        case .none: []
        }
    }

    private func waveStrokes(in size: CGSize) -> [PatternStroke] {
        let w = size.width
        let h = size.height
        let primaryCenter = CGPoint(x: w * 0.91, y: h * 0.12)
        let echoCenter = CGPoint(x: w * 0.08, y: h * 0.83)
        var result = ringPaths(
            center: primaryCenter,
            count: isSheet ? 4 : 5,
            radius: min(w, h) * (isSheet ? 0.15 : 0.22),
            isPrimary: true
        )
        if !isSheet {
            result += ringPaths(center: echoCenter, count: 3, radius: min(w, h) * 0.13, forceDashed: true)
        }

        let topY = h * (isSheet ? 0.25 : 0.43)
        let amplitude = h * (isSheet ? 0.06 : 0.10)
        result.append(wavePath(size: size, y: topY, amplitude: amplitude, primary: true, width: 1.15))
        result.append(wavePath(size: size, y: topY + h * 0.035, amplitude: amplitude, dash: [3, 5], width: 0.9))
        if !isSheet {
            result.append(wavePath(size: size, y: topY + h * 0.065, amplitude: amplitude, width: 0.8))
        }
        result.append(wavePath(size: size, y: h * 0.70, amplitude: h * 0.04, width: 0.8))
        result.append(wavePath(size: size, y: h * 0.73, amplitude: h * 0.035, dash: [3, 5], width: 0.75))
        return result
    }

    private func waveNodes(in size: CGSize) -> [PatternNode] {
        let w = size.width
        let h = size.height
        let focal = CGPoint(x: w * 0.28, y: h * (isSheet ? 0.25 : 0.40))
        let mainNodes = [
            PatternNode(point: focal, radius: 2.2, isPrimary: true, isFocal: true),
            PatternNode(point: CGPoint(x: w * 0.66, y: h * 0.46), radius: 1.7, isPrimary: false),
            PatternNode(point: CGPoint(x: w * 0.77, y: h * 0.49), radius: 1.6, isPrimary: false),
            PatternNode(point: CGPoint(x: w * 0.36, y: h * 0.70), radius: 1.5, isPrimary: false)
        ]
        return isSheet ? Array(mainNodes.prefix(3)) : mainNodes
    }

    private func meshStrokes(in size: CGSize) -> [PatternStroke] {
        let w = size.width
        let h = size.height
        let points = meshPoints(in: size)
        var result: [PatternStroke] = []
        let canvasEdges: [(Int, Int, Bool)] = [
            (0, 1, false), (1, 2, true), (2, 3, false), (3, 4, true),
            (5, 6, true), (6, 7, false), (7, 8, true), (8, 9, false),
            (0, 5, false), (1, 6, true), (2, 7, false), (3, 8, true), (4, 9, false),
            (0, 6, true), (2, 6, false), (2, 8, true), (4, 8, false)
        ]
        let sheetEdges: [(Int, Int, Bool)] = [
            (0, 1, false), (1, 2, true), (2, 3, false), (3, 4, true),
            (5, 6, true), (6, 7, false), (7, 8, true), (8, 9, false),
            (1, 6, true), (2, 7, false), (3, 8, true), (0, 6, true), (2, 8, true)
        ]
        let edges = isSheet ? sheetEdges : canvasEdges
        for (from, to, dashed) in edges {
            result.append(linePath(
                from: points[from],
                to: points[to],
                dash: dashed ? [2, 4] : [],
                width: 0.85
            ))
        }

        var backbone = Path()
        backbone.move(to: CGPoint(x: w * 0.08, y: h * 0.64))
        backbone.addCurve(
            to: CGPoint(x: w * 0.91, y: h * 0.28),
            control1: CGPoint(x: w * 0.34, y: h * 0.14),
            control2: CGPoint(x: w * 0.60, y: h * 0.88)
        )
        result.append(PatternStroke(path: backbone, isPrimary: true, lineWidth: 1.2))
        return result
    }

    private func meshNodes(in size: CGSize) -> [PatternNode] {
        let points = meshPoints(in: size)
        let visibleIndices = isSheet ? [1, 6, 8] : Array(points.indices)
        return visibleIndices.map { index in
            let point = points[index]
            return PatternNode(
                point: point,
                radius: index == 6 ? 2.1 : 1.4,
                isPrimary: index == 6,
                isFocal: index == 6
            )
        }
    }

    private func ringStrokes(in size: CGSize) -> [PatternStroke] {
        let w = size.width
        let h = size.height
        let primary = CGPoint(x: w * 0.80, y: h * (isSheet ? 0.18 : 0.22))
        let secondary = CGPoint(x: w * 0.19, y: h * (isSheet ? 0.72 : 0.76))
        var result = ringPaths(
            center: primary,
            count: isSheet ? 4 : 6,
            radius: min(w, h) * (isSheet ? 0.18 : 0.24),
            isPrimary: true
        )
        result += ringPaths(center: secondary, count: isSheet ? 3 : 4, radius: min(w, h) * (isSheet ? 0.13 : 0.17), forceDashed: true)
        var axis = Path()
        axis.move(to: CGPoint(x: w * 0.12, y: h * 0.18))
        axis.addLine(to: CGPoint(x: w * 0.88, y: h * 0.82))
        result.append(PatternStroke(path: axis, lineWidth: 0.8, dash: [3, 6]))
        return result
    }

    private func ringNodes(in size: CGSize) -> [PatternNode] {
        [
            PatternNode(
                point: CGPoint(x: size.width * 0.80, y: size.height * (isSheet ? 0.18 : 0.22)),
                radius: 2.2,
                isPrimary: true,
                isFocal: true
            ),
            PatternNode(
                point: CGPoint(x: size.width * 0.19, y: size.height * (isSheet ? 0.72 : 0.76)),
                radius: 1.8,
                isPrimary: false
            )
        ]
    }

    private func ringPaths(
        center: CGPoint,
        count: Int,
        radius: CGFloat,
        forceDashed: Bool = false,
        isPrimary: Bool = false
    ) -> [PatternStroke] {
        (0..<count).map { index in
            let ringRadius = radius * CGFloat(index + 1) / CGFloat(count)
            let rect = CGRect(
                x: center.x - ringRadius,
                y: center.y - ringRadius,
                width: ringRadius * 2,
                height: ringRadius * 2
            )
            return PatternStroke(
                path: Path(ellipseIn: rect),
                isPrimary: isPrimary,
                lineWidth: 0.8,
                dash: (forceDashed ? !index.isMultiple(of: 2) : index.isMultiple(of: 2)) ? [2, 4] : []
            )
        }
    }

    private func wavePath(
        size: CGSize,
        y: CGFloat,
        amplitude: CGFloat,
        primary: Bool = false,
        dash: [CGFloat] = [],
        width: CGFloat
    ) -> PatternStroke {
        var path = Path()
        path.move(to: CGPoint(x: 0, y: y))
        path.addCurve(
            to: CGPoint(x: size.width, y: y + amplitude * 0.12),
            control1: CGPoint(x: size.width * 0.28, y: y - amplitude),
            control2: CGPoint(x: size.width * 0.64, y: y + amplitude * 1.1)
        )
        return PatternStroke(path: path, isPrimary: primary, lineWidth: width, dash: dash)
    }

    private func linePath(from start: CGPoint, to end: CGPoint, dash: [CGFloat] = [], width: CGFloat) -> PatternStroke {
        var path = Path()
        path.move(to: start)
        path.addLine(to: end)
        return PatternStroke(path: path, lineWidth: width, dash: dash)
    }

    private func meshPoints(in size: CGSize) -> [CGPoint] {
        let w = size.width
        let h = size.height
        return [
            CGPoint(x: w * 0.06, y: h * 0.30), CGPoint(x: w * 0.27, y: h * 0.16),
            CGPoint(x: w * 0.49, y: h * 0.30), CGPoint(x: w * 0.73, y: h * 0.14),
            CGPoint(x: w * 0.95, y: h * 0.31), CGPoint(x: w * 0.08, y: h * 0.70),
            CGPoint(x: w * 0.30, y: h * 0.55), CGPoint(x: w * 0.53, y: h * 0.75),
            CGPoint(x: w * 0.76, y: h * 0.57), CGPoint(x: w * 0.93, y: h * 0.76)
        ]
    }
}

struct BackgroundPatternPreview: View {
    let pattern: BackgroundPatternID
    let accentColor: Color

    var body: some View {
        AmbientWaveArtView(
            variant: .sheet,
            pattern: pattern,
            accentColor: accentColor,
            isPulsing: false
        )
        .frame(height: 62)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .accessibilityHidden(true)
    }
}

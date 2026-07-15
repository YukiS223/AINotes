import SwiftUI
import PencilKit

enum CanvasToolMode: Equatable {
    case ink
    case text
    case selection
    case shape(ShapeKind)

    var shapeKind: ShapeKind? {
        if case .shape(let kind) = self { return kind }
        return nil
    }
}

enum ShapeKind: String, CaseIterable, Identifiable {
    case smart
    case line
    case arrow
    case rectangle
    case ellipse
    case triangle

    var id: Self { self }

    var title: String {
        switch self {
        case .smart: return "Smart Shape"
        case .line: return "Line"
        case .arrow: return "Arrow"
        case .rectangle: return "Rectangle"
        case .ellipse: return "Ellipse"
        case .triangle: return "Triangle"
        }
    }

    var symbolName: String {
        switch self {
        case .smart: return "wand.and.stars"
        case .line: return "line.diagonal"
        case .arrow: return "arrow.up.right"
        case .rectangle: return "rectangle"
        case .ellipse: return "circle"
        case .triangle: return "triangle"
        }
    }
}

struct ShapeStrokeStyle {
    var color: UIColor
    var width: CGFloat
}

/// The touch layer used by explicit shapes and Smart Shape. Explicit tools
/// turn a drag into clean geometry immediately; Smart Shape keeps an
/// unrecognized gesture as ink but snaps lines, triangles, rectangles, and
/// ellipses to corrected geometry when the gesture ends.
struct ShapeDrawingOverlay: View {
    let kind: ShapeKind
    let style: ShapeStrokeStyle
    let onCommit: ([PKStroke]) -> Void

    @State private var gesturePoints: [CGPoint] = []

    var body: some View {
        Canvas { context, _ in
            for points in ShapeGeometry.previewPaths(for: kind, points: gesturePoints) {
                guard let first = points.first else { continue }
                var path = Path()
                path.move(to: first)
                for point in points.dropFirst() { path.addLine(to: point) }
                context.stroke(
                    path,
                    with: .color(Color(uiColor: style.color)),
                    style: StrokeStyle(
                        lineWidth: max(1, style.width),
                        lineCap: .round,
                        lineJoin: .round
                    )
                )
            }
        }
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0, coordinateSpace: .local)
                .onChanged { value in
                    if gesturePoints.isEmpty { gesturePoints.append(value.startLocation) }
                    if gesturePoints.last.map({ distance($0, value.location) > 1.5 }) ?? true {
                        gesturePoints.append(value.location)
                    }
                }
                .onEnded { value in
                    if gesturePoints.isEmpty { gesturePoints.append(value.startLocation) }
                    gesturePoints.append(value.location)
                    let paths = ShapeGeometry.correctedPaths(for: kind, points: gesturePoints)
                    let strokes = paths.compactMap {
                        ShapeGeometry.stroke(points: $0, style: style)
                    }
                    if !strokes.isEmpty { onCommit(strokes) }
                    gesturePoints.removeAll(keepingCapacity: true)
                }
        )
        .accessibilityLabel("\(kind.title) drawing area")
    }

    private func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
        hypot(b.x - a.x, b.y - a.y)
    }
}

enum ShapeGeometry {
    static func previewPaths(for kind: ShapeKind,
                             points: [CGPoint]) -> [[CGPoint]] {
        guard points.count >= 2 else { return [] }
        // Showing the actual gesture for Smart Shape makes the correction
        // feel intentional rather than making the line jump between guessed
        // shapes while the user is still drawing.
        if kind == .smart { return [points] }
        return correctedPaths(for: kind, points: points)
    }

    static func correctedPaths(for kind: ShapeKind,
                               points: [CGPoint]) -> [[CGPoint]] {
        guard let start = points.first, let end = points.last,
              points.count >= 2 else { return [] }

        switch kind {
        case .smart:
            return smartPaths(points)
        case .line:
            return [[start, end]]
        case .arrow:
            return arrowPaths(from: start, to: end)
        case .rectangle:
            return straightEdgePaths(rectanglePoints(from: start, to: end))
        case .ellipse:
            return [ellipsePoints(in: standardizedRect(from: start, to: end), count: 48)]
        case .triangle:
            return straightEdgePaths(trianglePoints(from: start, to: end))
        }
    }

    static func stroke(points: [CGPoint],
                       style: ShapeStrokeStyle) -> PKStroke? {
        guard points.count >= 2 else { return nil }
        let controlPoints = points.enumerated().map { index, point in
            PKStrokePoint(
                location: point,
                timeOffset: TimeInterval(index) * 0.01,
                size: CGSize(width: style.width, height: style.width),
                opacity: 1,
                force: 1,
                azimuth: 0,
                altitude: .pi / 2
            )
        }
        let path = PKStrokePath(controlPoints: controlPoints, creationDate: .now)
        return PKStroke(
            ink: PKInk(.pen, color: style.color),
            path: path
        )
    }

    // MARK: - Smart correction

    private static func smartPaths(_ points: [CGPoint]) -> [[CGPoint]] {
        guard points.count >= 3 else {
            return points.count >= 2 ? [[points[0], points[points.count - 1]]] : []
        }

        let bounds = boundingRect(points)
        let diagonal = max(1, hypot(bounds.width, bounds.height))
        let direct = distance(points[0], points[points.count - 1])
        let length = pathLength(points)
        let maxLineError = points.map {
            distanceFromLine($0, start: points[0], end: points[points.count - 1])
        }.max() ?? 0

        if direct / max(1, length) > 0.84,
           maxLineError < max(7, diagonal * 0.08) {
            return [[points[0], points[points.count - 1]]]
        }

        let isClosed = direct < max(24, min(72, diagonal * 0.24))
        guard isClosed, bounds.width > 12, bounds.height > 12 else {
            // A curve or doodle is not a failed shape. Preserve it as ink.
            return [points]
        }

        let corners = simplifiedClosedCorners(points, bounds: bounds)
        if corners.count == 3 {
            return straightEdgePaths(trianglePoints(in: bounds))
        }

        let boxError = averageBoxEdgeError(points, bounds: bounds)
        let ellipseError = averageEllipseError(points, bounds: bounds)
        if (3...5).contains(corners.count), boxError < ellipseError * 0.9 {
            return straightEdgePaths(rectanglePoints(in: bounds))
        }

        return [ellipsePoints(in: bounds, count: 48)]
    }

    private static func simplifiedClosedCorners(_ points: [CGPoint],
                                                bounds: CGRect) -> [CGPoint] {
        var ring = points
        let diagonal = max(1, hypot(bounds.width, bounds.height))
        if let first = ring.first, let last = ring.last,
           distance(first, last) < diagonal * 0.18 {
            ring.removeLast()
        }
        guard ring.count >= 3 else { return ring }

        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        let startIndex = ring.indices.max(by: {
            distance(ring[$0], center) < distance(ring[$1], center)
        }) ?? ring.startIndex
        let rotated = Array(ring[startIndex...]) + Array(ring[..<startIndex])
        let closed = rotated + [rotated[0]]
        var simplified = ramerDouglasPeucker(
            closed,
            epsilon: max(5, diagonal * 0.055)
        )
        if simplified.count > 1,
           distance(simplified[0], simplified[simplified.count - 1]) < diagonal * 0.12 {
            simplified.removeLast()
        }

        var distinct: [CGPoint] = []
        for point in simplified {
            if distinct.last.map({ distance($0, point) > diagonal * 0.07 }) ?? true {
                distinct.append(point)
            }
        }
        return distinct
    }

    private static func ramerDouglasPeucker(_ points: [CGPoint],
                                            epsilon: CGFloat) -> [CGPoint] {
        guard points.count > 2, let first = points.first, let last = points.last else {
            return points
        }

        var farthestIndex = 0
        var farthestDistance: CGFloat = 0
        for index in 1..<(points.count - 1) {
            let d = distanceFromLine(points[index], start: first, end: last)
            if d > farthestDistance {
                farthestDistance = d
                farthestIndex = index
            }
        }

        guard farthestDistance > epsilon else { return [first, last] }
        let left = ramerDouglasPeucker(Array(points[...farthestIndex]), epsilon: epsilon)
        let right = ramerDouglasPeucker(Array(points[farthestIndex...]), epsilon: epsilon)
        return Array(left.dropLast()) + right
    }

    // MARK: - Shape construction

    private static func arrowPaths(from start: CGPoint,
                                   to end: CGPoint) -> [[CGPoint]] {
        let dx = end.x - start.x
        let dy = end.y - start.y
        let length = max(1, hypot(dx, dy))
        let angle = atan2(dy, dx)
        let headLength = min(28, max(12, length * 0.22))
        let spread: CGFloat = .pi / 7
        let left = CGPoint(
            x: end.x - headLength * cos(angle - spread),
            y: end.y - headLength * sin(angle - spread)
        )
        let right = CGPoint(
            x: end.x - headLength * cos(angle + spread),
            y: end.y - headLength * sin(angle + spread)
        )
        return [[start, end], [left, end], [end, right]]
    }

    /// PencilKit spline-interpolates the control points within one stroke.
    /// Keeping a polygon in a single stroke therefore bows its sides and
    /// rounds its corners. Emit each edge as its own two-point stroke so the
    /// selected PencilKit ink still renders the shape, but every side remains
    /// geometrically straight.
    private static func straightEdgePaths(_ closedPoints: [CGPoint]) -> [[CGPoint]] {
        zip(closedPoints, closedPoints.dropFirst()).map { [$0.0, $0.1] }
    }

    private static func standardizedRect(from start: CGPoint,
                                         to end: CGPoint) -> CGRect {
        CGRect(
            x: min(start.x, end.x),
            y: min(start.y, end.y),
            width: abs(end.x - start.x),
            height: abs(end.y - start.y)
        )
    }

    private static func rectanglePoints(from start: CGPoint,
                                        to end: CGPoint) -> [CGPoint] {
        rectanglePoints(in: standardizedRect(from: start, to: end))
    }

    private static func rectanglePoints(in rect: CGRect) -> [CGPoint] {
        [
            CGPoint(x: rect.minX, y: rect.minY),
            CGPoint(x: rect.maxX, y: rect.minY),
            CGPoint(x: rect.maxX, y: rect.maxY),
            CGPoint(x: rect.minX, y: rect.maxY),
            CGPoint(x: rect.minX, y: rect.minY)
        ]
    }

    private static func trianglePoints(from start: CGPoint,
                                       to end: CGPoint) -> [CGPoint] {
        trianglePoints(in: standardizedRect(from: start, to: end))
    }

    private static func trianglePoints(in rect: CGRect) -> [CGPoint] {
        [
            CGPoint(x: rect.midX, y: rect.minY),
            CGPoint(x: rect.maxX, y: rect.maxY),
            CGPoint(x: rect.minX, y: rect.maxY),
            CGPoint(x: rect.midX, y: rect.minY)
        ]
    }

    // MARK: - Geometry metrics

    private static func boundingRect(_ points: [CGPoint]) -> CGRect {
        guard let first = points.first else { return .zero }
        var minX = first.x, maxX = first.x
        var minY = first.y, maxY = first.y
        for point in points.dropFirst() {
            minX = min(minX, point.x)
            maxX = max(maxX, point.x)
            minY = min(minY, point.y)
            maxY = max(maxY, point.y)
        }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    private static func pathLength(_ points: [CGPoint]) -> CGFloat {
        zip(points, points.dropFirst()).reduce(0) { partial, pair in
            partial + distance(pair.0, pair.1)
        }
    }

    private static func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
        hypot(b.x - a.x, b.y - a.y)
    }

    private static func distanceFromLine(_ point: CGPoint,
                                         start: CGPoint,
                                         end: CGPoint) -> CGFloat {
        let dx = end.x - start.x
        let dy = end.y - start.y
        let denominator = hypot(dx, dy)
        guard denominator > 0.001 else { return distance(point, start) }
        return abs(dy * point.x - dx * point.y + end.x * start.y - end.y * start.x)
            / denominator
    }

    private static func averageBoxEdgeError(_ points: [CGPoint],
                                            bounds: CGRect) -> CGFloat {
        let width = max(1, bounds.width)
        let height = max(1, bounds.height)
        let sum = points.reduce(CGFloat.zero) { partial, point in
            let horizontal = min(abs(point.x - bounds.minX), abs(point.x - bounds.maxX)) / width
            let vertical = min(abs(point.y - bounds.minY), abs(point.y - bounds.maxY)) / height
            return partial + min(horizontal, vertical)
        }
        return sum / CGFloat(max(1, points.count))
    }

    private static func averageEllipseError(_ points: [CGPoint],
                                            bounds: CGRect) -> CGFloat {
        let rx = max(1, bounds.width / 2)
        let ry = max(1, bounds.height / 2)
        let sum = points.reduce(CGFloat.zero) { partial, point in
            let x = (point.x - bounds.midX) / rx
            let y = (point.y - bounds.midY) / ry
            return partial + abs(x * x + y * y - 1)
        }
        return sum / CGFloat(max(1, points.count))
    }
}

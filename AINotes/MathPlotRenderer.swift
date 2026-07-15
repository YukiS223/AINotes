//
//  MathPlotRenderer.swift
//  AINotes
//
//  Pure, bounded math/data plot planning. The output stays independent of
//  SwiftUI and PencilKit so ActionExpander can turn it into the app's existing
//  RenderSteps and persistence format.
//

import Foundation
import CoreGraphics

nonisolated struct MathPlotDomain: Codable, Equatable, Sendable {
    var xMin: Double
    var xMax: Double
    var yMin: Double
    var yMax: Double
    var tMin: Double?
    var tMax: Double?

    init(xMin: Double,
         xMax: Double,
         yMin: Double,
         yMax: Double,
         tMin: Double? = nil,
         tMax: Double? = nil) {
        self.xMin = xMin
        self.xMax = xMax
        self.yMin = yMin
        self.yMax = yMax
        self.tMin = tMin
        self.tMax = tMax
    }
}

/// Codable payload designed to sit directly inside a generative drawing action.
/// Only fields relevant to `kind` need to be supplied.
nonisolated struct MathPlotSpec: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable {
        case function
        case parametric
        case implicit
        case line
        case scatter
        case bar
        case histogram
        case disk
    }

    enum Relation: String, Codable, Sendable {
        case eq
        case lte
        case gte
    }

    var kind: Kind

    /// Function: y=f(x). Implicit: left side, `g(x,y)`, or a complete
    /// relation such as `x^2 + y^2 <= 4`.
    var expression: String?
    /// Parametric x(t) and y(t).
    var xExpression: String?
    var yExpression: String?
    /// Optional right side for an implicit relation; zero when omitted.
    var rightExpression: String?
    var relation: Relation?

    /// Line/scatter/bar data as [[x,y], ...]. Histogram input may use either
    /// `values` or the first number of each entry in `points`.
    var points: [[Double]]?
    var values: [Double]?
    var binCount: Int?

    /// Disk shorthand: (x-centerX)^2 + (y-centerY)^2 relation radius^2.
    var centerX: Double?
    var centerY: Double?
    var radius: Double?

    var domain: MathPlotDomain?
    var sampleCount: Int?
    var fill: Bool?
    /// Preserve equal x/y data-unit scale by letterboxing the chart area.
    /// Defaults to true for disk/implicit plots and false for other kinds.
    var equalScale: Bool?

    var title: String?
    var xAxisLabel: String?
    var yAxisLabel: String?

    init(kind: Kind,
         expression: String? = nil,
         xExpression: String? = nil,
         yExpression: String? = nil,
         rightExpression: String? = nil,
         relation: Relation? = nil,
         points: [[Double]]? = nil,
         values: [Double]? = nil,
         binCount: Int? = nil,
         centerX: Double? = nil,
         centerY: Double? = nil,
         radius: Double? = nil,
         domain: MathPlotDomain? = nil,
         sampleCount: Int? = nil,
         fill: Bool? = nil,
         equalScale: Bool? = nil,
         title: String? = nil,
         xAxisLabel: String? = nil,
         yAxisLabel: String? = nil) {
        self.kind = kind
        self.expression = expression
        self.xExpression = xExpression
        self.yExpression = yExpression
        self.rightExpression = rightExpression
        self.relation = relation
        self.points = points
        self.values = values
        self.binCount = binCount
        self.centerX = centerX
        self.centerY = centerY
        self.radius = radius
        self.domain = domain
        self.sampleCount = sampleCount
        self.fill = fill
        self.equalScale = equalScale
        self.title = title
        self.xAxisLabel = xAxisLabel
        self.yAxisLabel = yAxisLabel
    }
}

nonisolated struct PlotRenderLabel: Equatable, Sendable {
    enum Role: Sendable {
        case tick
        case title
        case xAxis
        case yAxis
    }

    var text: String
    var position: CGPoint
    var fontSize: CGFloat
    /// Radians. Existing center-anchored label renderers may safely ignore it;
    /// a richer overlay can rotate the y-axis title.
    var rotation: CGFloat
    var role: Role

    init(text: String,
         position: CGPoint,
         fontSize: CGFloat = 11,
         rotation: CGFloat = 0,
         role: Role = .tick) {
        self.text = text
        self.position = position
        self.fontSize = fontSize
        self.rotation = rotation
        self.role = role
    }
}

nonisolated struct PlotRenderOutput: Equatable, Sendable {
    /// Axes, ticks, bars, and other deliberately straight polylines.
    var straightPathGroups: [[CGPoint]] = []
    /// Function curves, contours, circles, and point markers.
    var smoothPathGroups: [[CGPoint]] = []
    /// Region fill represented as separate hatch segments. Integrators should
    /// commit these as a batch instead of animating every segment separately.
    var hatchPaths: [[CGPoint]] = []
    var labels: [PlotRenderLabel] = []

    var isEmpty: Bool {
        straightPathGroups.isEmpty && smoothPathGroups.isEmpty
            && hatchPaths.isEmpty && labels.isEmpty
    }
}

nonisolated enum MathPlotError: Error, Equatable, LocalizedError, Sendable {
    case invalidCanvasBounds
    case missingField(String)
    case invalidDomain(String)
    case invalidPoint(index: Int)
    case tooManyPoints(maximum: Int)
    case invalidDisk
    case noRenderableData
    case expression(String)

    var errorDescription: String? {
        switch self {
        case .invalidCanvasBounds:
            return "The plot rectangle is too small or non-finite."
        case .missingField(let field):
            return "The plot is missing required field '\(field)'."
        case .invalidDomain(let reason):
            return "Invalid plot domain: \(reason)."
        case .invalidPoint(let index):
            return "Point \(index) must contain two finite numbers [x,y]."
        case .tooManyPoints(let maximum):
            return "The plot has too many data points (maximum \(maximum))."
        case .invalidDisk:
            return "A disk requires finite center coordinates and a positive radius."
        case .noRenderableData:
            return "The plot contains no values inside the requested domain."
        case .expression(let message):
            return "Invalid plot expression: \(message)"
        }
    }
}

nonisolated enum MathPlotRenderer {
    private static let maximumDataPoints = 5_000
    private static let maximumDomainMagnitude = 1.0e12
    private static let maximumHatchSegments = 1_500

    /// Creates a deterministic vector plan in canvas coordinates. Expression
    /// compilation failures throw. Domain failures at isolated samples become
    /// discontinuities instead of failing the complete plot.
    static func render(spec: MathPlotSpec,
                       in bounds: CGRect) throws -> PlotRenderOutput {
        guard bounds.width.isFinite, bounds.height.isFinite,
              bounds.minX.isFinite, bounds.minY.isFinite,
              bounds.width >= 120, bounds.height >= 100 else {
            throw MathPlotError.invalidCanvasBounds
        }

        switch spec.kind {
        case .function:
            return try renderFunction(spec: spec, bounds: bounds)
        case .parametric:
            return try renderParametric(spec: spec, bounds: bounds)
        case .implicit:
            return try renderImplicit(spec: spec, bounds: bounds)
        case .line:
            return try renderSeries(spec: spec, bounds: bounds, scatterOnly: false)
        case .scatter:
            return try renderSeries(spec: spec, bounds: bounds, scatterOnly: true)
        case .bar:
            return try renderBar(spec: spec, bounds: bounds)
        case .histogram:
            return try renderHistogram(spec: spec, bounds: bounds)
        case .disk:
            return try renderDisk(spec: spec, bounds: bounds)
        }
    }
}

// MARK: - Plot kinds

nonisolated private extension MathPlotRenderer {
    static func renderFunction(spec: MathPlotSpec,
                               bounds: CGRect) throws -> PlotRenderOutput {
        guard let raw = nonempty(spec.expression) else {
            throw MathPlotError.missingField("expression")
        }
        let expressionSource = functionRightHandSide(raw)
        let expression = try compile(expressionSource)
        let count = clamped(spec.sampleCount ?? 180, lower: 32, upper: 512)

        let suppliedDomain = try requestedDomain(spec.domain)
        let xRange = suppliedDomain.map { $0.xMin...$0.xMax } ?? (-10.0...10.0)
        let samples: [DataSample?] = (0...count).map { index in
            let x = interpolate(xRange.lowerBound, xRange.upperBound,
                                fraction: Double(index) / Double(count))
            guard let y = expression.value(x: x) else { return nil }
            return DataSample(x: x, y: y)
        }

        let domain: MathPlotDomain
        if let suppliedDomain {
            domain = suppliedDomain
        } else {
            let finiteY = samples.compactMap { $0?.y }
            guard !finiteY.isEmpty else { throw MathPlotError.noRenderableData }
            let yRange = automaticRange(finiteY, includeZero: false, robust: true)
            domain = try validated(MathPlotDomain(
                xMin: xRange.lowerBound,
                xMax: xRange.upperBound,
                yMin: yRange.lowerBound,
                yMax: yRange.upperBound
            ))
        }

        let context = try RenderContext(bounds: bounds, domain: domain,
                                        hasTitle: nonempty(spec.title) != nil,
                                        hasAxisLabels: hasAxisLabels(spec),
                                        equalScale: spec.equalScale ?? false)
        var output = axesAndLabels(spec: spec, context: context)
        output.smoothPathGroups += clippedCurvePaths(samples, context: context)
        guard !output.smoothPathGroups.isEmpty else {
            throw MathPlotError.noRenderableData
        }
        return output
    }

    static func renderParametric(spec: MathPlotSpec,
                                 bounds: CGRect) throws -> PlotRenderOutput {
        guard let xSource = nonempty(spec.xExpression) else {
            throw MathPlotError.missingField("xExpression")
        }
        guard let ySource = nonempty(spec.yExpression) else {
            throw MathPlotError.missingField("yExpression")
        }
        let xExpression = try compile(xSource)
        let yExpression = try compile(ySource)
        let suppliedDomain = try spec.domain.map(validated)
        let tMin = suppliedDomain?.tMin ?? 0
        let tMax = suppliedDomain?.tMax ?? 2 * Double.pi
        guard validRange(tMin, tMax) else {
            throw MathPlotError.invalidDomain("tMin must be less than tMax")
        }

        let count = clamped(spec.sampleCount ?? 200, lower: 32, upper: 512)
        let samples: [DataSample?] = (0...count).map { index in
            let t = interpolate(tMin, tMax, fraction: Double(index) / Double(count))
            guard let x = xExpression.value(t: t),
                  let y = yExpression.value(t: t) else { return nil }
            return DataSample(x: x, y: y)
        }

        let domain: MathPlotDomain
        if let suppliedDomain {
            domain = suppliedDomain
        } else {
            let finite = samples.compactMap { $0 }
            guard !finite.isEmpty else { throw MathPlotError.noRenderableData }
            let xRange = automaticRange(finite.map(\.x), includeZero: false, robust: true)
            let yRange = automaticRange(finite.map(\.y), includeZero: false, robust: true)
            domain = try validated(MathPlotDomain(
                xMin: xRange.lowerBound,
                xMax: xRange.upperBound,
                yMin: yRange.lowerBound,
                yMax: yRange.upperBound,
                tMin: tMin,
                tMax: tMax
            ))
        }

        let context = try RenderContext(bounds: bounds, domain: domain,
                                        hasTitle: nonempty(spec.title) != nil,
                                        hasAxisLabels: hasAxisLabels(spec),
                                        equalScale: spec.equalScale ?? false)
        var output = axesAndLabels(spec: spec, context: context)
        output.smoothPathGroups += clippedCurvePaths(samples, context: context)
        guard !output.smoothPathGroups.isEmpty else {
            throw MathPlotError.noRenderableData
        }
        return output
    }

    static func renderImplicit(spec: MathPlotSpec,
                               bounds: CGRect) throws -> PlotRenderOutput {
        guard let rawExpression = nonempty(spec.expression) else {
            throw MathPlotError.missingField("expression")
        }
        let relationParts = resolveImplicitRelation(spec: spec,
                                                    expression: rawExpression)
        let left = try compile(relationParts.left)
        let right = try compile(relationParts.right)
        let domain = try validated(spec.domain ?? MathPlotDomain(
            xMin: -10, xMax: 10, yMin: -10, yMax: 10
        ))
        let context = try RenderContext(bounds: bounds, domain: domain,
                                        hasTitle: nonempty(spec.title) != nil,
                                        hasAxisLabels: hasAxisLabels(spec),
                                        equalScale: spec.equalScale ?? true)
        var output = axesAndLabels(spec: spec, context: context)
        let count = clamped(spec.sampleCount ?? 80, lower: 24, upper: 128)

        let field: (Double, Double) -> Double? = { x, y in
            guard let lhs = left.value(x: x, y: y),
                  let rhs = right.value(x: x, y: y) else { return nil }
            let result = lhs - rhs
            return result.isFinite ? result : nil
        }

        let contour = contourPaths(field: field, context: context, count: count)
        output.smoothPathGroups += contour

        let shouldFill = spec.fill ?? (relationParts.relation != .eq)
        if shouldFill, relationParts.relation != .eq {
            output.hatchPaths += hatchPaths(
                field: field,
                relation: relationParts.relation,
                context: context,
                horizontalSamples: min(256, count * 2)
            )
        }

        // Do not report an axes-only plot as a successful relation. A valid
        // equality contributes a contour; a valid filled inequality
        // contributes either a contour or hatching (including the case where
        // the whole viewport satisfies it). An impossible inequality such as
        // x^2+y^2<=-1 contributes neither and must be rejected.
        if contour.isEmpty && output.hatchPaths.isEmpty {
            throw MathPlotError.noRenderableData
        }
        return output
    }

    static func renderSeries(spec: MathPlotSpec,
                             bounds: CGRect,
                             scatterOnly: Bool) throws -> PlotRenderOutput {
        let points = try decodedPoints(spec.points)
        guard !points.isEmpty else { throw MathPlotError.noRenderableData }
        let domain = try validated(spec.domain ?? automaticDataDomain(
            points: points,
            includeZeroOnY: false
        ))
        let context = try RenderContext(bounds: bounds, domain: domain,
                                        hasTitle: nonempty(spec.title) != nil,
                                        hasAxisLabels: hasAxisLabels(spec),
                                        equalScale: spec.equalScale ?? false)
        var output = axesAndLabels(spec: spec, context: context)

        var connectedPaths: [[CGPoint]] = []
        if !scatterOnly {
            let samples = points.map(Optional.some)
            connectedPaths = clippedCurvePaths(samples, context: context,
                                                splitLargeJumps: false)
            // A data-series `line` means straight interpolation between the
            // supplied observations. Routing it through smoothPathGroups
            // lets PencilKit's spline interpolation bow or overshoot those
            // exact values, so keep the connections in the straight channel.
            output.straightPathGroups += connectedPaths
        }
        var markerPaths: [[CGPoint]] = []
        for point in points where context.dataContains(x: point.x, y: point.y) {
            markerPaths.append(circle(
                center: context.canvasPoint(x: point.x, y: point.y),
                radius: scatterOnly ? 3.5 : 2.5,
                count: 12
            ))
        }
        output.smoothPathGroups += markerPaths
        guard !connectedPaths.isEmpty || !markerPaths.isEmpty else {
            throw MathPlotError.noRenderableData
        }
        return output
    }

    static func renderBar(spec: MathPlotSpec,
                          bounds: CGRect) throws -> PlotRenderOutput {
        let points = try decodedPoints(spec.points)
        guard !points.isEmpty else { throw MathPlotError.noRenderableData }
        let domain = try validated(spec.domain ?? automaticBarDomain(points: points))
        let context = try RenderContext(bounds: bounds, domain: domain,
                                        hasTitle: nonempty(spec.title) != nil,
                                        hasAxisLabels: hasAxisLabels(spec),
                                        equalScale: spec.equalScale ?? false)
        var output = axesAndLabels(spec: spec, context: context)
        let geometry = barPaths(points: points, context: context)
        guard !geometry.isEmpty else { throw MathPlotError.noRenderableData }
        output.straightPathGroups += geometry
        return output
    }

    static func renderHistogram(spec: MathPlotSpec,
                                bounds: CGRect) throws -> PlotRenderOutput {
        var values = spec.values ?? []
        if values.isEmpty, let rawPoints = spec.points {
            guard rawPoints.count <= maximumDataPoints else {
                throw MathPlotError.tooManyPoints(maximum: maximumDataPoints)
            }
            values = try rawPoints.enumerated().map { index, point in
                guard let value = point.first, value.isFinite else {
                    throw MathPlotError.invalidPoint(index: index)
                }
                return value
            }
        }
        guard values.count <= maximumDataPoints else {
            throw MathPlotError.tooManyPoints(maximum: maximumDataPoints)
        }
        guard !values.isEmpty, values.allSatisfy(\.isFinite) else {
            throw MathPlotError.noRenderableData
        }
        guard values.allSatisfy({ abs($0) <= maximumDomainMagnitude }) else {
            throw MathPlotError.invalidDomain(
                "histogram values must have magnitude at most \(maximumDomainMagnitude)"
            )
        }

        let requestedBins = spec.binCount
            ?? Int(Double(values.count).squareRoot().rounded(.up))
        let binCount = clamped(requestedBins, lower: 2, upper: 60)
        let minimum = values.min() ?? 0
        let maximum = values.max() ?? 1
        let inputRange: ClosedRange<Double>
        if minimum == maximum {
            // Scale-aware padding remains representable for large constants;
            // fixed ±0.5 disappears at sufficiently large magnitudes.
            let padding = max(0.5, abs(minimum) * 1e-6, minimum.ulp * 8)
            inputRange = (minimum - padding)...(maximum + padding)
        } else {
            inputRange = minimum...maximum
        }
        let span = inputRange.upperBound - inputRange.lowerBound
        let width = span / Double(binCount)
        guard span.isFinite, width.isFinite, width > 0 else {
            throw MathPlotError.invalidDomain("histogram range is not representable")
        }
        var counts = Array(repeating: 0, count: binCount)
        for value in values {
            let normalized = (value - inputRange.lowerBound) / width
            guard normalized.isFinite else {
                throw MathPlotError.invalidDomain("histogram bin index is non-finite")
            }
            let bounded = min(Double(binCount - 1), max(0, Foundation.floor(normalized)))
            counts[Int(bounded)] += 1
        }
        let bars = counts.enumerated().map { index, count in
            DataSample(
                x: inputRange.lowerBound + (Double(index) + 0.5) * width,
                y: Double(count)
            )
        }
        let automatic = MathPlotDomain(
            xMin: inputRange.lowerBound,
            xMax: inputRange.upperBound,
            yMin: 0,
            yMax: max(1, Double(counts.max() ?? 1) * 1.10)
        )
        let domain = try validated(spec.domain ?? automatic)
        let context = try RenderContext(bounds: bounds, domain: domain,
                                        hasTitle: nonempty(spec.title) != nil,
                                        hasAxisLabels: hasAxisLabels(spec),
                                        equalScale: spec.equalScale ?? false)
        var output = axesAndLabels(spec: spec, context: context)
        let geometry = barPaths(points: bars, context: context,
                                preferredDataWidth: width * 0.92)
        guard !geometry.isEmpty else { throw MathPlotError.noRenderableData }
        output.straightPathGroups += geometry
        return output
    }

    static func renderDisk(spec: MathPlotSpec,
                           bounds: CGRect) throws -> PlotRenderOutput {
        let centerX = spec.centerX ?? 0
        let centerY = spec.centerY ?? 0
        let radius = spec.radius ?? 2
        guard centerX.isFinite, centerY.isFinite,
              radius.isFinite, radius > 0,
              radius <= maximumDomainMagnitude else {
            throw MathPlotError.invalidDisk
        }

        let padding = radius * 1.35
        let domain = try validated(spec.domain ?? MathPlotDomain(
            xMin: centerX - padding,
            xMax: centerX + padding,
            yMin: centerY - padding,
            yMax: centerY + padding
        ))
        let context = try RenderContext(bounds: bounds, domain: domain,
                                        hasTitle: nonempty(spec.title) != nil,
                                        hasAxisLabels: hasAxisLabels(spec),
                                        equalScale: spec.equalScale ?? true)
        var output = axesAndLabels(spec: spec, context: context)
        let relation = spec.relation ?? .lte

        let boundary: [DataSample?] = (0...96).map { index in
            let angle = 2 * Double.pi * Double(index) / 96
            return DataSample(
                x: centerX + radius * Foundation.cos(angle),
                y: centerY + radius * Foundation.sin(angle)
            )
        }
        let boundaryPaths = clippedCurvePaths(
            boundary,
            context: context,
            splitLargeJumps: false
        )
        output.smoothPathGroups += boundaryPaths

        var fillPaths: [[CGPoint]] = []
        if spec.fill ?? (relation != .eq), relation != .eq {
            let radiusSquared = radius * radius
            let field: (Double, Double) -> Double? = { x, y in
                let dx = x - centerX
                let dy = y - centerY
                return dx * dx + dy * dy - radiusSquared
            }
            fillPaths = hatchPaths(field: field,
                                   relation: relation,
                                   context: context,
                                   horizontalSamples: 180)
            output.hatchPaths += fillPaths
        }
        guard !boundaryPaths.isEmpty || !fillPaths.isEmpty else {
            throw MathPlotError.noRenderableData
        }
        return output
    }
}

// MARK: - Axes and coordinate conversion

nonisolated private extension MathPlotRenderer {
    nonisolated struct RenderContext {
        let bounds: CGRect
        let chart: CGRect
        let domain: MathPlotDomain

        init(bounds: CGRect,
             domain: MathPlotDomain,
             hasTitle: Bool,
             hasAxisLabels: Bool,
             equalScale: Bool) throws {
            self.bounds = bounds
            self.domain = domain

            let left = min(48, max(34, bounds.width * 0.13))
            let right = min(18, max(10, bounds.width * 0.04))
            let top = hasTitle ? min(32, max(24, bounds.height * 0.10)) : 12
            let bottom = hasAxisLabels
                ? min(42, max(32, bounds.height * 0.13))
                : min(30, max(24, bounds.height * 0.09))
            var chart = CGRect(
                x: bounds.minX + left,
                y: bounds.minY + top,
                width: bounds.width - left - right,
                height: bounds.height - top - bottom
            )
            guard chart.width >= 60, chart.height >= 50 else {
                throw MathPlotError.invalidCanvasBounds
            }

            if equalScale {
                let dataAspect = CGFloat(
                    (domain.xMax - domain.xMin) / (domain.yMax - domain.yMin)
                )
                let availableAspect = chart.width / chart.height
                if availableAspect > dataAspect {
                    let width = chart.height * dataAspect
                    chart.origin.x += (chart.width - width) / 2
                    chart.size.width = width
                } else if availableAspect < dataAspect {
                    let height = chart.width / dataAspect
                    chart.origin.y += (chart.height - height) / 2
                    chart.size.height = height
                }
            }
            self.chart = chart
        }

        func canvasPoint(x: Double, y: Double) -> CGPoint {
            let nx = (x - domain.xMin) / (domain.xMax - domain.xMin)
            let ny = (y - domain.yMin) / (domain.yMax - domain.yMin)
            return CGPoint(
                x: chart.minX + CGFloat(nx) * chart.width,
                y: chart.maxY - CGFloat(ny) * chart.height
            )
        }

        func dataX(canvasX: CGFloat) -> Double {
            let fraction = Double((canvasX - chart.minX) / chart.width)
            return domain.xMin + fraction * (domain.xMax - domain.xMin)
        }

        func dataY(canvasY: CGFloat) -> Double {
            let fraction = Double((chart.maxY - canvasY) / chart.height)
            return domain.yMin + fraction * (domain.yMax - domain.yMin)
        }

        func dataContains(x: Double, y: Double) -> Bool {
            x >= domain.xMin && x <= domain.xMax
                && y >= domain.yMin && y <= domain.yMax
        }
    }

    static func axesAndLabels(spec: MathPlotSpec,
                              context: RenderContext) -> PlotRenderOutput {
        var output = PlotRenderOutput()
        let chart = context.chart
        let domain = context.domain

        // A subtle frame makes the requested domain explicit even when zero
        // lies outside it.
        output.straightPathGroups.append([
            CGPoint(x: chart.minX, y: chart.minY),
            CGPoint(x: chart.maxX, y: chart.minY),
            CGPoint(x: chart.maxX, y: chart.maxY),
            CGPoint(x: chart.minX, y: chart.maxY),
            CGPoint(x: chart.minX, y: chart.minY)
        ])

        let xAxisValue = domain.yMin <= 0 && domain.yMax >= 0 ? 0 : domain.yMin
        let yAxisValue = domain.xMin <= 0 && domain.xMax >= 0 ? 0 : domain.xMin
        let xAxisY = context.canvasPoint(x: domain.xMin, y: xAxisValue).y
        let yAxisX = context.canvasPoint(x: yAxisValue, y: domain.yMin).x

        output.straightPathGroups.append([
            CGPoint(x: chart.minX, y: xAxisY),
            CGPoint(x: chart.maxX, y: xAxisY)
        ])
        output.straightPathGroups.append([
            CGPoint(x: yAxisX, y: chart.minY),
            CGPoint(x: yAxisX, y: chart.maxY)
        ])

        let xTicks = niceTicks(minimum: domain.xMin, maximum: domain.xMax,
                               targetCount: 6)
        let yTicks = niceTicks(minimum: domain.yMin, maximum: domain.yMax,
                               targetCount: 6)
        let xStep = tickStep(xTicks, fallback: domain.xMax - domain.xMin)
        let yStep = tickStep(yTicks, fallback: domain.yMax - domain.yMin)

        for value in xTicks {
            let x = context.canvasPoint(x: value, y: xAxisValue).x
            output.straightPathGroups.append([
                CGPoint(x: x, y: xAxisY - 4),
                CGPoint(x: x, y: xAxisY + 4)
            ])
            let labelY = min(context.bounds.maxY - 8, xAxisY + 13)
            output.labels.append(PlotRenderLabel(
                text: formattedTick(value, step: xStep),
                position: CGPoint(x: x, y: labelY)
            ))
        }

        for value in yTicks {
            if abs(value) < max(1e-12, yStep * 1e-8),
               abs(yAxisValue) < 1e-12 {
                // The x-axis already labels the shared zero.
                continue
            }
            let y = context.canvasPoint(x: yAxisValue, y: value).y
            output.straightPathGroups.append([
                CGPoint(x: yAxisX - 4, y: y),
                CGPoint(x: yAxisX + 4, y: y)
            ])
            let labelX = max(context.bounds.minX + 16, yAxisX - 20)
            output.labels.append(PlotRenderLabel(
                text: formattedTick(value, step: yStep),
                position: CGPoint(x: labelX, y: y)
            ))
        }

        if let title = nonempty(spec.title) {
            output.labels.append(PlotRenderLabel(
                text: title,
                position: CGPoint(x: chart.midX, y: context.bounds.minY + 11),
                fontSize: 14,
                role: .title
            ))
        }
        if let label = nonempty(spec.xAxisLabel) {
            output.labels.append(PlotRenderLabel(
                text: label,
                position: CGPoint(x: chart.midX, y: context.bounds.maxY - 7),
                fontSize: 12,
                role: .xAxis
            ))
        }
        if let label = nonempty(spec.yAxisLabel) {
            output.labels.append(PlotRenderLabel(
                text: label,
                position: CGPoint(x: context.bounds.minX + 9, y: chart.midY),
                fontSize: 12,
                rotation: -.pi / 2,
                role: .yAxis
            ))
        }
        return output
    }
}

// MARK: - Curves, clipping, bars, and markers

nonisolated private extension MathPlotRenderer {
    nonisolated struct DataSample: Equatable {
        let x: Double
        let y: Double
    }

    static func clippedCurvePaths(_ samples: [DataSample?],
                                  context: RenderContext,
                                  splitLargeJumps: Bool = true) -> [[CGPoint]] {
        var paths: [[CGPoint]] = []
        var current: [CGPoint] = []
        var previous: DataSample?

        func flush() {
            if current.count >= 2 { paths.append(current) }
            current.removeAll(keepingCapacity: true)
        }

        for sample in samples {
            guard let sample else {
                flush()
                previous = nil
                continue
            }
            guard let prior = previous else {
                previous = sample
                continue
            }

            let a = context.canvasPoint(x: prior.x, y: prior.y)
            let b = context.canvasPoint(x: sample.x, y: sample.y)
            let jump = abs(b.y - a.y) > context.chart.height * 1.5
                || abs(b.x - a.x) > context.chart.width * 1.5
            if splitLargeJumps && jump {
                flush()
                previous = sample
                continue
            }

            if let clipped = clipSegment(from: a, to: b, inside: context.chart) {
                if let last = current.last,
                   distance(last, clipped.start) > 0.75 {
                    flush()
                }
                if current.isEmpty { current.append(clipped.start) }
                if distance(current.last ?? clipped.start, clipped.end) > 0.05 {
                    current.append(clipped.end)
                }
            } else {
                flush()
            }
            previous = sample
        }
        flush()
        return paths
    }

    static func decodedPoints(_ raw: [[Double]]?) throws -> [DataSample] {
        let raw = raw ?? []
        guard raw.count <= maximumDataPoints else {
            throw MathPlotError.tooManyPoints(maximum: maximumDataPoints)
        }
        return try raw.enumerated().map { index, point in
            guard point.count >= 2, point[0].isFinite, point[1].isFinite else {
                throw MathPlotError.invalidPoint(index: index)
            }
            return DataSample(x: point[0], y: point[1])
        }
    }

    static func barPaths(points: [DataSample],
                         context: RenderContext,
                         preferredDataWidth: Double? = nil) -> [[CGPoint]] {
        let sortedX = Array(Set(points.map(\.x))).sorted()
        let minimumSpacing = zip(sortedX, sortedX.dropFirst())
            .map { $1 - $0 }
            .filter { $0 > 0 }
            .min()
        let fallbackWidth = (context.domain.xMax - context.domain.xMin)
            / Double(max(2, points.count * 2))
        let dataWidth = preferredDataWidth
            ?? (minimumSpacing.map { $0 * 0.72 } ?? fallbackWidth)
        let baseline = min(context.domain.yMax,
                           max(context.domain.yMin, 0))

        return points.compactMap { point in
            let left = point.x - dataWidth / 2
            let right = point.x + dataWidth / 2
            let lowerY = min(baseline, point.y)
            let upperY = max(baseline, point.y)
            guard right >= context.domain.xMin, left <= context.domain.xMax,
                  upperY >= context.domain.yMin, lowerY <= context.domain.yMax else {
                return nil
            }
            let clippedLeft = max(context.domain.xMin, left)
            let clippedRight = min(context.domain.xMax, right)
            let clippedLower = max(context.domain.yMin, lowerY)
            let clippedUpper = min(context.domain.yMax, upperY)
            guard clippedRight > clippedLeft,
                  clippedUpper > clippedLower else { return nil }
            let bottomLeft = context.canvasPoint(x: clippedLeft, y: clippedLower)
            let topRight = context.canvasPoint(x: clippedRight, y: clippedUpper)
            guard abs(topRight.x - bottomLeft.x) >= 0.5,
                  abs(bottomLeft.y - topRight.y) >= 0.5 else { return nil }
            return [
                CGPoint(x: bottomLeft.x, y: bottomLeft.y),
                CGPoint(x: bottomLeft.x, y: topRight.y),
                CGPoint(x: topRight.x, y: topRight.y),
                CGPoint(x: topRight.x, y: bottomLeft.y),
                CGPoint(x: bottomLeft.x, y: bottomLeft.y)
            ]
        }
    }

    static func circle(center: CGPoint, radius: CGFloat, count: Int) -> [CGPoint] {
        (0...count).map { index in
            let angle = 2 * CGFloat.pi * CGFloat(index) / CGFloat(count)
            return CGPoint(x: center.x + radius * Foundation.cos(angle),
                           y: center.y + radius * Foundation.sin(angle))
        }
    }

    nonisolated struct ClippedSegment {
        let start: CGPoint
        let end: CGPoint
    }

    /// Liang-Barsky segment clipping.
    static func clipSegment(from start: CGPoint,
                            to end: CGPoint,
                            inside rect: CGRect) -> ClippedSegment? {
        let dx = end.x - start.x
        let dy = end.y - start.y
        let p: [CGFloat] = [-dx, dx, -dy, dy]
        let q: [CGFloat] = [
            start.x - rect.minX,
            rect.maxX - start.x,
            start.y - rect.minY,
            rect.maxY - start.y
        ]
        var lower: CGFloat = 0
        var upper: CGFloat = 1

        for index in 0..<4 {
            if abs(p[index]) < .ulpOfOne {
                if q[index] < 0 { return nil }
                continue
            }
            let ratio = q[index] / p[index]
            if p[index] < 0 {
                lower = max(lower, ratio)
            } else {
                upper = min(upper, ratio)
            }
            if lower > upper { return nil }
        }

        return ClippedSegment(
            start: CGPoint(x: start.x + lower * dx, y: start.y + lower * dy),
            end: CGPoint(x: start.x + upper * dx, y: start.y + upper * dy)
        )
    }
}

// MARK: - Implicit contours and inequality hatching

nonisolated private extension MathPlotRenderer {
    nonisolated struct Segment {
        let start: CGPoint
        let end: CGPoint
    }

    static func contourPaths(field: (Double, Double) -> Double?,
                             context: RenderContext,
                             count: Int) -> [[CGPoint]] {
        let width = count + 1
        var values = Array<Double?>(repeating: nil, count: width * width)
        func offset(_ x: Int, _ y: Int) -> Int { y * width + x }

        for yIndex in 0...count {
            let y = interpolate(context.domain.yMin, context.domain.yMax,
                                fraction: Double(yIndex) / Double(count))
            for xIndex in 0...count {
                let x = interpolate(context.domain.xMin, context.domain.xMax,
                                    fraction: Double(xIndex) / Double(count))
                values[offset(xIndex, yIndex)] = field(x, y)
            }
        }

        var segments: [Segment] = []
        segments.reserveCapacity(count * count / 2)
        for yIndex in 0..<count {
            for xIndex in 0..<count {
                guard let v0 = values[offset(xIndex, yIndex)],
                      let v1 = values[offset(xIndex + 1, yIndex)],
                      let v2 = values[offset(xIndex + 1, yIndex + 1)],
                      let v3 = values[offset(xIndex, yIndex + 1)] else { continue }

                let x0 = interpolate(context.domain.xMin, context.domain.xMax,
                                     fraction: Double(xIndex) / Double(count))
                let x1 = interpolate(context.domain.xMin, context.domain.xMax,
                                     fraction: Double(xIndex + 1) / Double(count))
                let y0 = interpolate(context.domain.yMin, context.domain.yMax,
                                     fraction: Double(yIndex) / Double(count))
                let y1 = interpolate(context.domain.yMin, context.domain.yMax,
                                     fraction: Double(yIndex + 1) / Double(count))
                let p0 = context.canvasPoint(x: x0, y: y0)
                let p1 = context.canvasPoint(x: x1, y: y0)
                let p2 = context.canvasPoint(x: x1, y: y1)
                let p3 = context.canvasPoint(x: x0, y: y1)

                var intersections: [Int: CGPoint] = [:]
                intersections[0] = zeroCrossing(a: p0, valueA: v0, b: p1, valueB: v1)
                intersections[1] = zeroCrossing(a: p1, valueA: v1, b: p2, valueB: v2)
                intersections[2] = zeroCrossing(a: p2, valueA: v2, b: p3, valueB: v3)
                intersections[3] = zeroCrossing(a: p3, valueA: v3, b: p0, valueB: v0)
                intersections = intersections.filter { $0.value.x.isFinite && $0.value.y.isFinite }

                let edgeIndices = intersections.keys.sorted()
                if edgeIndices.count == 2,
                   let a = intersections[edgeIndices[0]],
                   let b = intersections[edgeIndices[1]] {
                    segments.append(Segment(start: a, end: b))
                } else if edgeIndices.count == 4 {
                    let pattern = (v0 >= 0 ? 1 : 0)
                        | (v1 >= 0 ? 2 : 0)
                        | (v2 >= 0 ? 4 : 0)
                        | (v3 >= 0 ? 8 : 0)
                    let centerPositive = (v0 + v1 + v2 + v3) / 4 >= 0
                    let pairings: [(Int, Int)]
                    if pattern == 5 {
                        pairings = centerPositive ? [(0, 1), (2, 3)]
                            : [(0, 3), (1, 2)]
                    } else if pattern == 10 {
                        pairings = centerPositive ? [(0, 3), (1, 2)]
                            : [(0, 1), (2, 3)]
                    } else {
                        pairings = [(0, 1), (2, 3)]
                    }
                    for pair in pairings {
                        if let a = intersections[pair.0], let b = intersections[pair.1] {
                            segments.append(Segment(start: a, end: b))
                        }
                    }
                }
            }
        }

        let tolerance = max(0.15,
                            min(context.chart.width, context.chart.height)
                                / CGFloat(count) * 0.08)
        return stitch(segments: segments, tolerance: tolerance)
    }

    static func zeroCrossing(a: CGPoint, valueA: Double,
                             b: CGPoint, valueB: Double) -> CGPoint? {
        let epsilon = 1e-12 * max(1, abs(valueA), abs(valueB))
        let aIsZero = abs(valueA) <= epsilon
        let bIsZero = abs(valueB) <= epsilon
        if aIsZero && bIsZero { return nil }
        if !aIsZero, !bIsZero, (valueA > 0) == (valueB > 0) { return nil }
        let denominator = valueA - valueB
        let fraction = abs(denominator) <= epsilon
            ? 0.5
            : min(1, max(0, valueA / denominator))
        return CGPoint(
            x: a.x + CGFloat(fraction) * (b.x - a.x),
            y: a.y + CGFloat(fraction) * (b.y - a.y)
        )
    }

    nonisolated struct EndpointKey: Hashable {
        let x: Int
        let y: Int
    }

    static func stitch(segments: [Segment], tolerance: CGFloat) -> [[CGPoint]] {
        guard !segments.isEmpty else { return [] }
        func key(_ point: CGPoint) -> EndpointKey {
            EndpointKey(x: Int((point.x / tolerance).rounded()),
                        y: Int((point.y / tolerance).rounded()))
        }

        var endpoints: [(EndpointKey, EndpointKey)] = []
        var representative: [EndpointKey: CGPoint] = [:]
        var adjacency: [EndpointKey: [Int]] = [:]
        endpoints.reserveCapacity(segments.count)
        for (index, segment) in segments.enumerated() {
            let a = key(segment.start)
            let b = key(segment.end)
            guard a != b else { continue }
            endpoints.append((a, b))
            let storedIndex = endpoints.count - 1
            representative[a] = representative[a] ?? segment.start
            representative[b] = representative[b] ?? segment.end
            adjacency[a, default: []].append(storedIndex)
            adjacency[b, default: []].append(storedIndex)
            _ = index // documents that source ordering is intentionally retained
        }

        var used = Array(repeating: false, count: endpoints.count)
        var paths: [[CGPoint]] = []

        func walk(from start: EndpointKey, firstEdge: Int) -> [CGPoint] {
            var result: [CGPoint] = [representative[start] ?? .zero]
            var current = start
            var edgeIndex: Int? = firstEdge
            while let edge = edgeIndex, !used[edge] {
                used[edge] = true
                let pair = endpoints[edge]
                let next = pair.0 == current ? pair.1 : pair.0
                result.append(representative[next] ?? .zero)
                current = next
                if current == start { break }
                edgeIndex = adjacency[current]?.first(where: { !used[$0] })
            }
            return result
        }

        // Open contours first, then remaining closed loops.
        for (vertex, edges) in adjacency where edges.count != 2 {
            for edge in edges where !used[edge] {
                let path = walk(from: vertex, firstEdge: edge)
                if path.count >= 2 { paths.append(path) }
            }
        }
        for index in endpoints.indices where !used[index] {
            let path = walk(from: endpoints[index].0, firstEdge: index)
            if path.count >= 2 { paths.append(path) }
        }
        return paths
    }

    static func hatchPaths(field: (Double, Double) -> Double?,
                           relation: MathPlotSpec.Relation,
                           context: RenderContext,
                           horizontalSamples: Int) -> [[CGPoint]] {
        guard relation != .eq else { return [] }
        let columns = clamped(horizontalSamples, lower: 48, upper: 256)
        let rowSpacing = max(6, context.chart.height / 80)
        var result: [[CGPoint]] = []
        var canvasY = context.chart.minY + rowSpacing / 2

        while canvasY < context.chart.maxY,
              result.count < maximumHatchSegments {
            let dataY = context.dataY(canvasY: canvasY)
            var runStart: CGFloat?

            for index in 0...columns {
                let fraction = CGFloat(index) / CGFloat(columns)
                let canvasX = context.chart.minX + fraction * context.chart.width
                let dataX = context.dataX(canvasX: canvasX)
                let value = field(dataX, dataY)
                let inside: Bool
                if let value {
                    inside = relation == .lte ? value <= 0 : value >= 0
                } else {
                    inside = false
                }

                if inside, runStart == nil {
                    runStart = canvasX
                }
                if (!inside || index == columns), let start = runStart {
                    let end = inside ? canvasX : max(start, canvasX - context.chart.width
                        / CGFloat(columns))
                    if end - start >= 1 {
                        result.append([
                            CGPoint(x: start, y: canvasY),
                            CGPoint(x: end, y: canvasY)
                        ])
                    }
                    runStart = nil
                }
                if result.count >= maximumHatchSegments { break }
            }
            canvasY += rowSpacing
        }
        return result
    }
}

// MARK: - Domain, ticks, and expression helpers

nonisolated private extension MathPlotRenderer {
    nonisolated struct ImplicitRelation {
        let left: String
        let relation: MathPlotSpec.Relation
        let right: String
    }

    static func compile(_ source: String) throws -> MathExpression {
        do {
            return try MathExpression(source)
        } catch {
            throw MathPlotError.expression(
                (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            )
        }
    }

    static func requestedDomain(_ domain: MathPlotDomain?) throws
        -> MathPlotDomain? {
        try domain.map(validated)
    }

    static func validated(_ domain: MathPlotDomain) throws -> MathPlotDomain {
        let values = [domain.xMin, domain.xMax, domain.yMin, domain.yMax]
            + [domain.tMin, domain.tMax].compactMap { $0 }
        guard values.allSatisfy(\.isFinite) else {
            throw MathPlotError.invalidDomain("all bounds must be finite")
        }
        guard values.allSatisfy({ abs($0) <= maximumDomainMagnitude }) else {
            throw MathPlotError.invalidDomain(
                "bounds must have magnitude at most \(maximumDomainMagnitude)"
            )
        }
        guard validRange(domain.xMin, domain.xMax),
              validRange(domain.yMin, domain.yMax) else {
            throw MathPlotError.invalidDomain("minimums must be less than maximums")
        }
        if let tMin = domain.tMin, let tMax = domain.tMax,
           !validRange(tMin, tMax) {
            throw MathPlotError.invalidDomain("tMin must be less than tMax")
        }
        return domain
    }

    static func validRange(_ minimum: Double, _ maximum: Double) -> Bool {
        minimum.isFinite && maximum.isFinite && minimum < maximum
            && maximum - minimum >= 1e-12
    }

    static func automaticDataDomain(points: [DataSample],
                                    includeZeroOnY: Bool) -> MathPlotDomain {
        let x = automaticRange(points.map(\.x), includeZero: false, robust: false)
        let y = automaticRange(points.map(\.y), includeZero: includeZeroOnY,
                               robust: false)
        return MathPlotDomain(xMin: x.lowerBound, xMax: x.upperBound,
                              yMin: y.lowerBound, yMax: y.upperBound)
    }

    static func automaticBarDomain(points: [DataSample]) -> MathPlotDomain {
        let sortedX = Array(Set(points.map(\.x))).sorted()
        let spacing = zip(sortedX, sortedX.dropFirst()).map { $1 - $0 }
            .filter { $0 > 0 }.min() ?? 1
        let xMin = (sortedX.first ?? 0) - spacing * 0.6
        let xMax = (sortedX.last ?? 1) + spacing * 0.6
        let y = automaticRange(points.map(\.y), includeZero: true, robust: false)
        return MathPlotDomain(xMin: xMin, xMax: xMax,
                              yMin: y.lowerBound, yMax: y.upperBound)
    }

    static func automaticRange(_ rawValues: [Double],
                               includeZero: Bool,
                               robust: Bool) -> ClosedRange<Double> {
        var values = rawValues.filter(\.isFinite).sorted()
        guard !values.isEmpty else { return -1...1 }
        if robust, values.count >= 20 {
            let lowerIndex = Int(Double(values.count - 1) * 0.02)
            let upperIndex = Int(Double(values.count - 1) * 0.98)
            values = Array(values[lowerIndex...max(lowerIndex, upperIndex)])
        }
        var minimum = values.first ?? -1
        var maximum = values.last ?? 1
        if includeZero {
            minimum = min(0, minimum)
            maximum = max(0, maximum)
        }
        if minimum == maximum {
            let padding = max(1, abs(minimum) * 0.2)
            return (minimum - padding)...(maximum + padding)
        }
        let padding = (maximum - minimum) * 0.08
        return (minimum - padding)...(maximum + padding)
    }

    static func resolveImplicitRelation(spec: MathPlotSpec,
                                        expression: String) -> ImplicitRelation {
        if let split = splitTopLevelRelation(expression) {
            return split
        }
        return ImplicitRelation(
            left: expression,
            relation: spec.relation ?? .eq,
            right: nonempty(spec.rightExpression) ?? "0"
        )
    }

    static func functionRightHandSide(_ expression: String) -> String {
        guard let split = splitTopLevelRelation(expression), split.relation == .eq else {
            return expression
        }
        let left = split.left.replacingOccurrences(of: " ", with: "").lowercased()
        let right = split.right.replacingOccurrences(of: " ", with: "").lowercased()
        if left == "y" || left == "f(x)" { return split.right }
        if right == "y" || right == "f(x)" { return split.left }
        return expression
    }

    static func splitTopLevelRelation(_ source: String) -> ImplicitRelation? {
        let characters = Array(source)
        var depth = 0
        var index = 0
        while index < characters.count {
            switch characters[index] {
            case "(": depth += 1
            case ")": depth = max(0, depth - 1)
            default: break
            }
            if depth == 0 {
                let character = characters[index]
                var relation: MathPlotSpec.Relation?
                var length = 1
                if character == "≤" { relation = .lte }
                else if character == "≥" { relation = .gte }
                else if character == "=" { relation = .eq }
                else if character == "<" {
                    relation = .lte
                    if index + 1 < characters.count, characters[index + 1] == "=" {
                        length = 2
                    }
                } else if character == ">" {
                    relation = .gte
                    if index + 1 < characters.count, characters[index + 1] == "=" {
                        length = 2
                    }
                }
                if let relation {
                    if character == "=", index + 1 < characters.count,
                       characters[index + 1] == "=" {
                        length = 2
                    }
                    let left = String(characters[..<index])
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    let right = String(characters[(index + length)...])
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    if !left.isEmpty, !right.isEmpty {
                        return ImplicitRelation(left: left, relation: relation, right: right)
                    }
                }
            }
            index += 1
        }
        return nil
    }

    static func hasAxisLabels(_ spec: MathPlotSpec) -> Bool {
        nonempty(spec.xAxisLabel) != nil || nonempty(spec.yAxisLabel) != nil
    }

    static func nonempty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    static func niceTicks(minimum: Double,
                          maximum: Double,
                          targetCount: Int) -> [Double] {
        let span = maximum - minimum
        guard span.isFinite, span > 0 else { return [] }
        let rawStep = span / Double(max(2, targetCount - 1))
        let magnitude = Foundation.pow(10, floor(Foundation.log10(rawStep)))
        let normalized = rawStep / magnitude
        let niceNormalized: Double
        if normalized <= 1 { niceNormalized = 1 }
        else if normalized <= 2 { niceNormalized = 2 }
        else if normalized <= 5 { niceNormalized = 5 }
        else { niceNormalized = 10 }
        let step = niceNormalized * magnitude
        let first = ceil(minimum / step) * step
        let last = floor(maximum / step) * step
        guard first <= last else { return [] }

        var result: [Double] = []
        var value = first
        while value <= last + step * 1e-9, result.count < 20 {
            result.append(abs(value) < step * 1e-10 ? 0 : value)
            value += step
        }
        return result
    }

    static func tickStep(_ ticks: [Double], fallback: Double) -> Double {
        guard ticks.count >= 2 else { return fallback }
        return abs(ticks[1] - ticks[0])
    }

    static func formattedTick(_ value: Double, step: Double) -> String {
        let absolute = abs(value)
        if absolute >= 10_000 || (absolute > 0 && absolute < 0.001) {
            return String(format: "%.1e", value)
        }
        let decimals: Int
        if step >= 1 { decimals = 0 }
        else {
            decimals = min(6, max(1, Int(ceil(-Foundation.log10(step))) + 1))
        }
        var text = String(format: "%.*f", decimals, value)
        while text.contains(".") && text.last == "0" { text.removeLast() }
        if text.last == "." { text.removeLast() }
        return text == "-0" ? "0" : text
    }

    static func interpolate(_ lower: Double,
                            _ upper: Double,
                            fraction: Double) -> Double {
        lower + (upper - lower) * fraction
    }

    static func clamped(_ value: Int, lower: Int, upper: Int) -> Int {
        min(upper, max(lower, value))
    }

    static func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
        Foundation.hypot(a.x - b.x, a.y - b.y)
    }
}

//
//  DrawingActions.swift
//  AINotes
//
//  Generative drawing actions — the "draw" layer that creates new content
//  on the canvas (contrast with AnnotationDTO which only marks existing
//  user ink). All over-the-wire coordinates are fractional (0...1 of the
//  snapshot image), same convention as AnnotationDTO.
//

import Foundation
import SwiftUI
import CoreGraphics
import UIKit

// MARK: - DTOs (model → app)

struct DrawingActionDTO: Codable {
    enum Kind: String, Codable {
        case path      // freehand polyline from explicit fractional points
        case text      // single label in empty canvas space
        case equation  // TeX-style mathematical notation
        case plot      // deterministic mathematical/data graph
        case node      // labeled circle (one node, manually placed)
        case edge      // line between two anchors, optional arrowhead
        case tree      // composite: parent-linked nodes, auto-laid-out
    }

    let type: Kind

    // Common placement. Meaning varies by kind (see system prompt).
    let x: Double?
    let y: Double?
    let width: Double?
    let height: Double?
    let color: String?
    let text: String?
    let latex: String?
    let plot: MathPlotSpec?

    // path
    let points: [[Double]]?    // [[x,y], [x,y], ...]

    // edge
    // Each anchor is either "x,y" (raw fractional coords) or
    // "id:LABEL" (a previously-emitted node's label).
    let from: String?
    let to: String?
    let arrowhead: Bool?

    // tree
    let nodes: [TreeNodeSpec]?
}

struct TreeNodeSpec: Codable {
    let id: String
    let label: String
    let parent: String?     // nil = root
    let side: String?       // "left" or "right" — REQUIRED for binary trees
}

// MARK: - Palette

/// Single source of truth for AI ink colors. Black/white/gray/yellow are
/// remapped to hues that stay visible everywhere: the on-screen canvas is
/// systemBackground (white in light mode, near-black in dark mode) and the
/// snapshot the model sees is always white, so those four blend into one
/// background or the other — that's how "Gemini claims it drew something
/// but nothing is visible" happened. The tool schema no longer offers
/// them, but the model may still say them; remap instead of dropping ink.
enum AIPalette {
    static func uiColor(_ name: String?) -> UIColor {
        switch (name ?? "blue").lowercased() {
        case "red":    return .systemRed
        case "blue":   return .systemBlue
        case "green":  return .systemGreen
        case "orange": return .systemOrange
        case "purple": return .systemPurple
        case "yellow": return .systemOrange          // unreadable on white
        case "black", "white", "gray", "grey":
                       return .systemIndigo          // visible on both themes
        default:       return .systemBlue
        }
    }

    static func color(_ name: String?) -> Color {
        Color(uiColor(name))
    }

    /// Inverse mapping for persistence. Remapped names round-trip:
    /// "black" → indigo → "black" → indigo.
    static func name(for color: UIColor) -> String {
        switch color {
        case .systemRed:    return "red"
        case .systemGreen:  return "green"
        case .systemOrange: return "orange"
        case .systemPurple: return "purple"
        case .systemIndigo: return "black"
        default:            return "blue"
        }
    }
}

extension DrawingActionDTO {
    var uiColor: UIColor { AIPalette.uiColor(color) }

    /// Copy with the anchor point shifted by fractional offsets. Used by
    /// TextBlockPlacer to relocate explanation text into empty space.
    func offsetBy(dx: Double, dy: Double) -> DrawingActionDTO {
        DrawingActionDTO(type: type,
                         x: x.map { $0 + dx }, y: y.map { $0 + dy },
                         width: width, height: height,
                         color: color, text: text, latex: latex, plot: plot,
                         points: points,
                         from: from, to: to, arrowhead: arrowhead,
                         nodes: nodes)
    }

    /// Copy with an explicit frame in the persistent canvas coordinate
    /// space. Text/equation coordinates are center anchors; plot/tree
    /// coordinates are top-left anchors with an explicit size.
    func placed(in frame: CGRect, canvasBounds: CGRect) -> DrawingActionDTO {
        let usesTopLeft = type == .plot || type == .tree
        let px = usesTopLeft ? frame.minX : frame.midX
        let py = usesTopLeft ? frame.minY : frame.midY
        return DrawingActionDTO(
            type: type,
            x: Double((px - canvasBounds.minX) / canvasBounds.width),
            y: Double((py - canvasBounds.minY) / canvasBounds.height),
            // Label width/height are internal layout constraints. They let a
            // collision-driven shrink survive into ActionExpander instead of
            // being remeasured at the original full size.
            width: type == .node ? width : Double(frame.width / canvasBounds.width),
            height: type == .node ? height : Double(frame.height / canvasBounds.height),
            color: color,
            text: text,
            latex: latex,
            plot: plot,
            points: points,
            from: from,
            to: to,
            arrowhead: arrowhead,
            nodes: nodes
        )
    }

    func replacingText(_ replacement: String,
                       layoutWidth: Double? = nil) -> DrawingActionDTO {
        DrawingActionDTO(type: type, x: x, y: y,
                         width: layoutWidth ?? width, height: height,
                         color: color, text: replacement, latex: latex, plot: plot,
                         points: points, from: from, to: to,
                         arrowhead: arrowhead, nodes: nodes)
    }
}

// MARK: - AI label measurement

/// Shared metrics for placement, live rendering, persistence bounds, and
/// snapshots. Keeping these paths on one measurement model prevents a label
/// that looked safe to the placer from being wider when it was finally drawn.
enum AILabelLayout {
    struct Metrics {
        let size: CGSize
        let fontSize: CGFloat
    }

    static func plainSize(text: String, fontSize: CGFloat) -> CGSize {
        let font = UIFont.systemFont(ofSize: fontSize, weight: .semibold)
        let lines = text.components(separatedBy: .newlines)
        let width = lines.map {
            ($0 as NSString).size(withAttributes: [.font: font]).width
        }.max() ?? 0
        return CGSize(width: ceil(width),
                      height: ceil(font.lineHeight * CGFloat(max(1, lines.count))))
    }

    /// Inserts deterministic line breaks instead of relying on the live
    /// SwiftUI renderer and the snapshot CoreText renderer to wrap at
    /// subtly different glyph positions.
    static func wrappedPlain(text: String, maxWidth: CGFloat,
                             fontSize: CGFloat = 16) -> String {
        guard maxWidth > 1 else { return text }
        let font = UIFont.systemFont(ofSize: fontSize, weight: .semibold)
        func width(_ value: String) -> CGFloat {
            (value as NSString).size(withAttributes: [.font: font]).width
        }
        func chunks(of word: String) -> [String] {
            guard width(word) > maxWidth else { return [word] }
            var chunks: [String] = []
            var current = ""
            for character in word {
                let next = current + String(character)
                if !current.isEmpty, width(next) > maxWidth {
                    chunks.append(current)
                    current = String(character)
                } else {
                    current = next
                }
            }
            if !current.isEmpty { chunks.append(current) }
            return chunks
        }

        return text.components(separatedBy: .newlines).map { paragraph in
            let words = paragraph.split(whereSeparator: { $0.isWhitespace })
                .flatMap { chunks(of: String($0)) }
            guard !words.isEmpty else { return "" }
            var lines: [String] = []
            var line = ""
            for word in words {
                let proposed = line.isEmpty ? word : line + " " + word
                if !line.isEmpty, width(proposed) > maxWidth {
                    lines.append(line)
                    line = word
                } else {
                    line = proposed
                }
            }
            if !line.isEmpty { lines.append(line) }
            return lines.joined(separator: "\n")
        }.joined(separator: "\n")
    }

    static func adaptivePlain(text: String, maxSize: CGSize) -> Metrics {
        let baseFontSize: CGFloat = 16
        let base = plainSize(text: text, fontSize: baseFontSize)
        let scale = min(1,
                        maxSize.width / max(1, base.width),
                        maxSize.height / max(1, base.height))
        let fontSize = max(11, baseFontSize * scale)
        return Metrics(size: plainSize(text: text, fontSize: fontSize),
                       fontSize: fontSize)
    }

    static func adaptiveMath(latex: String, maxSize: CGSize) -> Metrics {
        let baseFontSize: CGFloat = 22
        let base = MathLabelRenderer.measure(latex: latex, fontSize: baseFontSize)
        let scale = min(1,
                        maxSize.width / max(1, base.width),
                        maxSize.height / max(1, base.height))
        let fontSize = max(13, baseFontSize * scale)
        return Metrics(
            size: MathLabelRenderer.measure(latex: latex, fontSize: fontSize),
            fontSize: fontSize
        )
    }

    static func rect(for label: StoredAILabel) -> CGRect {
        let size: CGSize
        if label.format == "latex" {
            size = MathLabelRenderer.measure(
                latex: label.text,
                fontSize: CGFloat(label.fontSize ?? 22)
            )
        } else {
            size = plainSize(text: label.text,
                             fontSize: CGFloat(label.fontSize ?? 16))
        }
        return CGRect(x: CGFloat(label.canvasX) - size.width / 2,
                      y: CGFloat(label.canvasY) - size.height / 2,
                      width: size.width, height: size.height)
    }

    static func plainImage(text: String, color: UIColor,
                           fontSize: CGFloat, leading: Bool,
                           scale: CGFloat = 2) -> UIImage {
        let size = plainSize(text: text, fontSize: fontSize)
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        format.opaque = false
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = leading ? .left : .center
            paragraph.lineBreakMode = .byClipping
            let attributed = NSAttributedString(
                string: text,
                attributes: [
                    .font: UIFont.systemFont(ofSize: fontSize, weight: .semibold),
                    .foregroundColor: color,
                    .paragraphStyle: paragraph
                ]
            )
            attributed.draw(
                with: CGRect(origin: .zero, size: size),
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                context: nil
            )
        }
    }
}

// MARK: - Content placement (avoid ink / controls / prior AI content)

/// Places explanation text, equations, plots, and trees one at a time.
/// Requested coordinates are preserved when the full footprint is safe.
/// When they are not, a bounded deterministic search uses the full page —
/// including left and right lanes — and adds each result to the keep-out set
/// before placing the next action. Targeted paths/edges are never relocated.
enum TextBlockPlacer {
    struct Result {
        let actions: [DrawingActionDTO]
        /// Inflated plot/tree boxes persisted by AIDrawingPlayer. Their
        /// interiors otherwise look deceptively empty when inferred only
        /// from thin PencilKit axis/curve stroke bounds on the next call.
        let reservedRects: [CGRect]
        let skippedCount: Int
    }

    private struct Candidate {
        let frame: CGRect
        let scale: CGFloat
        let overlap: CGFloat
        let score: CGFloat
    }

    private struct Placement {
        let action: DrawingActionDTO
        let candidate: Candidate
    }

    private static let contentGap: CGFloat = 10

    static func adjust(_ actions: [DrawingActionDTO],
                       canvasBounds: CGRect,
                       avoid: [CGRect]) -> Result {
        guard canvasBounds.width > 0, canvasBounds.height > 0 else {
            return Result(actions: actions, reservedRects: [], skippedCount: 0)
        }

        let edge = min(14, max(8, min(canvasBounds.width, canvasBounds.height) * 0.015))
        let safeBounds = canvasBounds.insetBy(dx: edge, dy: edge)
        var occupied = avoid.compactMap { normalized($0, inside: canvasBounds) }
            .map { $0.insetBy(dx: -contentGap, dy: -contentGap) }
        var output: [DrawingActionDTO] = []
        var persistedReservations: [CGRect] = []
        var skippedCount = 0

        for action in actions {
            // Prose is evaluated at several wrap widths. A wide empty row
            // can use nearly the whole page, while a narrow gap beside ink
            // can still accept the same text as a compact column.
            if action.type == .text {
                guard let placement = bestProsePlacement(
                    for: action,
                    canvasBounds: canvasBounds,
                    safeBounds: safeBounds,
                    occupied: occupied
                ), placement.candidate.overlap < 0.5 else {
                    skippedCount += 1
                    continue
                }
                let placedAction = placement.action.placed(
                    in: placement.candidate.frame,
                    canvasBounds: canvasBounds
                )
                output.append(placedAction)
                occupied.append(placement.candidate.frame.insetBy(
                    dx: -contentGap,
                    dy: -contentGap
                ))
                continue
            }

            guard let requested = footprint(for: action,
                                            canvasBounds: canvasBounds,
                                            safeBounds: safeBounds) else {
                if isRelocatable(action.type) {
                    skippedCount += 1
                } else {
                    output.append(action)
                }
                continue
            }

            if isRelocatable(action.type) {
                let result = bestCandidate(for: action,
                                           requested: requested,
                                           canvasBounds: canvasBounds,
                                           safeBounds: safeBounds,
                                           occupied: occupied)
                // A completely full page is not permission to cover the
                // student's work. Tiny labels are tried before this point;
                // if even those collide, omit the structured action.
                guard result.overlap < 0.5 else {
                    skippedCount += 1
                    continue
                }
                let placedAction = action.placed(in: result.frame,
                                                 canvasBounds: canvasBounds)
                output.append(placedAction)
                occupied.append(result.frame.insetBy(dx: -contentGap,
                                                      dy: -contentGap))
                if action.type == .plot || action.type == .tree {
                    let inflated = result.frame.insetBy(dx: -contentGap,
                                                        dy: -contentGap)
                        .intersection(canvasBounds)
                    if !inflated.isNull { persistedReservations.append(inflated) }
                }
            } else {
                output.append(action)
                // Targeted paths and edges keep their coordinates, but later
                // explanatory content in this same response must avoid them.
                occupied.append(requested.insetBy(dx: -contentGap,
                                                   dy: -contentGap))
            }
        }

        return Result(actions: output, reservedRects: persistedReservations,
                      skippedCount: skippedCount)
    }

    private static func bestProsePlacement(
        for action: DrawingActionDTO,
        canvasBounds: CGRect,
        safeBounds: CGRect,
        occupied: [CGRect]
    ) -> Placement? {
        guard let text = action.text, action.x != nil, action.y != nil else {
            return nil
        }

        var widths: [CGFloat] = []
        if let requested = action.width, requested > 0 {
            widths.append(CGFloat(requested) * canvasBounds.width)
        }
        widths += [0.92, 0.76, 0.60, 0.46, 0.34, 0.26].map {
            safeBounds.width * $0
        }

        var best: Placement?
        var seenLayouts = Set<String>()
        for proposedWidth in widths {
            let layoutWidth = min(
                safeBounds.width,
                max(min(120, safeBounds.width), proposedWidth)
            )
            let wrapped = AILabelLayout.wrappedPlain(
                text: text,
                maxWidth: layoutWidth
            )
            let layoutKey = "\(Int(layoutWidth.rounded())):\(wrapped)"
            guard seenLayouts.insert(layoutKey).inserted else { continue }

            let variant = action.replacingText(
                wrapped,
                layoutWidth: Double(layoutWidth / canvasBounds.width)
            )
            guard let requested = footprint(
                for: variant,
                canvasBounds: canvasBounds,
                safeBounds: safeBounds
            ) else { continue }
            let candidate = bestCandidate(
                for: variant,
                requested: requested,
                canvasBounds: canvasBounds,
                safeBounds: safeBounds,
                occupied: occupied
            )

            let lineCount = max(1, wrapped.components(separatedBy: .newlines).count)
            let unusedWidth = max(0, 1 - layoutWidth / max(1, safeBounds.width))
            let layoutPenalty = CGFloat(lineCount - 1) * 2 + unusedWidth * 6
            let scored = Candidate(
                frame: candidate.frame,
                scale: candidate.scale,
                overlap: candidate.overlap,
                score: candidate.score + layoutPenalty
            )
            let placement = Placement(action: variant, candidate: scored)
            if best == nil || scored.score < best!.candidate.score {
                best = placement
            }
        }
        return best
    }

    static func labelMetrics(for action: DrawingActionDTO,
                             canvasBounds: CGRect) -> AILabelLayout.Metrics? {
        let edge = min(14, max(8, min(canvasBounds.width, canvasBounds.height) * 0.015))
        let safeSize = canvasBounds.insetBy(dx: edge, dy: edge).size
        let maximum = CGSize(
            width: min(safeSize.width,
                       action.width.map { max(1, CGFloat($0) * canvasBounds.width) }
                           ?? safeSize.width),
            height: min(safeSize.height,
                        action.height.map { max(1, CGFloat($0) * canvasBounds.height) }
                            ?? safeSize.height)
        )
        let metrics: AILabelLayout.Metrics?
        switch action.type {
        case .text:
            guard let text = action.text else { return nil }
            metrics = AILabelLayout.adaptivePlain(text: text, maxSize: maximum)
        case .equation:
            guard let latex = action.latex ?? action.text else { return nil }
            metrics = AILabelLayout.adaptiveMath(latex: latex, maxSize: maximum)
        default:
            return nil
        }
        guard let metrics,
              // Persisted normalized dimensions can round-trip a measured
              // UIKit glyph box a fraction of a point smaller. The placer
              // already reserves a 10pt gap, so a two-point tolerance keeps
              // an otherwise identical label renderable without risking a
              // visual collision or canvas overflow.
              metrics.size.width <= maximum.width + 2,
              metrics.size.height <= maximum.height + 2 else { return nil }
        return metrics
    }

    private static func isRelocatable(_ type: DrawingActionDTO.Kind) -> Bool {
        type == .text || type == .equation || type == .plot
            || type == .tree || type == .node
    }

    private static func footprint(for action: DrawingActionDTO,
                                  canvasBounds: CGRect,
                                  safeBounds: CGRect) -> CGRect? {
        switch action.type {
        case .text, .equation:
            guard let x = action.x, let y = action.y,
                  let metrics = labelMetrics(for: action,
                                             canvasBounds: canvasBounds) else { return nil }
            let center = canvasPoint(x, y, in: canvasBounds)
            return CGRect(x: center.x - metrics.size.width / 2,
                          y: center.y - metrics.size.height / 2,
                          width: metrics.size.width, height: metrics.size.height)
        case .plot:
            return topLeftBox(for: action, canvasBounds: canvasBounds,
                              safeBounds: safeBounds,
                              defaultOrigin: CGPoint(x: 0.08, y: 0.18),
                              defaultSize: CGSize(width: 0.72, height: 0.60),
                              minimumSize: CGSize(width: 120, height: 100))
        case .tree:
            return topLeftBox(for: action, canvasBounds: canvasBounds,
                              safeBounds: safeBounds,
                              defaultOrigin: CGPoint(x: 0.1, y: 0.1),
                              defaultSize: CGSize(width: 0.8, height: 0.6),
                              minimumSize: CGSize(width: 80, height: 80))
        case .node:
            guard let x = action.x, let y = action.y else { return nil }
            let center = canvasPoint(x, y, in: canvasBounds)
            let diameter = max(40, CGFloat(action.width ?? 0.08) * canvasBounds.width)
            return CGRect(x: center.x - diameter / 2, y: center.y - diameter / 2,
                          width: diameter, height: diameter)
        case .path:
            let points = (action.points ?? []).compactMap { point -> CGPoint? in
                guard point.count >= 2 else { return nil }
                return canvasPoint(point[0], point[1], in: canvasBounds)
            }
            return pointsBounds(points)
        case .edge:
            let points = [action.from, action.to].compactMap {
                rawAnchor($0, canvasBounds: canvasBounds)
            }
            return pointsBounds(points)
        }
    }

    private static func topLeftBox(for action: DrawingActionDTO,
                                   canvasBounds: CGRect,
                                   safeBounds: CGRect,
                                   defaultOrigin: CGPoint,
                                   defaultSize: CGSize,
                                   minimumSize: CGSize) -> CGRect {
        let rawWidth = CGFloat(action.width ?? Double(defaultSize.width)) * canvasBounds.width
        let rawHeight = CGFloat(action.height ?? Double(defaultSize.height)) * canvasBounds.height
        let width = min(safeBounds.width, max(minimumSize.width, rawWidth))
        let height = min(safeBounds.height, max(minimumSize.height, rawHeight))
        let x = canvasBounds.minX
            + CGFloat(action.x ?? Double(defaultOrigin.x)) * canvasBounds.width
        let y = canvasBounds.minY
            + CGFloat(action.y ?? Double(defaultOrigin.y)) * canvasBounds.height
        return fit(CGRect(x: x, y: y, width: width, height: height),
                   inside: safeBounds)
    }

    private static func bestCandidate(for action: DrawingActionDTO,
                                      requested: CGRect,
                                      canvasBounds: CGRect,
                                      safeBounds: CGRect,
                                      occupied: [CGRect]) -> Candidate {
        let requestedFitted = fit(requested, inside: safeBounds)
        let exactOverlap = overlapArea(of: requestedFitted, with: occupied)
        let isCenteredLabel = (action.type == .text || action.type == .equation)
            && abs(requestedFitted.midX - safeBounds.midX) < safeBounds.width * 0.12
        // Gemini often defaults labels to (0.5, 0.5). Treat that as a hint,
        // not an instruction to build a single center column. Non-centered
        // coordinates remain exact when they are safe.
        let repackCenteredLabel = isCenteredLabel
        if exactOverlap < 0.5, !repackCenteredLabel {
            return Candidate(frame: requestedFitted, scale: 1,
                             overlap: 0, score: 0)
        }

        let canShrink = action.type == .plot || action.type == .tree
            || action.type == .text || action.type == .equation
        let minimum: CGSize
        if action.type == .plot {
            minimum = CGSize(width: min(120, safeBounds.width),
                             height: min(100, safeBounds.height))
        } else if action.type == .tree {
            minimum = CGSize(width: min(80, safeBounds.width),
                             height: min(80, safeBounds.height))
        } else {
            minimum = CGSize(width: 1, height: 1)
        }
        let scales: [CGFloat]
        if action.type == .text {
            // Prose already tries several real wrap widths. Scaling its
            // measured frame introduces fractional line-height rounding and
            // can make the final persisted constraint one pixel too short;
            // keep prose at a readable 16pt and choose another wrap instead.
            scales = [1]
        } else if action.type == .equation {
            let metrics = labelMetrics(for: action,
                                       canvasBounds: canvasBounds)
            let floor: CGFloat = 13
            let minimumScale = metrics.map { floor / max(floor, $0.fontSize) } ?? 1
            scales = [1, 0.9, 0.82, 0.74, 0.68, 0.60]
                .filter { $0 + 0.001 >= minimumScale }
        } else {
            scales = canShrink ? [1, 0.86, 0.72, 0.58, 0.45] : [1]
        }
        var best: Candidate?
        var seenSizes = Set<String>()

        for nominalScale in scales {
            let size = CGSize(
                width: min(safeBounds.width,
                           max(minimum.width, requested.width * nominalScale)),
                height: min(safeBounds.height,
                            max(minimum.height, requested.height * nominalScale))
            )
            let sizeKey = "\(Int(size.width.rounded()))x\(Int(size.height.rounded()))"
            guard seenSizes.insert(sizeKey).inserted else { continue }
            let actualScale = min(size.width / max(1, requested.width),
                                  size.height / max(1, requested.height))

            for origin in candidateOrigins(size: size,
                                           requested: requestedFitted,
                                           safeBounds: safeBounds,
                                           occupied: occupied) {
                let frame = CGRect(origin: origin, size: size)
                let overlap = overlapArea(of: frame, with: occupied)
                let normalizedOverlap = overlap / max(1, frame.width * frame.height)
                let distance = hypot(frame.midX - requested.midX,
                                     frame.midY - requested.midY)
                    / max(1, hypot(safeBounds.width, safeBounds.height))
                let shrinkPenalty = (1 - actualScale) * 240
                // Collision dominates every other preference. Scale is next,
                // then distance, then a tiny reading-order nudge for stable
                // top/left choices when candidates are otherwise identical.
                let readingOrder = ((frame.minY - safeBounds.minY) / max(1, safeBounds.height))
                    + ((frame.minX - safeBounds.minX) / max(1, safeBounds.width)) * 0.1
                let centerLanePenalty: CGFloat = repackCenteredLabel
                    && abs(frame.midX - safeBounds.midX) < safeBounds.width * 0.18
                    ? 90 : 0
                let score = normalizedOverlap * 1_000_000
                    + shrinkPenalty + distance * 6 + centerLanePenalty
                    + readingOrder * 18
                let candidate = Candidate(frame: frame, scale: actualScale,
                                          overlap: overlap, score: score)
                if best == nil || candidate.score < best!.score {
                    best = candidate
                }
            }
        }

        return best ?? Candidate(frame: requestedFitted, scale: 1,
                                 overlap: exactOverlap,
                                 score: exactOverlap)
    }

    private static func candidateOrigins(size: CGSize,
                                         requested: CGRect,
                                         safeBounds: CGRect,
                                         occupied: [CGRect]) -> [CGPoint] {
        let maxX = safeBounds.maxX - size.width
        let maxY = safeBounds.maxY - size.height
        func clamped(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: min(maxX, max(safeBounds.minX, x)),
                    y: min(maxY, max(safeBounds.minY, y)))
        }

        var result: [CGPoint] = [clamped(requested.minX, requested.minY)]
        var seen = Set<String>()
        func append(_ point: CGPoint) {
            let p = clamped(point.x, point.y)
            let key = "\(Int((p.x * 2).rounded())):\(Int((p.y * 2).rounded()))"
            if seen.insert(key).inserted { result.append(p) }
        }

        // Full-width lanes are intentional: they keep repeated center
        // requests from consuming only one vertical strip of the page.
        let xSteps = 10
        let ySteps = 14
        let coarseX = (0...xSteps).map { ix in
            safeBounds.minX
                + (maxX - safeBounds.minX) * CGFloat(ix) / CGFloat(xSteps)
        }
        let coarseY = (0...ySteps).map { iy in
            safeBounds.minY
                + (maxY - safeBounds.minY) * CGFloat(iy) / CGFloat(ySteps)
        }
        for x in coarseX {
            for y in coarseY {
                append(CGPoint(x: x, y: y))
            }
        }

        // Obstacle-edge candidates catch narrow but useful gaps that a
        // coarse grid can straddle. Cap the work so placement remains
        // deterministic even on pages containing thousands of strokes.
        let nearby = occupied.sorted {
            hypot($0.midX - requested.midX, $0.midY - requested.midY)
                < hypot($1.midX - requested.midX, $1.midY - requested.midY)
        }.prefix(32)
        for obstacle in nearby {
            // Test obstacle edges across the entire page rather than only
            // along the model's requested x/y. This catches useful corner
            // and margin gaps that the old center-biased search never saw.
            for y in coarseY {
                append(CGPoint(x: obstacle.minX - size.width - contentGap, y: y))
                append(CGPoint(x: obstacle.maxX + contentGap, y: y))
            }
            for x in coarseX {
                append(CGPoint(x: x, y: obstacle.minY - size.height - contentGap))
                append(CGPoint(x: x, y: obstacle.maxY + contentGap))
            }
        }
        return result
    }

    private static func overlapArea(of frame: CGRect, with occupied: [CGRect]) -> CGFloat {
        occupied.reduce(into: CGFloat(0)) { total, obstacle in
            let intersection = frame.intersection(obstacle)
            if !intersection.isNull {
                total += max(0, intersection.width) * max(0, intersection.height)
            }
        }
    }

    private static func fit(_ frame: CGRect, inside bounds: CGRect) -> CGRect {
        var result = frame
        result.size.width = min(max(1, result.width), bounds.width)
        result.size.height = min(max(1, result.height), bounds.height)
        result.origin.x = min(bounds.maxX - result.width,
                              max(bounds.minX, result.minX))
        result.origin.y = min(bounds.maxY - result.height,
                              max(bounds.minY, result.minY))
        return result
    }

    private static func normalized(_ rect: CGRect, inside bounds: CGRect) -> CGRect? {
        guard !rect.isNull, !rect.isInfinite,
              rect.minX.isFinite, rect.minY.isFinite,
              rect.maxX.isFinite, rect.maxY.isFinite,
              rect.width > 0, rect.height > 0 else { return nil }
        let clipped = rect.intersection(bounds)
        return clipped.isNull ? nil : clipped
    }

    private static func canvasPoint(_ x: Double, _ y: Double,
                                    in bounds: CGRect) -> CGPoint {
        CGPoint(x: bounds.minX + CGFloat(min(1, max(0, x))) * bounds.width,
                y: bounds.minY + CGFloat(min(1, max(0, y))) * bounds.height)
    }

    private static func pointsBounds(_ points: [CGPoint]) -> CGRect? {
        guard let first = points.first else { return nil }
        return points.dropFirst().reduce(CGRect(origin: first, size: .zero)) {
            $0.union(CGRect(origin: $1, size: .zero))
        }.insetBy(dx: -3, dy: -3)
    }

    private static func rawAnchor(_ value: String?,
                                  canvasBounds: CGRect) -> CGPoint? {
        guard let value, !value.hasPrefix("id:") else { return nil }
        let parts = value.split(separator: ",").compactMap {
            Double($0.trimmingCharacters(in: .whitespaces))
        }
        guard parts.count == 2 else { return nil }
        return canvasPoint(parts[0], parts[1], in: canvasBounds)
    }
}

// MARK: - Persistence

// The committed PKDrawing of AI strokes is saved as raw bytes on Page.
// PKDrawing doesn't carry text, so text labels live in JSON beside it.

struct StoredAILabel: Codable {
    var canvasX: Double
    var canvasY: Double
    var text: String
    var color: String?
    /// Optional for backward compatibility with notes saved before math
    /// labels existed. Unknown values intentionally fall back to plain text.
    var format: String? = nil
    var fontSize: Double? = nil
    /// Direct AI prose uses leading-aligned, explicitly wrapped lines.
    /// Nil retains centered rendering for legacy labels and graph/node text.
    var alignment: String? = nil
}

struct StoredCanvasRect: Codable {
    var x: Double
    var y: Double
    var width: Double
    var height: Double

    nonisolated init(_ rect: CGRect) {
        x = Double(rect.minX)
        y = Double(rect.minY)
        width = Double(rect.width)
        height = Double(rect.height)
    }

    nonisolated var cgRect: CGRect {
        CGRect(x: x, y: y, width: width, height: height)
    }
}

struct StoredAIDrawing: Codable {
    var pkDrawingBytes: Data        // PKDrawing.dataRepresentation()
    var labels: [StoredAILabel]
    /// Optional keeps existing notes decodable. These are inflated boxes for
    /// structured content whose sparse strokes do not describe its footprint.
    var reservedRects: [StoredCanvasRect]? = nil
}

// MARK: - RenderStep (intermediate, what the player consumes)

// Each DrawingActionDTO expands into a flat sequence of these.
// The player walks them linearly: each .stroke animates over ~0.2-0.6s,
// each .label fades in.
enum RenderStep {
    case stroke(points: [CGPoint], color: UIColor)
    /// Dense deterministic geometry (axes, hatching, bars) commits in one
    /// batch instead of animating every short segment for 0.18 seconds.
    case strokeGroup(paths: [[CGPoint]], color: UIColor, thickness: CGFloat)
    case label(at: CGPoint, text: String, color: UIColor)
    case proseLabel(at: CGPoint, text: String, color: UIColor, fontSize: CGFloat)
    case sizedLabel(at: CGPoint, text: String, color: UIColor, fontSize: CGFloat)
    case mathLabel(at: CGPoint, latex: String, color: UIColor, fontSize: CGFloat)
}

// MARK: - Expander (DTOs → RenderSteps in canvas coords)

final class ActionExpander {
    private let canvasBounds: CGRect
    // Bounds of the student's ink strokes — used to snap closed loops
    // ("circle the answer") onto the handwriting they aim at.
    private let inkBounds: [CGRect]
    // Registry of named anchors so subsequent edge actions can reference
    // nodes emitted earlier in the same response.
    private var nodeAnchors: [String: CGPoint] = [:]
    // Default radius used when trimming edges to node bubbles; updated per-tree.
    private var lastNodeRadius: CGFloat = 24
    // Ink regions already claimed by a snapped loop in this batch.
    private var snappedUnions: [CGRect] = []

    init(canvasBounds: CGRect,
         initialAnchors: [String: CGPoint] = [:],
         inkBounds: [CGRect] = []) {
        self.canvasBounds = canvasBounds
        self.nodeAnchors = initialAnchors
        self.inkBounds = inkBounds
    }

    /// Anchors after expansion — the player reads this back and feeds it
    /// into the next expander so cross-call references like "id:90" work.
    var finalAnchors: [String: CGPoint] { nodeAnchors }

    func expand(_ actions: [DrawingActionDTO]) -> [RenderStep] {
        expandReporting(actions).steps
    }

    /// Counts source actions that produced at least one concrete render step.
    /// This lets the live tool response distinguish schema-valid actions from
    /// actions that could not resolve an anchor or otherwise rendered nothing.
    func expandReporting(_ actions: [DrawingActionDTO])
        -> (steps: [RenderStep], renderedActionCount: Int) {
        var steps: [RenderStep] = []
        var renderedActionCount = 0
        for action in actions {
            let expanded = expandOne(action)
            if !expanded.isEmpty { renderedActionCount += 1 }
            steps.append(contentsOf: expanded)
        }
        return (steps, renderedActionCount)
    }

    // MARK: per-type expansion

    private func expandOne(_ a: DrawingActionDTO) -> [RenderStep] {
        switch a.type {
        case .path: return expandPath(a)
        case .text: return expandText(a)
        case .equation: return expandEquation(a)
        case .plot: return expandPlot(a)
        case .node: return expandNode(a)
        case .edge: return expandEdge(a)
        case .tree: return expandTree(a)
        }
    }

    private func expandPath(_ a: DrawingActionDTO) -> [RenderStep] {
        guard let pts = a.points, pts.count >= 2 else { return [] }
        let canvasPts: [CGPoint] = pts.compactMap {
            guard $0.count >= 2 else { return nil }
            return canvasPoint($0[0], $0[1])
        }
        guard canvasPts.count >= 2 else { return [] }
        // A closed loop drawn around the student's handwriting is meant to
        // circle it — snap it onto the actual ink (the model's coordinate
        // estimates are reliably a few percent off).
        if let snapped = snapClosedLoopToInk(canvasPts) {
            return [.stroke(points: snapped, color: a.uiColor)]
        }
        return [.stroke(points: canvasPts, color: a.uiColor)]
    }

    /// If `pts` form a closed-ish, modestly-sized loop and user ink lies
    /// inside it (with tolerance), return a clean ellipse hugging that ink.
    /// Returns nil when this doesn't look like "circle the answer".
    private func snapClosedLoopToInk(_ pts: [CGPoint]) -> [CGPoint]? {
        guard !inkBounds.isEmpty, pts.count >= 8,
              let first = pts.first, let last = pts.last else { return nil }
        var bbox = CGRect(origin: first, size: .zero)
        for p in pts { bbox = bbox.union(CGRect(origin: p, size: .zero)) }
        let diag = max(1, hypot(bbox.width, bbox.height))
        // Closed: endpoints near each other relative to the loop's size.
        guard hypot(last.x - first.x, last.y - first.y) < diag * 0.3 else { return nil }
        // Circling gesture, not a big diagram outline.
        guard bbox.width < canvasBounds.width * 0.5,
              bbox.height < canvasBounds.height * 0.4 else { return nil }

        let tol = 0.2 * min(bbox.width, bbox.height)
        let region = bbox.insetBy(dx: -tol, dy: -tol)
        let hits = inkBounds.filter { region.contains(CGPoint(x: $0.midX, y: $0.midY)) }
        guard !hits.isEmpty else { return nil }
        var u = hits[0]
        for r in hits.dropFirst() { u = u.union(r) }
        // The target must genuinely be where the loop was drawn (not just
        // brushing the tolerance band), and the snapped ellipse can't be
        // wildly bigger than the loop the model drew — otherwise we'd
        // hijack deliberate shapes or engulf a whole line of writing.
        guard u.intersects(bbox),
              u.width < bbox.width * 1.5 + 40,
              u.height < bbox.height * 1.5 + 40 else { return nil }
        let padded = u.insetBy(dx: -12, dy: -9)
        // Two loops in one batch snapping onto the same ink (Venn circles
        // over one cluster) would collapse into concentric ellipses — keep
        // the model's own stroke for the later ones.
        for prior in snappedUnions {
            let i = prior.intersection(padded)
            if !i.isNull {
                let ratio = (i.width * i.height)
                    / min(prior.width * prior.height, padded.width * padded.height)
                if ratio > 0.7 { return nil }
            }
        }
        snappedUnions.append(padded)
        return ellipsePoints(in: padded)
    }

    private func expandText(_ a: DrawingActionDTO) -> [RenderStep] {
        guard let nx = a.x, let ny = a.y, let text = a.text else { return [] }
        guard let metrics = TextBlockPlacer.labelMetrics(for: a,
                                                         canvasBounds: canvasBounds) else {
            return []
        }
        var p = canvasPoint(nx, ny)
        let halfW = metrics.size.width / 2
        let halfH = metrics.size.height / 2
        p.x = min(canvasBounds.maxX - halfW, max(canvasBounds.minX + halfW, p.x))
        p.y = min(canvasBounds.maxY - halfH, max(canvasBounds.minY + halfH, p.y))
        return [.proseLabel(at: p, text: text, color: a.uiColor,
                            fontSize: metrics.fontSize)]
    }

    private func expandEquation(_ a: DrawingActionDTO) -> [RenderStep] {
        guard let nx = a.x, let ny = a.y,
              let latex = a.latex ?? a.text, !latex.isEmpty else { return [] }
        guard let metrics = TextBlockPlacer.labelMetrics(for: a,
                                                         canvasBounds: canvasBounds) else {
            return []
        }
        var p = canvasPoint(nx, ny)
        let halfW = metrics.size.width / 2
        let halfH = metrics.size.height / 2
        p.x = min(canvasBounds.maxX - halfW, max(canvasBounds.minX + halfW, p.x))
        p.y = min(canvasBounds.maxY - halfH, max(canvasBounds.minY + halfH, p.y))
        return [.mathLabel(at: p, latex: latex, color: a.uiColor,
                           fontSize: metrics.fontSize)]
    }

    private func expandPlot(_ a: DrawingActionDTO) -> [RenderStep] {
        guard let spec = a.plot else { return [] }

        let margin: CGFloat = 10
        var box = CGRect(
            x: canvasBounds.minX + CGFloat(a.x ?? 0.08) * canvasBounds.width,
            y: canvasBounds.minY + CGFloat(a.y ?? 0.18) * canvasBounds.height,
            width: CGFloat(a.width ?? 0.72) * canvasBounds.width,
            height: CGFloat(a.height ?? 0.60) * canvasBounds.height
        )
        box.size.width = min(max(box.width, 120), canvasBounds.width - margin * 2)
        box.size.height = min(max(box.height, 100), canvasBounds.height - margin * 2)
        box.origin.x = min(canvasBounds.maxX - margin - box.width,
                           max(canvasBounds.minX + margin, box.origin.x))
        box.origin.y = min(canvasBounds.maxY - margin - box.height,
                           max(canvasBounds.minY + margin, box.origin.y))

        guard let output = try? MathPlotRenderer.render(spec: spec, in: box),
              !output.isEmpty else { return [] }

        let color = a.uiColor
        var steps: [RenderStep] = []
        if !output.hatchPaths.isEmpty {
            steps.append(.strokeGroup(
                paths: output.hatchPaths,
                // PencilKit normalizes translucent PKInk colors during
                // archival on some OS versions, which made inequality fill
                // disappear entirely. Thin opaque hatching stays visible
                // while leaving the underlying page readable.
                color: color,
                thickness: 2.0
            ))
        }
        let straightSegments = output.straightPathGroups.flatMap { path in
            zip(path, path.dropFirst()).map { [$0.0, $0.1] }
        }
        if !straightSegments.isEmpty {
            steps.append(.strokeGroup(paths: straightSegments,
                                      color: color, thickness: 2.2))
        }
        if !output.smoothPathGroups.isEmpty {
            steps.append(.strokeGroup(paths: output.smoothPathGroups,
                                      color: color, thickness: 3.0))
        }
        steps += output.labels.map { label in
            if case .title = label.role,
               label.text.contains(where: { "^_=\\<>".contains($0) }) {
                return .mathLabel(at: label.position, latex: label.text,
                                  color: color, fontSize: label.fontSize)
            }
            return .sizedLabel(at: label.position, text: label.text,
                               color: color, fontSize: label.fontSize)
        }
        return steps
    }

    private func expandNode(_ a: DrawingActionDTO) -> [RenderStep] {
        guard let nx = a.x, let ny = a.y else { return [] }
        var center = canvasPoint(nx, ny)
        let diameter = (a.width ?? 0.08) * canvasBounds.width
        let radius = max(20, diameter / 2)
        lastNodeRadius = radius
        // Keep the whole circle on-canvas (center clamping alone leaves
        // half the bubble hanging off the edge).
        center.x = min(canvasBounds.maxX - radius - 2,
                       max(canvasBounds.minX + radius + 2, center.x))
        center.y = min(canvasBounds.maxY - radius - 2,
                       max(canvasBounds.minY + radius + 2, center.y))

        var steps: [RenderStep] = [
            .stroke(points: circlePoints(center: center, radius: radius),
                    color: a.uiColor)
        ]
        if let label = a.text {
            steps.append(.label(at: center, text: label, color: a.uiColor))
            nodeAnchors[label] = center
        }
        return steps
    }

    private func expandEdge(_ a: DrawingActionDTO) -> [RenderStep] {
        guard let p1 = parseAnchor(a.from), let p2 = parseAnchor(a.to) else { return [] }
        // If either endpoint is anchored to a node, back off so the line
        // doesn't overlap the bubble — but only when the edge is long
        // enough. Backing off both ends of an edge shorter than 2*pad
        // makes start and end pass each other and the arrow points the
        // wrong way.
        var pad = lastNodeRadius + 4
        var start = p1, end = p2
        let (dx, dy) = (end.x - start.x, end.y - start.y)
        let len = max(1, hypot(dx, dy))
        pad = min(pad, len / 2 - 2)
        let (ux, uy) = (dx / len, dy / len)
        if pad > 0, a.from?.hasPrefix("id:") == true {
            start = CGPoint(x: start.x + ux * pad, y: start.y + uy * pad)
        }
        if pad > 0, a.to?.hasPrefix("id:") == true {
            end = CGPoint(x: end.x - ux * pad, y: end.y - uy * pad)
        }

        var steps: [RenderStep] = [.stroke(points: [start, end], color: a.uiColor)]
        if a.arrowhead == true {
            steps.append(contentsOf: arrowheadSteps(tipAt: end, comingFrom: start,
                                                    color: a.uiColor))
        }
        return steps
    }

    private func expandTree(_ a: DrawingActionDTO) -> [RenderStep] {
        guard let specs = a.nodes, !specs.isEmpty else { return [] }
        var box = CGRect(
            x: canvasBounds.minX + CGFloat(a.x ?? 0.1) * canvasBounds.width,
            y: canvasBounds.minY + CGFloat(a.y ?? 0.1) * canvasBounds.height,
            width: CGFloat(a.width  ?? 0.8) * canvasBounds.width,
            height: CGFloat(a.height ?? 0.6) * canvasBounds.height
        )
        // Contain the box: the raw-coordinate clamp elsewhere never saw
        // tree boxes, so a tree anchored at x=0.8 with width 0.4 rendered
        // a third of its nodes past the right edge — invisible ink the
        // tool response still called "ok".
        let margin: CGFloat = 8
        // max() first: a zero/negative width or height from the model
        // would otherwise survive the min() and mirror the layout.
        box.size.width = min(max(box.width, 80), canvasBounds.width - 2 * margin)
        box.size.height = min(max(box.height, 80), canvasBounds.height - 2 * margin)
        box.origin.x = min(canvasBounds.maxX - margin - box.width,
                           max(canvasBounds.minX + margin, box.origin.x))
        box.origin.y = min(canvasBounds.maxY - margin - box.height,
                           max(canvasBounds.minY + margin, box.origin.y))

        let radius = treeNodeRadius(for: specs, in: box)
        lastNodeRadius = radius
        // Node CENTERS are laid out in this box; inset it so the bubbles
        // of edge nodes (center ± radius) stay inside the outer box too.
        var layoutBox = box.insetBy(dx: radius + 2, dy: radius + 2)
        if layoutBox.width < 1 || layoutBox.height < 1 { layoutBox = box }
        let positions = TreeLayout.layout(specs, in: layoutBox)
        let color = a.uiColor

        // Draw in BFS order so the tree "grows" downward from the root.
        let depths = computeDepths(specs)
        let ordered = specs.sorted { (depths[$0.id] ?? 0) < (depths[$1.id] ?? 0) }

        var steps: [RenderStep] = []
        for spec in ordered {
            guard let center = positions[spec.id] else { continue }
            // Edge from parent first, so the line reaches DOWN toward
            // where the new node will appear.
            if let parentId = spec.parent, let parentPos = positions[parentId] {
                let (s, e) = trimLine(from: parentPos, to: center, by: radius + 4)
                steps.append(.stroke(points: [s, e], color: color))
            }
            steps.append(.stroke(points: circlePoints(center: center, radius: radius),
                                 color: color))
            steps.append(.label(at: center, text: spec.label, color: color))
            // Register under BOTH keys: the system prompt tells the model
            // to reference nodes as "id:LABEL", and for BSTs the label is
            // the value ("90") while the id may be arbitrary ("n3"). The
            // old code registered trees only by id, so label references
            // silently resolved to nothing and the edge never appeared.
            nodeAnchors[spec.id] = center
            nodeAnchors[spec.label] = center
        }
        return steps
    }

    // MARK: helpers

    private func canvasPoint(_ nx: Double, _ ny: Double) -> CGPoint {
        // Clamp into the visible canvas. The model occasionally emits
        // coordinates just outside 0...1; off-canvas ink renders fine but
        // is invisible to the student, and the tool response would still
        // have claimed success.
        let cx = min(1, max(0, nx))
        let cy = min(1, max(0, ny))
        return CGPoint(
            x: canvasBounds.minX + CGFloat(cx) * canvasBounds.width,
            y: canvasBounds.minY + CGFloat(cy) * canvasBounds.height
        )
    }

    private func parseAnchor(_ s: String?) -> CGPoint? {
        guard let s else { return nil }
        if s.hasPrefix("id:") {
            return nodeAnchors[String(s.dropFirst(3))]
        }
        let parts = s.split(separator: ",")
            .compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
        guard parts.count == 2 else { return nil }
        return canvasPoint(parts[0], parts[1])
    }

    private func arrowheadSteps(tipAt tip: CGPoint, comingFrom origin: CGPoint,
                                color: UIColor) -> [RenderStep] {
        let angle = atan2(tip.y - origin.y, tip.x - origin.x)
        let len: CGFloat = 12
        let spread: CGFloat = .pi / 7
        let left = CGPoint(x: tip.x - len * cos(angle - spread),
                           y: tip.y - len * sin(angle - spread))
        let right = CGPoint(x: tip.x - len * cos(angle + spread),
                            y: tip.y - len * sin(angle + spread))
        return [
            .stroke(points: [tip, left], color: color),
            .stroke(points: [tip, right], color: color)
        ]
    }

    private func trimLine(from a: CGPoint, to b: CGPoint, by pad: CGFloat) -> (CGPoint, CGPoint) {
        let dx = b.x - a.x, dy = b.y - a.y
        let len = max(1, hypot(dx, dy))
        // Never trim past the midpoint from each side, or the endpoints
        // cross and the "line" runs backwards.
        let p = min(pad, len / 2 - 1)
        guard p > 0 else { return (a, b) }
        let ux = dx / len, uy = dy / len
        return (
            CGPoint(x: a.x + ux * p, y: a.y + uy * p),
            CGPoint(x: b.x - ux * p, y: b.y - uy * p)
        )
    }

    private func treeNodeRadius(for specs: [TreeNodeSpec], in box: CGRect) -> CGFloat {
        let depth = max(1, computeDepths(specs).values.max() ?? 1)
        let leaves = max(1, specs.filter { spec in
            !specs.contains(where: { $0.parent == spec.id })
        }.count)
        let rByWidth  = box.width / CGFloat(leaves) * 0.35
        let rByHeight = box.height / CGFloat(depth + 1) * 0.30
        return max(18, min(rByWidth, rByHeight, 40))
    }

    private func computeDepths(_ specs: [TreeNodeSpec]) -> [String: Int] {
        // uniquingKeysWith + the hop cap below keep this total even for
        // malformed model output (duplicate ids, parent cycles) —
        // Dictionary(uniqueKeysWithValues:) would trap and the old
        // recursion never terminated on a cycle. LiveSession validates and
        // reports these upstream, but layout must never be crashable.
        let parentMap: [String: String] = Dictionary(
            specs.compactMap { spec in spec.parent.map { (spec.id, $0) } },
            uniquingKeysWith: { first, _ in first }
        )
        var depths: [String: Int] = [:]
        for s in specs {
            var chain: [String] = []
            var cursor: String? = s.id
            // Walk up until a known depth, a root, or an (impossible in a
            // valid tree) hop count that indicates a cycle.
            while let id = cursor, depths[id] == nil, chain.count <= specs.count {
                chain.append(id)
                cursor = parentMap[id]
            }
            var base = cursor.flatMap { depths[$0] } ?? -1
            if chain.count > specs.count { base = -1 }   // cycle: treat top as root
            for id in chain.reversed() {
                base += 1
                depths[id] = base
            }
        }
        return depths
    }
}

// MARK: - Geometry helpers

/// Generates a closed list of points around a circle. PencilKit's
/// Catmull-Rom smoothing makes ~20 control points look like a real circle.
func circlePoints(center: CGPoint, radius: CGFloat, count: Int = 20) -> [CGPoint] {
    var pts: [CGPoint] = []
    pts.reserveCapacity(count + 1)
    for i in 0...count {
        let theta = 2 * .pi * CGFloat(i) / CGFloat(count)
        pts.append(CGPoint(x: center.x + radius * cos(theta),
                           y: center.y + radius * sin(theta)))
    }
    return pts
}

/// Closed ellipse polyline inscribed in `rect` — used when snapping a
/// "circle the answer" loop onto the handwriting it targets.
func ellipsePoints(in rect: CGRect, count: Int = 24) -> [CGPoint] {
    let c = CGPoint(x: rect.midX, y: rect.midY)
    let rx = max(12, rect.width / 2), ry = max(10, rect.height / 2)
    var pts: [CGPoint] = []
    pts.reserveCapacity(count + 1)
    for i in 0...count {
        let t = 2 * .pi * CGFloat(i) / CGFloat(count)
        pts.append(CGPoint(x: c.x + rx * cos(t), y: c.y + ry * sin(t)))
    }
    return pts
}

// MARK: - Tree layout (recursive, width-balanced)

enum TreeLayout {
    /// Returns canvas-coord positions for each node within `box`.
    /// Honors the `side` field on TreeNodeSpec so single-child chains
    /// branch left or right instead of collapsing into a vertical line.
    static func layout(_ specs: [TreeNodeSpec], in box: CGRect) -> [String: CGPoint] {
        guard !specs.isEmpty,
              let root = specs.first(where: { $0.parent == nil }) else { return [:] }

        // Group children of each parent into explicit left/right slots.
        // If a child specifies side="left"/"right", honor it. Otherwise,
        // fall back to insertion order: first unsided child = left, second = right.
        var leftChild: [String: String] = [:]
        var rightChild: [String: String] = [:]
        var extras: [String: [String]] = [:]   // 3rd+ child or conflicts

        for spec in specs {
            guard let parent = spec.parent else { continue }
            let preferred = spec.side?.lowercased()
            switch preferred {
            case "left":
                if leftChild[parent] == nil { leftChild[parent] = spec.id }
                else if rightChild[parent] == nil { rightChild[parent] = spec.id }
                else { extras[parent, default: []].append(spec.id) }
            case "right":
                if rightChild[parent] == nil { rightChild[parent] = spec.id }
                else if leftChild[parent] == nil { leftChild[parent] = spec.id }
                else { extras[parent, default: []].append(spec.id) }
            default:
                if leftChild[parent] == nil { leftChild[parent] = spec.id }
                else if rightChild[parent] == nil { rightChild[parent] = spec.id }
                else { extras[parent, default: []].append(spec.id) }
            }
        }

        var raw: [String: (x: Double, depth: Int)] = [:]
        var nextLeaf: Double = 0
        // Cycle/duplicate guard: malformed specs (duplicate ids whose
        // parent links loop) would recurse forever. Validation upstream
        // rejects them, but layout itself must never be crashable.
        var visiting = Set<String>()

        // Recursive placement. For each parent: place its left subtree (or
        // reserve a phantom leaf slot to push the parent rightward), then
        // its right subtree (or reserve a phantom slot to push the parent
        // leftward), then any extras, then position the parent at the
        // midpoint of all its children's x positions. The phantom slots
        // are what make a single-child node branch left or right visually.
        func place(_ id: String, depth: Int) {
            guard visiting.insert(id).inserted else { return }
            let L = leftChild[id]
            let R = rightChild[id]
            let extraIds = extras[id] ?? []
            let hasAny = L != nil || R != nil || !extraIds.isEmpty

            if !hasAny {
                raw[id] = (nextLeaf, depth)
                nextLeaf += 1
                return
            }

            let leftX: Double
            if let L {
                place(L, depth: depth + 1)
                // nil only if a cycle guard cut the recursion short.
                if let x = raw[L]?.x { leftX = x }
                else { leftX = nextLeaf; nextLeaf += 1 }
            } else {
                leftX = nextLeaf; nextLeaf += 1
            }

            let rightX: Double
            if let R {
                place(R, depth: depth + 1)
                if let x = raw[R]?.x { rightX = x }
                else { rightX = nextLeaf; nextLeaf += 1 }
            } else if L != nil {
                rightX = nextLeaf; nextLeaf += 1
            } else {
                rightX = leftX
            }

            for extraId in extraIds { place(extraId, depth: depth + 1) }

            var childXs = [leftX, rightX]
            for extraId in extraIds {
                if let x = raw[extraId]?.x { childXs.append(x) }
            }
            let avg = (childXs.min()! + childXs.max()!) / 2
            raw[id] = (avg, depth)
        }
        place(root.id, depth: 0)

        let xs = raw.values.map(\.x)
        let minX = xs.min() ?? 0, maxX = xs.max() ?? 0
        let xSpan = max(0.0001, maxX - minX)
        let maxDepth = raw.values.map(\.depth).max() ?? 0

        var result: [String: CGPoint] = [:]
        for (id, pos) in raw {
            let nx = xSpan > 0.0001 ? (pos.x - minX) / xSpan : 0.5
            let ny: Double = maxDepth == 0 ? 0.5 : Double(pos.depth) / Double(maxDepth)
            result[id] = CGPoint(
                x: box.minX + CGFloat(nx) * box.width,
                y: box.minY + CGFloat(ny) * box.height
            )
        }
        return result
    }
}

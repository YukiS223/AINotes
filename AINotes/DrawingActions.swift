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
                         color: color, text: text, points: points,
                         from: from, to: to, arrowhead: arrowhead,
                         nodes: nodes)
    }
}

// MARK: - Text block placement (avoid ink / controls / prior AI content)

/// Moves the TEXT actions of a batch — as one rigid block, preserving
/// their relative layout — away from occupied regions when they'd land on
/// top of the student's handwriting, earlier AI ink, or the app's corner
/// buttons. Only text moves: paths/edges/trees may be deliberately aimed
/// at the student's work (circling an answer must NOT be relocated).
enum TextBlockPlacer {
    static func adjust(_ actions: [DrawingActionDTO],
                       canvasBounds: CGRect,
                       avoid: [CGRect]) -> [DrawingActionDTO] {
        guard !avoid.isEmpty else { return actions }
        let textIdx = actions.indices.filter {
            actions[$0].type == .text && actions[$0].x != nil
                && actions[$0].y != nil && actions[$0].text != nil
        }
        guard !textIdx.isEmpty else { return actions }

        func rect(for a: DrawingActionDTO) -> CGRect {
            let cx = canvasBounds.minX + CGFloat(a.x!) * canvasBounds.width
            let cy = canvasBounds.minY + CGFloat(a.y!) * canvasBounds.height
            // ~16pt semibold: ≈9.5pt per character, 22pt line height.
            let w = CGFloat(a.text!.count) * 9.5 + 8
            return CGRect(x: cx - w / 2, y: cy - 11, width: w, height: 22)
        }
        let rects = textIdx.map { rect(for: actions[$0]) }
        var union = rects[0]
        for r in rects.dropFirst() { union = union.union(r) }

        // Overlap (pt²) with occupied regions + heavy penalty for leaving
        // the canvas, at a given block translation.
        func score(_ dx: CGFloat, _ dy: CGFloat) -> CGFloat {
            var s: CGFloat = 0
            for r in rects {
                let rr = r.offsetBy(dx: dx, dy: dy)
                let clipped = rr.intersection(canvasBounds)
                let clippedArea = clipped.isNull ? 0 : clipped.width * clipped.height
                s += (rr.width * rr.height - clippedArea) * 3
                for a in avoid {
                    let i = rr.intersection(a)
                    if !i.isNull { s += i.width * i.height }
                }
            }
            return s
        }

        let base = score(0, 0)
        let blockArea = rects.reduce(CGFloat(0)) { $0 + $1.width * $1.height }
        // Under ~12% covered: the model's placement is fine, don't move.
        guard base > blockArea * 0.12 else { return actions }

        // Grid search over whole-block translations. Distance from the
        // model's requested spot is only a TIE-BREAKER (tiny weight): a
        // strong distance penalty made any move cost more than the total
        // overlap of a short label, so exactly the "one short answer
        // label buried in handwriting" case could never relocate.
        var best: (dx: CGFloat, dy: CGFloat, overlap: CGFloat, scored: CGFloat) =
            (0, 0, base, base)
        let steps = 10
        for ix in 0...steps {
            for iy in 0...steps {
                let dx = (CGFloat(ix) / CGFloat(steps) - 0.5) * canvasBounds.width
                let dy = (CGFloat(iy) / CGFloat(steps) - 0.5) * canvasBounds.height
                let o = score(dx, dy)
                let s = o + hypot(dx, dy) * 0.05
                if s < best.scored { best = (dx, dy, o, s) }
            }
        }
        // Move only for a real overlap improvement, judged on overlap alone.
        guard best.overlap < base * 0.4, base - best.overlap > 80,
              best.dx != 0 || best.dy != 0 else { return actions }

        let fdx = Double(best.dx / canvasBounds.width)
        let fdy = Double(best.dy / canvasBounds.height)
        var out = actions
        for i in textIdx { out[i] = out[i].offsetBy(dx: fdx, dy: fdy) }
        return out
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
}

struct StoredAIDrawing: Codable {
    var pkDrawingBytes: Data        // PKDrawing.dataRepresentation()
    var labels: [StoredAILabel]
}

// MARK: - RenderStep (intermediate, what the player consumes)

// Each DrawingActionDTO expands into a flat sequence of these.
// The player walks them linearly: each .stroke animates over ~0.2-0.6s,
// each .label fades in.
enum RenderStep {
    case stroke(points: [CGPoint], color: UIColor)
    case label(at: CGPoint, text: String, color: UIColor)
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
        var steps: [RenderStep] = []
        for action in actions {
            steps.append(contentsOf: expandOne(action))
        }
        return steps
    }

    // MARK: per-type expansion

    private func expandOne(_ a: DrawingActionDTO) -> [RenderStep] {
        switch a.type {
        case .path: return expandPath(a)
        case .text: return expandText(a)
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
        var p = canvasPoint(nx, ny)
        // Keep the whole (center-anchored) label on-canvas, not just its
        // center — long labels near an edge used to run off-screen.
        let halfW = min(canvasBounds.width / 2, CGFloat(text.count) * 9.5 / 2 + 4)
        let halfH: CGFloat = 11
        p.x = min(canvasBounds.maxX - halfW, max(canvasBounds.minX + halfW, p.x))
        p.y = min(canvasBounds.maxY - halfH, max(canvasBounds.minY + halfH, p.y))
        return [.label(at: p, text: text, color: a.uiColor)]
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

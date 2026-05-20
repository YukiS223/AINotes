import SwiftUI
import CoreGraphics

// One drawing action returned by Claude.
// All coordinates are fractions (0...1) of the snapshot image.
struct AnnotationDTO: Codable {
    enum Kind: String, Codable {
        case circle, arrow, highlight, write
    }
    let type: Kind
    let x: Double?
    let y: Double?
    let width: Double?
    let height: Double?
    let x1: Double?
    let y1: Double?
    let x2: Double?
    let y2: Double?
    let text: String?
    let color: String?
}

extension AnnotationDTO {
    var swiftUIColor: Color {
        switch (color ?? "red").lowercased() {
        case "blue":   return .blue
        case "green":  return .green
        case "orange": return .orange
        case "yellow": return .yellow
        case "purple": return .purple
        case "black":  return .black
        default:       return .red
        }
    }
}

struct CanvasSnapshot {
    let image: UIImage
    let bounds: CGRect
}

// What we persist for the AI mark layer: the actions plus the canvas
// region they map into. CGRect is Codable via CoreGraphics.
struct StoredAnnotations: Codable {
    var annotations: [AnnotationDTO]
    var bounds: CGRect
}

struct AnnotationOverlay: View {
    let annotations: [AnnotationDTO]
    let snapshotBounds: CGRect
    // renderBounds of every user stroke, in canvas coordinates.
    // This is the exact ink geometry we snap circles/highlights to.
    let inkBounds: [CGRect]

    var body: some View {
        Canvas { ctx, _ in
            guard snapshotBounds.width > 0, snapshotBounds.height > 0 else { return }

            for a in annotations {
                let color = a.swiftUIColor
                switch a.type {
                case .circle:
                    guard let rough = rect(a) else { continue }
                    let r = snapped(to: rough)
                    ctx.stroke(Path(ellipseIn: r), with: .color(color), lineWidth: 3)

                case .highlight:
                    guard let rough = rect(a) else { continue }
                    let r = snapped(to: rough)
                    ctx.fill(Path(roundedRect: r, cornerRadius: 4),
                             with: .color(color.opacity(0.30)))

                case .arrow:
                    guard let x1 = a.x1, let y1 = a.y1,
                          let x2 = a.x2, let y2 = a.y2 else { continue }
                                    // The model's tip estimate; we keep its DIRECTION but
                                    // re-anchor the arrow to the real ink it's aiming at so
                                    // the body never lands on top of the writing.
                    let (p1, p2) = snappedArrow(tail: point(x1, y1),
                                                                tip: point(x2, y2))
                    var line = Path()
                    line.move(to: p1)
                    line.addLine(to: p2)
                    ctx.stroke(line, with: .color(color), lineWidth: 3)
                    drawArrowhead(ctx: ctx, from: p1, to: p2, color: color)

                case .write:
                    guard let nx = a.x, let ny = a.y,
                          let text = a.text else { continue }
                    ctx.draw(
                        Text(text)
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundColor(color),
                        at: point(nx, ny),
                        anchor: .topLeading
                    )
                }
            }
        }
        .allowsHitTesting(false)
    }

    // MARK: - Coordinate mapping (fraction -> canvas point)

    private func point(_ nx: Double, _ ny: Double) -> CGPoint {
        CGPoint(
            x: snapshotBounds.minX + CGFloat(nx) * snapshotBounds.width,
            y: snapshotBounds.minY + CGFloat(ny) * snapshotBounds.height
        )
    }

    private func rect(_ a: AnnotationDTO) -> CGRect? {
        guard let nx = a.x, let ny = a.y,
              let nw = a.width, let nh = a.height else { return nil }
        let origin = point(nx, ny)
        return CGRect(x: origin.x, y: origin.y,
                      width: CGFloat(nw) * snapshotBounds.width,
                      height: CGFloat(nh) * snapshotBounds.height)
    }

    // MARK: - Snap to real ink

    // Given Claude's rough box, return a tight box around the actual
    // strokes whose centers fall inside it (with a little tolerance).
    // If the rough box happens to miss all ink, fall back to it unchanged.
    private func snapped(to rough: CGRect) -> CGRect {
        guard !inkBounds.isEmpty else { return rough }

        let tol = 0.30 * min(rough.width, rough.height)
        let region = rough.insetBy(dx: -tol, dy: -tol)

        let hits = inkBounds.filter {
            region.contains(CGPoint(x: $0.midX, y: $0.midY))
        }
        guard let first = hits.first else { return rough }

        var u = first
        for r in hits.dropFirst() { u = u.union(r) }
        return u.insetBy(dx: -12, dy: -12)
    }
    
    // Rebuild the arrow as a short stub that sits just OUTSIDE the ink
        // it points at: tip ~6pt off the glyph, body a fixed short length in
        // empty space, keeping the model's intended approach direction.
    private func snappedArrow(tail: CGPoint, tip: CGPoint) -> (CGPoint, CGPoint) {
            // Find the stroke whose bounds are nearest the model's tip.
        guard let target = inkBounds.min(by: {
                distance($0, to: tip) < distance($1, to: tip)
        }) else {
            return (tail, tip)   // no ink: trust the model
        }

            // Direction the model wanted the arrow to travel (tail -> tip).
            var dx = tip.x - tail.x
            var dy = tip.y - tail.y
            let len = max(1, hypot(dx, dy))
            dx /= len; dy /= len   // unit vector

            // New tip: just outside the target glyph, offset along -direction
            // from the glyph's center so the head stops next to the ink.
            let center = CGPoint(x: target.midX, y: target.midY)
            let reach = max(target.width, target.height) / 2 + 6   // 6pt gap
            let newTip = CGPoint(x: center.x - dx * reach,
                                 y: center.y - dy * reach)

            // Short fixed body so it stays in empty space, not over the ink.
            let bodyLen: CGFloat = 34
            let newTail = CGPoint(x: newTip.x - dx * bodyLen,
                                  y: newTip.y - dy * bodyLen)
            return (newTail, newTip)
        }

        private func distance(_ r: CGRect, to p: CGPoint) -> CGFloat {
            hypot(r.midX - p.x, r.midY - p.y)
        }

    private func drawArrowhead(ctx: GraphicsContext,
                               from p1: CGPoint, to p2: CGPoint,
                               color: Color) {
        let angle = atan2(p2.y - p1.y, p2.x - p1.x)
        let len: CGFloat = 14
        let spread: CGFloat = .pi / 7
        var head = Path()
        head.move(to: p2)
        head.addLine(to: CGPoint(x: p2.x - len * cos(angle - spread),
                                 y: p2.y - len * sin(angle - spread)))
        head.move(to: p2)
        head.addLine(to: CGPoint(x: p2.x - len * cos(angle + spread),
                                 y: p2.y - len * sin(angle + spread)))
        ctx.stroke(head, with: .color(color), lineWidth: 3)
    }
}

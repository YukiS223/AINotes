import SwiftUI
import CoreGraphics

// One drawing action returned by Claude.
// All coordinates are fractions (0...1) of the snapshot image.
struct AnnotationDTO: Decodable {
    enum Kind: String, Decodable {
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
                    let p1 = point(x1, y1)
                    let p2 = point(x2, y2)
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

import CoreGraphics
import UIKit

/// Produces a bounded, coarse set of keep-out rectangles for visible content
/// in an imported page image. Pure-white paper remains available; document
/// text, diagrams, and photographs are protected from automatic AI layout.
@MainActor
enum BackgroundOccupancy {
    static func rects(for image: UIImage, canvasBounds: CGRect) -> [CGRect] {
        guard canvasBounds.width > 0, canvasBounds.height > 0,
              image.size.width > 0, image.size.height > 0 else { return [] }

        let sampleWidth = 128
        let aspect = image.size.height / image.size.width
        let sampleHeight = min(176, max(32, Int((CGFloat(sampleWidth) * aspect).rounded())))
        guard let pixels = rgbaPixels(for: image,
                                      width: sampleWidth,
                                      height: sampleHeight) else { return [] }

        let columns = 20
        let rows = min(28, max(8, Int((CGFloat(columns) * aspect).rounded())))
        var occupied = Array(repeating: false, count: columns * rows)

        for row in 0..<rows {
            let y0 = row * sampleHeight / rows
            let y1 = max(y0 + 1, (row + 1) * sampleHeight / rows)
            for column in 0..<columns {
                let x0 = column * sampleWidth / columns
                let x1 = max(x0 + 1, (column + 1) * sampleWidth / columns)
                var nonWhite = 0
                var samples = 0
                for y in y0..<min(y1, sampleHeight) {
                    for x in x0..<min(x1, sampleWidth) {
                        let offset = (y * sampleWidth + x) * 4
                        let alpha = Int(pixels[offset + 3])
                        guard alpha > 16 else { continue }
                        samples += 1
                        let red = Int(pixels[offset])
                        let green = Int(pixels[offset + 1])
                        let blue = Int(pixels[offset + 2])
                        // A small antialiased glyph should claim its tile,
                        // while JPEG noise on white paper should not.
                        if min(red, green, blue) < 238
                            || max(red, green, blue) - min(red, green, blue) > 18 {
                            nonWhite += 1
                        }
                    }
                }
                let threshold = max(2, samples / 45)
                occupied[row * columns + column] = nonWhite >= threshold
            }
        }

        let imageRect = aspectFitRect(contentSize: image.size,
                                      container: canvasBounds)
        let tileWidth = imageRect.width / CGFloat(columns)
        let tileHeight = imageRect.height / CGFloat(rows)
        var result: [CGRect] = []

        // Horizontal run merging limits output to at most rows*ceil(cols/2)
        // rectangles and gives the placer useful blank lanes between lines.
        for row in 0..<rows {
            var column = 0
            while column < columns {
                guard occupied[row * columns + column] else {
                    column += 1
                    continue
                }
                let start = column
                while column < columns, occupied[row * columns + column] {
                    column += 1
                }
                result.append(CGRect(
                    x: imageRect.minX + CGFloat(start) * tileWidth,
                    // CGBitmapContext stores row zero at the lower edge for
                    // this pixel format, while UIKit/page coordinates start
                    // at the upper edge. Mirror the sampled row when mapping
                    // it back to canvas space so printed content is protected
                    // at its actual vertical position.
                    y: imageRect.minY + CGFloat(rows - row - 1) * tileHeight,
                    width: CGFloat(column - start) * tileWidth,
                    height: tileHeight
                ).insetBy(dx: -2, dy: -2).intersection(canvasBounds))
            }
        }
        return result.filter { !$0.isNull && $0.width > 0 && $0.height > 0 }
    }

    private static func rgbaPixels(for image: UIImage,
                                   width: Int,
                                   height: Int) -> [UInt8]? {
        var bytes = Array(repeating: UInt8(255), count: width * height * 4)
        let created = bytes.withUnsafeMutableBytes { storage -> Bool in
            guard let base = storage.baseAddress,
                  let context = CGContext(
                    data: base,
                    width: width,
                    height: height,
                    bitsPerComponent: 8,
                    bytesPerRow: width * 4,
                    space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                  ) else { return false }
            context.setFillColor(UIColor.white.cgColor)
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            context.interpolationQuality = .medium
            // Imported backgrounds are normalized at ingestion, but UIImage
            // drawing also keeps this correct for legacy oriented images.
            UIGraphicsPushContext(context)
            image.draw(in: CGRect(x: 0, y: 0, width: width, height: height))
            UIGraphicsPopContext()
            return true
        }
        return created ? bytes : nil
    }

    private static func aspectFitRect(contentSize: CGSize,
                                      container: CGRect) -> CGRect {
        let scale = min(container.width / contentSize.width,
                        container.height / contentSize.height)
        let size = CGSize(width: contentSize.width * scale,
                          height: contentSize.height * scale)
        return CGRect(x: container.midX - size.width / 2,
                      y: container.midY - size.height / 2,
                      width: size.width, height: size.height)
    }
}

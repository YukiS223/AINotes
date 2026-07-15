import Foundation
import PDFKit
import UIKit
import UniformTypeIdentifiers

struct ImportedPageBackground: Sendable {
    let data: Data
    let sourceName: String
    let contentType: String
    let pageNumber: Int?
}

enum PageBackgroundImportError: LocalizedError {
    case unsupportedFile(String)
    case unreadableFile(String)
    case emptyPDF(String)
    case renderingFailed(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedFile(let name):
            return "\(name) is not a supported PDF or image."
        case .unreadableFile(let name):
            return "\(name) could not be opened."
        case .emptyPDF(let name):
            return "\(name) does not contain any pages."
        case .renderingFailed(let name):
            return "\(name) could not be converted into a note page."
        }
    }
}

/// Converts user-selected PDFs and images into self-contained page
/// backgrounds. PDF pages are rendered once at import time, so notes remain
/// available even if the source file is later moved or its security scope
/// expires.
enum PageBackgroundImporter {
    nonisolated private static let maxPixelDimension: CGFloat = 2_400

    /// Renders one page at a time away from the main actor, then hands that
    /// page back for immediate persistence. This keeps the progress UI live
    /// and avoids retaining every high-resolution PDF page in memory.
    static func importFile(
        at url: URL,
        onPage: @MainActor (ImportedPageBackground) throws -> Void
    ) async throws {
        let hasSecurityScope = url.startAccessingSecurityScopedResource()
        defer {
            if hasSecurityScope { url.stopAccessingSecurityScopedResource() }
        }

        let values = try? url.resourceValues(forKeys: [.contentTypeKey, .nameKey])
        let name = values?.name ?? url.lastPathComponent
        let contentType: UTType?
        if let knownType = values?.contentType {
            contentType = knownType
        } else if !url.pathExtension.isEmpty {
            contentType = UTType(filenameExtension: url.pathExtension)
        } else {
            contentType = nil
        }

        if contentType?.conforms(to: .pdf) == true
            || url.pathExtension.lowercased() == "pdf" {
            let pageCount = try await Task.detached(priority: .userInitiated) {
                try pdfPageCount(at: url, sourceName: name)
            }.value

            for pageIndex in 0..<pageCount {
                try Task.checkCancellation()
                let background = try await Task.detached(priority: .userInitiated) {
                    try renderPDFPage(
                        at: url,
                        sourceName: name,
                        pageIndex: pageIndex
                    )
                }.value
                try onPage(background)
                await Task.yield()
            }
            return
        }

        if contentType?.conforms(to: .image) == true {
            do {
                let typeIdentifier = contentType?.identifier ?? UTType.image.identifier
                let background = try await Task.detached(priority: .userInitiated) {
                    try loadImage(
                        data: Data(contentsOf: url),
                        sourceName: name,
                        sourceContentType: typeIdentifier
                    )
                }.value
                try onPage(background)
                return
            } catch let error as PageBackgroundImportError {
                throw error
            } catch {
                throw PageBackgroundImportError.unreadableFile(name)
            }
        }

        throw PageBackgroundImportError.unsupportedFile(name)
    }

    nonisolated static func loadImage(data: Data,
                                     sourceName: String,
                                     sourceContentType: String = UTType.image.identifier) throws
        -> ImportedPageBackground {
        guard let image = UIImage(data: data) else {
            throw PageBackgroundImportError.unreadableFile(sourceName)
        }
        guard let encoded = encodeForPage(image) else {
            throw PageBackgroundImportError.renderingFailed(sourceName)
        }
        return ImportedPageBackground(
            data: encoded,
            sourceName: sourceName,
            contentType: sourceContentType,
            pageNumber: nil
        )
    }

    nonisolated private static func pdfPageCount(
        at url: URL,
        sourceName: String
    ) throws -> Int {
        guard let document = PDFDocument(url: url) else {
            throw PageBackgroundImportError.unreadableFile(sourceName)
        }
        guard document.pageCount > 0 else {
            throw PageBackgroundImportError.emptyPDF(sourceName)
        }
        return document.pageCount
    }

    nonisolated private static func renderPDFPage(
        at url: URL,
        sourceName: String,
        pageIndex: Int
    ) throws -> ImportedPageBackground {
        guard let document = PDFDocument(url: url) else {
            throw PageBackgroundImportError.unreadableFile(sourceName)
        }
        guard let page = document.page(at: pageIndex) else {
            throw PageBackgroundImportError.renderingFailed(
                "\(sourceName), page \(pageIndex + 1)"
            )
        }
        let mediaSize = page.bounds(for: .mediaBox).size
        // PDF media boxes are measured in points (often only 612×792).
        // Render upward to a print-like page texture so small document text
        // remains readable when zoomed on a Retina display.
        let requestedSize = fittedSize(
            mediaSize,
            maxDimension: maxPixelDimension,
            allowsUpscaling: true
        )
        let image = page.thumbnail(of: requestedSize, for: .mediaBox)
        guard let encoded = encodeForPage(image) else {
            throw PageBackgroundImportError.renderingFailed(
                "\(sourceName), page \(pageIndex + 1)"
            )
        }
        return ImportedPageBackground(
            data: encoded,
            sourceName: sourceName,
            contentType: UTType.pdf.identifier,
            pageNumber: pageIndex + 1
        )
    }

    nonisolated private static func fittedSize(
        _ size: CGSize,
        maxDimension: CGFloat,
        allowsUpscaling: Bool = false
    ) -> CGSize {
        guard size.width > 0, size.height > 0 else {
            return CGSize(width: maxDimension, height: maxDimension)
        }
        let targetScale = maxDimension / max(size.width, size.height)
        let scale = allowsUpscaling ? targetScale : min(1, targetScale)
        return CGSize(width: max(1, size.width * scale),
                      height: max(1, size.height * scale))
    }

    /// Normalizes orientation, bounds memory use, and gives transparent
    /// photos a white paper backing before JPEG compression.
    nonisolated private static func encodeForPage(_ image: UIImage) -> Data? {
        let targetSize = fittedSize(image.size, maxDimension: maxPixelDimension)
        guard targetSize.width > 0, targetSize.height > 0 else { return nil }

        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let rendered = UIGraphicsImageRenderer(size: targetSize, format: format).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: targetSize))
            image.draw(in: CGRect(origin: .zero, size: targetSize))
        }
        return rendered.jpegData(compressionQuality: 0.9)
    }
}

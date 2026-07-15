// Item.swift / Models.swift
import Foundation
import SwiftData
import PencilKit

@Model
final class Notebook {
    var title: String
    var createdAt: Date

    @Relationship(deleteRule: .cascade, inverse: \Page.notebook)
    var pages: [Page] = []

    init(title: String, createdAt: Date = .now) {
        self.title = title
        self.createdAt = createdAt
    }
}

@Model
final class Page {
    var index: Int            // page order within the notebook
    var drawingData: Data     // serialized PKDrawing (user ink)
    var chatData: Data        // JSON-encoded [TutorMessage]
    var annotationData: Data  // JSON-encoded StoredAnnotations (marks over user ink)
    var aiDrawingData: Data   // JSON-encoded StoredAIDrawing (generative AI strokes + labels)
    var textLayerData: Data?  // JSON-encoded StoredNoteTextLayer (typed text boxes)

    // Imported images and rendered PDF pages are page backgrounds. Keeping
    // the payload in SwiftData external storage avoids bloating the SQLite
    // row that is rewritten whenever PencilKit ink changes, while still
    // making deletion and backup follow the owning Page automatically.
    @Attribute(.externalStorage) var backgroundData: Data?
    var backgroundSourceName: String?
    var backgroundContentType: String?
    var backgroundPageNumber: Int?
    // The first viewport this page was edited in becomes its stable
    // coordinate space. Imported paper is laid out against this size so a
    // later rotation, Split View resize, or device change cannot rescale the
    // document out from under absolute PencilKit stroke coordinates.
    var referenceCanvasWidth: Double?
    var referenceCanvasHeight: Double?

    var createdAt: Date
    var notebook: Notebook?

    init(index: Int,
         drawingData: Data = Data(),
         chatData: Data = Data(),
         annotationData: Data = Data(),
         aiDrawingData: Data = Data(),
         textLayerData: Data? = nil,
         backgroundData: Data? = nil,
         backgroundSourceName: String? = nil,
         backgroundContentType: String? = nil,
         backgroundPageNumber: Int? = nil,
         referenceCanvasWidth: Double? = nil,
         referenceCanvasHeight: Double? = nil,
         createdAt: Date = .now) {
        self.index = index
        self.drawingData = drawingData
        self.chatData = chatData
        self.annotationData = annotationData
        self.aiDrawingData = aiDrawingData
        self.textLayerData = textLayerData
        self.backgroundData = backgroundData
        self.backgroundSourceName = backgroundSourceName
        self.backgroundContentType = backgroundContentType
        self.backgroundPageNumber = backgroundPageNumber
        self.referenceCanvasWidth = referenceCanvasWidth
        self.referenceCanvasHeight = referenceCanvasHeight
        self.createdAt = createdAt
    }
}

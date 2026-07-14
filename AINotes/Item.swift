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
    var createdAt: Date
    var notebook: Notebook?

    init(index: Int,
         drawingData: Data = Data(),
         chatData: Data = Data(),
         annotationData: Data = Data(),
         aiDrawingData: Data = Data(),
         createdAt: Date = .now) {
        self.index = index
        self.drawingData = drawingData
        self.chatData = chatData
        self.annotationData = annotationData
        self.aiDrawingData = aiDrawingData
        self.createdAt = createdAt
    }
}

//Item.swift to Models.swift
import Foundation
import SwiftData
import PencilKit

@Model
final class Notebook {
    var title: String
    var createdAt: Date

    // Cascade delete: deleting a notebook deletes its pages
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
    var drawingData: Data     // serialized PKDrawing
    var chatData: Data        // JSON-encoded [TutorMessage] (the tutor thread)
    var annotationData: Data  // JSON-encoded StoredAnnotations (the AI marks)
    var createdAt: Date
    var notebook: Notebook?

    init(index: Int,
         drawingData: Data = Data(),
         chatData: Data = Data(),
         annotationData: Data = Data(),
         createdAt: Date = .now) {
        self.index = index
        self.drawingData = drawingData
        self.chatData = chatData
        self.annotationData = annotationData
        self.createdAt = createdAt
    }
}

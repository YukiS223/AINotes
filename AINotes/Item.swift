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
    var createdAt: Date
    var notebook: Notebook?

    init(index: Int, drawingData: Data = Data(), createdAt: Date = .now) {
        self.index = index
        self.drawingData = drawingData
        self.createdAt = createdAt
    }
}

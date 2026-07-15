import SwiftUI
import Observation
import UniformTypeIdentifiers
import UIKit

struct StoredNoteTextLayer: Codable {
    var version = 1
    var boxes: [NoteTextBox]
}

struct NotePageRect: Codable, Equatable, Sendable {
    var x: Double
    var y: Double
    var width: Double
    var height: Double

    var cgRect: CGRect {
        CGRect(x: x, y: y, width: width, height: height)
    }
}

struct NoteTextBox: Codable, Identifiable, Equatable, Sendable {
    var id: UUID
    var text: String
    var frame: NotePageRect
    var fontSize: Double

    init(id: UUID = UUID(),
         text: String,
         frame: NotePageRect,
         fontSize: Double = 22) {
        self.id = id
        self.text = text
        self.frame = frame
        self.fontSize = fontSize
    }
}

@MainActor
protocol TextSelectionEditing: AnyObject {
    func connectUndoManager(_ undoManager: UndoManager?)
    func copySelectedText() -> Bool
    func cutSelectedText() -> Bool
    func pasteTextBox() -> Bool
    func deleteSelectedText() -> Bool
    func deselectText()
}

/// Object-style text editing that complements PencilKit's native lasso.
/// The lasso keeps its rich PKDrawing clipboard representation, while this
/// store places portable JSON plus plain text on the pasteboard for text boxes.
@MainActor
@Observable
final class PageTextStore: TextSelectionEditing {
    var boxes: [NoteTextBox] = []
    var selectedID: UUID?

    @ObservationIgnored private weak var undoManager: UndoManager?
    @ObservationIgnored private var pageBounds = CGRect(x: 0, y: 0, width: 820, height: 1100)

    private static let pasteboardType = "com.yukis.AINotes.note-text-box"

    func load(from data: Data?) {
        guard let data, !data.isEmpty,
              let stored = try? JSONDecoder().decode(StoredNoteTextLayer.self, from: data) else {
            boxes = []
            selectedID = nil
            return
        }
        boxes = stored.boxes.map { box in
            var box = box
            box.frame.height = measuredHeight(
                text: box.text,
                fontSize: box.fontSize,
                width: box.frame.width
            )
            box.frame = clamped(box.frame)
            return box
        }
        selectedID = nil
    }

    func encodedData() -> Data? {
        guard !boxes.isEmpty else { return nil }
        return try? JSONEncoder().encode(StoredNoteTextLayer(boxes: boxes))
    }

    func setPageBounds(_ bounds: CGRect) {
        guard bounds.width > 0, bounds.height > 0 else { return }
        pageBounds = bounds
    }

    func textBox(id: UUID) -> NoteTextBox? {
        boxes.first { $0.id == id }
    }

    func select(_ id: UUID) {
        guard boxes.contains(where: { $0.id == id }) else { return }
        selectedID = id
    }

    func addText(_ text: String, centeredAt point: CGPoint) {
        let cleanText = normalized(text)
        guard !cleanText.isEmpty else { return }
        let width = min(280, max(120, pageBounds.width - 48))
        let height = measuredHeight(text: cleanText, fontSize: 22, width: width)
        let rect = NotePageRect(
            x: point.x - width / 2,
            y: point.y - height / 2,
            width: width,
            height: height
        )
        let box = NoteTextBox(text: cleanText, frame: clamped(rect))
        mutate(actionName: "Add Text") {
            boxes.append(box)
            selectedID = box.id
        }
    }

    func updateText(id: UUID, text: String) {
        let cleanText = normalized(text)
        guard !cleanText.isEmpty,
              let index = boxes.firstIndex(where: { $0.id == id }) else { return }
        mutate(actionName: "Edit Text") {
            boxes[index].text = cleanText
            boxes[index].frame.height = measuredHeight(
                text: cleanText,
                fontSize: boxes[index].fontSize,
                width: boxes[index].frame.width
            )
            boxes[index].frame = clamped(boxes[index].frame)
            selectedID = id
        }
    }

    func moveTextBox(id: UUID, translation: CGSize) {
        guard abs(translation.width) > 0.1 || abs(translation.height) > 0.1,
              let index = boxes.firstIndex(where: { $0.id == id }) else { return }
        mutate(actionName: "Move Text") {
            var frame = boxes[index].frame
            frame.x += translation.width
            frame.y += translation.height
            boxes[index].frame = clamped(frame)
            selectedID = id
        }
    }

    func connectUndoManager(_ undoManager: UndoManager?) {
        self.undoManager = undoManager
    }

    func copySelectedText() -> Bool {
        guard let box = selectedBox,
              let data = try? JSONEncoder().encode(box) else { return false }
        UIPasteboard.general.setItems([[
            Self.pasteboardType: data,
            UTType.plainText.identifier: box.text
        ]])
        return true
    }

    func cutSelectedText() -> Bool {
        guard copySelectedText() else { return false }
        return deleteSelectedText()
    }

    func pasteTextBox() -> Bool {
        let pasteboard = UIPasteboard.general
        if let data = pasteboard.data(forPasteboardType: Self.pasteboardType),
           var copied = try? JSONDecoder().decode(NoteTextBox.self, from: data) {
            copied.id = UUID()
            copied.frame.x += 24
            copied.frame.y += 24
            copied.frame.height = measuredHeight(
                text: copied.text,
                fontSize: copied.fontSize,
                width: copied.frame.width
            )
            copied.frame = clamped(copied.frame)
            mutate(actionName: "Paste Text") {
                boxes.append(copied)
                selectedID = copied.id
            }
            return true
        }

        // A PencilKit copy may also expose a recognized-text flavor. Only
        // turn external clipboard content into a text box when every offered
        // type is textual; otherwise leave the rich stroke payload to the
        // native canvas paste action.
        let containsOnlyText = !pasteboard.types.isEmpty
            && pasteboard.types.allSatisfy { identifier in
                UTType(identifier)?.conforms(to: .text) == true
            }
        guard containsOnlyText, let plainText = pasteboard.string else { return false }
        let cleanText = normalized(plainText)
        guard !cleanText.isEmpty else { return false }
        addText(
            cleanText,
            centeredAt: CGPoint(
                x: pageBounds.midX,
                y: pageBounds.minY + max(140, pageBounds.height * 0.24)
            )
        )
        return true
    }

    func deleteSelectedText() -> Bool {
        guard let selectedID,
              let index = boxes.firstIndex(where: { $0.id == selectedID }) else {
            return false
        }
        mutate(actionName: "Delete Text") {
            boxes.remove(at: index)
            self.selectedID = nil
        }
        return true
    }

    func deselectText() {
        selectedID = nil
    }

    private var selectedBox: NoteTextBox? {
        guard let selectedID else { return nil }
        return boxes.first { $0.id == selectedID }
    }

    private func normalized(_ text: String) -> String {
        String(text.prefix(4_000)).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func clamped(_ rect: NotePageRect) -> NotePageRect {
        let inset: CGFloat = 12
        let maximumWidth = max(40, pageBounds.width - inset * 2)
        let maximumHeight = max(36, pageBounds.height - inset * 2)
        let width = min(max(40, rect.width), maximumWidth)
        let height = min(max(36, rect.height), maximumHeight)
        let maximumX = max(pageBounds.minX + inset, pageBounds.maxX - inset - width)
        let maximumY = max(pageBounds.minY + inset, pageBounds.maxY - inset - height)
        return NotePageRect(
            x: min(max(rect.x, pageBounds.minX + inset), maximumX),
            y: min(max(rect.y, pageBounds.minY + inset), maximumY),
            width: width,
            height: height
        )
    }

    private func measuredHeight(text: String,
                                fontSize: Double,
                                width: Double) -> Double {
        let contentWidth = max(20, width - 12)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: fontSize)
        ]
        let measured = (text as NSString).boundingRect(
            with: CGSize(width: contentWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: attributes,
            context: nil
        )
        return max(44, ceil(measured.height) + 8)
    }

    private func mutate(actionName: String, changes: () -> Void) {
        let previous = boxes
        changes()
        guard previous != boxes else { return }
        registerUndo(snapshot: previous, actionName: actionName)
    }

    private func registerUndo(snapshot: [NoteTextBox], actionName: String) {
        undoManager?.registerUndo(withTarget: self) { target in
            target.restore(snapshot, actionName: actionName)
        }
        undoManager?.setActionName(actionName)
    }

    private func restore(_ snapshot: [NoteTextBox], actionName: String) {
        let current = boxes
        undoManager?.registerUndo(withTarget: self) { target in
            target.restore(current, actionName: actionName)
        }
        boxes = snapshot
        selectedID = nil
        undoManager?.setActionName(actionName)
    }
}

struct TextPlacementOverlay: View {
    let onTap: (CGPoint) -> Void

    var body: some View {
        Color.clear
            .contentShape(Rectangle())
            .gesture(
                SpatialTapGesture()
                    .onEnded { value in onTap(value.location) }
            )
            .accessibilityLabel("Add text to page")
    }
}

struct NoteTextBoxesOverlay: View {
    @Bindable var store: PageTextStore
    let mode: CanvasToolMode
    let onEdit: (UUID) -> Void

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.clear.allowsHitTesting(false)
            ForEach(store.boxes) { box in
                NoteTextBoxView(
                    box: box,
                    isSelected: store.selectedID == box.id,
                    mode: mode,
                    onSelect: { store.select(box.id) },
                    onMove: { store.moveTextBox(id: box.id, translation: $0) },
                    onEdit: { onEdit(box.id) },
                    onCopy: {
                        store.select(box.id)
                        _ = store.copySelectedText()
                    },
                    onCut: {
                        store.select(box.id)
                        _ = store.cutSelectedText()
                    },
                    onPaste: {
                        store.select(box.id)
                        _ = store.pasteTextBox()
                    },
                    onDelete: {
                        store.select(box.id)
                        _ = store.deleteSelectedText()
                    }
                )
            }
        }
    }
}

private struct NoteTextBoxView: View {
    let box: NoteTextBox
    let isSelected: Bool
    let mode: CanvasToolMode
    let onSelect: () -> Void
    let onMove: (CGSize) -> Void
    let onEdit: () -> Void
    let onCopy: () -> Void
    let onCut: () -> Void
    let onPaste: () -> Void
    let onDelete: () -> Void

    @State private var dragTranslation: CGSize = .zero

    var body: some View {
        if mode == .selection {
            textBox
                .offset(dragTranslation)
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            onSelect()
                            dragTranslation = value.translation
                        }
                        .onEnded { value in
                            onMove(value.translation)
                            dragTranslation = .zero
                        }
                )
                .contextMenu {
                    Button("Copy", systemImage: "doc.on.doc", action: onCopy)
                    Button("Cut", systemImage: "scissors", action: onCut)
                    Button("Paste", systemImage: "doc.on.clipboard", action: onPaste)
                    Button("Delete", systemImage: "trash",
                           role: .destructive, action: onDelete)
                }
        } else if mode == .text {
            textBox
                .onTapGesture(perform: onEdit)
        } else {
            textBox.allowsHitTesting(false)
        }
    }

    private var textBox: some View {
        styledTextBox
            .position(
                x: CGFloat(box.frame.x + box.frame.width / 2),
                y: CGFloat(box.frame.y + box.frame.height / 2)
            )
            .accessibilityLabel(Text(box.text))
    }

    private var styledTextBox: some View {
        Text(box.text)
            .font(.system(size: CGFloat(box.fontSize)))
            .foregroundStyle(.black)
            .multilineTextAlignment(.leading)
            .padding(.horizontal, 6)
            .frame(width: CGFloat(box.frame.width), alignment: .leading)
            .frame(height: CGFloat(box.frame.height), alignment: .leading)
            .clipped()
            .background(
                isSelected ? Color.accentColor.opacity(0.10) : Color.clear,
                in: RoundedRectangle(cornerRadius: 6)
            )
            .overlay { selectionBorder }
    }

    @ViewBuilder
    private var selectionBorder: some View {
        if isSelected {
            RoundedRectangle(cornerRadius: 6)
                .stroke(
                    Color.accentColor,
                    style: StrokeStyle(lineWidth: 1.5, dash: [5])
                )
        }
    }
}

import SwiftUI
import PencilKit

// One picker is shared by the canvases in this app process. Only the explicitly
// active page attaches to it, so a TabView swipe cannot make neighboring
// pages fight over first responder or drift to different selected tools.
@MainActor
enum SharedToolPicker {
    private static let lastInkIdentifierKey = "editor.lastInk.identifier.v1"
    private static let lastInkWidthKey = "editor.lastInk.width.v1"
    private static let lastInkColorKey = "editor.lastInk.color.v1"

    private static var configuredIDs: Set<String> = []
    private static var storedPicker: PKToolPicker?

    static var lastInkItemIdentifier: String? =
        UserDefaults.standard.string(forKey: lastInkIdentifierKey)

    static var lastInkTool: PKInkingTool = {
        let defaults = UserDefaults.standard
        let identifier = defaults.string(forKey: lastInkIdentifierKey)
        let type: PKInkingTool.InkType
        switch identifier {
        case EditorPickerItemID.pencil: type = .pencil
        case EditorPickerItemID.marker: type = .marker
        default: type = .pen
        }

        let widthNumber = defaults.object(forKey: lastInkWidthKey) as? NSNumber
        let width = widthNumber.map { CGFloat(truncating: $0) } ?? 4
        var color = UIColor.label
        if let data = defaults.data(forKey: lastInkColorKey),
           let restored = try? NSKeyedUnarchiver.unarchivedObject(
               ofClass: UIColor.self,
               from: data
           ) {
            color = restored
        }
        return PKInkingTool(type, color: color, width: max(1, width))
    }()

    /// Returns the process-wide picker, rebuilding only the picker (never its
    /// canvas) when customization changes. The selected item is carried into
    /// the replacement when it is still enabled.
    static func picker(enabledIDs: Set<String>) -> PKToolPicker {
        if let storedPicker, configuredIDs == enabledIDs { return storedPicker }

        let previousIdentifier = storedPicker?.selectedToolItem.identifier
        if let storedPicker { rememberSelectedInk(in: storedPicker) }

        let replacement = EditorToolPickerFactory.make(enabledIDs: enabledIDs)
        if let previousIdentifier,
           let matchingItem = replacement.toolItems.first(where: {
               $0.identifier == previousIdentifier
           }) {
            replacement.selectedToolItem = matchingItem
        }
        storedPicker = replacement
        configuredIDs = enabledIDs
        return replacement
    }

    static func rememberSelectedInk(in picker: PKToolPicker) {
        guard let item = picker.selectedToolItem as? PKToolPickerInkingItem else { return }
        rememberInk(identifier: item.identifier, tool: item.inkingTool)
    }

    static func rememberInk(identifier: String, tool: PKInkingTool) {
        lastInkItemIdentifier = identifier
        lastInkTool = tool

        let defaults = UserDefaults.standard
        defaults.set(identifier, forKey: lastInkIdentifierKey)
        defaults.set(Double(tool.width), forKey: lastInkWidthKey)
        if let colorData = try? NSKeyedArchiver.archivedData(
            withRootObject: tool.color,
            requiringSecureCoding: true
        ) {
            defaults.set(colorData, forKey: lastInkColorKey)
        }
    }

    @discardableResult
    static func selectLasso(in picker: PKToolPicker) -> Bool {
        if picker.selectedToolItem is PKToolPickerLassoItem { return true }
        guard let lasso = picker.toolItems.first(where: {
            $0 is PKToolPickerLassoItem
        }) else { return false }
        picker.selectedToolItem = lasso
        return true
    }

    @discardableResult
    static func selectInk(in picker: PKToolPicker) -> Bool {
        if picker.selectedToolItem is PKToolPickerInkingItem {
            rememberSelectedInk(in: picker)
            return true
        }

        let remembered = lastInkItemIdentifier.flatMap { identifier in
            picker.toolItems.first(where: { $0.identifier == identifier })
        }
        guard let ink = remembered
                ?? picker.toolItems.first(where: { $0 is PKToolPickerInkingItem }) else {
            return false
        }
        picker.selectedToolItem = ink
        rememberSelectedInk(in: picker)
        return true
    }
}

/// Imperative bridge for edit commands that must reach the active
/// PKCanvasView first responder. PencilKit owns the lasso selection and its
/// rich pasteboard representation; routing standard UIKit edit actions keeps
/// copied handwriting as editable strokes instead of flattening it to an
/// image.
@MainActor
final class CanvasController {
    private weak var canvas: PKCanvasView?
    private weak var picker: PKToolPicker?
    private weak var textEditor: (any TextSelectionEditing)?
    private var drawingDidChange: ((PKDrawing) -> Void)?

    func attach(_ canvas: PKCanvasView,
                picker: PKToolPicker,
                drawingDidChange: @escaping (PKDrawing) -> Void) {
        self.canvas = canvas
        self.picker = picker
        self.drawingDidChange = drawingDidChange
        textEditor?.connectUndoManager(canvas.undoManager)
    }

    func attachTextEditor(_ textEditor: any TextSelectionEditing) {
        self.textEditor = textEditor
        textEditor.connectUndoManager(canvas?.undoManager)
    }

    func detach(_ canvas: PKCanvasView) {
        guard self.canvas === canvas else { return }
        textEditor?.connectUndoManager(nil)
        self.canvas = nil
        picker = nil
        drawingDidChange = nil
    }

    func append(strokes: [PKStroke]) {
        guard let canvas, !strokes.isEmpty else { return }
        var allStrokes = canvas.drawing.strokes
        allStrokes.append(contentsOf: strokes)
        apply(PKDrawing(strokes: allStrokes), registeringUndo: true)
    }

    func currentShapeStyle() -> ShapeStrokeStyle {
        let tool = SharedToolPicker.lastInkTool
        return ShapeStrokeStyle(color: tool.color, width: max(2, tool.width))
    }

    func activateInk() {
        canvas?.isDrawingEnabled = true
        canvas?.tool = SharedToolPicker.lastInkTool
    }

    func undo() {
        canvas?.undoManager?.undo()
    }

    func redo() {
        canvas?.undoManager?.redo()
    }

    func copySelection() {
        if textEditor?.copySelectedText() == true { return }
        perform(#selector(UIResponderStandardEditActions.copy(_:)))
    }

    func cutSelection() {
        if textEditor?.cutSelectedText() == true { return }
        perform(#selector(UIResponderStandardEditActions.cut(_:)))
    }

    func paste() {
        if textEditor?.pasteTextBox() == true { return }
        perform(#selector(UIResponderStandardEditActions.paste(_:)))
    }

    func deleteSelection() {
        if textEditor?.deleteSelectedText() == true { return }
        perform(#selector(UIResponderStandardEditActions.delete(_:)))
    }

    func canvasInteractionBegan() {
        textEditor?.deselectText()
    }

    private func perform(_ action: Selector) {
        guard let canvas else { return }
        canvas.becomeFirstResponder()
        UIApplication.shared.sendAction(action, to: canvas, from: nil, for: nil)
    }

    private func apply(_ newDrawing: PKDrawing, registeringUndo: Bool) {
        guard let canvas else { return }
        let previous = canvas.drawing
        if registeringUndo {
            canvas.undoManager?.registerUndo(withTarget: self) { target in
                target.apply(previous, registeringUndo: true)
            }
        }
        canvas.drawing = newDrawing
        drawingDidChange?(newDrawing)
    }
}

struct CanvasView: UIViewRepresentable {
    @Binding var drawing: PKDrawing
    @Binding var toolMode: CanvasToolMode
    let controller: CanvasController
    let enabledToolIDs: Set<String>
    let selectedNativeToolID: String
    let inkColor: UIColor
    let inkWidth: CGFloat
    let isActive: Bool
    let onRequestToolCustomization: () -> Void

    func makeUIView(context: Context) -> PKCanvasView {
        let canvas = PKCanvasView()
        canvas.drawing = drawing
        canvas.drawingPolicy = .anyInput
        canvas.delegate = context.coordinator
        canvas.backgroundColor = .clear
        canvas.isOpaque = false
        // Pin the coordinate space: no scrolling, no automatic safe-area
        // content inset, no zoom. The AI overlay canvas and the snapshot
        // pipeline both assume this drawing's (0,0) is exactly the view's
        // top-left; an automatic inset here shifts user ink ~47pt relative
        // to the AI ink and to what the model sees, so the model points at
        // the wrong spot. (The AI canvas already pins these — the two
        // layers must match.)
        canvas.isScrollEnabled = false
        canvas.contentInsetAdjustmentBehavior = .never
        canvas.contentInset = .zero
        canvas.minimumZoomScale = 1.0
        canvas.maximumZoomScale = 1.0
        context.coordinator.canvas = canvas
        context.coordinator.connect(controller: controller)
        context.coordinator.applyToolMode()

        // Do NOT grab focus or attach the picker here. In a paged TabView
        // several canvases are created up-front (current + neighbors);
        // if each one claims focus on creation they fight over the single
        // shared picker, which is the flicker. We defer all focus work to
        // claimFocusIfOnscreen(), which only acts for the visible canvas.
        DispatchQueue.main.async {
            context.coordinator.claimFocusIfOnscreen()
        }
        return canvas
    }

    func updateUIView(_ canvas: PKCanvasView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.replacePickerIfNeeded(enabledIDs: enabledToolIDs)
        context.coordinator.connect(controller: controller)
        if canvas.drawing != drawing {
            canvas.drawing = drawing
        }
        context.coordinator.applyToolMode()
        // Re-evaluate on every SwiftUI update (these fire during a swipe),
        // but the gate inside only lets the on-screen canvas act.
        DispatchQueue.main.async {
            context.coordinator.claimFocusIfOnscreen()
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    static func dismantleUIView(_ canvas: PKCanvasView,
                                coordinator: Coordinator) {
        coordinator.deactivatePicker()
        coordinator.controller?.detach(canvas)
        canvas.delegate = nil
    }

    class Coordinator: NSObject, PKCanvasViewDelegate, PKToolPickerObserver {
        var parent: CanvasView
        weak var canvas: PKCanvasView?
        weak var controller: CanvasController?
        private var isSynchronizingTool = false
        private var appliedToolMode: CanvasToolMode?
        private var isObservingToolPicker = false
        private var isCanvasAttachedToPicker = false
        private var needsPickerStateSync = true
        private var appliedNativeToolID: String?
        private var appliedInkColor: UIColor?
        private var appliedInkWidth: CGFloat?
        private var pickerAccessoryItem: UIBarButtonItem?
        private var picker: PKToolPicker

        init(_ parent: CanvasView) {
            self.parent = parent
            picker = SharedToolPicker.picker(enabledIDs: parent.enabledToolIDs)
        }

        /// Tool membership is immutable on PKToolPicker, so customization
        /// replaces the shared picker while retaining the PKCanvasView and
        /// its undo manager. Every coordinator detaches from the exact old
        /// picker before adopting the replacement.
        func replacePickerIfNeeded(enabledIDs: Set<String>) {
            let replacement = SharedToolPicker.picker(enabledIDs: enabledIDs)
            guard replacement !== picker else { return }

            deactivatePicker(resignFirstResponder: false)
            picker = replacement
            appliedToolMode = nil
            needsPickerStateSync = true

            if let canvas, let controller {
                controller.attach(canvas, picker: picker) { [weak self] newDrawing in
                    self?.parent.drawing = newDrawing
                }
            }
        }

        func connect(controller: CanvasController) {
            self.controller = controller
            guard let canvas else { return }
            controller.attach(canvas, picker: picker) { [weak self] newDrawing in
                self?.parent.drawing = newDrawing
            }
        }

        func applyToolMode() {
            guard let canvas else { return }
            // Wait until the visible page owns first-responder focus before
            // changing its active PencilKit tool. Neighbor pages in the
            // paged TabView must remain passive.
            guard !needsPickerStateSync else { return }
            let modeChanged = appliedToolMode != parent.toolMode
            if parent.toolMode == .ink {
                applyNativeTool(force: modeChanged)
            }
            guard modeChanged else { return }
            isSynchronizingTool = true
            defer { isSynchronizingTool = false }

            switch parent.toolMode {
            case .ink:
                canvas.isDrawingEnabled = true
            case .selection:
                canvas.isDrawingEnabled = true
                // Selection uses PencilKit's real lasso tool, preserving
                // editable stroke copy/paste without its carousel UI.
                canvas.tool = PKLassoTool()
            case .shape, .text:
                // SwiftUI's object overlays own touches in these modes, but
                // the canvas stays first responder for undo and clipboard.
                canvas.isDrawingEnabled = false
            }
            appliedToolMode = parent.toolMode
        }

        private func applyNativeTool(force: Bool) {
            guard let canvas else { return }
            let identifier = parent.enabledToolIDs.contains(parent.selectedNativeToolID)
                ? parent.selectedNativeToolID
                : EditorPickerItemID.pen
            let colorChanged = appliedInkColor.map {
                !$0.isEqual(parent.inkColor)
            } ?? true
            guard force
                    || appliedNativeToolID != identifier
                    || colorChanged
                    || appliedInkWidth != parent.inkWidth else { return }

            canvas.isDrawingEnabled = true
            switch identifier {
            case EditorPickerItemID.eraser:
                let eraserType = PKEraserTool.EraserType.fixedWidthBitmap
                let range = eraserType.validWidthRange
                let width = min(range.upperBound,
                                max(range.lowerBound, parent.inkWidth))
                canvas.tool = PKEraserTool(eraserType, width: width)
            default:
                let inkType: PKInkingTool.InkType
                switch identifier {
                case EditorPickerItemID.pencil: inkType = .pencil
                case EditorPickerItemID.marker: inkType = .marker
                default: inkType = .pen
                }
                let tool = PKInkingTool(
                    inkType,
                    color: parent.inkColor,
                    width: max(1, parent.inkWidth)
                )
                canvas.tool = tool
                SharedToolPicker.rememberInk(identifier: identifier, tool: tool)
            }
            appliedNativeToolID = identifier
            appliedInkColor = parent.inkColor
            appliedInkWidth = parent.inkWidth
        }

        func toolPickerSelectedToolItemDidChange(_ toolPicker: PKToolPicker) {
            guard !isSynchronizingTool, canvas?.isFirstResponder == true else { return }
            applySelectedPickerItem(toolPicker.selectedToolItem)
        }

        private func applySelectedPickerItem(_ item: PKToolPickerItem) {
            guard let canvas else { return }
            if item is PKToolPickerLassoItem {
                canvas.isDrawingEnabled = true
                appliedToolMode = .selection
                if parent.toolMode != .selection { parent.toolMode = .selection }
            } else if item.identifier == EditorPickerItemID.text {
                canvas.isDrawingEnabled = false
                appliedToolMode = .text
                if parent.toolMode != .text { parent.toolMode = .text }
            } else if let shape = EditorPickerItemID.shapeKind(for: item.identifier) {
                canvas.isDrawingEnabled = false
                let mode = CanvasToolMode.shape(shape)
                appliedToolMode = mode
                if parent.toolMode != mode { parent.toolMode = mode }
            } else {
                if item is PKToolPickerInkingItem {
                    SharedToolPicker.rememberSelectedInk(in: picker)
                }
                canvas.isDrawingEnabled = true
                appliedToolMode = .ink
                if parent.toolMode != .ink { parent.toolMode = .ink }
            }
        }

        // Only the canvas that is genuinely visible on screen attaches the
        // shared picker and becomes first responder. Off-screen neighbor
        // canvases (pre-rendered by the paged TabView) stay completely
        // passive, so there is no first-responder hand-off to flicker.
        @MainActor
        func claimFocusIfOnscreen() {
            guard let canvas else { return }

            // Geometry alone is insufficient during an interactive page
            // swipe because both pages intersect the window. NotebookView's
            // selection is the single source of active-page ownership.
            guard parent.isActive else {
                deactivatePicker()
                return
            }

            // Must be in a window at all.
            guard let window = canvas.window else {
                deactivatePicker()
                return
            }

            // Is this canvas actually within the visible screen bounds?
            // Neighbor pages in a TabView sit off to the side; their
            // window-space frame won't intersect the screen.
            let frameInWindow = canvas.convert(canvas.bounds, to: nil)
            let onScreen = window.bounds.intersects(frameInWindow)
            guard onScreen else {
                deactivatePicker()
                return
            }

            // PencilKit's picker applies an unavoidable depth blur to its
            // outer carousel items. The app supplies a flat SwiftUI toolbar,
            // while this canvas remains first responder so PencilKit still
            // owns drawing, lasso selection, undo, and the standard edit menu.
            deactivatePicker(resignFirstResponder: false)
            if !canvas.isFirstResponder { canvas.becomeFirstResponder() }
            needsPickerStateSync = false
            applyToolMode()
        }

        func stopObservingToolPicker() {
            guard isObservingToolPicker else { return }
            picker.removeObserver(self)
            isObservingToolPicker = false
        }

        func deactivatePicker(resignFirstResponder: Bool = true) {
            guard let canvas else {
                stopObservingToolPicker()
                needsPickerStateSync = true
                return
            }
            if isCanvasAttachedToPicker {
                picker.setVisible(false, forFirstResponder: canvas)
                picker.removeObserver(canvas)
                isCanvasAttachedToPicker = false
            }
            if resignFirstResponder, canvas.isFirstResponder {
                canvas.resignFirstResponder()
            }
            if picker.accessoryItem === pickerAccessoryItem {
                picker.accessoryItem = nil
            }
            pickerAccessoryItem = nil
            stopObservingToolPicker()
            needsPickerStateSync = true
        }

        private func installPickerAccessoryItemIfNeeded() {
            guard pickerAccessoryItem == nil else { return }
            let action = UIAction(
                title: "Customize Tools",
                image: UIImage(systemName: "slider.horizontal.3")
            ) { [weak self] _ in
                self?.parent.onRequestToolCustomization()
            }
            let item = UIBarButtonItem(primaryAction: action)
            item.accessibilityLabel = "Customize Tools"
            pickerAccessoryItem = item
            picker.accessoryItem = item
        }

        private func startObservingToolPicker() {
            guard !isObservingToolPicker else { return }
            picker.addObserver(self)
            isObservingToolPicker = true
        }

        func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
            parent.canvasViewDrawingDidChange(canvasView)
        }

        func canvasViewDidBeginUsingTool(_ canvasView: PKCanvasView) {
            controller?.canvasInteractionBegan()
        }
    }

    fileprivate func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
        DispatchQueue.main.async {
            self.drawing = canvasView.drawing
        }
    }
}

// Keep this if it was at the bottom of your file before.
extension PKDrawing {
    func snapshot(bounds: CGRect, scale: CGFloat = 2.0) -> UIImage {
        return image(from: bounds, scale: scale)
    }
}

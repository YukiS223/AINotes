import SwiftUI
import PencilKit

struct CanvasView: UIViewRepresentable {
    @Binding var drawing: PKDrawing

    func makeUIView(context: Context) -> PKCanvasView {
        let canvas = PKCanvasView()
        canvas.drawing = drawing
        canvas.drawingPolicy = .anyInput
        canvas.delegate = context.coordinator
        canvas.backgroundColor = .systemBackground

        // Attach the tool picker (kept alive by the Coordinator)
        let picker = context.coordinator.toolPicker
        picker.setVisible(true, forFirstResponder: canvas)
        picker.addObserver(canvas)

        // Become first responder on the next runloop tick, once on screen
        DispatchQueue.main.async {
            canvas.becomeFirstResponder()
        }
        return canvas
    }

    func updateUIView(_ canvas: PKCanvasView, context: Context) {
        if canvas.drawing != drawing {
            canvas.drawing = drawing
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    class Coordinator: NSObject, PKCanvasViewDelegate {
        var parent: CanvasView
        let toolPicker = PKToolPicker()   // <-- key: stored property, lives as long as the view

        init(_ parent: CanvasView) {
            self.parent = parent
        }

        func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
            parent.canvasViewDrawingDidChange(canvasView)
        }
    }

    // Forwarded from Coordinator
    fileprivate func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
        // SwiftUI bindings can't be mutated from inside makeUIView's call stack
        DispatchQueue.main.async {
            self.drawing = canvasView.drawing
        }
    }
    
}

extension PKDrawing {
    func snapshot(bounds: CGRect, scale: CGFloat = 2.0) -> UIImage {
        return image(from: bounds, scale: scale)
    }
}

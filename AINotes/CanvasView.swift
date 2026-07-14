import SwiftUI
import PencilKit

// One tool picker shared by every canvas in the app.
// (Multiple pickers fighting is what caused the flicker.)
enum SharedToolPicker {
    static let picker = PKToolPicker()
}

struct CanvasView: UIViewRepresentable {
    @Binding var drawing: PKDrawing

    func makeUIView(context: Context) -> PKCanvasView {
        let canvas = PKCanvasView()
        canvas.drawing = drawing
        canvas.drawingPolicy = .anyInput
        canvas.delegate = context.coordinator
        canvas.backgroundColor = .systemBackground
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
        if canvas.drawing != drawing {
            canvas.drawing = drawing
        }
        // Re-evaluate on every SwiftUI update (these fire during a swipe),
        // but the gate inside only lets the on-screen canvas act.
        DispatchQueue.main.async {
            context.coordinator.claimFocusIfOnscreen()
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    class Coordinator: NSObject, PKCanvasViewDelegate {
        var parent: CanvasView
        weak var canvas: PKCanvasView?

        init(_ parent: CanvasView) { self.parent = parent }

        // Only the canvas that is genuinely visible on screen attaches the
        // shared picker and becomes first responder. Off-screen neighbor
        // canvases (pre-rendered by the paged TabView) stay completely
        // passive, so there is no first-responder hand-off to flicker.
        @MainActor
        func claimFocusIfOnscreen() {
            guard let canvas else { return }

            // Must be in a window at all.
            guard let window = canvas.window else { return }

            // Is this canvas actually within the visible screen bounds?
            // Neighbor pages in a TabView sit off to the side; their
            // window-space frame won't intersect the screen.
            let frameInWindow = canvas.convert(canvas.bounds, to: nil)
            let onScreen = window.bounds.intersects(frameInWindow)
            guard onScreen else { return }

            // Already focused → do nothing. Repeatedly re-claiming focus
            // is itself a source of churn.
            guard !canvas.isFirstResponder else { return }

            let picker = SharedToolPicker.picker
            picker.addObserver(canvas)
            picker.setVisible(true, forFirstResponder: canvas)
            canvas.becomeFirstResponder()
        }

        func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
            parent.canvasViewDrawingDidChange(canvasView)
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

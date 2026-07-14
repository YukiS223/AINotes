//
//  AIDrawing.swift
//  AINotes
//
//  Layer 2: turning RenderSteps into real PencilKit ink, animated stroke
//  by stroke. The player progressively appends control points to the
//  in-progress stroke each frame, then commits the finished stroke to a
//  PKDrawing that lives parallel to the user's drawing.
//

import SwiftUI
import PencilKit
import UIKit

// MARK: - PKStroke synthesis

enum AIStrokeFactory {
    /// Build a PKStroke from a list of canvas-coord points. PencilKit
    /// Catmull-Rom-smooths between control points, so sparse points still
    /// render as smooth curves.
    static func stroke(points: [CGPoint],
                       color: UIColor,
                       thickness: CGFloat = 4) -> PKStroke {
        let strokePoints: [PKStrokePoint] = points.enumerated().map { (idx, pt) in
            PKStrokePoint(
                location: pt,
                timeOffset: TimeInterval(idx) * 0.01,
                size: CGSize(width: thickness, height: thickness),
                opacity: 1.0,
                force: 1.0,
                azimuth: 0,
                altitude: 0
            )
        }
        let path = PKStrokePath(controlPoints: strokePoints, creationDate: Date())
        let ink = PKInk(.pen, color: color)
        return PKStroke(ink: ink, path: path)
    }
}

// MARK: - Animation player

@MainActor
@Observable
final class AIDrawingPlayer {
    /// Committed strokes (excludes the currently-animating partial stroke).
    /// This is what gets persisted.
    private(set) var committedDrawing = PKDrawing()
    /// The stroke currently being animated, rendered on top of committed.
    /// Nil when no animation is in progress.
    private(set) var inProgressStroke: PKStroke?
    /// Text labels (committed only; rendered via a separate Canvas overlay).
    private(set) var labels: [StoredAILabel] = []
    /// True while play() is running. Subsequent play() calls are queued
    /// implicitly by the caller awaiting.
    private(set) var isPlaying = false
    
    private var playTail: Task<Void, Never>?
    /// Bumped by clear()/cancelPlayback(). playTail?.cancel() only reaches
    /// the LAST task in the chain — a currently-running earlier play would
    /// keep painting. Every runPlay captures the generation it started
    /// under and stops the moment it goes stale.
    private var playGeneration = 0
    /// Persistent across play() calls, so `edge from:"id:90"` works even
    /// when "90" was emitted in an earlier call.
    private var nodeAnchors: [String: CGPoint] = [:]

    /// What the AIDrawingCanvas should display = committed ∪ {inProgress}.
    var displayedDrawing: PKDrawing {
        guard let ip = inProgressStroke else { return committedDrawing }
        var strokes = committedDrawing.strokes
        strokes.append(ip)
        return PKDrawing(strokes: strokes)
    }

    /// Hydrate from persistence without animating.
    func loadCommitted(drawing: PKDrawing, labels: [StoredAILabel]) {
        committedDrawing = drawing
        self.labels = labels
        inProgressStroke = nil
        // Rebuild what anchors we can: node/tree labels were persisted as
        // text labels at the node centers, so "id:LABEL" edge references
        // keep working after an app relaunch instead of silently failing.
        for label in labels {
            nodeAnchors[label.text] = CGPoint(x: label.canvasX, y: label.canvasY)
        }
    }

    /// Wipe everything (the Clear AI button). Cancels any in-flight
    /// animation — otherwise the running play() keeps committing strokes
    /// and "cleared" ink reappears mid-wipe.
    func clear() {
        playGeneration += 1
        playTail?.cancel()
        playTail = nil
        committedDrawing = PKDrawing()
        inProgressStroke = nil
        labels = []
        nodeAnchors = [:]
    }

    /// Run the actions one after another. Strokes animate; labels pop in
    /// with a small inter-step delay so they don't all flash at once.
    /// `userInk`: bounds of the student's strokes (snap targets + no-go
    /// zones). `avoidRects`: extra keep-out regions (UI controls).
    func play(actions: [DrawingActionDTO], canvasBounds: CGRect,
              userInk: [CGRect] = [], avoidRects: [CGRect] = []) async {
        // Capture the generation at ENQUEUE time. A task queued in the
        // middle of a chain isn't the tail (so cancel() never reaches it),
        // and reading playGeneration when it finally starts would see the
        // post-clear value and think it's fresh — this stamp is what marks
        // it stale.
        let gen = playGeneration
        let prev = playTail
        let task = Task { [weak self] in
            _ = await prev?.value
            await self?.runPlay(actions: actions, canvasBounds: canvasBounds,
                                userInk: userInk, avoidRects: avoidRects, gen: gen)
        }
        playTail = task
        await task.value
    }

    /// Stop any in-flight animation without touching committed content.
    /// Called on End Session so a dead session's strokes don't keep
    /// appearing; contrast clear(), which also wipes committed ink.
    func cancelPlayback() {
        playGeneration += 1
        playTail?.cancel()
        playTail = nil
        inProgressStroke = nil
        isPlaying = false
    }

    private func runPlay(actions: [DrawingActionDTO], canvasBounds: CGRect,
                         userInk: [CGRect], avoidRects: [CGRect], gen: Int) async {
        // A play cancelled or invalidated while still queued behind the
        // previous one must not execute AT ALL — especially not the
        // tree-wipe below, which would erase committed ink and then draw
        // nothing. `gen` was stamped when play() enqueued this task.
        guard !Task.isCancelled, gen == playGeneration else { return }
        isPlaying = true
        defer { isPlaying = false }

        // A new `tree` REPLACES any existing tree — clear prior AI ink first
        // so revisions don't pile on top of each other. Non-tree primitives
        // (node, edge, path, text) remain additive. Only wipe for a tree
        // that can actually render (has nodes and a root): validation
        // upstream should guarantee this, but a dud tree must never
        // vaporize existing ink and leave a blank layer.
        let hasRenderableTree = actions.contains { a in
            guard a.type == .tree, let nodes = a.nodes, !nodes.isEmpty else { return false }
            return nodes.contains { $0.parent == nil }
        }
        if hasRenderableTree {
            committedDrawing = PKDrawing()
            labels = []
            nodeAnchors = [:]
        }

        // Relocate explanation text away from occupied space: student ink,
        // caller-supplied keep-out zones, and OUR OWN surviving content
        // (computed after the tree-wipe above so freshly-cleared ink
        // doesn't count as occupied).
        var occupied = userInk + avoidRects
        occupied += committedDrawing.strokes.map(\.renderBounds)
        occupied += labels.map { l in
            let w = CGFloat(l.text.count) * 9.5 + 8
            return CGRect(x: l.canvasX - Double(w) / 2, y: l.canvasY - 11,
                          width: Double(w), height: 22)
        }
        let placed = TextBlockPlacer.adjust(actions,
                                            canvasBounds: canvasBounds,
                                            avoid: occupied)

        let expander = ActionExpander(canvasBounds: canvasBounds,
                                      initialAnchors: nodeAnchors,
                                      inkBounds: userInk)
        let steps = expander.expand(placed)

        for step in steps {
            guard !Task.isCancelled, gen == playGeneration else { return }
            switch step {
            case .stroke(let points, let color):
                await animateStroke(points: points, color: color, gen: gen)
            case .label(let at, let text, let color):
                appendLabel(at: at, text: text, color: color)
                try? await Task.sleep(nanoseconds: 80_000_000)
            }
        }

        // Skip on cancellation (Clear AI / End Session) — the anchors were
        // reset and restoring the expander's would resurrect stale state.
        guard !Task.isCancelled, gen == playGeneration else { return }
        nodeAnchors = expander.finalAnchors
    }

    // MARK: helpers

    private func animateStroke(points: [CGPoint], color: UIColor, gen: Int) async {
        guard points.count >= 2 else { return }

        // Duration grows with length but caps so big trees don't drag.
        let duration: TimeInterval = min(0.6, max(0.18, Double(points.count) * 0.025))
        let fps: Double = 30
        let frames = max(2, Int(duration * fps))
        let frameNanos = UInt64(1.0 / fps * 1_000_000_000)

        for f in 1...frames {
            guard !Task.isCancelled, gen == playGeneration else {
                inProgressStroke = nil    // cancelled mid-stroke: don't commit
                return
            }
            let progress = Double(f) / Double(frames)
            let cutoff = max(2, Int(Double(points.count) * progress))
            let partial = Array(points.prefix(cutoff))
            inProgressStroke = AIStrokeFactory.stroke(points: partial, color: color)
            try? await Task.sleep(nanoseconds: frameNanos)
        }

        guard !Task.isCancelled, gen == playGeneration else {
            inProgressStroke = nil
            return
        }
        // Commit the full stroke.
        var strokes = committedDrawing.strokes
        strokes.append(AIStrokeFactory.stroke(points: points, color: color))
        committedDrawing = PKDrawing(strokes: strokes)
        inProgressStroke = nil
    }

    private func appendLabel(at: CGPoint, text: String, color: UIColor) {
        labels.append(StoredAILabel(
            canvasX: Double(at.x),
            canvasY: Double(at.y),
            text: text,
            color: AIPalette.name(for: color)
        ))
    }
}

// MARK: - Views

/// A non-interactive PKCanvasView that renders the AI's PKDrawing.
/// Touches pass through to the user's canvas below.
struct AIDrawingCanvas: UIViewRepresentable {
    let drawing: PKDrawing

    func makeUIView(context: Context) -> PKCanvasView {
        let v = PKCanvasView()
        v.isUserInteractionEnabled = false
        v.backgroundColor = .clear
        v.isOpaque = false
        v.drawingPolicy = .anyInput
        // Force the same coord space as the user's canvas: no scroll,
        // no auto safe-area inset, no zoom. Without this, the two
        // PKCanvasViews can drift by the status-bar height (~47pt).
        v.isScrollEnabled = false
        v.contentInsetAdjustmentBehavior = .never
        v.contentInset = .zero
        v.minimumZoomScale = 1.0
        v.maximumZoomScale = 1.0
        v.zoomScale = 1.0
        v.drawing = drawing
        return v
    }

    func updateUIView(_ v: PKCanvasView, context: Context) {
        // Always set — PKDrawing equality can be expensive and the player
        // rebuilds the drawing each animation frame anyway.
        v.drawing = drawing
    }
}

/// Renders the AI's text labels (PKStroke can't carry text).
struct AILabelsOverlay: View {
    let labels: [StoredAILabel]

    var body: some View {
        Canvas { ctx, _ in
            for l in labels {
                ctx.draw(
                    Text(l.text)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(AIPalette.color(l.color)),
                    at: CGPoint(x: l.canvasX, y: l.canvasY),
                    anchor: .center
                )
            }
        }
        .allowsHitTesting(false)
    }
}

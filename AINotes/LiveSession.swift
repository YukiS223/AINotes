//
//  LiveSession.swift
//  AINotes
//
//  Orchestrator. Owns the WebSocket client, mic capture, speaker
//  playback, and a 1 fps video frame loop. Wires Gemini's tool calls
//  back to the on-screen drawing pipeline.
//

import Foundation
import UIKit

@MainActor
@Observable
final class LiveSession {
    
    enum State: Equatable {
        case idle
        case starting
        case live           // mic, speaker, and video timer all running
        case error(String)
    }
    
    // MARK: - Public state
    
    private(set) var state: State = .idle
    private(set) var transcript: String = ""    // running output transcription
    private var heartbeatTask: Task<Void, Never>?
    private let heartbeatInterval: TimeInterval = 3.0
    private(set) var toolCallsReceived: Int = 0
    private(set) var drawingsExtracted: Int = 0
    private(set) var drawingsDispatched: Int = 0
    
    private(set) var lastFrameSent: UIImage?
    private(set) var framesSent: Int = 0
    
    
    /// Provider for periodic video frames; called ~once per second.
    var snapshotProvider: (() -> UIImage?)?
    /// Provider for the current canvas coord space (for tool call mapping).
    var canvasBoundsProvider: (() -> CGRect)?
    /// Called when the model invokes the `draw` tool. The view layer
    /// passes these into AIDrawingPlayer.play(actions:canvasBounds:).
    var onDrawAction: (([DrawingActionDTO], CGRect) -> Void)?
    /// Fires on stop() so the owning view can kill anything session-scoped
    /// it owns (e.g. an in-flight drawing animation).
    var onSessionEnded: (() -> Void)?

    /// True from the first audio chunk of a model turn until the server
    /// says the turn is over (or the user interrupts). Gating the mic on
    /// this — not just on queued playback — closes the mid-utterance gaps
    /// where the buffer briefly drains, echo slips through, the server VAD
    /// "hears the user", and the model restarts with a near-identical
    /// answer.
    private var modelTurnActive = false
    private var lastModelAudioAt: CFAbsoluteTime = 0
    
    // MARK: - Internals
    
    private let client = GeminiLiveClient()
    private let audio = LiveAudioEngine()
    private var pendingFrameTask: Task<Void, Never>?
    private let frameDebounce: TimeInterval = 0.5
    
    // MARK: - Lifecycle
    
    func start(apiKey: String) {
        // Restartable from .idle AND .error — previously a connection
        // failure left state == .error forever and the start button
        // silently did nothing.
        switch state {
        case .starting, .live: return
        case .idle, .error: break
        }
        state = .starting
        transcript = ""
        // Turn-gate state must not survive into a new session: after a
        // connection drop mid-turn, a quick retry would otherwise inherit
        // modelTurnActive=true and silently mute the mic for up to 5s
        // while the UI already says "Live".
        modelTurnActive = false
        lastModelAudioAt = 0

        client.disconnect()   // clear any stale socket/error from a prior run
        wireClient()
        client.connect(apiKey: apiKey, setup: SetupConfig.tutor(systemInstruction: systemPrompt))
    }
    
    func stop() {
        pendingFrameTask?.cancel()
        pendingFrameTask = nil
        audio.onPCMChunk = nil     // no mic chunks can outlive the session
        audio.stop()
        client.disconnect()        // also drops all client callbacks
        state = .idle
        heartbeatTask?.cancel()
        heartbeatTask = nil
        modelTurnActive = false
        lastModelAudioAt = 0
        onSessionEnded?()
    }
    
    // MARK: - Client wiring
    
    private func wireClient() {
        client.onReady = { [weak self] in self?.beginStreaming() }
        client.onAudioChunk = { [weak self] data in
            self?.modelTurnActive = true
            self?.lastModelAudioAt = CFAbsoluteTimeGetCurrent()
            self?.audio.enqueue(data)
        }
        client.onTranscriptDelta = { [weak self] s in self?.transcript += s }
        // The server says the user interrupted the model. Drop everything
        // still queued for the speaker — otherwise the stale rest of the
        // old utterance plays out with the new response queued behind it,
        // which sounds like the model talking over itself.
        client.onInterrupted = { [weak self] in
            self?.audio.flushPlayback()
            self?.modelTurnActive = false
        }
        client.onTurnComplete = { [weak self] in
            self?.modelTurnActive = false
        }
        client.onToolCall = { [weak self] call in self?.handleToolCall(call) }
        client.onClosed = { [weak self] msg in
            self?.state = .error(msg ?? "Connection closed")
            self?.audio.onPCMChunk = nil
            self?.audio.stop()
            self?.pendingFrameTask?.cancel()
            self?.pendingFrameTask = nil
            // Without this the heartbeat keeps capturing and "sending"
            // frames into a dead socket every 3s forever.
            self?.heartbeatTask?.cancel()
            self?.heartbeatTask = nil
            self?.modelTurnActive = false
            self?.lastModelAudioAt = 0
            // Fully tear down the socket + URLSession; the receive loop's
            // error path doesn't invalidate them and the session object
            // would otherwise linger until the next start().
            self?.client.disconnect()
            // Same contract as stop(): a dead session must not keep
            // painting — cancel any in-flight drawing animation too.
            self?.onSessionEnded?()
        }
    }
    
    private func beginStreaming() {
        // Audio in.
        audio.onPCMChunk = { [weak self] chunk in
            guard let self else { return }
            // Safety valve: if turnComplete got lost, don't stay muted
            // forever — 5s with no model audio and an idle speaker means
            // the turn is over no matter what the flag says.
            if self.modelTurnActive, !self.audio.isPlaybackActive,
               CFAbsoluteTimeGetCurrent() - self.lastModelAudioAt > 5 {
                self.modelTurnActive = false
            }
            // Mic-gate: don't ship audio to the server for the WHOLE model
            // turn (first chunk → turnComplete), not merely while buffers
            // are queued — the queue drains briefly between streamed
            // chunks, and echo leaking through those gaps made the server
            // VAD "hear the user", interrupt, and re-answer. Hardware echo
            // cancellation in LiveAudioEngine does the heavy lifting; this
            // is the backstop.
            guard !self.modelTurnActive, !self.audio.isPlaybackActive else { return }
            self.client.sendAudio(chunk)
        }
        do {
            try audio.start()
        } catch {
            state = .error("Audio start failed: \(error.localizedDescription)")
            client.disconnect()
            return
        }

        // Mark live BEFORE kicking off frame tasks — captureAndSendFrame
        // gates on .live so frames can't leak into a dead/closed session.
        state = .live

        // Video.
        // Send one initial frame so the model has visual context before the
        // user does anything. Subsequent frames are sent on canvas changes
        // via noteCanvasChanged().
        captureAndSendFrame()
        // Heartbeat: keep model's visual context fresh even when the student
        // isn't drawing (e.g. talking through a problem). ~20 frames/min on top
        // of stroke-triggered captures — still ~3x cheaper than 1 fps continuous.
        // Deliberately NOT `guard let self` up front: that would hold the
        // session strongly for the life of the loop and it could never
        // deallocate. Re-resolve weakly each tick instead.
        let interval = heartbeatInterval
        heartbeatTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                guard !Task.isCancelled, let self else { break }
                self.captureAndSendFrame()
            }
        }
    }
    
    /// Signal that the user's canvas changed. Debounced so a rapid burst of
    /// strokes coalesces into a single frame send.
    func noteCanvasChanged() {
        guard state == .live else { return }
        pendingFrameTask?.cancel()
        pendingFrameTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: UInt64(self.frameDebounce * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self.captureAndSendFrame()
        }
    }

    private func captureAndSendFrame() {
        guard state == .live else { return }
        guard let img = snapshotProvider?() else { return }
        guard let jpeg = img.jpegData(compressionQuality: 0.6) else { return }
        lastFrameSent = img
        framesSent += 1
        client.sendVideoFrame(jpeg)
    }

    /// Called by the view layer once the AI's strokes finish animating.
    /// Pushes a fresh frame right away — instead of waiting up to
    /// `heartbeatInterval` — so the model immediately SEES its own ink
    /// land. This closes the loop: if a draw silently produced nothing
    /// (bad anchor, off-canvas coords), the next frame shows that too and
    /// the model can correct itself instead of insisting it already drew.
    func noteAIDrawingFinished() {
        guard state == .live else { return }
        captureAndSendFrame()
    }
    
    // MARK: - Tool dispatch
    
    private func handleToolCall(_ call: ToolCall) {
        toolCallsReceived += 1
        // A tool call is mid-turn server activity: keep the 5s turn-gate
        // safety valve from firing during the round trip (audio pauses
        // while the model waits for our response, but the turn is NOT
        // over — reopening the mic here invites the echo/restart loop).
        lastModelAudioAt = CFAbsoluteTimeGetCurrent()
        guard call.name == "draw" else {
            // Unknown tool — acknowledge so the session continues.
            client.sendToolResponse(callID: call.id, name: call.name,
                                    result: ["status": "ignored"])
            return
        }

        // Extract the raw array. Tolerate the occasional double-encoding
        // quirk where the model sends `drawings` as a JSON *string*.
        let rawActions: [Any]?
        if let arr = call.args["drawings"] as? [Any] {
            rawActions = arr
        } else if let str = call.args["drawings"] as? String,
                  let data = str.data(using: .utf8),
                  let arr = (try? JSONSerialization.jsonObject(with: data)) as? [Any] {
            rawActions = arr
        } else {
            rawActions = nil
        }

        // Lossy per-element decode. The old code decoded the whole array
        // in one JSONDecoder call, which is all-or-nothing: one malformed
        // action voided the entire batch, the canvas stayed blank, and the
        // model (which narrates in the same turn it calls the tool) had
        // already told the student "here's the diagram". Now each action
        // sinks or swims on its own, and the model is told exactly which
        // ones sank and why, so it can fix and re-call.
        var drawings: [DrawingActionDTO] = []
        var problems: [String] = []
        let decoder = JSONDecoder()
        for (i, el) in (rawActions ?? []).enumerated() {
            do {
                let data = try JSONSerialization.data(withJSONObject: el)
                let dto = try decoder.decode(DrawingActionDTO.self, from: data)
                if let why = validationProblem(for: dto) {
                    problems.append("drawings[\(i)] (\(dto.type.rawValue)): \(why)")
                } else {
                    drawings.append(dto)
                }
            } catch {
                let t = (el as? [String: Any])?["type"] as? String ?? "?"
                problems.append("drawings[\(i)] (type=\(t)): \(shortDecodeError(error))")
            }
        }

        drawingsExtracted += drawings.count
        let bounds = canvasBoundsProvider?() ?? .zero

        // Build a response the model can actually act on. The key contract:
        // it must never be able to mistake "nothing rendered" for success.
        var result: [String: Any]
        if rawActions == nil {
            result = ["status": "error",
                      "error": "missing or malformed 'drawings' argument — NOTHING was drawn"]
        } else if bounds.width == 0 || bounds.height == 0 {
            result = ["status": "error",
                      "error": "canvas not ready — NOTHING was drawn, retry in a moment"]
        } else if drawings.isEmpty {
            result = ["status": "error",
                      "error": "no valid actions — NOTHING was drawn. Fix these and call draw again: "
                               + problems.joined(separator: "; ")]
        } else {
            drawingsDispatched += drawings.count
            onDrawAction?(drawings, bounds)
            if problems.isEmpty {
                result = ["status": "ok",
                          "drewActions": drawings.count,
                          "note": "ink is rendering on the canvas now; the next video frame shows it"]
            } else {
                result = ["status": "partial",
                          "drewActions": drawings.count,
                          "skippedActions": problems.count,
                          "error": "these actions were invalid and NOT drawn: "
                                   + problems.joined(separator: "; ")]
            }
        }

        print("📐 draw tool: \(result)  bounds=\(bounds)")

        client.sendToolResponse(callID: call.id, name: call.name, result: result)
    }

    /// Semantic checks that decoding alone can't catch: an action can be
    /// schema-valid yet expand to zero strokes in ActionExpander (which
    /// silently returns []). Catch those here so the tool response never
    /// claims "ok" for ink that will never appear.
    private func validationProblem(for d: DrawingActionDTO) -> String? {
        switch d.type {
        case .path:
            let usable = (d.points ?? []).filter { $0.count >= 2 }
            if usable.count < 2 {
                return "path needs points:[[x,y],[x,y],...] with at least 2 points"
            }
        case .text:
            if d.x == nil || d.y == nil || d.text == nil {
                return "text needs x, y, and text"
            }
        case .node:
            if d.x == nil || d.y == nil {
                return "node needs x and y"
            }
        case .edge:
            if d.from == nil || d.to == nil {
                return "edge needs from and to"
            }
        case .tree:
            let nodes = d.nodes ?? []
            if nodes.isEmpty {
                return "tree needs a non-empty nodes array"
            }
            // Structural checks — the layout code walks parent links, so
            // malformed specs straight from the model must be caught here,
            // reported back, and never crash or hang the app.
            var seen = Set<String>()
            let ids = Set(nodes.map(\.id))
            let roots = nodes.filter { $0.parent == nil }
            if roots.count != 1 {
                return "tree needs exactly ONE root node (parent:null), got \(roots.count)"
            }
            for n in nodes {
                if !seen.insert(n.id).inserted {
                    return "duplicate node id '\(n.id)' — every id must be unique"
                }
                if let p = n.parent {
                    if p == n.id { return "node '\(n.id)' is its own parent" }
                    if !ids.contains(p) {
                        return "node '\(n.id)' references unknown parent '\(p)'"
                    }
                }
            }
            // Cycle check: walk up from every node; a well-formed tree
            // reaches the root in <= nodes.count hops.
            let parentOf = Dictionary(nodes.map { ($0.id, $0.parent) },
                                      uniquingKeysWith: { a, _ in a })
            for n in nodes {
                var cursor: String? = n.id
                var hops = 0
                while let c = cursor, let next = parentOf[c] ?? nil {
                    hops += 1
                    if hops > nodes.count {
                        return "parent links form a cycle involving '\(n.id)'"
                    }
                    cursor = next
                }
            }
        }
        return nil
    }

    /// Compact, model-readable description of a DecodingError. The model
    /// reads this back, so keep it short and actionable.
    private func shortDecodeError(_ error: Error) -> String {
        switch error {
        case DecodingError.keyNotFound(let key, _):
            return "missing required field '\(key.stringValue)'"
        case DecodingError.typeMismatch(_, let ctx):
            let path = ctx.codingPath.map(\.stringValue).filter { !$0.isEmpty }
            return "wrong type at '\(path.joined(separator: "."))'"
        case DecodingError.valueNotFound(_, let ctx):
            let path = ctx.codingPath.map(\.stringValue).filter { !$0.isEmpty }
            return "unexpected null at '\(path.joined(separator: "."))'"
        case DecodingError.dataCorrupted(let ctx):
            return ctx.debugDescription
        default:
            return error.localizedDescription
        }
    }
    
    // MARK: - System instruction
    
    private let systemPrompt = """
        # Your two abilities
        
        You are an AI tutor. You have TWO equally essential abilities:
        1. SPEAK to the student through their iPad speaker.
        2. DRAW on the student's iPad canvas using the `draw` tool. This
           puts real ink on their screen — they see it instantly.
        
        You also see a live video feed of their canvas (a fresh frame
        every ~3 seconds and after each stroke they make).
        
        # CRITICAL: you CAN draw — never claim otherwise
        
        # Tool use is NOT one-time

        You can call `draw` as many times as you want during a session. If
        you drew earlier, that does NOT mean you should stop drawing now.
        Each new request to see, add, fix, modify, extend, or visualize
        something is a fresh tool call. NEVER say "I already drew that" or
        "I did draw it" without actually calling the tool in the same turn.
        Saying "I drew it" without an accompanying tool call is a lie to
        the student — they see nothing on the canvas.

        # Verify your ink — read the tool response

        Every `draw` call returns a status. It is the ground truth:
          - "ok": every action rendered. Immediately after, you receive a
            fresh video frame that INCLUDES your new ink — look at it.
          - "partial": some actions rendered, the rest were invalid and
            were SKIPPED. The "error" field lists exactly which and why.
            Fix only those and call `draw` again right away.
          - "error": NOTHING was drawn. The canvas did not change. Fix
            the problem described in "error" and call `draw` again
            immediately. Do NOT tell the student it's on screen.
        Never describe ink as visible unless the response said ok or
        partial. If a frame arrives and your drawing isn't in it, your
        call failed — draw again instead of insisting you already did.

        When EXTENDING a previous tree (e.g. "add 100 to the BST"):
        re-state EVERY previous node plus the new one in the new `tree`
        action's `nodes` array. Don't omit any. The app replaces the old
        tree wholesale with the new one.
        
        The `draw` tool is part of you, available RIGHT NOW. You do not
        need permission. You do not apologize for "not being able to."
        The following phrases are FORBIDDEN — never produce them:
          - "I can't draw"
          - "I don't have the ability to draw"
          - "I'm just a voice assistant"
          - "I can only describe in words"
          - "Unfortunately I can't show you"
          - "I'd love to but..."
        
        When the student asks to SEE, DRAW, SKETCH, SHOW, DEMONSTRATE,
        ILLUSTRATE, FINISH, ADD TO, or VISUALIZE anything — you CALL THE
        TOOL. Always. Then narrate what you drew while it appears.
        
        # Drawing primitives
        
        Coordinates are fractions of the canvas:
        (0,0) = top-left, (1,1) = bottom-right, (0.5, 0.5) = center.
        
        Primitives:
          - path: {type:"path", points:[[x,y],...], color}
          - text: {type:"text", x, y, text, color}  -- (x,y) = center
          - node: {type:"node", x, y, width, text, color}
                  labeled circle, (x,y) = center, width = diameter
          - edge: {type:"edge", from, to, arrowhead, color}
                  from/to is "x,y" raw coords OR "id:LABEL" to anchor
        - tree: {type:"tree", x, y, width, height, color,
                 nodes:[{id, label, parent, side}, ...]}
                parent=null for the root. EVERY non-root node MUST have
                side:"left" OR side:"right". This is mandatory, not optional.
                Without it, a single child can't be drawn on the correct side
                of its parent and the tree becomes unreadable.
        
        # Placement policy — read the frame FIRST, then pick a spot

        Every frame includes a faint blue coordinate grid labeled 0.0-1.0.
        Before every draw call:
        1. Look at the LATEST frame and find genuinely EMPTY regions.
        2. Put new content in the largest empty region NEXT TO the work it
           refers to — an empty right or left column beats the center. Do
           NOT default to the middle of the page and grow downward.
        3. NEVER cover: the student's handwriting, your own earlier ink,
           or the top-right corner (x > 0.72, y < 0.12 — app buttons).
        4. Pack text tightly: consecutive lines share the same x and step
           y by just 0.05. Keep explanations to a few short lines.
        5. Keep everything inside 0.03...0.97 on both axes.
        6. Out of room? Ask the student to tap "Clear AI" or add a page —
           never pile ink on ink.
        Typical sizes (shrink further when space is tight):
          tree width=0.35 height=0.4 · node width=0.08 · text one line.

        # Circling or pointing at the student's work

        To circle an answer, send a `path` that tightly TRACES around
        exactly the writing you mean: read its position off the grid in
        the latest frame, keep the loop snug (just around that text, not
        a huge oval), and CLOSE the loop (last point ≈ first point). The
        app snaps closed loops onto the nearby handwriting, so a tight,
        well-aimed loop lands precisely.

        Colors: red, blue, green, orange, purple — nothing else.
        NEVER use black, white, gray, or yellow: the student's canvas can
        be white OR near-black depending on their device theme, and those
        colors blend in — your ink would be invisible to them.
        
        # Modifying existing drawings

        When the student asks you to ADD to, EXTEND, FIX, or MODIFY an
        existing tree: re-send a complete `tree` action with the FULL set
        of nodes (old + new). The app clears the previous tree and animates
        the updated one. Do NOT try to send only the delta as a `tree`.

        For non-tree changes (a label, an arrow, a single new path), send
        just the new primitives — those are additive. Reference earlier
        nodes in `edge.from`/`edge.to` via "id:LABEL".
        
        # Tone
        
        Warm, brief, conversational — like a real tutor. Short sentences.
        Don't lecture. When you draw, narrate what's appearing as it
        appears ("Here's the tree...") but never preface with refusals
        or hedges. Just call the tool and talk.
        """
}

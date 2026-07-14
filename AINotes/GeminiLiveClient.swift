//
//  GeminiLiveClient.swift
//  AINotes
//
//  Pure protocol layer over Gemini Live's bidirectional WebSocket.
//  Owns the connection and routes inbound server messages to typed
//  callbacks. Doesn't know about audio capture / playback / drawings —
//  LiveSession does that wiring.
//
//  Protocol reference: ai.google.dev/api/live (May 2026)
//

import Foundation

@MainActor
@Observable
final class GeminiLiveClient {

    enum Status: Equatable {
        case disconnected
        case connecting
        case ready             // setupComplete received; safe to stream
        case error(String)
    }

    // MARK: - Public state & callbacks

    private(set) var status: Status = .disconnected

    /// Fires when the server confirms setup; safe to begin streaming now.
    var onReady: (() -> Void)?
    /// 24kHz mono Int16 PCM chunk to play (little-endian).
    var onAudioChunk: ((Data) -> Void)?
    /// Optional output transcript (only if outputAudioTranscription enabled).
    var onTranscriptDelta: ((String) -> Void)?
    /// Server told us the user interrupted the model; flush playback.
    var onInterrupted: (() -> Void)?
    /// Model finished its turn.
    var onTurnComplete: (() -> Void)?
    /// Tool call from the model. Respond with `sendToolResponse(...)`.
    var onToolCall: ((ToolCall) -> Void)?
    /// Connection failed or closed unexpectedly.
    var onClosed: ((String?) -> Void)?

    // MARK: - Internal

    private var task: URLSessionWebSocketTask?
    private var session: URLSession?
    private var receiveLoopTask: Task<Void, Never>?
    private var sendTail: Task<Void, Never>?

    // Endpoint per ai.google.dev/api/live (v1beta).
    private let endpoint =
        "wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent"

    // MARK: - Public API

    func connect(apiKey: String, setup: SetupConfig) {
        // Reconnectable from .disconnected and any .error. (The old guard
        // compared against .error("") which never matches a real error
        // message, so a client that had errored could never reconnect.)
        switch status {
        case .connecting, .ready: return
        case .disconnected, .error: break
        }
        status = .connecting

        guard var comps = URLComponents(string: endpoint) else {
            status = .error("Bad endpoint URL"); return
        }
        comps.queryItems = [URLQueryItem(name: "key", value: apiKey)]
        guard let url = comps.url else {
            status = .error("Bad endpoint URL"); return
        }

        let config = URLSessionConfiguration.default
        let s = URLSession(configuration: config)
        session = s
        let t = s.webSocketTask(with: url)
        task = t
        t.resume()

        // Kick off receive loop and send the setup payload immediately.
        receiveLoopTask = Task { [weak self] in await self?.receiveLoop() }
        send(["setup": setup.payload])
    }

    func disconnect() {
        receiveLoopTask?.cancel()
        sendTail?.cancel()
        sendTail = nil
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        session?.invalidateAndCancel()
        session = nil
        status = .disconnected
        // Drop every callback: nothing from this dead session may call
        // back into its old owner. start() re-wires fresh closures before
        // the next connect().
        onReady = nil
        onAudioChunk = nil
        onTranscriptDelta = nil
        onInterrupted = nil
        onTurnComplete = nil
        onToolCall = nil
        onClosed = nil
    }

    /// Send a chunk of mic PCM (16kHz, mono, Int16, little-endian).
    func sendAudio(_ pcm: Data) {
        send([
            "realtimeInput": [
                "audio": [
                    "data": pcm.base64EncodedString(),
                    "mimeType": "audio/pcm;rate=16000"
                ]
            ]
        ])
    }

    /// Send a single JPEG frame as part of the live video stream.
    /// Keep frames small (~1024px longest side): the server silently
    /// DROPS oversized frames — the socket stays open, no error comes
    /// back, and the model just says it can't see the screen.
    func sendVideoFrame(_ jpeg: Data) {
        send([
            "realtimeInput": [
                "video": [
                    "data": jpeg.base64EncodedString(),
                    "mimeType": "image/jpeg"
                ]
            ]
        ])
    }

    /// Send a text message via the realtime input channel.
    func sendText(_ text: String) {
        send([
            "realtimeInput": ["text": text]
        ])
    }

    /// Respond to a tool call. `result` becomes the `response` field;
    /// keep it small — the model reads it back.
    func sendToolResponse(callID: String, name: String, result: [String: Any]) {
        send([
            "toolResponse": [
                "functionResponses": [[
                    "id": callID,
                    "name": name,
                    "response": result
                ]]
            ]
        ])
    }

    // MARK: - Sending

    /// All outbound messages funnel through here, chained one behind the
    /// other. A bare `Task { await task.send(...) }` per message gives no
    /// ordering guarantee — consecutive mic chunks could hit the wire out
    /// of order and garble the audio stream the model hears.
    private func send(_ obj: [String: Any]) {
        guard let task else { return }
        let prev = sendTail
        sendTail = Task { [weak self] in
            await prev?.value
            guard !Task.isCancelled else { return }
            do {
                let data = try JSONSerialization.data(withJSONObject: obj, options: [])
                guard let str = String(data: data, encoding: .utf8) else { return }
                try await task.send(.string(str))
            } catch {
                // Only report if this is still the CURRENT socket — after a
                // deliberate disconnect(), in-flight sends fail on the old
                // task and must not flip a fresh/idle session into .error.
                guard let self, self.task === task, !Task.isCancelled else { return }
                self.status = .error("Send failed: \(error.localizedDescription)")
                self.onClosed?("Send failed: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Receive loop

    private func receiveLoop() async {
        while !Task.isCancelled, let task {
            do {
                let msg = try await task.receive()
                let payload: Data?
                switch msg {
                case .string(let s): payload = s.data(using: .utf8)
                case .data(let d):   payload = d
                @unknown default:    payload = nil
                }
                guard let payload,
                      let json = try? JSONSerialization.jsonObject(with: payload) as? [String: Any]
                else { continue }
                handleServerMessage(json)
            } catch {
                if !Task.isCancelled {
                    status = .error("Receive failed: \(error.localizedDescription)")
                    onClosed?(error.localizedDescription)
                }
                return
            }
        }
    }

    private func handleServerMessage(_ json: [String: Any]) {
        if json["setupComplete"] != nil {
            status = .ready
            onReady?()
            return
        }
        if let serverContent = json["serverContent"] as? [String: Any] {
            handleServerContent(serverContent)
        }
        if let toolCall = json["toolCall"] as? [String: Any] {
            handleToolCall(toolCall)
        }
        // toolCallCancellation / goAway / sessionResumptionUpdate ignored for now.
    }

    private func handleServerContent(_ sc: [String: Any]) {
        // Interrupted: user spoke; flush local playback.
        if let interrupted = sc["interrupted"] as? Bool, interrupted {
            onInterrupted?()
        }
        if let turn = sc["modelTurn"] as? [String: Any],
           let parts = turn["parts"] as? [[String: Any]] {
            for part in parts {
                // Audio chunk.
                if let inline = part["inlineData"] as? [String: Any],
                   let mime = inline["mimeType"] as? String,
                   mime.hasPrefix("audio/pcm"),
                   let dataStr = inline["data"] as? String,
                   let data = Data(base64Encoded: dataStr) {
                    onAudioChunk?(data)
                }
                // NOTE: modelTurn text parts are deliberately NOT appended
                // to the transcript — outputAudioTranscription is always on
                // in our setup, and appending both duplicates the text.
            }
        }
        // Output transcription as a separate top-level field on serverContent.
        if let outTr = sc["outputTranscription"] as? [String: Any],
           let txt = outTr["text"] as? String {
            onTranscriptDelta?(txt)
        }
        if let done = sc["turnComplete"] as? Bool, done {
            onTurnComplete?()
        }
    }

    private func handleToolCall(_ tc: [String: Any]) {
        guard let calls = tc["functionCalls"] as? [[String: Any]] else { return }
        for call in calls {
            let id   = (call["id"]   as? String) ?? ""
            let name = (call["name"] as? String) ?? ""
            let args = (call["args"] as? [String: Any]) ?? [:]
            onToolCall?(ToolCall(id: id, name: name, args: args))
        }
    }
}

// MARK: - Setup + tool types

struct ToolCall {
    let id: String
    let name: String
    let args: [String: Any]
}

/// Holds the JSON payload sent in the very first message of a session.
/// Built via `SetupConfig.default(...)`; not Codable because Gemini's
/// schema accepts arbitrary nested dicts (function declarations etc.).
struct SetupConfig {
    let payload: [String: Any]

    /// Standard configuration for the tutor: audio in/out, video in, one
    /// `draw` tool wired to our DrawingActionDTO schema. Output
    /// transcription on so we can show what the model is saying.
    static func tutor(systemInstruction: String) -> SetupConfig {
        let payload: [String: Any] = [
            "model": "models/gemini-3.1-flash-live-preview",
            "generationConfig": [
                "responseModalities": ["AUDIO"],
                "speechConfig": [
                    "voiceConfig": [
                        "prebuiltVoiceConfig": ["voiceName": "Aoede"]
                    ]
                ]
            ],
            "systemInstruction": [
                "parts": [["text": systemInstruction]]
            ],
            "outputAudioTranscription": [:],
            // Without this the server hard-caps the connection at ~10
            // minutes; with a sliding window it compresses old context and
            // keeps a long tutoring session alive. Verified live.
            "contextWindowCompression": ["slidingWindow": [:]],
            // Tune server-side voice activity detection: less trigger-happy
            // start-of-speech (residual speaker echo used to read as the
            // user barging in, so the model interrupted itself constantly)
            // and a slightly longer silence before end-of-turn. Field names
            // verified live against the v1beta endpoint.
            "realtimeInputConfig": [
                "automaticActivityDetection": [
                    "startOfSpeechSensitivity": "START_SENSITIVITY_LOW",
                    // Less eager end-of-speech: a student pausing mid-
                    // question used to get answered twice (once for each
                    // half), which read as "queued duplicate responses".
                    "endOfSpeechSensitivity": "END_SENSITIVITY_LOW",
                    "prefixPaddingMs": 200,
                    "silenceDurationMs": 1000
                ]
            ],
            "tools": [[
                "functionDeclarations": [drawFunctionDeclaration]
            ]]
        ]
        return SetupConfig(payload: payload)
    }

    /// JSON-Schema declaration for the `draw` tool. Matches DrawingActionDTO.
    private static let drawFunctionDeclaration: [String: Any] = [
        "name": "draw",
        "description": """
            Draw on the student's canvas to visualize concepts, recreate \
            diagrams, or sketch examples. Call this whenever showing a \
            picture would help more than describing it in words — trees, \
            graphs, labeled diagrams, equations, free-form sketches, or \
            circling part of the student's work (closed path loops snap \
            onto the handwriting they surround — trace tightly around \
            exactly what you mean). Coordinates are fractions of the \
            visible canvas (0,0 top-left, 1,1 bottom-right). Place new \
            content in EMPTY space, never over existing writing.
            """,
        "parameters": [
            "type": "object",
            "properties": [
                "drawings": [
                    "type": "array",
                    "description": "One or more drawing actions to perform in order.",
                    "items": [
                        "type": "object",
                        "properties": [
                            "type": [
                                "type": "string",
                                "enum": ["path", "text", "node", "edge", "tree"],
                                "description": "Which primitive this is."
                            ],
                            "x": ["type": "number", "description": "Fractional x (0-1)."],
                            "y": ["type": "number", "description": "Fractional y (0-1)."],
                            "width": ["type": "number"],
                            "height": ["type": "number"],
                            // No black/white/gray (blend into the canvas in
                            // light or dark mode) and no yellow (unreadable
                            // on the white snapshot the model sees).
                            "color": [
                                "type": "string",
                                "enum": ["red","blue","green","orange","purple"]
                            ],
                            "text": ["type": "string"],
                            "points": [
                                "type": "array",
                                "items": [
                                    "type": "array",
                                    "items": ["type": "number"]
                                ]
                            ],
                            "from": ["type": "string"],
                            "to":   ["type": "string"],
                            "arrowhead": ["type": "boolean"],
                            "nodes": [
                                "type": "array",
                                "items": [
                                    "type": "object",
                                    "properties": [
                                        "id":     ["type": "string"],
                                        "label":  ["type": "string"],
                                        "parent": ["type": "string"],
                                        "side": [
                                            "type": "string",
                                            "enum": ["left", "right"],
                                            "description": "For binary trees: which side of the parent this child sits on. REQUIRED whenever a parent might have only one child — without it, the layout cannot tell which way a single child branches and collapses the whole chain into a vertical line."
                                        ]
                                    ],
                                    "required": ["id", "label"]
                                ]
                            ]
                        ],
                        "required": ["type"]
                    ]
                ]
            ],
            "required": ["drawings"]
        ]
    ]
}

//
//  LLMClient.swift
//  AINotes
//
import Foundation
import UIKit

enum LLMError: Error, LocalizedError {
    case badImage
    case http(Int, String)
    case decoding(String)

    var errorDescription: String? {
        switch self {
        case .badImage: return "Couldn't encode the canvas image."
        case .http(let code, let body): return "API error \(code): \(body)"
        case .decoding(let msg): return "Couldn't read the response: \(msg)"
        }
    }
}

struct TutorResponse {
    let reply: String
    let annotations: [AnnotationDTO]
}

struct LLMClient {
    let model = "claude-sonnet-4-5"

    func askAboutCanvas(image: UIImage,
                        userQuestion: String,
                        history: [TutorMessage]) async throws -> TutorResponse {
        guard let jpegData = image.jpegData(compressionQuality: 0.8) else {
            throw LLMError.badImage
        }
        let base64Image = jpegData.base64EncodedString()

        let systemPrompt = """
            You are a friendly, patient AI tutor helping a student taking \
            handwritten notes on an iPad. You are shown a screenshot of their \
            current page.

            COORDINATE GRID: a faint blue grid is drawn over the image. \
            Gridlines appear every 0.1. Numbers along the TOP edge label the x \
            value of each vertical line (0.0 far left, 1.0 far right). Numbers \
            along the LEFT edge label the y value of each horizontal line (0.0 \
            top, 1.0 bottom). Read coordinates off this grid by interpolating \
            between the nearest labelled lines. The grid is only a guide and is \
            NOT on the student's real page.

            IMPORTANT: for circle and highlight, your box does NOT need to be \
                        tight or perfectly centered. The app automatically snaps it to the \
                        exact pixels of the student's handwriting. Just make a box that \
                        clearly OVERLAPS the target item and is not so large it also covers \
                        neighboring items. Prioritize selecting the RIGHT item over precise \
                        sizing.

                        Actions (coordinates are grid fractions):
                        - circle:    {"type":"circle","x","y","width","height","color"} \
                          x,y = top-left of a box that overlaps the target.
                        - highlight: {"type":"highlight","x","y","width","height","color"} \
                          x,y = top-left of a box that overlaps the target.
                        - arrow:     {"type":"arrow","x1","y1","x2","y2","color"} \
                          arrowhead at x2,y2 points AT the target; start the tail in \
                          nearby empty space.
                        - write:     {"type":"write","x","y","text","color"} \
                          x,y = top-left in EMPTY space near the relevant work, not over \
                          it. Keep text very short.
                        Colors: red, blue, green, orange, yellow, purple, black.
            
            RESPOND WITH ONE JSON OBJECT AND NOTHING ELSE. No markdown, no \
            backticks, no text outside the JSON. Shape:
            {"reply": "<plain-text tutor reply, under ~120 words>", \
             "annotations": [ ...zero or more actions... ]}
            If no marks would help, use an empty annotations array. Do not \
            mention the grid in your reply.
            """

        var apiMessages: [[String: Any]] = history.map { msg in
            ["role": msg.role == .user ? "user" : "assistant",
             "content": msg.text]
        }

        var currentContent: [[String: Any]] = [
            ["type": "image",
             "source": ["type": "base64",
                        "media_type": "image/jpeg",
                        "data": base64Image]]
        ]
        let questionText = userQuestion
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !questionText.isEmpty {
            currentContent.append(["type": "text", "text": questionText])
        } else {
            currentContent.append([
                "type": "text",
                "text": "Here's my current note. What am I working on, and how can I improve or extend it?"
            ])
        }
        apiMessages.append(["role": "user", "content": currentContent])

        let body: [String: Any] = [
            "model": model,
            "max_tokens": 1024,
            "system": systemPrompt,
            "messages": apiMessages
        ]

        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(Secrets.anthropicAPIKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw LLMError.decoding("No HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            let bodyText = String(data: data, encoding: .utf8) ?? "(no body)"
            throw LLMError.http(http.statusCode, bodyText)
        }

        guard
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let contentArr = json["content"] as? [[String: Any]]
        else {
            throw LLMError.decoding("Unexpected top-level shape")
        }
        let rawText = contentArr
            .compactMap { $0["text"] as? String }
            .joined(separator: "\n")
        if rawText.isEmpty {
            throw LLMError.decoding("No text in response")
        }

        return parse(rawText)
    }

    private func parse(_ raw: String) -> TutorResponse {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("```") {
            s = s.replacingOccurrences(of: "```json", with: "")
                 .replacingOccurrences(of: "```", with: "")
                 .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let first = s.firstIndex(of: "{"),
           let last = s.lastIndex(of: "}") {
            s = String(s[first...last])
        }

        struct Raw: Decodable {
            let reply: String
            let annotations: [AnnotationDTO]?
        }
        if let d = s.data(using: .utf8),
           let parsed = try? JSONDecoder().decode(Raw.self, from: d) {
            return TutorResponse(reply: parsed.reply,
                                 annotations: parsed.annotations ?? [])
        }
        return TutorResponse(reply: raw, annotations: [])
    }
}

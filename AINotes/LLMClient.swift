//
//  LLMClient.swift
//  AINotes
//
//  Created by 落 on 2026-05-15.
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

struct LLMClient {
    // Update this when Anthropic ships newer Sonnet/Opus revs.
    // Sonnet 4.5 is the current solid choice for vision + reasoning as of mid-2026.
    let model = "claude-sonnet-4-5"

    func askAboutCanvas(image: UIImage, userQuestion: String, history: [TutorMessage]) async throws -> String {
        // 1. Encode image as base64 JPEG (smaller payload than PNG, plenty for handwriting).
        guard let jpegData = image.jpegData(compressionQuality: 0.8) else {
            throw LLMError.badImage
        }
        let base64Image = jpegData.base64EncodedString()

        // 2. Build the messages array.
        //    System prompt steers Claude to act like a tutor.
        let systemPrompt = """
            You are a friendly, patient AI tutor helping a student who is taking handwritten notes \
            on an iPad. You will be shown a screenshot of their current note page. Read what they've \
            written or drawn, and:
            - If they asked a question, answer it clearly with relevant context from the page.
            - If they didn't ask anything specific, briefly identify what they're working on and offer \
              one concrete next step or a small check-for-understanding question.
            Be concise. Use plain text (no markdown formatting). Keep responses under ~150 words \
            unless the student asks for more detail.
            """

        // Build prior turns as plain-text history (no images on past turns to save tokens).
        var apiMessages: [[String: Any]] = history.map { msg in
            [
                "role": msg.role == .user ? "user" : "assistant",
                "content": msg.text
            ]
        }

        // Current turn: image + (optional) text question.
        var currentContent: [[String: Any]] = [
            [
                "type": "image",
                "source": [
                    "type": "base64",
                    "media_type": "image/jpeg",
                    "data": base64Image
                ]
            ]
        ]
        let questionText = userQuestion.trimmingCharacters(in: .whitespacesAndNewlines)
        if !questionText.isEmpty {
            currentContent.append(["type": "text", "text": questionText])
        } else {
            currentContent.append([
                "type": "text",
                "text": "Here's my current note. What am I working on, and how can I improve or extend it?"
            ])
        }
        apiMessages.append(["role": "user", "content": currentContent])

        // 3. Build the request.
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

        // 4. Send and parse.
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw LLMError.decoding("No HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            let bodyText = String(data: data, encoding: .utf8) ?? "(no body)"
            throw LLMError.http(http.statusCode, bodyText)
        }

        // Anthropic response shape:
        // { "content": [ { "type": "text", "text": "..." }, ... ], ... }
        guard
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let contentArr = json["content"] as? [[String: Any]]
        else {
            throw LLMError.decoding("Unexpected top-level shape")
        }
        let text = contentArr
            .compactMap { $0["text"] as? String }
            .joined(separator: "\n")
        if text.isEmpty {
            throw LLMError.decoding("No text in response")
        }
        return text
    }
}

//
//  TutorPanel.swift
//  AINotes
//
//  Created by 落 on 2026-05-15.
//
import SwiftUI
import PencilKit

@MainActor
@Observable
final class TutorViewModel {
    var messages: [TutorMessage] = []
    var isLoading: Bool = false
    var errorText: String?

    private let client = LLMClient()

    func askAboutCanvas(image: UIImage, userQuestion: String) async {
        isLoading = true
        errorText = nil
        defer { isLoading = false }

        // Show the user's turn immediately for snappy UX.
        let userText = userQuestion.isEmpty ? "(Screenshot sent)" : userQuestion
        messages.append(.init(role: .user, text: userText))

        // Pass conversation history *excluding* the just-appended user turn,
        // since the API call adds the current turn itself.
        let history = Array(messages.dropLast())

        do {
            let reply = try await client.askAboutCanvas(
                image: image,
                userQuestion: userQuestion,
                history: history
            )
            messages.append(.init(role: .assistant, text: reply))
        } catch {
            errorText = error.localizedDescription
        }
    }}

struct TutorMessage: Identifiable {
    enum Role { case user, assistant }
    let id = UUID()
    let role: Role
    let text: String
}

struct TutorPanel: View {
    let captureSnapshot: () -> UIImage?
    @State private var vm = TutorViewModel()
    @State private var userInput: String = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Messages
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 12) {
                            ForEach(vm.messages) { msg in
                                MessageBubble(message: msg).id(msg.id)
                            }
                            if vm.isLoading {
                                HStack(spacing: 8) {
                                    ProgressView()
                                    Text("Thinking…").foregroundStyle(.secondary)
                                }
                                .padding(.horizontal)
                            }
                            if let err = vm.errorText {
                                Text(err)
                                    .foregroundStyle(.red)
                                    .padding(.horizontal)
                            }
                        }
                        .padding(.vertical)
                    }
                    .onChange(of: vm.messages.count) { _, _ in
                        if let last = vm.messages.last {
                            withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                        }
                    }
                }

                Divider()

                // Input row
                HStack(spacing: 8) {
                    TextField("Ask a question (optional)", text: $userInput, axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                        .lineLimit(1...4)

                    Button {
                        sendSnapshot()
                    } label: {
                        Label("Screenshot", systemImage: "camera.viewfinder")
                            .labelStyle(.iconOnly)
                            .font(.title2)
                            .padding(8)
                            .background(.tint, in: Circle())
                            .foregroundStyle(.white)
                    }
                    .disabled(vm.isLoading)
                }
                .padding()
            }
            .navigationTitle("AI Tutor")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
    }

    private func sendSnapshot() {
        guard let image = captureSnapshot() else {
            vm.errorText = "Couldn't capture the canvas."
            return
        }
        let question = userInput
        userInput = ""
        Task { await vm.askAboutCanvas(image: image, userQuestion: question) }
    }
}

private struct MessageBubble: View {
    let message: TutorMessage
    var body: some View {
        HStack {
            if message.role == .assistant {
                Text(message.text)
                    .padding(10)
                    .background(.gray.opacity(0.15), in: RoundedRectangle(cornerRadius: 12))
                Spacer(minLength: 40)
            } else {
                Spacer(minLength: 40)
                Text(message.text)
                    .padding(10)
                    .foregroundStyle(.white)
                    .background(.tint, in: RoundedRectangle(cornerRadius: 12))
            }
        }
        .padding(.horizontal)
    }
}


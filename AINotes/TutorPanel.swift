//
//  TutorPanel.swift
//  AINotes
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

    func askAboutCanvas(image: UIImage,
                        userQuestion: String) async -> [AnnotationDTO]? {
        isLoading = true
        errorText = nil
        defer { isLoading = false }

        let userText = userQuestion.isEmpty ? "(Screenshot sent)" : userQuestion
        messages.append(.init(role: .user, text: userText))

        let history = Array(messages.dropLast())

        do {
            let result = try await client.askAboutCanvas(
                image: image,
                userQuestion: userQuestion,
                history: history
            )
            messages.append(.init(role: .assistant, text: result.reply))
            return result.annotations
        } catch {
            errorText = error.localizedDescription
            return nil
        }
    }
}

struct TutorMessage: Identifiable, Codable {
    enum Role: String, Codable { case user, assistant }
    let id = UUID()
    let role: Role
    let text: String

    // `id` is in-memory identity for SwiftUI's ForEach, not saved data.
    // Excluding it from CodingKeys silences the warning and stops a
    // saved id from being (pointlessly) re-generated on decode.
    private enum CodingKeys: String, CodingKey {
        case role, text
    }
}

struct TutorPanel: View {
    let captureSnapshot: () -> CanvasSnapshot?
    let onAnnotations: ([AnnotationDTO], CGRect) -> Void
    // Persisted thread for this page, and a way to report changes back.
    let initialMessages: [TutorMessage]
    let onMessagesChanged: ([TutorMessage]) -> Void

    @State private var vm = TutorViewModel()
    @State private var userInput: String = ""
    @State private var didSeed = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
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

                VStack(spacing: 4) {
                    HStack(spacing: 8) {
                        TextField("Ask a question (optional)",
                                  text: $userInput, axis: .vertical)
                            .textFieldStyle(.roundedBorder)
                            .lineLimit(1...4)
                            .submitLabel(.send)
                            .onSubmit { sendSnapshot() }

                        Button {
                            sendSnapshot()
                        } label: {
                            Image(systemName: "arrow.up.circle.fill")
                                .font(.system(size: 32))
                                .foregroundStyle(vm.isLoading ? Color.gray : Color.accentColor)
                        }
                        .disabled(vm.isLoading)
                    }
                    Text("Send captures a fresh screenshot with your question.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
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
            // Load the saved thread the first time the sheet opens.
            .onAppear {
                if !didSeed {
                    vm.messages = initialMessages
                    didSeed = true
                }
            }
            // Persist whenever a turn is added (messages only ever append).
            .onChange(of: vm.messages.count) { _, _ in
                if didSeed { onMessagesChanged(vm.messages) }
            }
        }
    }

    private func sendSnapshot() {
        guard !vm.isLoading else { return }
        guard let snap = captureSnapshot() else {
            vm.errorText = "Couldn't capture the canvas."
            return
        }
        let question = userInput
        userInput = ""
        Task {
            if let anns = await vm.askAboutCanvas(image: snap.image,
                                                  userQuestion: question) {
                onAnnotations(anns, snap.bounds)
            }
        }
    }
}

private struct MessageBubble: View {
    let message: TutorMessage
    var body: some View {
        HStack {
            if message.role == .assistant {
                Text(message.text)
                    .padding(10)
                    .background(.gray.opacity(0.15),
                                in: RoundedRectangle(cornerRadius: 12))
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

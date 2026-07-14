//
//  TutorPanel.swift
//  AINotes
//
//  Live-session UI. One big Start/Stop button, a status indicator, and
//  an optional rolling transcript of what the model is saying. No more
//  mic button, no more send button — opening this sheet IS the
//  screensharing session.
//

import SwiftUI

struct TutorPanel: View {
    let captureSnapshot: () -> UIImage?
    let canvasBounds: () -> CGRect
    let onDrawAction: ([DrawingActionDTO], CGRect) -> Void


    let session: LiveSession
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Spacer()

                statusIndicator
                    .frame(height: 120)

                transcriptArea

                // Live proof that screen share is working: the exact last
                // frame shipped to the model, plus send/tool counters.
                if isLive || session.framesSent > 0 {
                    lastFramePreview
                }

                Spacer()

                primaryButton

                Text(captionText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 24)
            }
            .padding(.horizontal, 24)
            .navigationTitle("AI Tutor")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") {
                        dismiss()
                    }
                }
            }
            .onAppear {
                session.snapshotProvider = captureSnapshot
                session.canvasBoundsProvider = canvasBounds
                session.onDrawAction = onDrawAction
            }
        }
    }

    // MARK: - Subviews

    private var statusIndicator: some View {
        ZStack {
            Circle()
                .fill(circleColor.opacity(0.18))
                .frame(width: 120, height: 120)
                .scaleEffect(isLive ? 1.1 : 1.0)
                .animation(
                    isLive
                        ? .easeInOut(duration: 1.0).repeatForever(autoreverses: true)
                        : .default,
                    value: isLive
                )
            Image(systemName: iconName)
                .font(.system(size: 44, weight: .regular))
                .foregroundStyle(circleColor)
        }
    }


    private var transcriptArea: some View {
        ScrollViewReader { proxy in
            ScrollView {
                Text(session.transcript.isEmpty ? " " : session.transcript)
                    .font(.body)
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 4)
                    .id("transcriptEnd")
                    .onChange(of: session.transcript) { _, _ in
                        proxy.scrollTo("transcriptEnd", anchor: .bottom)
                    }
            }
            .frame(maxHeight: 220)
            .background(.gray.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
        }
    }

    private var primaryButton: some View {
        Button {
            toggleSession()
        } label: {
            HStack(spacing: 10) {
                Image(systemName: isLive ? "stop.circle.fill" : "play.circle.fill")
                    .font(.system(size: 22))
                Text(isLive ? "End Session" : "Start Live Session")
                    .font(.headline)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity)
            .background(isLive ? Color.red : Color.accentColor, in: Capsule())
            .foregroundStyle(.white)
        }
        .disabled(isStarting)
    }

    // MARK: - Derived

    private var isLive: Bool {
        if case .live = session.state { return true }
        return false
    }
    private var isStarting: Bool {
        if case .starting = session.state { return true }
        return false
    }

    private var iconName: String {
        switch session.state {
        case .idle:       return "mic.slash"
        case .starting:   return "ellipsis"
        case .live:       return "waveform"
        case .error:      return "exclamationmark.triangle"
        }
    }
    private var circleColor: Color {
        switch session.state {
        case .idle:       return .gray
        case .starting:   return .orange
        case .live:       return .accentColor
        case .error:      return .red
        }
    }
    private var captionText: String {
        switch session.state {
        case .idle:
            return "Tap Start to begin a live conversation. The tutor will see your canvas and hear you."
        case .starting:
            return "Connecting…"
        case .live:
            return "Live. The tutor can see and hear you. Speak naturally."
        case .error(let m):
            return m
        }
    }

    private func toggleSession() {
        if isLive {
            session.stop()
        } else if !isStarting {
            // Works from .idle and from .error (retry after a failure).
            session.start(apiKey: Secrets.geminiAPIKey)
        }
    }
    private var lastFramePreview: some View {
        VStack(spacing: 4) {
            if let img = session.lastFrameSent {
                Image(uiImage: img)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxHeight: 120)
                    .overlay(RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.gray.opacity(0.4), lineWidth: 1))
            } else {
                Text("No frames sent yet")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(maxHeight: 120)
            }
            Text("Frames: \(session.framesSent)  ·  Tools: \(session.toolCallsReceived)  ·  Extracted: \(session.drawingsExtracted)  ·  Drew: \(session.drawingsDispatched)")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
    }
}

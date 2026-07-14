//
//  LiveAudioEngine.swift
//  AINotes
//
//  ONE AVAudioEngine for both mic capture and model-voice playback.
//  Sharing a single engine matters: with voice processing enabled on the
//  input node, the engine's own output is the echo-cancellation reference,
//  so the model's voice is subtracted from the mic signal before it ever
//  reaches us. (The previous design used two engines — the capture engine
//  couldn't cancel what the playback engine was emitting, so Gemini heard
//  its own voice through the mic, read it as the user barging in, and
//  restarted the same sentence over and over.)
//
//  Mic side: taps the input node at hardware format, converts to 16kHz
//  mono Int16 — what Gemini Live expects on realtimeInput.audio.
//  Speaker side: schedules 24kHz mono Int16 chunks from the server on an
//  AVAudioPlayerNode; the mixer converts to the hardware format.
//

import Foundation
@preconcurrency import AVFoundation

@MainActor
final class LiveAudioEngine {

    /// Called on the main actor with one chunk of 16kHz Int16 mono PCM.
    var onPCMChunk: ((Data) -> Void)?

    private let engine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private var playbackFormat: AVAudioFormat?
    private(set) var isRunning = false

    // Playback bookkeeping for the mic gate.
    private var pendingBuffers = 0
    private var lastPlaybackEndedAt: CFAbsoluteTime = 0
    /// Bumped on every flush/stop. Completion handlers of already-scheduled
    /// buffers capture the generation they were scheduled under; stale ones
    /// (fired en masse by playerNode.stop() during a flush) must not
    /// decrement the counter that now belongs to the NEXT utterance.
    private var playbackGeneration = 0
    private var observers: [NSObjectProtocol] = []
    /// Extra time after the last buffer audibly finishes during which
    /// playback still counts as "active". Covers room reverb, residual
    /// output latency, AND the ~100ms of already-recorded speaker audio
    /// sitting in the next mic tap buffer — 0.4s proved too short on
    /// device (echo tails tripped the server VAD into re-answering).
    private let playbackHangover: CFTimeInterval = 0.75

    /// True while the model's voice is (or was just) coming out of the
    /// speaker. LiveSession uses this to gate mic uploads.
    var isPlaybackActive: Bool {
        pendingBuffers > 0 ||
            (CFAbsoluteTimeGetCurrent() - lastPlaybackEndedAt) < playbackHangover
    }

    func start() throws {
        guard !isRunning else { return }

        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord,
                                mode: .voiceChat,
                                options: [.defaultToSpeaker, .allowBluetoothHFP])
        try session.setActive(true, options: [])

        // Hardware echo cancellation. Must be set before the engine starts:
        // it swaps the engine's I/O unit for the voice-processing unit that
        // subtracts this engine's own output from the mic signal. `try?`
        // because some routes (odd external hardware) can refuse — the mic
        // gate in LiveSession still covers us if it does.
        if !engine.inputNode.isVoiceProcessingEnabled {
            try? engine.inputNode.setVoiceProcessingEnabled(true)
        }

        // Playback graph: 24kHz mono Int16 in; the mixer resamples to hardware.
        guard let outFormat = AVAudioFormat(commonFormat: .pcmFormatInt16,
                                            sampleRate: 24_000,
                                            channels: 1,
                                            interleaved: true) else {
            throw NSError(domain: "LiveAudioEngine", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Couldn't build playback format"])
        }
        playbackFormat = outFormat
        engine.attach(playerNode)
        engine.connect(playerNode, to: engine.mainMixerNode, format: outFormat)

        // Capture graph: tap at hardware format (read AFTER enabling voice
        // processing — it can change the input format), convert to 16k Int16.
        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0 else {
            throw NSError(domain: "LiveAudioEngine", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "No mic input available"])
        }
        guard let target = AVAudioFormat(commonFormat: .pcmFormatInt16,
                                         sampleRate: 16_000,
                                         channels: 1,
                                         interleaved: true),
              let converter = AVAudioConverter(from: inputFormat, to: target) else {
            throw NSError(domain: "LiveAudioEngine", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "Couldn't build mic converter"])
        }

        // The tap fires on a realtime audio thread. Convert right there
        // (the converter is only ever touched on that serial tap queue),
        // then hand the bytes to the main actor. DispatchQueue.main
        // preserves FIFO order — spawning a Task per buffer does not, and
        // out-of-order mic chunks garble what the model hears.
        input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
            guard let data = Self.convert(buffer: buffer, with: converter, to: target) else { return }
            DispatchQueue.main.async { self?.onPCMChunk?(data) }
        }

        engine.prepare()
        try engine.start()
        playerNode.play()
        isRunning = true
        installObservers()
    }

    func stop() {
        guard isRunning else { return }
        removeObservers()
        engine.inputNode.removeTap(onBus: 0)
        playerNode.stop()
        engine.stop()
        engine.detach(playerNode)
        playbackGeneration += 1
        pendingBuffers = 0
        lastPlaybackEndedAt = 0
        isRunning = false
        // Leave the audio session active; deactivating here can clobber
        // other audio. iOS reclaims it when the app goes inactive.
    }

    /// Route changes (AirPods in/out) and interruptions (phone call) stop
    /// the engine and can change hardware formats under our feet — the
    /// mic converter and tap are frozen at start(). Tear down and rebuild.
    private func installObservers() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.restart() }
        })
        observers.append(center.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: nil, queue: .main
        ) { [weak self] note in
            let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            guard raw == AVAudioSession.InterruptionType.ended.rawValue else { return }
            MainActor.assumeIsolated { self?.restart() }
        })
    }

    private func removeObservers() {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers = []
    }

    private func restart() {
        guard isRunning else { return }
        let handler = onPCMChunk
        stop()
        onPCMChunk = handler
        try? start()
    }

    // MARK: - Playback

    /// Queue a chunk of 24kHz Int16 mono PCM from the server. The player
    /// node plays scheduled buffers back-to-back, so no explicit queue is
    /// needed and chunks can never overlap.
    func enqueue(_ pcm: Data) {
        guard isRunning, let format = playbackFormat else { return }

        let frameCount = AVAudioFrameCount(pcm.count / MemoryLayout<Int16>.size)
        guard frameCount > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format,
                                            frameCapacity: frameCount) else { return }
        buffer.frameLength = frameCount
        guard let channelData = buffer.int16ChannelData else { return }
        pcm.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            memcpy(channelData[0], base, pcm.count)
        }

        pendingBuffers += 1
        let generation = playbackGeneration
        // .dataPlayedBack fires when the audio has actually left the
        // speaker (output latency included), unlike the legacy callback
        // which fires when the buffer is merely consumed by the node.
        // That difference is exactly the window that used to reopen the
        // mic gate onto the tail of the model's own voice.
        playerNode.scheduleBuffer(buffer, at: nil, options: [],
                                  completionCallbackType: .dataPlayedBack) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                guard self.playbackGeneration == generation else { return }
                self.pendingBuffers = max(0, self.pendingBuffers - 1)
                self.lastPlaybackEndedAt = CFAbsoluteTimeGetCurrent()
            }
        }
    }

    /// Drop all queued playback immediately. Called when the server says
    /// the user interrupted the model (barge-in) — without this, the stale
    /// remainder of the previous utterance keeps playing and the new
    /// response queues behind it, which sounds like two voices talking.
    func flushPlayback() {
        guard isRunning else { return }
        playbackGeneration += 1    // invalidate completions of flushed buffers
        playerNode.stop()          // fires completion handlers for queued buffers
        playerNode.play()
        pendingBuffers = 0
        lastPlaybackEndedAt = CFAbsoluteTimeGetCurrent()
    }

    // MARK: - Capture conversion (runs on the tap's audio thread)

    nonisolated private static func convert(buffer: AVAudioPCMBuffer,
                                            with converter: AVAudioConverter,
                                            to target: AVAudioFormat) -> Data? {
        let ratio = target.sampleRate / buffer.format.sampleRate
        let outCapacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio + 64)
        guard let outBuf = AVAudioPCMBuffer(pcmFormat: target,
                                            frameCapacity: outCapacity) else { return nil }

        var consumed = false
        var error: NSError?
        let status = converter.convert(to: outBuf, error: &error) { _, inputStatus in
            if consumed {
                inputStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            inputStatus.pointee = .haveData
            return buffer
        }

        guard status != .error, outBuf.frameLength > 0,
              let channelData = outBuf.int16ChannelData else { return nil }
        let byteCount = Int(outBuf.frameLength) * MemoryLayout<Int16>.size
        return Data(bytes: channelData[0], count: byteCount)
    }
}

// TranscriptionManager.swift
// Manages AVAudioEngine capture and WhisperKit transcription.

import Foundation
import Combine
import AVFoundation
import CoreAudio
import WhisperKit

@MainActor
final class TranscriptionManager: ObservableObject {

    // MARK: - Published state

    @Published var modelState: ModelState = .notLoaded
    @Published var availableModels: [String] = [
        "openai_whisper-tiny",
        "openai_whisper-base",
        "openai_whisper-small",
        "openai_whisper-medium",
        "openai_whisper-large-v3-v20240930_turbo",
        "openai_whisper-large-v2",
        "openai_whisper-large-v3",
    ]

    // MARK: - Callback

    var onTranscript: (String) -> Void = { _ in }

    // MARK: - Private

    private var whisperKit: WhisperKit?
    private var audioEngine: AVAudioEngine?
    private var systemCapture: SystemAudioCapture?
    private var loopTask: Task<Void, Never>?
    nonisolated(unsafe) private var combinedMode = false

    // Thread-safe sample buffer — accessed from real-time audio callback
    nonisolated(unsafe) private var rawSamples: [Float] = []
    private let samplesLock = NSLock()  // NSLock is Sendable; let constant is safe from any context

    // MARK: - Model loading

    enum ModelState: Equatable {
        case notLoaded
        case loading(String)
        case ready(String)
        case failed(String)
    }

    func loadModel(name: String) async {
        modelState = .loading(name)
        do {
            let config = WhisperKitConfig(
                model: name,
                verbose: false,
                logLevel: .error,
                prewarm: true,
                load: true,
                download: true
            )
            whisperKit = try await WhisperKit(config)
            modelState = .ready(name)
        } catch {
            modelState = .failed(error.localizedDescription)
        }
    }

    // MARK: - Capture

    func startCapture(deviceID: AudioDeviceID?) throws {
        guard let wk = whisperKit else {
            throw CaptureError.modelNotLoaded
        }

        let engine = AVAudioEngine()
        let input = engine.inputNode

        if let deviceID {
            setInputDevice(deviceID, on: input)
        }

        let hwFormat = input.outputFormat(forBus: 0)
        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16_000,
            channels: 1,
            interleaved: false
        ) else { throw CaptureError.formatError }

        guard let converter = AVAudioConverter(from: hwFormat, to: targetFormat) else {
            throw CaptureError.formatError
        }

        input.installTap(onBus: 0, bufferSize: 4096, format: hwFormat) { [weak self] buffer, _ in
            guard let self else { return }
            let samples = self.convertBuffer(buffer, converter: converter, target: targetFormat)
            self.samplesLock.withLock {
                self.rawSamples.append(contentsOf: samples)
            }
        }

        try engine.start()
        audioEngine = engine

        // Pass whisperKit directly so the nonisolated loop doesn't need MainActor hops
        loopTask = Task.detached(priority: .userInitiated) { [weak self] in
            await self?.transcriptionLoop(whisperKit: wk)
        }
    }

    // MARK: - System audio capture (ScreenCaptureKit)

    func startSystemAudioCapture() async throws {
        guard let wk = whisperKit else { throw CaptureError.modelNotLoaded }

        let capture = SystemAudioCapture()
        capture.onSamples = { [weak self] samples in
            guard let self else { return }
            self.samplesLock.withLock { self.rawSamples.append(contentsOf: samples) }
        }
        try await capture.start()
        systemCapture = capture

        loopTask = Task.detached(priority: .userInitiated) { [weak self] in
            await self?.transcriptionLoop(whisperKit: wk)
        }
    }

    // MARK: - Combined capture (microphone + system audio simultaneously)

    func startCombinedCapture(deviceID: AudioDeviceID?) async throws {
        guard let wk = whisperKit else { throw CaptureError.modelNotLoaded }

        // Start microphone
        let engine = AVAudioEngine()
        let input  = engine.inputNode
        if let deviceID { setInputDevice(deviceID, on: input) }

        let hwFormat = input.outputFormat(forBus: 0)
        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16_000, channels: 1, interleaved: false
        ) else { throw CaptureError.formatError }
        guard let converter = AVAudioConverter(from: hwFormat, to: targetFormat) else {
            throw CaptureError.formatError
        }

        input.installTap(onBus: 0, bufferSize: 4096, format: hwFormat) { [weak self] buffer, _ in
            guard let self else { return }
            let samples = self.convertBuffer(buffer, converter: converter, target: targetFormat)
            self.samplesLock.withLock { self.rawSamples.append(contentsOf: samples) }
        }
        try engine.start()
        audioEngine = engine

        // Start system audio
        let capture = SystemAudioCapture()
        capture.onSamples = { [weak self] samples in
            guard let self else { return }
            self.samplesLock.withLock { self.rawSamples.append(contentsOf: samples) }
        }
        try await capture.start()
        systemCapture = capture
        combinedMode = true   // Double-rate buffer: use larger chunks

        loopTask = Task.detached(priority: .userInitiated) { [weak self] in
            await self?.transcriptionLoop(whisperKit: wk)
        }
    }

    func stopCapture() {
        loopTask?.cancel()
        loopTask = nil
        combinedMode = false
        // Microphone path
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        audioEngine = nil
        // System audio path
        systemCapture?.stop()
        systemCapture = nil
        samplesLock.withLock { rawSamples.removeAll() }
    }

    func pause() {
        audioEngine?.pause()
        // System audio has no pause — just stop accumulating (loop still runs but buffer drains)
    }

    func resume() { try? audioEngine?.start() }

    // MARK: - Transcription loop (nonisolated — runs off the main actor)

    nonisolated private func transcriptionLoop(whisperKit: WhisperKit) async {
        // Low-latency streaming: poll often and transcribe short windows so captions
        // trail speech by ~1.5 s instead of 5–10 s.
        //
        // minSamples   — emit as soon as ~1.5 s of audio has accumulated.
        // chunkSamples — catch-up cap; never transcribe more than ~3 s in one pass.
        // In combined mode two streams fill the buffer ~2× faster, so double both.
        let minSamples   = combinedMode ? 48_000 : 24_000  // 1.5 s at 16 kHz
        let chunkSamples = combinedMode ? 96_000 : 48_000  // 3.0 s at 16 kHz

        // Decode options tuned for speed: skip the slow temperature-fallback
        // re-decode loop and drop timestamp/special tokens we don't use.
        var options = DecodingOptions()
        options.temperatureFallbackCount = 0
        options.withoutTimestamps = true
        options.skipSpecialTokens = true

        while !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled else { return }

            let chunk: [Float] = samplesLock.withLock {
                if rawSamples.count >= chunkSamples {
                    let r = Array(rawSamples.prefix(chunkSamples))
                    rawSamples.removeFirst(chunkSamples)
                    return r
                } else if rawSamples.count >= minSamples {
                    let r = rawSamples
                    rawSamples.removeAll()
                    return r
                }
                return []
            }

            guard !chunk.isEmpty else { continue }

            // Skip near-silent windows — Whisper hallucinates ("you you you",
            // [BLANK_AUDIO], [inaudible]) when fed silence or low-level room noise.
            guard Self.hasSpeech(chunk) else { continue }

            do {
                let results = try await whisperKit.transcribe(audioArray: chunk, decodeOptions: options)
                let raw = results
                    .map(\.text)
                    .joined(separator: " ")
                let text = Self.cleanTranscript(raw)

                guard !text.isEmpty else { continue }

                // Hop back to main actor to call the callback
                await MainActor.run { [weak self] in
                    self?.onTranscript(text)
                }
            } catch {
                // Non-fatal: continue loop on transcription error
            }
        }
    }

    // MARK: - Speech detection & output cleanup

    /// Energy gate: returns false for silent / low-level-noise windows so we don't
    /// feed Whisper audio it will hallucinate captions from.
    nonisolated private static func hasSpeech(_ samples: [Float]) -> Bool {
        guard !samples.isEmpty else { return false }
        var sumSquares: Float = 0
        for s in samples { sumSquares += s * s }
        let rms = (sumSquares / Float(samples.count)).squareRoot()
        return rms > 0.005  // ~ -46 dBFS; below this is effectively silence
    }

    /// Strips Whisper's non-speech annotation tokens and collapses repeated-word
    /// hallucinations that slip past the energy gate.
    nonisolated private static func cleanTranscript(_ text: String) -> String {
        var s = text

        // Remove bracketed / parenthesised annotations: [BLANK_AUDIO], [inaudible],
        // (music), *laughs*, etc.
        for pattern in ["\\[[^\\]]*\\]", "\\([^\\)]*\\)", "\\*[^\\*]*\\*"] {
            s = s.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
        }

        // Collapse consecutive duplicate words ("you you you" -> "you").
        s = s.replacingOccurrences(
            of: "\\b(\\w+)(\\s+\\1\\b)+",
            with: "$1",
            options: [.regularExpression, .caseInsensitive]
        )

        // Normalise leftover whitespace.
        s = s.replacingOccurrences(of: "\\s{2,}", with: " ", options: .regularExpression)

        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Audio helpers

    nonisolated private func convertBuffer(
        _ buffer: AVAudioPCMBuffer,
        converter: AVAudioConverter,
        target: AVAudioFormat
    ) -> [Float] {
        let ratio = target.sampleRate / buffer.format.sampleRate
        let outCapacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio + 1)
        guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: outCapacity) else { return [] }

        var done = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            guard !done else { status.pointee = .noDataNow; return nil }
            done = true
            status.pointee = .haveData
            return buffer
        }
        guard error == nil, let data = output.floatChannelData else { return [] }
        return Array(UnsafeBufferPointer(start: data[0], count: Int(output.frameLength)))
    }

    nonisolated private func setInputDevice(_ deviceID: AudioDeviceID, on node: AVAudioInputNode) {
        guard let unit = node.audioUnit else { return }
        var id = deviceID
        AudioUnitSetProperty(
            unit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &id,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )
    }

    // MARK: - Errors

    enum CaptureError: LocalizedError {
        case modelNotLoaded
        case formatError

        var errorDescription: String? {
            switch self {
            case .modelNotLoaded:
                return "No model loaded. Download a model in Settings first."
            case .formatError:
                return "Audio format error — cannot start capture."
            }
        }
    }
}

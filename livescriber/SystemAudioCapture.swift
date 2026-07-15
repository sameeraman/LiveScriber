// SystemAudioCapture.swift
// Captures system-wide audio output using ScreenCaptureKit (macOS 13+).
// No virtual audio driver required.

import ScreenCaptureKit
import AVFoundation
import CoreMedia
import Combine

@MainActor
final class SystemAudioCapture: NSObject, ObservableObject {

    @Published var permissionGranted = false
    @Published var captureError: String?

    var onSamples: (([Float]) -> Void)?

    nonisolated(unsafe) private var scStream: SCStream?
    nonisolated(unsafe) private var sourceRate: Double = 44100

    // MARK: - Capture
    // No separate permission check — SCShareableContent is the authoritative gate
    // for ScreenCaptureKit's own TCC category ("Screen & System Audio Recording").
    // CGPreflightScreenCaptureAccess checks the legacy category and is unreliable here.

    func start() async throws {
        let content: SCShareableContent
        do {
            // Try the simplest possible call first
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        } catch {
            let nsErr = error as NSError
            permissionGranted = false
            throw SCKError.permissionDenied(underlying: "code \(nsErr.code): \(nsErr.localizedDescription)")
        }

        guard let display = content.displays.first else { throw SCKError.noDisplay }

        permissionGranted = true

        // Exclude nothing = capture all app audio
        let filter = SCContentFilter(
            display: display,
            excludingApplications: [],
            exceptingWindows: []
        )

        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true
        config.sampleRate = 44100
        config.channelCount = 1
        // Audio-only: set minimal video to satisfy SCStream requirement
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 30) // 30fps but tiny = minimal CPU
        config.showsCursor = false
        config.capturesShadowsOnly = false

        sourceRate = Double(config.sampleRate)

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        do {
            try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: .global(qos: .userInitiated))
            try await stream.startCapture()
        } catch {
            throw error
        }
        scStream = stream
    }

    func stop() {
        let s = scStream
        scStream = nil
        Task.detached { try? await s?.stopCapture() }
    }

    enum SCKError: LocalizedError {
        case permissionDenied(underlying: String)
        case noDisplay

        var errorDescription: String? {
            switch self {
            case .permissionDenied(let detail):
                return """
                System audio capture requires Screen & System Audio Recording permission.

                1. Open System Settings → Privacy & Security → Screen & System Audio Recording
                2. Enable the toggle for "LiveScriber"
                3. Quit the app completely (menu bar → Quit)
                4. Relaunch from Xcode

                System detail: \(detail)
                """
            case .noDisplay:
                return "No display found for system audio capture."
            }
        }
    }
}

// MARK: - SCStreamOutput

extension SystemAudioCapture: SCStreamOutput {

    nonisolated func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of type: SCStreamOutputType
    ) {
        guard type == .audio else { return }
        let samples = extractAndResample(sampleBuffer)
        guard !samples.isEmpty else { return }
        Task { @MainActor [weak self] in self?.onSamples?(samples) }
    }

    /// Extracts Float32 PCM samples from a CMSampleBuffer and resamples to 16 kHz.
    nonisolated private func extractAndResample(_ buffer: CMSampleBuffer) -> [Float] {
        var audioBufferList = AudioBufferList()
        var blockBuffer: CMBlockBuffer?

        guard CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            buffer,
            bufferListSizeNeededOut: nil,
            bufferListOut: &audioBufferList,
            bufferListSize: MemoryLayout<AudioBufferList>.size,
            blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil,
            flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment,
            blockBufferOut: &blockBuffer
        ) == noErr,
        let data = audioBufferList.mBuffers.mData
        else { return [] }

        let count = Int(audioBufferList.mBuffers.mDataByteSize) / MemoryLayout<Float>.size
        let raw = Array(UnsafeBufferPointer(
            start: data.assumingMemoryBound(to: Float.self),
            count: count
        ))

        // Resample 44100 → 16000 using linear interpolation
        return resampleLinear(raw, fromRate: sourceRate, toRate: 16000)
    }

    /// Linear interpolation resampler — sufficient quality for speech transcription.
    nonisolated private func resampleLinear(_ input: [Float], fromRate: Double, toRate: Double) -> [Float] {
        guard fromRate != toRate, !input.isEmpty else { return input }
        let ratio     = fromRate / toRate
        let outCount  = Int(Double(input.count) / ratio)
        var output    = [Float]()
        output.reserveCapacity(outCount)
        for i in 0 ..< outCount {
            let pos   = Double(i) * ratio
            let lower = Int(pos)
            let upper = min(lower + 1, input.count - 1)
            let frac  = Float(pos - Double(lower))
            output.append(input[lower] * (1 - frac) + input[upper] * frac)
        }
        return output
    }
}

// MARK: - SCStreamDelegate

extension SystemAudioCapture: SCStreamDelegate {
    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        Task { @MainActor [weak self] in
            self?.captureError = error.localizedDescription
        }
    }
}

// AppModel.swift
// Central application state and session coordinator.

import SwiftUI
import Combine
import AVFoundation

extension Notification.Name {
    static let openMainWindow = Notification.Name("LWN.openMainWindow")
}

@MainActor
final class AppModel: ObservableObject {

    // MARK: - Capture mode

    @AppStorage("captureSystemAudio") var captureSystemAudio: Bool = false

    // MARK: - Session state

    @Published var isRecording = false
    @Published var isPaused    = false
    @Published var status      = "Ready"
    @Published var sessionStartTime: Date?
    @Published var estimatedEndTime: Date?
    @Published var targetDuration: SessionDuration = .unlimited
    @Published var currentSessionFile: URL?
    @Published var liveEntries: [TranscriptEntry] = []

    // MARK: - UI

    @Published var showSettings = false
    @Published var selectedSession: CaptionSession?   // nil = live view
    @Published var viewedEntries: [TranscriptEntry] = []
    @Published var alwaysOnTop = false
    @Published var errorMessage: String?

    // Rename dialog state
    @Published var sessionToRename: CaptionSession?
    @Published var renameText: String = ""

    // MARK: - Managers (all @MainActor by same isolation)

    let transcription  = TranscriptionManager()
    let sessionMgr     = SessionManager()
    let audioDevices   = AudioDeviceManager()

    // MARK: - Persisted settings

    @AppStorage("selectedModel")  var selectedModel = "openai_whisper-base"
    @AppStorage("defaultDuration") var defaultDurationRaw = SessionDuration.unlimited.rawValue
    @AppStorage("alwaysOnTopPref") var alwaysOnTopPref = false
    @AppStorage("shortcutEnabled") var shortcutEnabled = false

    // MARK: - Internals

    private var timerTask: Task<Void, Never>?
    private var globalMonitor: Any?
    private var cancellables = Set<AnyCancellable>()

    // MARK: - Session duration

    enum SessionDuration: String, CaseIterable, Identifiable {
        case unlimited  = "No limit"
        case min30      = "30 minutes"
        case hour1      = "1 hour"
        case hour2      = "2 hours"
        case hour4      = "4 hours"

        var id: String { rawValue }

        var seconds: TimeInterval? {
            switch self {
            case .unlimited: nil
            case .min30:     30 * 60
            case .hour1:     60 * 60
            case .hour2:  2 * 60 * 60
            case .hour4:  4 * 60 * 60
            }
        }
    }

    // MARK: - Init

    init() {
        transcription.onTranscript = { [weak self] text in
            self?.handleTranscript(text)
        }
        alwaysOnTop = alwaysOnTopPref
        if let d = SessionDuration(rawValue: defaultDurationRaw) {
            targetDuration = d
        }

        // Load devices eagerly so the Audio settings picker isn't empty on first open
        audioDevices.loadDevices()

        // Forward TranscriptionManager's objectWillChange so every view observing
        // AppModel (including SettingsView) re-renders when the model state changes.
        transcription.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)

        // Forward SessionManager changes so the sidebar list refreshes when sessions
        // are added or deleted.
        sessionMgr.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)

        // Mirror model-load progress into the main-window status label.
        transcription.$modelState
            .sink { [weak self] state in
                guard let self, !self.isRecording else { return }
                switch state {
                case .loading:   self.status = "Loading model…"
                case .ready:     self.status = "Ready"
                case .failed:    self.status = "Ready"
                case .notLoaded: break
                }
            }
            .store(in: &cancellables)

        // Start loading the default model immediately in the background
        status = "Loading model…"
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.transcription.loadModel(name: self.selectedModel)
        }
    }

    // MARK: - Model loading

    func loadModelIfNeeded() {
        guard case .notLoaded = transcription.modelState else { return }
        Task { await transcription.loadModel(name: selectedModel) }
    }

    func reloadModel(name: String) {
        selectedModel = name
        Task { await transcription.loadModel(name: name) }
    }

    // MARK: - Session control

    func startSession() async {
        guard !isRecording else { return }

        guard await requestMicrophonePermission() else {
            errorMessage = "Microphone permission denied. Enable it in System Settings → Privacy."
            return
        }

        guard case .ready = transcription.modelState else {
            errorMessage = "Model not ready. Please wait for it to finish loading."
            return
        }

        isRecording = true
        isPaused    = false
        status      = "Listening…"
        sessionStartTime = Date()
        liveEntries  = []
        errorMessage = nil
        selectedSession = nil

        updateEstimatedEndTime()

        audioDevices.loadDevices()
        let hasMic = audioDevices.selectedDeviceID != nil
        let micName = audioDevices.selectedDeviceName
        let deviceLabel = hasMic && captureSystemAudio ? "\(micName) + System Audio"
                        : captureSystemAudio           ? "System Audio"
                        :                               micName
        currentSessionFile = sessionMgr.createNewSession(
            deviceName: deviceLabel,
            duration: targetDuration
        )
        viewedEntries = liveEntries

        do {
            if captureSystemAudio && hasMic {
                do {
                    try await transcription.startCombinedCapture(deviceID: audioDevices.selectedDeviceID)
                } catch {
                    let code = (error as NSError).code
                    status = "Listening\u{2026} (mic only)"
                    if code == -3801 {
                        // Permission not granted — keep toggle ON so restart will work automatically
                        errorMessage = "System audio needs Screen Recording permission.\n\n1. Open System Settings \u{2192} Privacy & Security \u{2192} Screen & System Audio Recording\n2. Enable the toggle for \"LiveScriber\"\n3. Quit the app (menu bar \u{2192} Quit), then relaunch"
                    } else {
                        captureSystemAudio = false
                        errorMessage = "System audio unavailable: \(error.localizedDescription)\nUsing mic only."
                    }
                    try transcription.startCapture(deviceID: audioDevices.selectedDeviceID)
                }
            } else if captureSystemAudio && !hasMic {
                try await transcription.startSystemAudioCapture()
            } else {
                try transcription.startCapture(deviceID: audioDevices.selectedDeviceID)
            }
        } catch {
            isRecording  = false
            status       = "Error"
            errorMessage = error.localizedDescription
            return
        }

        startTimer()
        openMainWindow()
    }

    func stopSession() {
        guard isRecording else { return }
        isRecording = false
        isPaused    = false
        status      = "Stopped"

        timerTask?.cancel()
        timerTask = nil
        transcription.stopCapture()

        if let file = currentSessionFile {
            sessionMgr.finalizeSession(at: file, startTime: sessionStartTime, endTime: Date())
        }
        sessionMgr.reloadSessions()
    }

    func pauseResumeSession() {
        guard isRecording else { return }
        isPaused.toggle()
        if isPaused {
            transcription.pause()
            status = "Paused"
        } else {
            transcription.resume()
            status = "Listening…"
        }
    }

    func copyLastMinute() {
        let cutoff  = Date().addingTimeInterval(-60)
        let recent  = liveEntries.filter { $0.timestamp >= cutoff }
        let text    = recent.map(\.text).joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    // MARK: - Duration helpers

    func setTargetDuration(_ d: SessionDuration) {
        targetDuration = d
        defaultDurationRaw = d.rawValue
        if isRecording { updateEstimatedEndTime() }
    }

    private func updateEstimatedEndTime() {
        if let secs = targetDuration.seconds {
            estimatedEndTime = Date().addingTimeInterval(secs)
        } else {
            estimatedEndTime = nil
        }
    }

    private func startTimer() {
        timerTask = Task { @MainActor in
            while !Task.isCancelled, isRecording {
                try? await Task.sleep(for: .seconds(1))
                guard isRecording else { break }
                if let start = sessionStartTime,
                   let secs  = targetDuration.seconds,
                   Date().timeIntervalSince(start) >= secs {
                    stopSession()
                }
            }
        }
    }

    // MARK: - Sidebar selection

    func selectSession(_ session: CaptionSession) {
        selectedSession  = session
        viewedEntries    = sessionMgr.parseEntries(from: session.fileURL)
    }

    func showLiveSession() {
        selectedSession = nil
        viewedEntries   = liveEntries
    }

    func deleteSession(_ session: CaptionSession) {
        // If the session being deleted is currently open, fall back to the live view.
        if selectedSession == session {
            showLiveSession()
        }
        sessionMgr.deleteSession(session)
    }

    // MARK: - Rename

    func beginRename(_ session: CaptionSession) {
        sessionToRename = session
        renameText = session.title ?? ""
    }

    func commitRename() {
        guard let session = sessionToRename else { return }
        let wasSelected = selectedSession == session
        sessionMgr.renameSession(session, to: renameText)
        sessionToRename = nil
        renameText = ""
        // Re-select the renamed session so it stays highlighted/open.
        if wasSelected, let updated = sessionMgr.sessions.first(where: { $0.date == session.date }) {
            selectedSession = updated
        }
    }

    func cancelRename() {
        sessionToRename = nil
        renameText = ""
    }

    // MARK: - Transcript accumulation

    private func handleTranscript(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let now = Date()
        let cal = Calendar.current
        if let _ = liveEntries.last,
           cal.isDate(liveEntries[liveEntries.count - 1].timestamp, equalTo: now, toGranularity: .minute) {
            // Same minute — grow in memory AND append continuation to file
            liveEntries[liveEntries.count - 1].text += " " + trimmed
            if let file = currentSessionFile {
                sessionMgr.appendContinuation(trimmed, to: file)
            }
        } else {
            // New minute — write timestamp heading + first sentence
            let entry = TranscriptEntry(timestamp: now, text: trimmed)
            liveEntries.append(entry)
            if let file = currentSessionFile {
                sessionMgr.appendEntry(entry, to: file)
            }
        }

        if selectedSession == nil {
            viewedEntries = liveEntries
        }
    }

    // MARK: - Window

    func openMainWindow() {
        for w in NSApp.windows where w.identifier?.rawValue == "main" {
            w.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        NotificationCenter.default.post(name: .openMainWindow, object: nil)
    }

    // MARK: - Global shortcut

    func registerGlobalShortcut(enabled: Bool) {
        if let monitor = globalMonitor {
            NSEvent.removeMonitor(monitor)
            globalMonitor = nil
        }
        guard enabled else { return }

        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            // ⌘⇧N  — start new session
            if event.modifierFlags.contains([.command, .shift]),
               event.charactersIgnoringModifiers?.lowercased() == "n" {
                Task { @MainActor [weak self] in
                    await self?.startSession()
                }
            }
            // ⌘⇧. — stop session
            if event.modifierFlags.contains([.command, .shift]),
               event.charactersIgnoringModifiers == "." {
                Task { @MainActor [weak self] in
                    self?.stopSession()
                }
            }
        }
    }

    // MARK: - Microphone permission

    private func requestMicrophonePermission() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:   return true
        case .notDetermined:
            return await AVCaptureDevice.requestAccess(for: .audio)
        default:            return false
        }
    }
}

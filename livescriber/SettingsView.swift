// SettingsView.swift
// Settings panel: model management, audio device, session defaults, keyboard shortcuts.

import SwiftUI
import AVFoundation

struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    @State private var showAccessibilityAlert = false

    var body: some View {
        TabView {
            ModelTab()
                .tabItem { Label("Model", systemImage: "brain") }

            AudioTab()
                .tabItem { Label("Audio", systemImage: "mic") }

            SessionTab()
                .tabItem { Label("Session", systemImage: "doc.text") }

            ShortcutsTab(showAccessibilityAlert: $showAccessibilityAlert)
                .tabItem { Label("Shortcuts", systemImage: "keyboard") }
        }
        .environmentObject(model)
        .padding()
        .frame(width: 480, height: 400)
        .alert("Accessibility Required", isPresented: $showAccessibilityAlert) {
            Button("Open System Settings") {
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Global shortcuts require Accessibility access. Please enable it for LiveScriber in System Settings → Privacy & Security → Accessibility.")
        }
    }
}

// MARK: - Model Tab

private struct ModelTab: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Whisper Model").font(.headline)

            stateView

            Picker("Active model", selection: $model.selectedModel) {
                ForEach(model.transcription.availableModels, id: \.self) { m in
                    Text(m).tag(m)
                }
            }
            .pickerStyle(.menu)

            HStack {
                Button("Load / Download Model") {
                    model.reloadModel(name: model.selectedModel)
                }
                .disabled({
                    if case .loading = model.transcription.modelState { return true }
                    return false
                }())
                Spacer()
            }

            Text("Models are cached in ~/Library/Application Support/huggingface/")
                .font(.caption)
                .foregroundStyle(.secondary)

            Spacer()
        }
        .padding()
    }

    @ViewBuilder
    private var stateView: some View {
        HStack(spacing: 8) {
            switch model.transcription.modelState {
            case .notLoaded:
                Image(systemName: "circle").foregroundStyle(.secondary)
                Text("No model loaded").foregroundStyle(.secondary)
            case .loading(let name):
                ProgressView().controlSize(.small)
                Text("Loading \(name)…").foregroundStyle(.orange)
            case .ready(let name):
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                Text(name + " — Ready").foregroundStyle(.green)
            case .failed(let msg):
                Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
                Text(msg).foregroundStyle(.red).lineLimit(2)
            }
        }
        .font(.callout)
    }
}

// MARK: - Audio Tab

private struct AudioTab: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {

            // ── Microphone input ──────────────────────────────────
            Text("Microphone Input").font(.headline)

            HStack {
                Picker("Input device", selection: Binding(
                    get: { model.audioDevices.selectedDeviceID },
                    set: { model.audioDevices.selectedDeviceID = $0 }
                )) {
                    ForEach(model.audioDevices.inputDevices) { dev in
                        Text(dev.name).tag(Optional(dev.id))
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()

                Button {
                    model.audioDevices.loadDevices()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("Refresh device list")
            }

            Divider()

            // ── System audio ──────────────────────────────────────
            VStack(alignment: .leading, spacing: 6) {
                Toggle(isOn: $model.captureSystemAudio) {
                    Label("Also capture system audio", systemImage: "speaker.wave.2.fill")
                        .font(.body)
                }

                if model.captureSystemAudio {
                    Text("Captures all audio output — Teams calls, browser video, any app.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.leading, 24)
                    Text("macOS will ask for Screen Recording permission on first use.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.leading, 24)
                }
            }

            if model.audioDevices.selectedDeviceID != nil && model.captureSystemAudio {
                Label("Mic + System Audio — both streams will be transcribed together.", systemImage: "waveform.and.mic")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.accentColor.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
            }

            Divider()

            // ── Transcription window ──────────────────────────────────
            VStack(alignment: .leading, spacing: 6) {
                Text("Transcription Speed vs. Accuracy").font(.headline)

                Slider(
                    value: Binding(
                        get: { model.chunkSeconds },
                        set: { model.setChunkSeconds($0) }
                    ),
                    in: 1.5...8.0,
                    step: 0.5
                ) {
                    Text("Chunk size")
                } minimumValueLabel: {
                    Image(systemName: "hare.fill").foregroundStyle(.secondary)
                } maximumValueLabel: {
                    Image(systemName: "tortoise.fill").foregroundStyle(.secondary)
                }

                HStack {
                    Text("Smaller chunks — faster captions")
                    Spacer()
                    Text("Larger chunks — more accurate")
                }
                .font(.caption2)
                .foregroundStyle(.secondary)

                Text(String(format: "Current window: %.1f s of audio per pass", model.chunkSeconds))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
        .padding()
        .onAppear { model.audioDevices.loadDevices() }
    }
}

// MARK: - Session Tab

private struct SessionTab: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Session Defaults").font(.headline)

            Picker("Default duration", selection: Binding(
                get: { model.targetDuration },
                set: { model.setTargetDuration($0) }
            )) {
                ForEach(AppModel.SessionDuration.allCases) { d in
                    Text(d.rawValue).tag(d)
                }
            }
            .pickerStyle(.menu)

            Divider()

            Text("Window").font(.headline)

            Toggle("Keep window always on top", isOn: Binding(
                get: { model.alwaysOnTop },
                set: {
                    model.alwaysOnTop = $0
                    model.alwaysOnTopPref = $0
                }
            ))

            Divider()

            Text("Output folder").font(.headline)
            Text(model.sessionMgr.outputPath)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .truncationMode(.middle)

            Spacer()
        }
        .padding()
    }
}

// MARK: - Shortcuts Tab

private struct ShortcutsTab: View {
    @EnvironmentObject var model: AppModel
    @Binding var showAccessibilityAlert: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Global Keyboard Shortcuts").font(.headline)

            Toggle("Enable global shortcuts", isOn: Binding(
                get: { model.shortcutEnabled },
                set: { enabled in
                    if enabled && !AXIsProcessTrusted() {
                        showAccessibilityAlert = true
                    } else {
                        model.shortcutEnabled = enabled
                        model.registerGlobalShortcut(enabled: enabled)
                    }
                }
            ))

            Group {
                shortcutRow(label: "New Session",   shortcut: "⌘ ⇧ N")
                shortcutRow(label: "Stop Session",  shortcut: "⌘ ⇧ .")
            }
            .disabled(!model.shortcutEnabled)
            .foregroundStyle(model.shortcutEnabled ? .primary : .secondary)

            if !AXIsProcessTrusted() {
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
                    Text("Accessibility access not granted.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()
        }
        .padding()
    }

    private func shortcutRow(label: String, shortcut: String) -> some View {
        HStack {
            Text(label)
            Spacer()
            Text(shortcut)
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 4))
        }
    }
}

// livescriberApp.swift
// App entry point — menu bar agent, main window, and settings window.

import SwiftUI

@main
struct livescriberApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        // ── Main transcript window ──────────────────────────────────
        Window("LiveScriber", id: "main") {
            ContentView()
                .environmentObject(model)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)
        .defaultSize(width: 760, height: 520)
        .commands {
            CommandGroup(after: .newItem) {
                Button("New Caption Session") {
                    Task { await model.startSession() }
                }
                .keyboardShortcut("n", modifiers: [.command, .shift])

                Button("Stop Session") {
                    model.stopSession()
                }
                .keyboardShortcut(".", modifiers: [.command, .shift])
                    .disabled(!model.isRecording)
            }
        }

        // ── Menu bar ────────────────────────────────────────────────
        MenuBarExtra {
            MenuBarContentView()
                .environmentObject(model)
        } label: {
            Image(systemName: model.isRecording
                  ? (model.isPaused ? "waveform.circle" : "waveform.circle.fill")
                  : "waveform.circle")
            .symbolEffect(.pulse, isActive: model.isRecording && !model.isPaused)
            .foregroundStyle(model.isRecording ? .red : .primary)
        }
        .menuBarExtraStyle(.menu)

        // ── Settings ────────────────────────────────────────────────
        Settings {
            SettingsView()
                .environmentObject(model)
        }
    }
}

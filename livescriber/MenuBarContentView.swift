// MenuBarContentView.swift
// Content shown in the menu bar dropdown.

import SwiftUI

struct MenuBarContentView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {

            // Status header
            HStack(spacing: 6) {
                Image(systemName: model.isRecording ? "record.circle.fill" : "waveform.circle")
                    .foregroundStyle(model.isRecording ? .red : .secondary)
                    .symbolEffect(.pulse, isActive: model.isRecording && !model.isPaused)
                Text(model.isRecording ? (model.isPaused ? "Paused" : "Listening…") : "Idle")
                    .font(.headline)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            if model.isRecording, let end = model.estimatedEndTime {
                Text("Ends at \(end.formatted(.dateTime.hour().minute()))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 4)
            }

            Divider()

            // Primary actions
            if !model.isRecording {
                Button {
                    Task { await model.startSession() }
                } label: {
                    Label("New Caption Session", systemImage: "record.circle")
                }
                .keyboardShortcut("n", modifiers: [.command, .shift])
            } else {
                Button {
                    model.pauseResumeSession()
                } label: {
                    Label(model.isPaused ? "Resume" : "Pause", systemImage: model.isPaused ? "play.circle" : "pause.circle")
                }

                Button(role: .destructive) {
                    model.stopSession()
                } label: {
                    Label("Stop Session", systemImage: "stop.circle")
                }
                .keyboardShortcut(".", modifiers: [.command, .shift])
            }

            Divider()

            // Duration picker (only shown when recording or setting up)
            Menu {
                ForEach(AppModel.SessionDuration.allCases) { dur in
                    Button {
                        model.setTargetDuration(dur)
                    } label: {
                        HStack {
                            Text(dur.rawValue)
                            if model.targetDuration == dur {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            } label: {
                Label("Duration: \(model.targetDuration.rawValue)", systemImage: "timer")
            }

            Divider()

            Button {
                model.openMainWindow()
            } label: {
                Label("Open Window", systemImage: "macwindow")
            }

            Divider()

            Button("Quit LiveScriber") {
                if model.isRecording { model.stopSession() }
                NSApp.terminate(nil)
            }
            .keyboardShortcut("q", modifiers: .command)
        }
        .frame(minWidth: 250)
    }
}

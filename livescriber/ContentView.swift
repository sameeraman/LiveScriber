// ContentView.swift
// Main window: sidebar of previous sessions + live transcript detail.

import SwiftUI

struct ContentView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        NavigationSplitView(columnVisibility: .constant(.all)) {
            SidebarView()
        } detail: {
            DetailView()
        }
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 650, minHeight: 430)
        .toolbar {
            // Recording indicator pill (left)
            ToolbarItem(placement: .navigation) {
                RecordingPill()
            }

            // Session title / estimated end (centre)
            ToolbarItemGroup(placement: .principal) {
                VStack(spacing: 1) {
                    Text(model.selectedSession?.displayName ?? (model.isRecording ? "Recording…" : "LiveScriber"))
                        .font(.headline)
                    if let end = model.estimatedEndTime, model.isRecording {
                        Text("Ends ~\(end.formatted(.dateTime.hour().minute()))")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 5)
            }

            // Settings (right)
            ToolbarItem(placement: .primaryAction) {
                Button { model.showSettings = true } label: {
                    Image(systemName: "gear")
                }
                .help("Settings")
            }
        }
        .sheet(isPresented: $model.showSettings) {
            SettingsView().environmentObject(model)
        }
        .alert("Error", isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { model.errorMessage = nil }
            if model.errorMessage?.contains("Screen Recording") == true ||
               model.errorMessage?.contains("Screen & System") == true {
                Button("Quit to Restart") {
                    model.stopSession()
                    NSApp.terminate(nil)
                }
            }
        } message: {
            Text(model.errorMessage ?? "")
        }
        .alert("Rename Session", isPresented: Binding(
            get: { model.sessionToRename != nil },
            set: { if !$0 { model.cancelRename() } }
        )) {
            TextField("Session name", text: $model.renameText)
            Button("Save") { model.commitRename() }
            Button("Cancel", role: .cancel) { model.cancelRename() }
        } message: {
            Text("Enter a new name for this session. Leave empty to restore the date.")
        }
        .background(WindowLevelView(alwaysOnTop: model.alwaysOnTop))
        .onReceive(NotificationCenter.default.publisher(for: .openMainWindow)) { _ in
            // Window is already open from the scene; just make it key
            for w in NSApp.windows where w.identifier?.rawValue == "main" {
                w.makeKeyAndOrderFront(nil)
            }
        }
    }
}

// MARK: - Sidebar

struct SidebarView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        List {
            // Live session row — always selectable; jumps to the live/active view.
            Section {
                Button {
                    model.showLiveSession()
                } label: {
                    HStack(spacing: 8) {
                        Circle()
                            .fill(model.isRecording ? Color.red : Color.secondary)
                            .frame(width: 8, height: 8)
                            .symbolEffect(.pulse, isActive: model.isRecording)
                        Text(model.isRecording ? "Live — \(model.status)" : "No active session")
                            .font(.callout)
                            .foregroundStyle(model.isRecording ? .primary : .secondary)
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 2)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .listRowBackground(rowBackground(selected: model.selectedSession == nil))
            }

            // Previous sessions — disabled while a live caption is running.
            if !model.sessionMgr.sessions.isEmpty {
                Section("Previous Sessions") {
                    ForEach(model.sessionMgr.sessions) { session in
                        Button {
                            // Block loading previous sessions during live capture.
                            guard !model.isRecording else { return }
                            model.selectSession(session)
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(session.displayName)
                                    .font(.callout)
                                Text(session.title != nil ? session.dateLabel : session.fileURL.lastPathComponent)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                            .padding(.vertical, 2)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .opacity(model.isRecording ? 0.35 : 1)
                        .help(model.isRecording ? "Stop the live session to open previous captions" : "")
                        .listRowBackground(rowBackground(selected: model.selectedSession == session))
                        .contextMenu {
                            Button {
                                model.beginRename(session)
                            } label: {
                                Label("Rename…", systemImage: "pencil")
                            }
                            Button(role: .destructive) {
                                model.deleteSession(session)
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("Sessions")
        .navigationSplitViewColumnWidth(min: 190, ideal: 210, max: 280)
        .onAppear { model.sessionMgr.reloadSessions() }
    }

    @ViewBuilder
    private func rowBackground(selected: Bool) -> some View {
        if selected {
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.accentColor.opacity(0.18))
                .padding(.horizontal, 4)
        } else {
            Color.clear
        }
    }
}

// MARK: - Detail / Transcript

struct DetailView: View {
    @EnvironmentObject var model: AppModel

    private var isViewingLive: Bool { model.selectedSession == nil }

    var body: some View {
        VStack(spacing: 0) {
            // Status bar
            HStack(spacing: 8) {
                Image(systemName: statusIcon)
                    .foregroundStyle(statusColor)
                    .symbolEffect(.pulse, isActive: model.isRecording && !model.isPaused)
                Text("Status: \(model.status)")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
                if let end = model.estimatedEndTime, model.isRecording {
                    Label(end.formatted(.dateTime.hour().minute()), systemImage: "timer")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.bar)

            Divider()

            // Transcript scroll area
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        if model.viewedEntries.isEmpty {
                            emptyState
                        } else if model.isEditing {
                            editableTranscript
                        } else {
                            // One selectable Text so highlighting spans across minutes.
                            Text(transcriptAttributed(model.viewedEntries))
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        // Invisible anchor for auto-scroll
                        Color.clear.frame(height: 1).id("bottom")
                    }
                    .padding(16)
                }
                .onChange(of: model.viewedEntries.count) { _, _ in
                    if isViewingLive && !model.isEditing {
                        withAnimation(.easeOut(duration: 0.3)) {
                            proxy.scrollTo("bottom", anchor: .bottom)
                        }
                    }
                }
            }

            Divider()

            // Control bar
            ControlBarView()
        }
    }

    private var statusIcon: String {
        if model.isPaused         { return "pause.circle.fill" }
        if model.isRecording      { return "record.circle.fill" }
        return "circle"
    }

    private var statusColor: Color {
        if model.isPaused    { return .orange }
        if model.isRecording { return .red }
        return .secondary
    }

    /// Builds the whole transcript as a single AttributedString so the user can
    /// select and copy text spanning multiple minute blocks.
    private func transcriptAttributed(_ entries: [TranscriptEntry]) -> AttributedString {
        var out = AttributedString()
        for (index, entry) in entries.enumerated() {
            if index > 0 { out += AttributedString("\n\n") }

            var label = AttributedString(entry.minuteLabel + "\n")
            label.font = .caption.weight(.semibold)
            label.foregroundColor = .secondary
            out += label

            var body = AttributedString(entry.text)
            body.font = .body
            out += body
        }
        return out
    }

    @ViewBuilder
    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "waveform.badge.mic")
                .font(.system(size: 48))
                .foregroundStyle(.tertiary)
            Text(isViewingLive ? "Press Start to begin transcribing." : "No transcript found.")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 200)
    }

    /// Editable transcript: one auto-growing text field per minute block. Timestamps
    /// stay fixed; only the wording is editable. Saved when the user leaves edit mode.
    @ViewBuilder
    private var editableTranscript: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach($model.viewedEntries) { $entry in
                VStack(alignment: .leading, spacing: 4) {
                    Text(entry.minuteLabel)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    TextField("", text: $entry.text, axis: .vertical)
                        .textFieldStyle(.plain)
                        .font(.body)
                        .padding(8)
                        .background(Color(nsColor: .textBackgroundColor),
                                    in: RoundedRectangle(cornerRadius: 6))
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(Color.secondary.opacity(0.25))
                        )
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Transcript entry row

struct TranscriptEntryView: View {
    let entry: TranscriptEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(entry.minuteLabel)
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.accentColor.opacity(0.12), in: Capsule())

            Text(entry.text)
                .font(.body)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Control bar

struct ControlBarView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        HStack(spacing: 10) {
            // Start / Stop
            Button {
                Task {
                    if model.isRecording { model.stopSession() }
                    else                 { await model.startSession() }
                }
            } label: {
                Label(
                    model.isRecording ? "Stop" : "Start",
                    systemImage: model.isRecording ? "stop.circle.fill" : "record.circle"
                )
                .foregroundStyle(model.isRecording ? .red : .accentColor)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)

            // Pause / Resume
            Button {
                model.pauseResumeSession()
            } label: {
                Label(
                    model.isPaused ? "Resume" : "Pause",
                    systemImage: model.isPaused ? "play.circle" : "pause.circle"
                )
            }
            .buttonStyle(.bordered)
            .disabled(!model.isRecording)

            // Edit / Done — toggles editable transcript, saving on exit.
            // Works during live recording: new speech keeps flowing into the fields.
            Button {
                model.toggleEditMode()
            } label: {
                Label(
                    model.isEditing ? "Done" : "Edit",
                    systemImage: model.isEditing ? "checkmark.circle" : "pencil"
                )
                .foregroundStyle(model.isEditing ? Color.green : Color.primary)
            }
            .buttonStyle(.bordered)
            .disabled(model.viewedEntries.isEmpty)
            .help("Edit the transcript to fix mistakes — live transcription keeps updating while you edit")

            // Copy last minute
            Button {
                model.copyLastMinute()
            } label: {
                Label("Copy Last Minute", systemImage: "doc.on.clipboard")
            }
            .buttonStyle(.bordered)
            .disabled(model.liveEntries.isEmpty)

            Spacer()

            // Duration picker (accessible while recording)
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
                Label(model.targetDuration.rawValue, systemImage: "timer")
                    .font(.callout)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
    }
}

// MARK: - Recording indicator pill

struct RecordingPill: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        if model.isRecording {
            HStack(spacing: 5) {
                Circle()
                    .fill(model.isPaused ? Color.orange : Color.red)
                    .frame(width: 7, height: 7)
                    .symbolEffect(.pulse, isActive: !model.isPaused)
                Text(model.isPaused ? "Paused" : "REC")
                    .font(.caption2.bold())
                    .foregroundStyle(model.isPaused ? .orange : .red)
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(
                (model.isPaused ? Color.orange : Color.red).opacity(0.12),
                in: Capsule()
            )
        }
    }
}

// MARK: - Always-on-top helper

struct WindowLevelView: NSViewRepresentable {
    let alwaysOnTop: Bool

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async {
            view.window?.level = self.alwaysOnTop ? .floating : .normal
        }
    }
}

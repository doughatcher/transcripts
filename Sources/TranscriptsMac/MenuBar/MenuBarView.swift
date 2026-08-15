import SwiftUI
import AppKit
import TranscriptsCore

struct MenuBarView: View {
    @EnvironmentObject private var controller: AppController
    @State private var showingNote = false
    @State private var noteTitle = ""
    @State private var noteBody = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header

            banners

            Divider()

            sessionBanner
            recordControls

            // Proof the call is transcribing itself: opens the live, speaker-
            // labeled transcript in the configured viewer while recording runs.
            if controller.isRecording, controller.liveTranscriptURL != nil {
                Button {
                    controller.openLiveTranscript()
                } label: {
                    Label("Open live transcript", systemImage: "waveform.badge.magnifyingglass")
                        .font(.callout)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.tint)
            }

            if showingNote { noteEditor }

            Divider()

            if !controller.recents.isEmpty {
                ForEach(controller.groupedByDay(controller.recents)) { group in
                    Text(group.label).font(.caption).foregroundStyle(.secondary)
                    ForEach(group.calls) { call in
                        callRow(call)
                    }
                }
                Divider()
            }

            if let err = controller.lastError {
                Text(err).font(.caption2).foregroundStyle(.red).lineLimit(3)
                Divider()
            }

            HStack {
                Button("Settings…") { controller.openSettings() }
                Button("Recordings…") { controller.openRecordings(nil) }
                Spacer()
                Button("Quit") { NSApplication.shared.terminate(nil) }
            }
        }
        .padding(12)
        .frame(width: 320)
    }

    @ViewBuilder
    private var banners: some View {
        if let app = controller.pendingCallApp {
            banner(icon: "dot.radiowaves.left.and.right",
                   text: "On a \(app) call. Announce you're recording, then start.",
                   primary: "Record",
                   action: { controller.startPendingCallRecording() },
                   dismiss: { controller.dismissPendingCall() })
        }
        if controller.shouldPromptLaunchAtLogin {
            banner(icon: "power", text: "Launch Transcripts automatically at login?",
                   primary: "Enable",
                   action: { controller.answerLaunchAtLoginPrompt(enable: true) },
                   dismiss: { controller.answerLaunchAtLoginPrompt(enable: false) })
        }
        if let update = controller.updateAvailable {
            banner(icon: "arrow.down.circle", text: "Transcripts \(update.version) is available.",
                   primary: "Update",
                   action: { controller.installUpdate(update) },
                   dismiss: { controller.updateAvailable = nil })
        }
        if let suggestion = controller.namedVoiceSuggestions.first {
            banner(icon: "person.wave.2",
                   text: "Remember \(suggestion.name)'s voice? Future meetings would name them automatically. (Heard in: \(suggestion.sourceTitle))",
                   primary: "Remember",
                   action: { controller.resolveVoiceSuggestion(id: suggestion.id, accept: true, as: suggestion.name) },
                   dismiss: { controller.resolveVoiceSuggestion(id: suggestion.id, accept: false, as: suggestion.name) })
        }
    }

    private func banner(icon: String, text: String, primary: String,
                        action: @escaping () -> Void, dismiss: @escaping () -> Void) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
            Text(text).font(.callout).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            Button(primary, action: action).controlSize(.small).buttonStyle(.borderedProminent)
            Button { dismiss() } label: { Image(systemName: "xmark") }.buttonStyle(.plain)
        }
        .padding(8)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
    }

    /// A call: a single recording shows as a row; a multi-fragment call collapses into
    /// one expandable row (meeting name + part count).
    @ViewBuilder
    private func callRow(_ call: AppController.CallGroup) -> some View {
        if call.isSingle {
            recentRow(call.items[0])
        } else {
            DisclosureGroup {
                ForEach(call.items) { recentRow($0) }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "person.wave.2")
                        .foregroundStyle(call.allEmpty ? Color.secondary : Color.accentColor)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(call.allEmpty ? "No audio captured" : call.title)
                            .font(.callout).lineLimit(1)
                            .foregroundStyle(call.allEmpty ? .secondary : .primary)
                        Text("\(call.count) recordings · \(call.when.formatted(date: .omitted, time: .shortened))")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
            }
        }
    }

    @ViewBuilder
    private func recentRow(_ item: AppController.RecentItem) -> some View {
        HStack(spacing: 6) {
            Button {
                controller.openRecent(item)
            } label: {
                HStack(spacing: 6) {
                    statusIcon(for: item)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(item.isEmpty ? "No audio captured" : item.title)
                            .font(.callout).lineLimit(1)
                            .foregroundStyle(item.isEmpty ? .secondary : .primary)
                        Text(recentSubtitle(item)).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(openHelp(item))

            if item.retryable {
                Button {
                    controller.retry(item.id)
                } label: {
                    Image(systemName: "arrow.clockwise.circle")
                }
                .buttonStyle(.plain)
                .help("Reprocess this recording")
            }
        }
        .contextMenu { recentContextMenu(item) }
    }

    private func openHelp(_ item: AppController.RecentItem) -> String {
        if item.isEmpty { return "This recording captured no audio" }
        if item.path != nil, controller.canOpenExternally { return controller.openExternallyLabel }
        return "Open in the Recordings browser"
    }

    /// Right-click actions for a recents row — mirrors the Recordings window.
    @ViewBuilder
    private func recentContextMenu(_ item: AppController.RecentItem) -> some View {
        Button("Rename…") { controller.promptRename(item.id) }
        Button("Open in Transcripts") { controller.openRecordings(item.id) }
        if item.path != nil {
            Divider()
            Button(controller.openExternallyLabel) { controller.openExternally(item.id) }
            Button("Re-sort now") { Task { await controller.resort(item.id) } }
            Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([item.path!]) }
        }
        if item.retryable {
            Button("Reprocess") { controller.retry(item.id) }
        }
        if item.status != .recording && item.status != .processing {
            Divider()
            Button("Delete…", role: .destructive) { controller.promptDelete(item.id) }
        }
    }

    @ViewBuilder
    private func statusIcon(for item: AppController.RecentItem) -> some View {
        if item.isEmpty {
            Image(systemName: "mic.slash").foregroundStyle(.tertiary)
        } else {
            switch item.status {
            case .completed:
                Image(systemName: "doc.text").foregroundStyle(Color.accentColor)
            case .failed:
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            case .processing:
                ProgressView().controlSize(.small)
            case .recording:
                Image(systemName: "record.circle").foregroundStyle(controller.recordingColor)
            }
        }
    }

    private func recentSubtitle(_ item: AppController.RecentItem) -> String {
        let time = item.when.formatted(date: .omitted, time: .shortened)
        if let dest = item.destination { return "\(time) · \(dest)" }
        return time
    }

    private var header: some View {
        HStack {
            if controller.isRecording {
                // TimelineView self-drives the redraw and reads the latest levels each
                // frame — a MenuBarExtra window doesn't reliably push frequent
                // @Published updates into its view, so the bars would otherwise freeze.
                TimelineView(.animation(minimumInterval: 0.06)) { _ in
                    LevelBarsView(levels: controller.levels, barCount: 5, height: 18,
                                  color: controller.recordingColor)
                }
                .frame(width: 24)
            } else {
                Image(systemName: controller.statusSymbol)
                    .symbolEffect(.pulse, options: .repeating, isActive: controller.isProcessing)
            }
            Text(statusText).font(.headline)
                .foregroundStyle(controller.isRecording ? controller.recordingColor : .primary)
                .monospacedDigit()
            Spacer()
            Toggle("Auto", isOn: Binding(
                get: { controller.config.autoRecordOnMicActivation },
                set: { controller.setAutoRecord($0) }
            ))
            .toggleStyle(.switch)
            .help("Automatically record when the microphone goes live")
        }
    }

    private var statusText: String {
        switch controller.state {
        case .idle: return "Idle"
        case .armed: return "Watching for meetings"
        case .recording(let since): return "Recording \(elapsed(since))"
        case .processing: return "Processing…"
        }
    }

    /// A running session, when there is one.
    ///
    /// Visible rather than implicit on purpose: a session silently changes where
    /// recordings are filed and arms an action that fires later, and state with
    /// consequences that arrive hours afterwards should not be invisible while
    /// it runs. Absent entirely when no session is active — nobody who does not
    /// use them should have to look at the concept.
    @ViewBuilder
    private var sessionBanner: some View {
        if let s = controller.sessions.active, s.isRunning,
           let p = controller.sessions.profile {
            HStack(spacing: 8) {
                Image(systemName: "circle.hexagongrid.fill").foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 1) {
                    Text(p.name).font(.subheadline.weight(.medium))
                    Text(s.recordingIDs.isEmpty
                         ? "Session running — nothing recorded yet"
                         : "^[\(s.recordingIDs.count) recording](inflect: true) this session")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Button("End") { controller.sessions.end() }
                    .controlSize(.small)
            }
            .padding(8)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    private var recordControls: some View {
        HStack(spacing: 8) {
            switch controller.state {
            case .recording:
                Button { controller.stopRecordingAndProcess() } label: {
                    Label("Stop & process", systemImage: "stop.circle").frame(maxWidth: .infinity)
                }
            case .processing:
                HStack { ProgressView().controlSize(.small); Text("Processing…") }
                    .frame(maxWidth: .infinity)
            default:
                Button { controller.startRecording() } label: {
                    Label("Start recording", systemImage: "record.circle").frame(maxWidth: .infinity)
                }
            }
            Button { showingNote.toggle() } label: {
                Label("New note", systemImage: "square.and.pencil").frame(maxWidth: .infinity)
            }
        }
    }

    private var noteEditor: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField("Title", text: $noteTitle)
            TextEditor(text: $noteBody).frame(height: 80).border(.quaternary)
            HStack {
                Spacer()
                Button("Save note") {
                    controller.saveNote(title: noteTitle.isEmpty ? "Note" : noteTitle, body: noteBody)
                    noteTitle = ""; noteBody = ""; showingNote = false
                }
                .disabled(noteBody.isEmpty)
            }
        }
    }

    private func elapsed(_ since: Date) -> String {
        let s = Int(Date().timeIntervalSince(since))
        return String(format: "%02d:%02d", s / 60, s % 60)
    }
}

import SwiftUI
import AppKit

/// The Recordings browser: a single window with a scrollable list of every
/// recording on the left and the selected transcript on the right — instead of a
/// separate window/tab per document. Backed by the durable history store, so it
/// shows the full history, not just the capped menu list.
struct LibraryView: View {
    @EnvironmentObject private var controller: AppController

    var body: some View {
        NavigationSplitView {
            List(selection: $controller.selectedRecordIDs) {
                ForEach(controller.groupedByDay(controller.allRecents)) { group in
                    Section(group.label) {
                        ForEach(group.calls) { call in
                            if call.isSingle {
                                row(call.items[0])
                            } else {
                                DisclosureGroup {
                                    ForEach(call.items) { row($0) }
                                } label: {
                                    CallHeaderRow(call: call)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Recordings")
            .frame(minWidth: 260)
            .overlay {
                if controller.allRecents.isEmpty {
                    Text("No recordings yet").foregroundStyle(.secondary)
                }
            }
        } detail: {
            detail
        }
        .onAppear { NSApp.activate(ignoringOtherApps: true) }
        .toolbar {
            // Only once more than one row is picked: a Merge button next to a
            // single selection is an invitation to wonder what it would do.
            if controller.selectedRecordIDs.count >= 2 {
                Button {
                    controller.promptMerge(Array(controller.selectedRecordIDs))
                } label: {
                    Label("Merge \(controller.selectedRecordIDs.count)…",
                          systemImage: "arrow.triangle.merge")
                }
                .help("Join these recordings into one note, on a single timeline")
            }
            if let id = controller.selectedRecordID,
               let item = controller.allRecents.first(where: { $0.id == id }), item.path != nil {
                Button {
                    controller.openExternally(id)
                } label: {
                    Label(controller.openExternallyLabel, systemImage: "arrow.up.forward.app")
                }
                .help("Open this recording's document in your configured app")
            }
        }
    }

    /// A single selectable recording row with its context menu.
    private func row(_ item: AppController.RecentItem) -> some View {
        RecordingRow(item: item)
            .tag(item.id)
            .contextMenu {
                Button("Rename…") { controller.promptRename(item.id) }
                if item.path != nil {
                    Divider()
                    Button(controller.openExternallyLabel) { controller.openExternally(item.id) }
                    Button("Re-sort now") { Task { await controller.resort(item.id) } }
                    Button("Reveal in Finder") {
                        if let p = item.path { NSWorkspace.shared.activateFileViewerSelecting([p]) }
                    }
                }
                if item.retryable {
                    Button("Reprocess") { controller.retry(item.id) }
                }
                if item.status != .recording && item.status != .processing {
                    Divider()
                    Button("Delete…", role: .destructive) { controller.promptDelete(item.id) }
                }
            }
    }

    @ViewBuilder
    private var detail: some View {
        if let id = controller.selectedRecordID,
           let item = controller.allRecents.first(where: { $0.id == id }) {
            if let path = item.path {
                MarkdownViewerView(url: path)
                    .id(path)   // reload when selection changes
            } else {
                unavailable(for: item)
            }
        } else {
            VStack(spacing: 8) {
                Image(systemName: "waveform").font(.largeTitle).foregroundStyle(.secondary)
                Text("Select a recording").foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private func unavailable(for item: AppController.RecentItem) -> some View {
        VStack(spacing: 10) {
            if item.status == .recording {
                // Show the live transcript right here, refreshing as turns land —
                // the in-app equivalent of watching it in Obsidian (#11).
                if let live = controller.liveTranscriptURL {
                    MarkdownViewerView(url: live, autoRefresh: true)
                } else {
                    Image(systemName: "record.circle")
                        .font(.largeTitle)
                        .foregroundStyle(controller.recordingColor)
                    Text(item.title).font(.headline)
                    Text("Recording now — the transcript appears here a few seconds in.")
                        .foregroundStyle(.secondary)
                }
            } else {
                Image(systemName: item.status == .processing ? "gearshape.2" : "exclamationmark.triangle")
                    .font(.largeTitle)
                    .foregroundStyle(item.status == .processing ? Color.secondary : Color.orange)
                Text(item.title).font(.headline)
                Text(item.status == .processing ? "Still processing…" : "This recording has no transcript document.")
                    .foregroundStyle(.secondary)
                if item.retryable {
                    Button("Reprocess") { controller.retry(item.id) }
                        .buttonStyle(.borderedProminent)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}

private struct RecordingRow: View {
    @EnvironmentObject private var controller: AppController
    let item: AppController.RecentItem

    var body: some View {
        HStack(spacing: 8) {
            statusIcon
            VStack(alignment: .leading, spacing: 2) {
                Text(item.isEmpty ? "No audio captured" : item.title)
                    .lineLimit(1)
                    .foregroundStyle(item.isEmpty ? .secondary : .primary)
                Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .padding(.vertical, 2)
    }

    private var subtitle: String {
        if item.isEmpty { return "\(item.when.formatted(date: .abbreviated, time: .shortened)) · silent mic" }
        var s = item.when.formatted(date: .abbreviated, time: .shortened)
        if let dest = item.destination { s += " · \(dest)" }
        return s
    }

    @ViewBuilder
    private var statusIcon: some View {
        if item.isEmpty {
            Image(systemName: "mic.slash").foregroundStyle(.tertiary)
        } else {
            switch item.status {
            case .completed: Image(systemName: "doc.text").foregroundStyle(Color.accentColor)
            case .failed: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            case .processing: Image(systemName: "gearshape.2").foregroundStyle(.secondary)
            case .recording: Image(systemName: "record.circle").foregroundStyle(controller.recordingColor)
            }
        }
    }
}

/// The collapsed header for a multi-fragment call: meeting name + part count.
private struct CallHeaderRow: View {
    let call: AppController.CallGroup

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "person.wave.2")
                .foregroundStyle(call.allEmpty ? Color.secondary : Color.accentColor)
            VStack(alignment: .leading, spacing: 2) {
                Text(call.allEmpty ? "No audio captured" : call.title)
                    .lineLimit(1)
                    .foregroundStyle(call.allEmpty ? .secondary : .primary)
                Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .padding(.vertical, 2)
    }

    private var subtitle: String {
        var s = "\(call.count) recordings · \(call.when.formatted(date: .abbreviated, time: .shortened))"
        if let dest = call.destination { s += " · \(dest)" }
        return s
    }
}

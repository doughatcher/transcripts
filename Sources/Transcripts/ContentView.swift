import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// List + detail. "New Recording" is a pinned row rather than a floating button,
/// so on iPad the record controls get a real pane instead of drifting in the
/// middle of a mostly-empty screen, and the takes list has somewhere to live.
/// `NavigationSplitView` collapses to a plain stack at compact width, so iPhone
/// keeps the single-column flow for free.
struct ContentView: View {
    @EnvironmentObject private var model: RecorderModel
    @State private var selection: Selection? = .newRecording
    @State private var picking = false
    /// Whether the picker that's open was launched from "Set up for me" (we own a
    /// Transcripts folder inside what they pick) or "Choose a folder" (use it as-is).
    @State private var pickingManaged = true

    enum Selection: Hashable {
        case newRecording
        case take(UUID)
        case transcript(URL)
    }

    /// One row of the unified library.
    ///
    /// A recording exists in two places once the Mac has processed it — the
    /// local audio on this device, and the finished transcript in the shared
    /// folder. They're the same event, so they're one row: the transcript wins,
    /// because it's the finished article and the one every device can see.
    enum Row: Identifiable {
        case local(RecorderModel.Take)
        case shared(TranscriptEntry)

        var id: String {
            switch self {
            case .local(let t): return "l-\(t.id.uuidString)"
            case .shared(let e): return "s-\(e.url.path)"
            }
        }
        var date: Date {
            switch self {
            case .local(let t): return t.startedAt
            case .shared(let e): return e.recordedAt ?? .distantPast
            }
        }
    }

    /// Rows grouped by the day they were recorded.
    ///
    /// A flat reverse-chronological list reads as unrelated items even when
    /// several belong to the same evening — and a session interrupted enough
    /// times becomes several rows regardless. Dating the groups puts them back
    /// together where they belong.
    private var grouped: [(key: Date, rows: [Row])] {
        let cal = Calendar.current
        return Dictionary(grouping: rows) { cal.startOfDay(for: $0.date) }
            .map { (key: $0.key, rows: $0.value.sorted { $0.date > $1.date }) }
            .sorted { $0.key > $1.key }
    }

    private static func dayLabel(_ day: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(day) { return "Today" }
        if cal.isDateInYesterday(day) { return "Yesterday" }
        if let days = cal.dateComponents([.day], from: day, to: Date()).day, days < 7 {
            return day.formatted(.dateTime.weekday(.wide))
        }
        return day.formatted(date: .abbreviated, time: .omitted)
    }

    /// Local takes and shared transcripts as one list, newest first.
    ///
    /// Deduped on `recorded_at`: the Mac stamps a device capture's frontmatter
    /// with the exact start time the phone recorded, so a match within a couple
    /// of seconds is the same recording rather than a coincidence.
    private var rows: [Row] {
        let shared = model.library
        let matched = Set(shared.compactMap { $0.recordedAt.map { $0.timeIntervalSince1970.rounded() } })
        let locals = model.takes.filter {
            !matched.contains($0.startedAt.timeIntervalSince1970.rounded())
                && !matched.contains(($0.startedAt.timeIntervalSince1970 + 1).rounded())
                && !matched.contains(($0.startedAt.timeIntervalSince1970 - 1).rounded())
        }
        return (locals.map(Row.local) + shared.map(Row.shared))
            .sorted { $0.date > $1.date }
    }

    /// Multi-select for merging. Hand-rolled rather than EditMode because the
    /// list's normal selection is a single `Selection?` driving navigation, and
    /// SwiftUI won't swap a list between selection types cleanly.
    @State private var picking2Merge = false
    @State private var picked: Set<UUID> = []
    @State private var merging = false

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Section {
                    NewRecordingRow(isRecording: model.isRecording,
                                    elapsed: model.elapsed,
                                    level: model.level,
                                    waveform: model.waveform) { model.toggle() }
                        .tag(Selection.newRecording)
                }
                ForEach(grouped, id: \.key) { group in
                  Section(Self.dayLabel(group.key)) {
                    ForEach(group.rows) { row in
                      switch row {
                      case .shared(let entry):
                        TranscriptRow(entry: entry).tag(Selection.transcript(entry.url))
                      case .local(let take):
                        if picking2Merge {
                            Button {
                                if picked.contains(take.id) { picked.remove(take.id) }
                                else { picked.insert(take.id) }
                            } label: {
                                TakeRow(take: take, picked: picked.contains(take.id))
                            }
                            .buttonStyle(.plain)
                        } else {
                            TakeRow(take: take, picked: nil)
                                .tag(Selection.take(take.id))
                                .swipeActions(edge: .trailing) {
                                    Button(role: .destructive) {
                                        model.deleteLocal(take)
                                    } label: { Label("Delete", systemImage: "trash") }
                                }
                        }
                      }
                    }
                  }
                }
            }
            .navigationTitle("Transcripts")
            .toolbar {
                if model.takes.count >= 2 {
                    ToolbarItem(placement: .primaryAction) {
                        if picking2Merge {
                            Button("Cancel") { picking2Merge = false; picked = [] }
                        } else {
                            Button("Merge…") { picking2Merge = true }
                        }
                    }
                }
                if picking2Merge {
                    ToolbarItem(placement: .bottomBar) {
                        Button {
                            merging = true
                            let ids = picked
                            picking2Merge = false
                            picked = []
                            Task { await model.merge(ids); merging = false }
                        } label: {
                            Text("Merge \(picked.count) into one recording")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(picked.count < 2)
                    }
                }
            }
            .safeAreaInset(edge: .bottom) {
                WorkspaceBar(destination: model.destination,
                             onAdd: { managed in
                                 pickingManaged = managed
                                 picking = true
                             },
                             onSwitch: { model.refreshLibrary() })
            }
            .overlay {
                if merging {
                    ProgressView("Merging…")
                        .padding(20)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
                }
            }
        } detail: {
            switch selection {
            case .newRecording, .none:
                // Setup comes first: a record button with nowhere to send the
                // audio is a trap, and the first run is the moment the user is
                // actually thinking about where their recordings should live.
                if model.destination.active == nil {
                    SetupPane(picking: $picking, managed: $pickingManaged)
                } else {
                    RecorderPane(picking: $picking, managed: $pickingManaged)
                }
            case .transcript(let url):
                if let entry = model.library.first(where: { $0.url == url }) {
                    TranscriptPane(entry: entry)
                } else {
                    ContentUnavailableView("Transcript gone", systemImage: "doc",
                                           description: Text("It is no longer in the shared folder."))
                }
            case .take(let id):
                if let take = model.takes.first(where: { $0.id == id }) {
                    TakePane(take: take)
                } else {
                    // The take was deleted while its detail was open.
                    ContentUnavailableView("Recording gone",
                                           systemImage: "trash",
                                           description: Text("It was deleted."))
                }
            }
        }
        .refreshable { model.refreshLibrary() }
        .task {
            // The first scan can land before iCloud has materialised anything it
            // was asked for; a second pass a few seconds later picks those up
            // without the user needing to know why the list was short.
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            model.refreshLibrary()
        }
        .onReceive(NotificationCenter.default.publisher(
            for: UIApplication.didBecomeActiveNotification)) { _ in
            model.refreshLibrary()
        }
        .fileImporter(isPresented: $picking, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result {
                model.destination.add(url, managed: pickingManaged)
                model.refreshLibrary()
            }
        }
    }
}

/// Which folder this is looking at, pinned to the bottom of the sidebar.
///
/// A switcher rather than a setting: the library above it is the contents of
/// whichever workspace is selected, so this is the frame around everything else
/// on screen, not a preference buried in a pane.
private struct WorkspaceBar: View {
    @ObservedObject var destination: Destination
    let onAdd: (Bool) -> Void
    let onSwitch: () -> Void

    @State private var renaming: Workspace?
    @State private var draftName = ""

    var body: some View {
        Menu {
            ForEach(destination.workspaces) { w in
                Button {
                    destination.select(w.id)
                    onSwitch()
                } label: {
                    Label(w.name, systemImage: w.id == destination.activeID
                          ? "checkmark.circle.fill" : "folder")
                }
            }
            Divider()
            if let active = destination.active {
                Button {
                    draftName = active.name
                    renaming = active
                } label: { Label("Rename “\(active.name)”", systemImage: "pencil") }
            }
            Button { onAdd(true) } label: {
                Label("Add a workspace…", systemImage: "plus")
            }
            if let active = destination.active, destination.workspaces.count > 1 {
                Button(role: .destructive) {
                    destination.remove(active.id)
                    onSwitch()
                } label: { Label("Forget “\(active.name)”", systemImage: "minus.circle") }
            }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "folder.fill").foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(destination.displayName ?? "No workspace")
                        .font(.subheadline.weight(.medium))
                    Text(destination.workspaces.count > 1
                         ? "\(destination.workspaces.count) workspaces"
                         : "Recordings are saved here")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(.bar)
        }
        .buttonStyle(.plain)
        .alert("Rename workspace", isPresented: Binding(
            get: { renaming != nil },
            set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $draftName)
            Button("Cancel", role: .cancel) { renaming = nil }
            Button("Rename") {
                if let w = renaming { destination.rename(w.id, to: draftName) }
                renaming = nil
            }
        } message: {
            Text("“Personal” and “Work” keep the two libraries apart at a glance.")
        }
    }
}

// MARK: - Sidebar rows

private struct NewRecordingRow: View {
    let isRecording: Bool
    let elapsed: TimeInterval
    let level: Float
    let waveform: [Float]
    let onToggle: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            // The transport lives here rather than in the detail pane: while
            // recording, the pane's job is the transcript, and a stop button is
            // one tap wherever you are in the app.
            Button(action: onToggle) {
                ZStack {
                    // The halo breathes with input level — the same signal the
                    // big button carried, and the reason it read as alive.
                    Circle()
                        .stroke(.red.opacity(0.35), lineWidth: 3)
                        .frame(width: 44, height: 44)
                        .scaleEffect(isRecording ? 1 + CGFloat(level) * 0.22 : 1)
                        .opacity(isRecording ? 1 : 0)
                        .animation(.easeOut(duration: 0.15), value: level)
                    Circle().fill(.red).frame(width: 34, height: 34)
                        .scaleEffect(isRecording ? 1 + CGFloat(level) * 0.07 : 1)
                        .animation(.easeOut(duration: 0.15), value: level)
                    if isRecording {
                        RoundedRectangle(cornerRadius: 3)
                            .fill(.white).frame(width: 12, height: 12)
                    } else {
                        Image(systemName: "mic.fill")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(.white)
                    }
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isRecording ? "Stop recording" : "Start recording")

            VStack(alignment: .leading, spacing: 1) {
                Text(isRecording ? "Recording…" : "New Recording")
                    .fontWeight(.medium)
                if isRecording {
                    Text(Clock.mmss(elapsed))
                        .font(.caption).monospacedDigit().foregroundStyle(.red)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 6)
        .background {
            // The level trace as the pill's own texture — present enough to show
            // the mic is hearing something, quiet enough to read text over.
            if isRecording {
                SidebarWaveform(samples: waveform)
                    .padding(.leading, 46)
                    .opacity(0.5)
                    .allowsHitTesting(false)
            }
        }
    }
}

/// Level trace drawn to sit behind the recording pill's text.
private struct SidebarWaveform: View {
    let samples: [Float]

    var body: some View {
        Canvas { context, size in
            guard !samples.isEmpty else { return }
            let count = RecorderModel.waveformWindow
            let barW = size.width / CGFloat(count)
            let offset = count - samples.count
            for (i, s) in samples.enumerated() {
                let h = max(1.5, CGFloat(s) * size.height * 0.9)
                let x = CGFloat(offset + i) * barW
                let rect = CGRect(x: x, y: (size.height - h) / 2,
                                  width: max(0.8, barW * 0.55), height: h)
                context.fill(Path(roundedRect: rect, cornerRadius: barW * 0.28),
                             with: .color(.red.opacity(0.55)))
            }
        }
    }
}

private struct TakeRow: View {
    let take: RecorderModel.Take
    /// nil = normal row; true/false = merge-picking mode with checkmark state.
    let picked: Bool?

    var body: some View {
        HStack(spacing: 10) {
            if let picked {
                Image(systemName: picked ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(picked ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(take.title ?? take.startedAt.formatted(date: .abbreviated, time: .shortened))
                    .lineLimit(1)
                Text("\(take.startedAt.formatted(date: .omitted, time: .shortened)) · \(Clock.human(take.duration))")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            // Only a genuine problem earns a mark. A recording in a shared
            // folder is simply there; announcing that on every row is noise.
            if !take.exported {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Still syncing")
            }
        }
    }
}

private struct TranscriptRow: View {
    let entry: TranscriptEntry

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.title).lineLimit(1)
                HStack(spacing: 6) {
                    if let at = entry.recordedAt {
                        Text(at.formatted(date: .abbreviated, time: .shortened))
                    }
                    if entry.folder != "transcripts" {
                        Text("· \(entry.folder)")
                    }
                }
                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
        }
    }
}

/// A finished transcript from the shared folder — the Mac's output, readable on
/// whichever device happens to be in your hand.
private struct TranscriptPane: View {
    let entry: TranscriptEntry
    @State private var body_: String = ""
    @State private var query = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(entry.title).font(.title2.weight(.semibold))
                    if let at = entry.recordedAt {
                        Text(at.formatted(date: .complete, time: .shortened))
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                }
                if let summary = entry.summary, !summary.isEmpty {
                    Text(summary)
                        .font(.callout)
                        .padding()
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 12))
                }
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Search this transcript", text: $query)
                        .textFieldStyle(.plain).autocorrectionDisabled()
                    if !query.isEmpty {
                        Button { query = "" } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                        }.buttonStyle(.plain)
                    }
                }
                .padding(8)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 9))

                ForEach(Array(paragraphs.enumerated()), id: \.offset) { _, para in
                    Text(highlighted(para)).font(.callout).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .frame(maxWidth: 620)
            .frame(maxWidth: .infinity)
            .padding(24)
        }
        .navigationTitle("Transcript")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: entry.url) { body_ = entry.body() }
    }

    private var paragraphs: [String] {
        let all = body_.components(separatedBy: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else { return all }
        let q = query.lowercased()
        return all.filter { $0.lowercased().contains(q) }
    }

    private func highlighted(_ text: String) -> AttributedString {
        var s = AttributedString(text)
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return s }
        var range = s.startIndex..<s.endIndex
        while let found = s[range].range(of: q, options: .caseInsensitive) {
            s[found].backgroundColor = .yellow.opacity(0.35)
            guard found.upperBound < s.endIndex else { break }
            range = found.upperBound..<s.endIndex
        }
        return s
    }
}

// MARK: - Detail panes

/// First-run destination choice. Two doors to the same picker: the default one
/// takes a parent folder and creates `Transcripts/` inside it, so the common case is
/// "point at iCloud Drive, done" with no folder admin.
private struct SetupPane: View {
    @EnvironmentObject private var model: RecorderModel
    @Binding var picking: Bool
    @Binding var managed: Bool

    var body: some View {
        VStack(spacing: 20) {
            Spacer(minLength: 0)
            Image(systemName: "folder.badge.gearshape")
                .font(.system(size: 52))
                .foregroundStyle(.tint)
            VStack(spacing: 6) {
                Text("Where should recordings go?").font(.title2.weight(.semibold))
                Text("Recordings are saved as ordinary audio files in a folder you choose. Nothing is ever uploaded.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            VStack(spacing: 12) {
                SetupOption(
                    title: "Set up for me",
                    detail: "Pick your iCloud Drive or OneDrive and Transcripts creates a “\(Destination.managedFolderName)” folder inside it.",
                    icon: "wand.and.stars",
                    prominent: true
                ) { managed = true; picking = true }

                SetupOption(
                    title: "Choose a folder",
                    detail: "Pick an exact folder and Transcripts uses it as-is — including one a Mac already watches.",
                    icon: "slider.horizontal.3",
                    prominent: false
                ) { managed = false; picking = true }
            }

            if let problem = model.destination.problem {
                Label(problem, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote).foregroundStyle(.orange)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: 460)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
        .navigationTitle("Set up")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct SetupOption: View {
    let title: String
    let detail: String
    let icon: String
    let prominent: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: icon).font(.title3).frame(width: 28)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).fontWeight(.semibold)
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(prominent ? AnyShapeStyle(.tint.opacity(0.12))
                                  : AnyShapeStyle(.quaternary.opacity(0.5)),
                        in: RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
    }
}

private struct RecorderPane: View {
    @EnvironmentObject private var model: RecorderModel
    @Binding var picking: Bool
    @Binding var managed: Bool

    enum LivePane: String, CaseIterable {
        case transcript = "Transcript"
        case summary = "Summary"
    }
    @State private var livePane: LivePane = .transcript

    var body: some View {
        VStack(spacing: 16) {
            // While recording the transport lives in the sidebar pill, so the
            // pane is nothing but the text. Idle, the big button is still the
            // obvious thing to press.
            if !model.isRecording {
                Spacer(minLength: 0)
                RecordButton(isRecording: false, level: 0) { model.toggle() }
                Text("Tap to start recording")
                    .font(.footnote).foregroundStyle(.secondary)
            }

            if model.isRecording || !model.chunks.isEmpty {
                Picker("Live view", selection: $livePane) {
                    ForEach(LivePane.allCases, id: \.self) { Text($0.rawValue) }
                }
                .pickerStyle(.segmented)

                switch livePane {
                case .transcript:
                    TranscriptFeed(chunks: model.chunks,
                                   partial: model.partial,
                                   note: model.transcriptionNote)
                        // The text is the point while recording — give it the room.
                        .frame(maxHeight: .infinity)
                case .summary:
                    LivePanel(text: model.liveSummary,
                              placeholder: "A summary appears once there's enough to summarize.",
                              note: nil)
                        .frame(maxHeight: .infinity)
                }
            } else {
                Spacer(minLength: 0)
            }

            if let problem = model.destination.problem ?? model.lastError {
                Label(problem, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        // Wide on purpose: the transcript is the content, and a 560pt column on
        // a 13" iPad left half the pane empty. Only the setup and detail panes
        // stay narrow, where the text really is short.
        .frame(maxWidth: 1000)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .navigationTitle("New Recording")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// The transcript as a scrollable feed of settled chunks.
///
/// Only the tail is shown by default: a two-hour meeting is hundreds of chunks,
/// and rendering all of them to look at the last three is both slow and useless.
/// Searching switches to the whole transcript, because the entire point of
/// searching is to reach something that scrolled away.
private struct TranscriptFeed: View {
    let chunks: [RecorderModel.TranscriptChunk]
    let partial: String
    let note: String?

    /// Enough to read back through the recent conversation without scrolling
    /// forever to reach it.
    private static let tailCount = 60

    @State private var query = ""
    @State private var showingAll = false
    /// Auto-follow pauses while reading back, so scrolling up doesn't fight the
    /// next chunk yanking you to the bottom.
    @State private var following = true

    private var searching: Bool { !query.trimmingCharacters(in: .whitespaces).isEmpty }

    private var visible: [RecorderModel.TranscriptChunk] {
        if searching {
            let q = query.lowercased()
            return chunks.filter { $0.text.lowercased().contains(q) }
        }
        if showingAll || chunks.count <= Self.tailCount { return chunks }
        return Array(chunks.suffix(Self.tailCount))
    }

    private var hidden: Int {
        (searching || showingAll) ? 0 : max(0, chunks.count - Self.tailCount)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search the transcript", text: $query)
                    .textFieldStyle(.plain)
                    .autocorrectionDisabled()
                if searching {
                    Text("\(visible.count)")
                        .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                    Button { query = "" } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(8)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 9))

            if let note {
                Label(note, systemImage: "info.circle")
                    .font(.caption2).foregroundStyle(.secondary)
            }

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        if hidden > 0 {
                            Button("Show \(hidden) earlier") { showingAll = true }
                                .font(.caption)
                                .frame(maxWidth: .infinity)
                        }
                        ForEach(visible) { chunk in
                            ChunkRow(chunk: chunk, highlight: searching ? query : nil)
                        }
                        if !partial.isEmpty && !searching {
                            ChunkRow(chunk: .init(at: -1, text: partial), highlight: nil)
                                .opacity(0.55)
                        }
                        Color.clear.frame(height: 1).id("tail")
                    }
                    .padding(.vertical, 4)
                }
                .onChange(of: chunks.count) {
                    guard following, !searching else { return }
                    withAnimation { proxy.scrollTo("tail", anchor: .bottom) }
                }
                .onChange(of: query) { following = !searching }
                .simultaneousGesture(DragGesture().onChanged { value in
                    // Dragging downward means reaching back for older text.
                    if value.translation.height > 12 { following = false }
                })
            }

            if !following && !searching {
                Button {
                    following = true
                } label: {
                    Label("Jump to latest", systemImage: "arrow.down.circle.fill")
                        .font(.caption)
                }
                .frame(maxWidth: .infinity)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            if chunks.isEmpty && partial.isEmpty {
                Text(searching ? "No matches." : "Listening…")
                    .font(.callout).foregroundStyle(.tertiary)
            }
        }
    }
}

private struct ChunkRow: View {
    let chunk: RecorderModel.TranscriptChunk
    let highlight: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            // Negative marks the in-flight guess, which has no settled time yet.
            Text(chunk.at < 0 ? "···" : Clock.mmss(chunk.at))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.tertiary)
                .frame(width: 44, alignment: .trailing)
            Text(attributed)
                .font(.callout)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Marks every occurrence of the query so a hit is findable inside a long
    /// passage, not just somewhere in the row.
    private var attributed: AttributedString {
        var s = AttributedString(chunk.text)
        guard let q = highlight?.trimmingCharacters(in: .whitespaces), !q.isEmpty else { return s }
        var searchRange = s.startIndex..<s.endIndex
        while let found = s[searchRange].range(of: q, options: .caseInsensitive) {
            s[found].backgroundColor = .yellow.opacity(0.35)
            s[found].inlinePresentationIntent = .stronglyEmphasized
            guard found.upperBound < s.endIndex else { break }
            searchRange = found.upperBound..<s.endIndex
        }
        return s
    }
}

/// The live transcript or summary, auto-following the newest text.
private struct LivePanel: View {
    let text: String
    let placeholder: String
    let note: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let note {
                Label(note, systemImage: "info.circle")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            if text.isEmpty {
                Text(placeholder).font(.callout).foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        Text(text)
                            .font(.callout)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id("tail")
                    }
                    .onChange(of: text) {
                        withAnimation { proxy.scrollTo("tail", anchor: .bottom) }
                    }
                }
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 12))
    }
}

/// A recording this device made, before the Mac has finished with it.
///
/// No transfer ceremony: the workspace is a shared folder, so a finished
/// recording is simply in it. What matters is the content — what was said and
/// what it was about — which the Mac then improves in place.
private struct TakePane: View {
    @EnvironmentObject private var model: RecorderModel
    let take: RecorderModel.Take
    @State private var query = ""
    @State private var confirmingDelete = false

    private var lines: [String] {
        let all = (take.draft ?? "")
            .components(separatedBy: CharacterSet(charactersIn: ".?!\n"))
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        return q.isEmpty ? all : all.filter { $0.lowercased().contains(q) }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(take.title ?? take.startedAt.formatted(date: .abbreviated, time: .shortened))
                        .font(.title2.weight(.semibold))
                    Text("\(take.startedAt.formatted(date: .abbreviated, time: .shortened)) · \(Clock.human(take.duration))")
                        .font(.subheadline).foregroundStyle(.secondary)
                }

                if let summary = take.summary, !summary.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Label("Summary", systemImage: "text.append")
                            .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        Text(summary).font(.callout).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding()
                    .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 12))
                }

                if take.draft?.isEmpty == false {
                    HStack(spacing: 8) {
                        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                        TextField("Search this transcript", text: $query)
                            .textFieldStyle(.plain).autocorrectionDisabled()
                        if !query.isEmpty {
                            Button { query = "" } label: {
                                Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                            }.buttonStyle(.plain)
                        }
                    }
                    .padding(8)
                    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 9))

                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                            Text(line).font(.callout).textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    // Sets expectations without making a ceremony of it: this is
                    // what the phone heard, and the Mac's pass supersedes it.
                    Text("Heard on this device. The Mac re-transcribes from the audio and adds speaker names — this entry is replaced by that version when it lands.")
                        .font(.caption2).foregroundStyle(.tertiary)
                } else {
                    ContentUnavailableView("No transcript",
                                           systemImage: "waveform.slash",
                                           description: Text("Nothing was transcribed on the device. The Mac still has the audio and will transcribe it."))
                        .frame(maxWidth: .infinity)
                }

                Divider()
                HStack(spacing: 12) {
                    if !take.exported {
                        Button("Retry sync") { Task { await model.export(take) } }
                            .buttonStyle(.bordered).controlSize(.small)
                    }
                    Spacer()
                    Button(role: .destructive) { confirmingDelete = true } label: {
                        Label("Delete", systemImage: "trash").font(.footnote)
                    }
                    .buttonStyle(.bordered).controlSize(.small)
                }
            }
            .frame(maxWidth: 720)
            .frame(maxWidth: .infinity)
            .padding(24)
        }
        .navigationTitle(take.title ?? "Recording")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("Delete this recording?", isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) { model.deleteLocal(take) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(take.exported
                 ? "The copy in your workspace stays — this only removes it from this device."
                 : "This recording hasn't reached your workspace yet. Deleting it here loses it.")
        }
    }
}

// MARK: - Pieces

/// Scrolling level history. Shows the take actually has audio in it while it is
/// being made — a dead mic is obvious here long before playback.
private struct LiveWaveform: View {
    let samples: [Float]
    let active: Bool

    var body: some View {
        let count = RecorderModel.waveformWindow
        Canvas { context, size in
            let barW = size.width / CGFloat(count)
            // Right-align so the newest sample sits at the trailing edge and the
            // trace grows leftward as the window fills.
            let offset = count - samples.count
            for (i, s) in samples.enumerated() {
                let h = max(2, CGFloat(s) * size.height)
                let x = CGFloat(offset + i) * barW
                let rect = CGRect(x: x + barW * 0.2,
                                  y: (size.height - h) / 2,
                                  width: max(1, barW * 0.6),
                                  height: h)
                context.fill(Path(roundedRect: rect, cornerRadius: barW * 0.3),
                             with: .color(active ? .red : .gray))
            }
        }
        .opacity(active ? 1 : 0.35)
        .overlay {
            if !active && samples.isEmpty {
                Text("Ready").font(.caption).foregroundStyle(.tertiary)
            }
        }
    }
}

/// Streaming text while the take is running. Auto-scrolls to the tail so the
/// newest words stay visible without the user chasing them.
private struct LiveTranscript: View {
    let text: String
    let note: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let note {
                Label(note, systemImage: "info.circle")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            if !text.isEmpty {
                ScrollViewReader { proxy in
                    ScrollView {
                        Text(text)
                            .font(.callout)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id("tail")
                    }
                    .frame(maxHeight: 160)
                    .onChange(of: text) {
                        withAnimation { proxy.scrollTo("tail", anchor: .bottom) }
                    }
                }
            } else if note == nil {
                Text("Listening…").font(.callout).foregroundStyle(.tertiary)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 12))
    }
}

private struct RecordButton: View {
    let isRecording: Bool
    let level: Float
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .stroke(.red.opacity(0.25), lineWidth: 6)
                    .frame(width: 150, height: 150)
                    .scaleEffect(isRecording ? 1 + CGFloat(level) * 0.12 : 1)
                    .animation(.easeOut(duration: 0.15), value: level)
                Circle().fill(.red).frame(width: 118, height: 118)
                Image(systemName: isRecording ? "stop.fill" : "mic.fill")
                    .font(.system(size: 42))
                    .foregroundStyle(.white)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isRecording ? "Stop recording" : "Start recording")
    }
}

private struct DestinationRow: View {
    let name: String?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack {
                Image(systemName: name == nil ? "folder.badge.plus" : "folder.fill")
                VStack(alignment: .leading, spacing: 2) {
                    Text(name ?? "Choose a destination folder")
                    Text(name == nil
                         ? "iCloud Drive, OneDrive, Dropbox, or on this device"
                         : "Recordings are saved here")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right").foregroundStyle(.tertiary)
            }
            .padding()
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
    }
}

enum Clock {
    static func mmss(_ t: TimeInterval) -> String {
        let s = Int(t)
        return String(format: "%02d:%02d", s / 60, s % 60)
    }

    static func human(_ t: TimeInterval) -> String {
        let s = Int(t)
        return s < 60 ? "\(s)s" : "\(s / 60)m \(s % 60)s"
    }
}

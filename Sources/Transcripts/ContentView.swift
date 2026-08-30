import SwiftUI
import Speech
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

    /// Library-wide search. Matches the title, the draft the phone heard, and a
    /// shared transcript's summary, so "ERP sync" finds the call you never
    /// titled — which is most of them, since titles are model-generated and you
    /// were busy at the time.
    @State private var query = ""

    /// The take a merge was started from, via its context menu. Non-nil presents
    /// the picker for what to join it with.
    @State private var mergeAnchor: RecorderModel.Take?
    @State private var merging = false

    /// The take being renamed, and the text field's contents.
    @State private var renaming: RecorderModel.Take?
    @State private var draftTitle = ""

    /// The shared transcript being renamed, and its own field contents. Separate
    /// from the take's: the two rows offer the same verb but change different
    /// things — one a local label, one a key inside a file every device reads.
    @State private var renamingEntry: TranscriptEntry?
    @State private var entryTitle = ""
    /// The shared transcript a delete has been asked for. Confirmed, unlike a
    /// take's: a take is a local copy of something the Mac also has, and this is
    /// the finished article, possibly the only copy anywhere.
    @State private var deletingEntry: TranscriptEntry?
    @State private var showingArchive = false

    @State private var showingPrivacy = false

    private var searched: [Row] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return rows }
        return rows.filter { row in
            switch row {
            case .local(let t):
                return (t.title ?? "").lowercased().contains(q)
                    || (t.draft ?? "").lowercased().contains(q)
            case .shared(let e):
                return e.title.lowercased().contains(q)
                    || (e.summary ?? "").lowercased().contains(q)
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
        return Dictionary(grouping: searched) { cal.startOfDay(for: $0.date) }
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
                            case .shared(let entry): sharedRow(entry)
                            case .local(let take): takeRow(take)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Transcripts")
            // The app asks for a microphone, speech recognition and a folder in
            // its first thirty seconds. "Where does this go?" is the reasonable
            // response and the phone had nowhere to answer it — the Mac has had
            // an About pane the whole time.
            .toolbar {
                // Only once there is something in it. An empty drawer advertised
                // on the chrome of every screen is a feature asking to be
                // noticed; this one appears the moment it has a reason to.
                if !model.archived.isEmpty {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button { showingArchive = true } label: {
                            Image(systemName: "archivebox")
                        }
                        .accessibilityLabel("Archived")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showingPrivacy = true } label: {
                        Image(systemName: "hand.raised")
                    }
                    .accessibilityLabel("Privacy")
                }
            }
            .sheet(isPresented: $showingPrivacy) { PrivacySheet() }
            .sheet(isPresented: $showingArchive) {
                ArchiveSheet(entries: model.archived,
                             onUnarchive: { model.unarchive($0) },
                             onDelete: { model.delete($0) })
            }
            // Always shown, not the default pull-down-to-reveal. A search field
            // you have to know is there is not a search field, and in a sidebar
            // there is no scroll gesture that obviously uncovers it.
            .searchable(text: $query,
                        placement: .navigationBarDrawer(displayMode: .always),
                        prompt: "Search recordings")
            .overlay {
                if !query.isEmpty && grouped.isEmpty {
                    ContentUnavailableView.search(text: query)
                }
            }
            .alert("Rename recording", isPresented: Binding(
                get: { renaming != nil },
                set: { if !$0 { renaming = nil } })) {
                TextField("Title", text: $draftTitle)
                Button("Save") {
                    if let take = renaming {
                        let name = draftTitle.trimmingCharacters(in: .whitespacesAndNewlines)
                        model.rename(take, to: name.isEmpty ? nil : name)
                    }
                    renaming = nil
                }
                Button("Cancel", role: .cancel) { renaming = nil }
            } message: {
                Text("Titles are written by the model from what it heard, so they are sometimes wrong. Clearing the name puts the date back.")
            }
            .alert("Rename transcript", isPresented: Binding(
                get: { renamingEntry != nil },
                set: { if !$0 { renamingEntry = nil } })) {
                TextField("Title", text: $entryTitle)
                Button("Save") {
                    if let entry = renamingEntry { model.rename(entry, to: entryTitle) }
                    renamingEntry = nil
                }
                Button("Cancel", role: .cancel) { renamingEntry = nil }
            } message: {
                Text("Changes the title inside the transcript, so every device sees it. The filename stays as it is, and so do the links to it.")
            }
            .alert("Delete this transcript?", isPresented: Binding(
                get: { deletingEntry != nil },
                set: { if !$0 { deletingEntry = nil } }),
                presenting: deletingEntry) { entry in
                Button("Delete", role: .destructive) { delete(entry) }
                Button("Cancel", role: .cancel) { deletingEntry = nil }
            } message: { entry in
                Text("“\(entry.title)” and its audio move to the Trash, where Files can still get them back. Every device sharing this folder loses the transcript. Archive keeps it without it being in the way.")
            }
            .alert("Couldn't do that", isPresented: Binding(
                get: { model.libraryError != nil },
                set: { if !$0 { model.libraryError = nil } })) {
                Button("OK", role: .cancel) { model.libraryError = nil }
            } message: {
                Text(model.libraryError ?? "")
            }
            .sheet(item: $mergeAnchor) { anchor in
                MergeSheet(anchor: anchor,
                           candidates: model.takes.filter { $0.id != anchor.id }
                                                  .sorted { $0.startedAt > $1.startedAt }) { ids in
                    mergeAnchor = nil
                    merging = true
                    Task { await model.merge(ids.union([anchor.id])); merging = false }
                } onCancel: {
                    mergeAnchor = nil
                }
            }
            .overlay {
                if merging {
                    ProgressView("Merging…")
                        .padding(20)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
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
        } detail: {
            switch selection {
            case .newRecording, .none:
                // Setup comes first: a record button with nowhere to send the
                // audio is a trap, and the first run is the moment the user is
                // actually thinking about where their recordings should live.
                if model.destination.active == nil {
                    SetupPane(picking: $picking, managed: $pickingManaged)
                } else if model.needsPermissionPriming {
                    // Between "where do recordings go" and the record button,
                    // because the alternative is three system dialogs stacked on
                    // a user who tapped record expecting to record.
                    PermissionsPane()
                } else {
                    RecorderPane(picking: $picking, managed: $pickingManaged)
                }
            case .transcript(let url):
                if let entry = model.library.first(where: { $0.url == url }) {
                    // The pane presents nothing itself: rename and delete both
                    // need a modal, and a sheet already covering the detail
                    // column on iPhone would have to own its own copies of both.
                    // These hand the decision back to the one place holding it.
                    TranscriptPane(entry: entry,
                                   onRename: { startRename(entry) },
                                   onArchive: { archive(entry) },
                                   onDelete: { deletingEntry = entry })
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
            #if DEBUG
            // Open on a recording rather than the recorder, for screenshots.
            // The detail pane is the half of this screen worth showing — the
            // transcript and its scrubber — and nothing but a tap reaches it,
            // which `simctl` cannot do.
            // Prefer a take that has been through the Mac — a title and a
            // summary as well as a transcript — because the newest one is
            // usually the shortest, and a pane holding eight seconds of a note
            // to self shows none of what the pane is for.
            if CommandLine.arguments.contains("--seed-select-take"),
               let best = model.takes
                   .filter({ $0.title != nil && $0.summary?.isEmpty == false })
                   .max(by: { $0.duration < $1.duration })
                   ?? model.takes.max(by: { $0.startedAt < $1.startedAt }) {
                selection = .take(best.id)
            }
            #endif
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

    // MARK: - Sidebar rows
    //
    // Split out of `body` rather than written inline. Two rows with a swipe set,
    // a menu and a tag each is more than the type checker will do in one
    // expression — it gave up on the whole view, and the error it gives up with
    // names neither the row nor the modifier that pushed it over.

    /// A finished transcript from the shared folder.
    ///
    /// Archive on the trailing edge, not delete — the opposite of the take row
    /// below, and for the reason that row already gives: the careless swipe, the
    /// one you make walking, must not be the destructive one. Deleting a take
    /// costs a local copy of something the Mac also has. Deleting one of these
    /// costs the finished article, so the swipe files it away and only the menu
    /// can bin it.
    @ViewBuilder
    private func sharedRow(_ entry: TranscriptEntry) -> some View {
        TranscriptRow(entry: entry)
            .tag(Selection.transcript(entry.url))
            .swipeActions(edge: .trailing) {
                Button { archive(entry) } label: {
                    Label("Archive", systemImage: "archivebox")
                }
                .tint(.orange)
            }
            .swipeActions(edge: .leading) {
                Button { startRename(entry) } label: {
                    Label("Rename", systemImage: "pencil")
                }
                .tint(.indigo)
            }
            .contextMenu { transcriptActions(entry) }
    }

    /// A recording this device made that the Mac hasn't turned into a transcript
    /// yet.
    @ViewBuilder
    private func takeRow(_ take: RecorderModel.Take) -> some View {
        TakeRow(take: take)
            .tag(Selection.take(take.id))
            .swipeActions(edge: .trailing) {
                Button(role: .destructive) {
                    model.deleteLocal(take)
                } label: { Label("Delete", systemImage: "trash") }
            }
            // Repairs on the leading edge, the destructive one on the trailing
            // edge. That is the iOS convention, and it means the careless swipe —
            // the one you make walking — cannot be the one that deletes.
            .swipeActions(edge: .leading) {
                Button {
                    draftTitle = take.title ?? ""
                    renaming = take
                } label: { Label("Rename", systemImage: "pencil") }
                    .tint(.indigo)

                if model.takes.count >= 2 {
                    Button {
                        mergeAnchor = take
                    } label: { Label("Merge", systemImage: "arrow.triangle.merge") }
                        .tint(.teal)
                }
            }
            // Long press rather than a toolbar button. These are occasional
            // repairs — a wrong title, a recording that broke in two — and
            // putting them on the chrome made the library look like something to
            // be managed rather than just read.
            .contextMenu { takeActions(take) }
    }

    @ViewBuilder
    private func takeActions(_ take: RecorderModel.Take) -> some View {
        Button {
            draftTitle = take.title ?? ""
            renaming = take
        } label: { Label("Rename", systemImage: "pencil") }

        if let text = take.draft, !text.isEmpty {
            ShareLink(item: text) {
                Label("Share transcript", systemImage: "square.and.arrow.up")
            }
        }
        ShareLink(item: take.audio) {
            Label("Share audio", systemImage: "waveform")
        }

        if model.takes.count >= 2 {
            Button {
                mergeAnchor = take
            } label: { Label("Merge with…", systemImage: "arrow.triangle.merge") }
        }

        Divider()
        Button(role: .destructive) {
            model.deleteLocal(take)
        } label: { Label("Delete", systemImage: "trash") }
    }

    /// The full set, for the long press. The swipes carry the two you reach for;
    /// this is where the third lives, behind the deliberate gesture, because it
    /// is the one there is no undo for.
    @ViewBuilder
    private func transcriptActions(_ entry: TranscriptEntry) -> some View {
        Button { startRename(entry) } label: { Label("Rename", systemImage: "pencil") }
        Button { archive(entry) } label: { Label("Archive", systemImage: "archivebox") }
        Divider()
        Button(role: .destructive) { deletingEntry = entry } label: {
            Label("Delete", systemImage: "trash")
        }
    }

    private func startRename(_ entry: TranscriptEntry) {
        entryTitle = entry.title
        renamingEntry = entry
    }

    /// Both of these can take the row out from under an open detail pane — on
    /// iPad it is the pane beside the list, on iPhone the one you are standing
    /// in. Sending the selection home first means the change reads as the thing
    /// you asked for rather than as the app losing the transcript.
    private func archive(_ entry: TranscriptEntry) {
        if selection == .transcript(entry.url) { selection = .newRecording }
        model.archive(entry)
    }

    private func delete(_ entry: TranscriptEntry) {
        if selection == .transcript(entry.url) { selection = .newRecording }
        model.delete(entry)
        deletingEntry = nil
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

    var body: some View {
        HStack(spacing: 10) {
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

/// What happens to your recordings, in the app rather than only on a website.
///
/// The wording tracks `docs/guide/privacy.md`, which is the published policy and
/// the URL App Review fetches. Keep them saying the same thing: an in-app claim
/// that outruns the policy is worse than no claim, and this one is checkable —
/// CI fails the build if a networking symbol reaches the binary.
private struct PrivacySheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Nothing leaves this device")
                            .font(.title3.weight(.semibold))
                        Text("Transcripts has no servers, no accounts, no analytics and no advertising. It contains no networking code at all — not disabled, not optional: absent.")
                            .foregroundStyle(.secondary)
                    }

                    Group {
                        Item(icon: "waveform",
                             title: "Recording stays here",
                             detail: "Audio is written to this device as ordinary .m4a files, with the transcript beside it as plain text. Nothing is uploaded.")

                        Item(icon: "text.bubble",
                             title: "Transcribed on this device",
                             detail: "Live text uses Apple's on-device speech recognition. If a device can't recognise speech locally, Transcripts turns live text off and tells you — it does not fall back to a server.")

                        Item(icon: "folder",
                             title: "Your folder, your rules",
                             detail: "Recordings are copied to the folder you pick. If that folder lives in iCloud Drive, OneDrive or Dropbox, that service syncs it under your account and its own policy — the same as any other file you put there.")

                        Item(icon: "mic",
                             title: "Microphone only while recording",
                             detail: "And only after you grant permission. You can revoke it any time in Settings ▸ Privacy & Security ▸ Microphone.")

                        Item(icon: "nosign",
                             title: "Never collected",
                             detail: "No personal information, contacts, location, device identifiers, usage analytics, crash reporting or advertising identifiers. There are no third-party SDKs.")
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Recording is your responsibility")
                            .font(.subheadline.weight(.semibold))
                        Text("Recording laws vary by country and by state, and some require the consent of everyone in the conversation. Transcripts gives you a recorder; the rest is yours.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    .padding()
                    .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 12))

                    Link("Read the full privacy policy",
                         destination: URL(string: "https://transcripts.hatcher.ltd/privacy")!)
                        .font(.callout)

                    Text("Everything above describes how the app is built, not a promise about how it is operated — there is no server to operate.")
                        .font(.caption).foregroundStyle(.tertiary)
                }
                .frame(maxWidth: 640)
                .frame(maxWidth: .infinity)
                .padding(24)
            }
            .navigationTitle("Privacy")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private struct Item: View {
        let icon: String
        let title: String
        let detail: String

        var body: some View {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: icon)
                    .font(.body)
                    .foregroundStyle(.tint)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.subheadline.weight(.semibold))
                    Text(detail).font(.callout).foregroundStyle(.secondary)
                }
            }
        }
    }
}

/// Picks what to join a take with. Reached from a take's context menu, so the
/// anchor is already chosen and this only asks "and which others" — which is
/// the whole reason it can be a sheet rather than a mode over the library.
/// The archive, as a drawer rather than a filter on the library.
///
/// Archiving is for getting something out of the way, and a list you can toggle
/// into is still part of the list you were reading. This is shut unless you went
/// looking, and it is the only place the two ways back out are offered.
private struct ArchiveSheet: View {
    let entries: [TranscriptEntry]
    let onUnarchive: (TranscriptEntry) -> Void
    let onDelete: (TranscriptEntry) -> Void

    @Environment(\.dismiss) private var dismiss
    /// Its own confirmation rather than the library's: an alert attached to the
    /// screen underneath a sheet does not reliably reach the top of the stack,
    /// and a destructive action that appears to do nothing is worse than one
    /// that asks twice.
    @State private var confirming: TranscriptEntry?

    var body: some View {
        NavigationStack {
            List {
                ForEach(entries) { entry in
                    TranscriptRow(entry: entry)
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) { confirming = entry } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                        .swipeActions(edge: .leading) {
                            Button { onUnarchive(entry) } label: {
                                Label("Unarchive", systemImage: "arrow.uturn.backward")
                            }
                            .tint(.indigo)
                        }
                        .contextMenu {
                            Button { onUnarchive(entry) } label: {
                                Label("Unarchive", systemImage: "arrow.uturn.backward")
                            }
                            Divider()
                            Button(role: .destructive) { confirming = entry } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                }
            }
            .overlay {
                if entries.isEmpty {
                    // Reachable: unarchive the last one while the sheet is open.
                    ContentUnavailableView("Nothing archived", systemImage: "archivebox",
                        description: Text("Archived recordings move into an Archive folder beside your transcripts. Nothing is deleted, and every device sees the same archive."))
                }
            }
            .navigationTitle("Archived")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .alert("Delete this transcript?", isPresented: Binding(
                get: { confirming != nil },
                set: { if !$0 { confirming = nil } }),
                presenting: confirming) { entry in
                Button("Delete", role: .destructive) { onDelete(entry); confirming = nil }
                Button("Cancel", role: .cancel) { confirming = nil }
            } message: { entry in
                Text("“\(entry.title)” and its audio move to the Trash, where Files can still get them back.")
            }
        }
    }
}

private struct MergeSheet: View {
    let anchor: RecorderModel.Take
    let candidates: [RecorderModel.Take]
    let onMerge: (Set<UUID>) -> Void
    let onCancel: () -> Void

    @State private var picked: Set<UUID> = []

    var body: some View {
        NavigationStack {
            List {
                Section("Joining") {
                    TakeRow(take: anchor)
                }
                Section("With") {
                    ForEach(candidates) { take in
                        Button {
                            if picked.contains(take.id) { picked.remove(take.id) }
                            else { picked.insert(take.id) }
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: picked.contains(take.id)
                                      ? "checkmark.circle.fill" : "circle")
                                    .font(.title3)
                                    .foregroundStyle(picked.contains(take.id)
                                                     ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))
                                TakeRow(take: take)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .navigationTitle("Merge recordings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onCancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Merge") { onMerge(picked) }
                        .disabled(picked.isEmpty)
                }
            }
            .safeAreaInset(edge: .bottom) {
                Text("They join oldest first into one recording. The originals are removed from this device.")
                    .font(.caption).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24).padding(.bottom, 12)
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
///
/// The file lives in the picked workspace, so every read here goes through the
/// security scope and tolerates iCloud not having downloaded it yet. Both are
/// invisible on the Mac that wrote the file and routine on the iPad that
/// didn't — which is exactly where this pane used to come up blank.
private struct TranscriptPane: View {
    @EnvironmentObject private var model: RecorderModel
    let entry: TranscriptEntry
    /// Rename, archive and delete, owned by `ContentView` — see the comment
    /// where this pane is built.
    let onRename: () -> Void
    let onArchive: () -> Void
    let onDelete: () -> Void
    /// nil while loading or failed; `settled` says which.
    @State private var text: String?
    @State private var settled = false
    @State private var audio: URL?
    @State private var audioSettled = false
    @State private var query = ""

    var body: some View {
        ScrollView {
            // Lazy on purpose: a two-hour meeting is thousands of lines, and
            // materialising every row before first paint froze the pane long
            // enough to read as broken.
            LazyVStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(entry.title).font(.title2.weight(.semibold))
                    if let at = entry.recordedAt {
                        Text(at.formatted(date: .complete, time: .shortened))
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                }

                if entry.audioFile != nil {
                    if let audio {
                        AudioScrubber(url: audio, disabled: model.isRecording)
                    } else if !audioSettled {
                        Label("Fetching the audio…", systemImage: "icloud.and.arrow.down")
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        Text("The audio hasn't synced to this device yet.")
                            .font(.caption).foregroundStyle(.tertiary)
                    }
                }

                if let summary = entry.summary, !summary.isEmpty {
                    Text(summary)
                        .font(.callout)
                        .padding()
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 12))
                }

                if let text {
                    if text.isEmpty {
                        // Read fine, and there is nothing under the frontmatter.
                        // Without this the pane goes blank and reads exactly like
                        // the failure this screen was built to stop showing.
                        ContentUnavailableView("No transcript text",
                                               systemImage: "doc",
                                               description: Text("This entry has a summary but no transcript body."))
                    } else {
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
                            line(para)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                } else if !settled {
                    ProgressView("Fetching the transcript…")
                        .frame(maxWidth: .infinity)
                        .padding(.top, 40)
                } else {
                    ContentUnavailableView {
                        Label("Not on this device yet", systemImage: "icloud.and.arrow.down")
                    } description: {
                        Text("The transcript is still syncing from the shared folder. It usually arrives within a moment of the Mac writing it.")
                    } actions: {
                        Button("Try again") { Task { await load() } }
                    }
                }
            }
            .frame(maxWidth: 620)
            .frame(maxWidth: .infinity)
            .padding(24)
        }
        .navigationTitle("Transcript")
        .navigationBarTitleDisplayMode(.inline)
        // The list has these on a swipe, and on iPhone the list is somewhere you
        // are not: you decide a transcript is mistitled while reading it, and
        // going back a screen to say so is the step that stops you bothering.
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button(action: onRename) { Label("Rename", systemImage: "pencil") }
                    Button(action: onArchive) { Label("Archive", systemImage: "archivebox") }
                    Divider()
                    Button(role: .destructive, action: onDelete) {
                        Label("Delete", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .accessibilityLabel("Actions")
            }
        }
        .task(id: entry.url) { await load() }
    }

    private func load() async {
        text = nil; settled = false
        audio = nil; audioSettled = false
        guard let bookmark = model.destination.active?.bookmark else {
            settled = true; audioSettled = true
            return
        }
        // Concurrent, then surfaced as each lands: the text is a fast read and
        // shouldn't wait behind a 40 MB audio download.
        async let body = SharedLibrary.body(of: entry, bookmark: bookmark)
        async let sound = SharedLibrary.localAudio(for: entry, bookmark: bookmark)
        text = await body; settled = true
        audio = await sound; audioSettled = true
    }

    private var paragraphs: [String] {
        let all = (text ?? "").components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else { return all }
        let q = query.lowercased()
        return all.filter { $0.lowercased().contains(q) }
    }

    /// One line of the document, with just enough markdown to match what the
    /// Mac writes: `##` section headings, `**bold**` speaker names and bullet
    /// lists. Anything fancier renders as the plain text it is.
    @ViewBuilder
    private func line(_ raw: String) -> some View {
        if raw.hasPrefix("#") {
            Text(raw.drop(while: { $0 == "#" }).trimmingCharacters(in: .whitespaces))
                .font(.headline)
                .padding(.top, 8)
        } else {
            Text(highlighted(raw))
                .font(.callout)
                .textSelection(.enabled)
        }
    }

    private func highlighted(_ text: String) -> AttributedString {
        var line = text
        if line.hasPrefix("* ") || line.hasPrefix("- ") {
            line = "•\u{2002}" + line.dropFirst(2)
        }
        var s = (try? AttributedString(
            markdown: line,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(line)
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

/// Asks for the microphone and speech recognition *before* iOS does, and warns
/// about what iOS is about to say.
///
/// Two problems this solves. First, permission prompts fired by tapping Record
/// interrupt the one action the user came to perform. Second, and worse: the
/// system's speech dialog states that speech data "will be sent to Apple to
/// process your requests" — boilerplate shown to every app, and simply untrue
/// here, because `startTranscribing()` sets `requiresOnDeviceRecognition` and
/// refuses to run at all on a device without local support. We cannot edit
/// Apple's dialog, so we get there first: told beforehand that the sentence is
/// coming and does not apply, the user reads it as the formality it is instead
/// of as a contradiction of everything the app claims.
private struct PermissionsPane: View {
    @EnvironmentObject private var model: RecorderModel
    @State private var asking = false

    var body: some View {
        VStack(spacing: 20) {
            Spacer(minLength: 0)
            Image(systemName: "waveform.badge.mic")
                .font(.system(size: 52))
                .foregroundStyle(.tint)

            VStack(spacing: 6) {
                Text("Two permissions and you're set")
                    .font(.title2.weight(.semibold))
                    .multilineTextAlignment(.center)
                Text("Both are used only while you are recording.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            VStack(spacing: 12) {
                PermissionRow(icon: "mic.fill", title: "Microphone",
                              detail: "Captures the audio. Without it there is no recording.")
                PermissionRow(icon: "text.bubble.fill", title: "Speech Recognition",
                              detail: "Writes down what it hears, on this device. Decline and you still get the recording — just no live text.")
            }

            // The whole point of this screen.
            VStack(alignment: .leading, spacing: 6) {
                Label("About the next screen", systemImage: "info.circle.fill")
                    .font(.subheadline.weight(.semibold))
                Text("iOS will say speech data is “sent to Apple.” That is Apple's standard wording for every app that asks. Transcripts requires on-device recognition — if this device can't do it locally, live text switches off rather than send your audio anywhere.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))

            Button {
                asking = true
                Task {
                    await model.primePermissions()
                    asking = false
                }
            } label: {
                Text(asking ? "Waiting…" : "Continue")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(asking)

            Spacer(minLength: 0)
        }
        .padding(24)
        .frame(maxWidth: 520)
        .navigationTitle("Permissions")
    }
}

private struct PermissionRow: View {
    let icon: String
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(.tint)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(detail)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding()
        .frame(maxWidth: .infinity)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
    }
}

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
                Text("Recordings are saved as ordinary audio files in a folder you choose. Transcribing happens on this device.")
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
    /// Why a recording came back without text. Speech authorisation is read at
    /// render time rather than stored per take: if it is still denied that is
    /// the live answer and the actionable one, and if it has since been granted
    /// the honest thing to say is that the Mac will handle this one.
    static var noTranscriptReason: String {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .denied, .restricted:
            return "Speech Recognition is off for Transcripts, so the phone could not write this down. Turn it on in Settings ▸ Privacy & Security ▸ Speech Recognition. The Mac still has the audio and will transcribe it."
        default:
            return "Nothing was transcribed on the device. The Mac still has the audio and will transcribe it."
        }
    }

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

                AudioScrubber(url: take.audio, disabled: model.isRecording)

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
                    // Say why, not just that. The app knows at record time
                    // whether speech recognition was allowed, and used to
                    // report it only in the live pane while recording — so a
                    // take with no transcript was silent about the one thing
                    // that would let you fix it.
                    ContentUnavailableView("No transcript",
                                           systemImage: "waveform.slash",
                                           description: Text(Self.noTranscriptReason))
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

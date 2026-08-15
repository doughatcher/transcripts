import SwiftUI
import TranscriptsCore
import TranscriptsEngine

/// The "who is this voice?" surface (#6). Two grids: voices waiting to be named
/// (each playable, with an editable name the transcript guessed) and voices
/// already remembered. Replaces the one-at-a-time menu banner with a review
/// board you can hear.
struct VoicesGrid: View {
    @EnvironmentObject private var controller: AppController
    @StateObject private var player = VoiceSnippetPlayer.shared

    private let columns = [GridItem(.adaptive(minimum: 200, maximum: 320), spacing: 10)]

    var body: some View {
        let suggestions = controller.voiceSuggestions
        let profiles = controller.voiceProfiles

        if !suggestions.isEmpty {
            Text("Waiting to be named — play each and type who it is")
                .font(.caption).foregroundStyle(.secondary)
            LazyVGrid(columns: columns, alignment: .leading, spacing: 10) {
                ForEach(suggestions) { s in
                    PendingVoiceCard(player: player, suggestion: s)
                }
            }
            .padding(.bottom, 4)
        }

        Text("Remembered")
            .font(.caption).foregroundStyle(.secondary)
        if profiles.isEmpty {
            Text("No voices remembered yet. After a call, voices Transcripts can name will appear above to confirm.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            LazyVGrid(columns: columns, alignment: .leading, spacing: 10) {
                ForEach(profiles, id: \.name) { p in
                    EnrolledVoiceCard(player: player, profile: p)
                }
            }
        }
    }
}

/// A voice Transcripts thinks it can name, with the guessed name editable before you
/// commit it. Play it to check, fix the name if the transcript was wrong.
private struct PendingVoiceCard: View {
    @EnvironmentObject private var controller: AppController
    @ObservedObject var player: VoiceSnippetPlayer
    let suggestion: SpeakerSuggestion
    @State private var name: String = ""
    @State private var affiliation: String = ""
    @State private var addingNew = false
    @State private var newName = ""
    @State private var loaded = false

    /// An unnamed voice is very often someone already enrolled whose match just
    /// fell short of the confidence bar — so the default picker is "who do we
    /// already know," not a blank field waiting to be typed into.
    private var knownNames: [String] {
        controller.voiceProfiles.map(\.name)
            .filter { $0 != FluidAudioDiarizer.selfName }
            .sorted()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                PlayButton(path: suggestion.sampleAudioPath, player: player)
                nameControl
            }
            AffiliationPicker(value: $affiliation)
            Text(subtitle)
                .font(.caption2).foregroundStyle(.secondary)
                .lineLimit(1)
            HStack {
                Button {
                    controller.resolveVoiceSuggestion(id: suggestion.id, accept: true,
                                                      as: name, affiliation: affiliation)
                } label: { Label(suggestion.isNamed ? "Confirm" : "Save", systemImage: "checkmark") }
                    .buttonStyle(.borderedProminent).controlSize(.small)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                Button(role: .destructive) {
                    controller.resolveVoiceSuggestion(id: suggestion.id, accept: false, as: name)
                } label: { Label("Ignore", systemImage: "xmark") }
                    .controlSize(.small)
            }
        }
        .padding(10)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
        .onAppear {
            guard !loaded else { return }
            loaded = true
            name = suggestion.name
            affiliation = suggestion.affiliation ?? ""
        }
    }

    /// For a named guess, just where it was heard; for an unnamed voice, lead with
    /// the diarizer label so several cards from one meeting stay distinguishable.
    private var subtitle: String {
        suggestion.isNamed
            ? "Heard in \(suggestion.sourceTitle)"
            : "\(suggestion.label.isEmpty ? "A voice" : suggestion.label) · \(suggestion.sourceTitle)"
    }

    /// Dropdown-first: pick an already-known voice, or type a new one. Matches
    /// the same "reassign from a list" pattern as the meeting review UI, since a
    /// blank name here is most often an existing person who just missed the
    /// match-confidence bar.
    @ViewBuilder
    private var nameControl: some View {
        if addingNew {
            HStack(spacing: 6) {
                TextField("New name", text: $newName)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { commitNew() }
                Button("Set", action: commitNew).controlSize(.small)
                    .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
                Button("Cancel") { addingNew = false }.controlSize(.small)
            }
        } else {
            Menu {
                if knownNames.isEmpty {
                    Text("No saved voices yet").foregroundStyle(.secondary)
                } else {
                    Section("Most likely — pick who this is") {
                        ForEach(knownNames, id: \.self) { person in
                            Button(person) { name = person }
                        }
                    }
                }
                Divider()
                Button("New name…") { newName = name; addingNew = true }
            } label: {
                HStack(spacing: 4) {
                    Text(name.isEmpty ? "Who is this?" : name)
                        .foregroundStyle(name.isEmpty ? .secondary : .primary)
                        .lineLimit(1)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
    }

    private func commitNew() {
        let n = newName.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty else { return }
        name = n
        addingNew = false
    }
}

/// An already-remembered voice: play it to remind yourself who it is, or forget
/// it. Your own auto-enrolled voice can't be forgotten by accident here.
private struct EnrolledVoiceCard: View {
    @EnvironmentObject private var controller: AppController
    @ObservedObject var player: VoiceSnippetPlayer
    let profile: SpeakerProfile
    @State private var affiliation: String = ""
    @State private var loaded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                PlayButton(path: profile.sampleAudioPath, player: player)
                VStack(alignment: .leading, spacing: 1) {
                    Text(profile.isSelf ? "\(profile.name) (you)" : profile.name)
                        .lineLimit(1)
                    Text("\(profile.meetings) meeting\(profile.meetings == 1 ? "" : "s")")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                Spacer(minLength: 4)
                if !profile.isSelf {
                    Button { controller.removeVoiceProfile(profile.name) } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless).controlSize(.small)
                    .help("Forget this voice")
                }
            }
            // Affiliation, as a pick-or-fill dropdown; commits immediately.
            AffiliationPicker(value: $affiliation) { controller.setVoiceAffiliation(profile.name, to: $0) }
        }
        .padding(10)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
        .onAppear {
            guard !loaded else { return }
            loaded = true
            affiliation = profile.affiliation ?? ""
        }
    }
}

/// A dropdown of the orgs/clients already in use, plus a fill-in for a new one —
/// the same list principle as reassigning a speaker. Binds a String; `onPick`
/// fires when a value is chosen so an enrolled card can persist immediately.
struct AffiliationPicker: View {
    @EnvironmentObject private var controller: AppController
    @Binding var value: String
    var onPick: (String) -> Void = { _ in }
    @State private var addingNew = false
    @State private var newValue = ""

    var body: some View {
        if addingNew {
            HStack(spacing: 6) {
                TextField("New organization", text: $newValue)
                    .textFieldStyle(.roundedBorder).font(.caption)
                    .onSubmit { commit() }
                Button("Set", action: commit).controlSize(.small)
                    .disabled(newValue.trimmingCharacters(in: .whitespaces).isEmpty)
                Button("Cancel") { addingNew = false }.controlSize(.small)
            }
        } else {
            Menu {
                Section("Affiliation") {
                    ForEach(controller.knownAffiliations, id: \.self) { org in
                        Button(org) { pick(org) }
                    }
                }
                Divider()
                Button("New organization…") { newValue = ""; addingNew = true }
                if !value.isEmpty { Button("Clear", role: .destructive) { pick("") } }
            } label: {
                HStack(spacing: 4) {
                    Text(value.isEmpty ? "Organization / client" : value)
                        .foregroundStyle(value.isEmpty ? .secondary : .primary)
                        .lineLimit(1)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                .font(.caption)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
    }

    private func pick(_ v: String) { value = v; onPick(v) }
    private func commit() {
        let v = newValue.trimmingCharacters(in: .whitespaces)
        guard !v.isEmpty else { return }
        pick(v); addingNew = false
    }
}

/// Play/stop for one clip. Disabled (dimmed) when there's no audio — an older
/// profile enrolled before snippets, or a cluster too short to sample.
struct PlayButton: View {
    let path: String?
    @ObservedObject var player: VoiceSnippetPlayer

    var body: some View {
        let isPlaying = path != nil && player.playingPath == path
        Button {
            if let path { player.toggle(path: path) }
        } label: {
            Image(systemName: isPlaying ? "stop.circle.fill" : "play.circle.fill")
                .font(.title2)
                .foregroundStyle(path == nil ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.tint))
        }
        .buttonStyle(.borderless)
        .disabled(path == nil)
        .help(path == nil ? "No voice sample for this one" : (isPlaying ? "Stop" : "Play a few seconds"))
    }
}

import SwiftUI
import TranscriptsCore
import TranscriptsEngine

/// Review and fix who-said-what, per meeting (#6). Diarization on calls full of
/// similar voices will sometimes match the wrong person — this is where you hear
/// each speaker and correct it. A correction shifts the voiceprints and rewrites
/// the transcript, so the fix sticks and future calls get better.
struct MeetingReview: View {
    @EnvironmentObject private var controller: AppController
    @StateObject private var player = VoiceSnippetPlayer.shared

    /// Only show meetings recent enough to still have their clips.
    private var meetings: [MeetingAttribution] {
        Array(controller.meetingAttributions.prefix(15))
    }

    var body: some View {
        if meetings.isEmpty {
            Text("Attributed meetings show up here after they process, so you can hear each speaker and fix any that were matched to the wrong person.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            ForEach(meetings) { meeting in
                MeetingRow(player: player, meeting: meeting)
            }
        }
    }
}

private struct MeetingRow: View {
    @EnvironmentObject private var controller: AppController
    @ObservedObject var player: VoiceSnippetPlayer
    let meeting: MeetingAttribution
    @State private var expanded = false

    private var reviewable: [MeetingSpeaker] { meeting.speakers.filter { !$0.isSelf } }

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            ForEach(reviewable) { speaker in
                SpeakerReviewRow(player: player, recordingID: meeting.recordingID, speaker: speaker)
            }
        } label: {
            VStack(alignment: .leading, spacing: 1) {
                Text(meeting.meetingName ?? "Recording")
                    .lineLimit(1)
                Text("\(meeting.meetingDate.formatted(date: .abbreviated, time: .shortened)) · \(reviewable.count) speaker\(reviewable.count == 1 ? "" : "s") to review")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
    }
}

private struct SpeakerReviewRow: View {
    @EnvironmentObject private var controller: AppController
    @ObservedObject var player: VoiceSnippetPlayer
    let recordingID: String
    let speaker: MeetingSpeaker
    @State private var addingNew = false
    @State private var newName = ""

    /// Everyone Transcripts knows, minus you and minus this speaker's current name —
    /// the candidates to reassign this voice to.
    private var candidates: [String] {
        controller.voiceProfiles.map(\.name)
            .filter { $0 != FluidAudioDiarizer.selfName && $0 != speaker.label }
            .sorted()
    }
    private var isAnonymous: Bool { SpeakerTurns.isAnonymousLabel(speaker.label) }

    var body: some View {
        HStack(spacing: 8) {
            PlayButton(path: speaker.clipPath, player: player)

            if addingNew {
                TextField("New name", text: $newName)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 200)
                    .onSubmit { commitNew() }
                Button("Save", action: commitNew)
                    .controlSize(.small)
                    .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
                Button("Cancel") { addingNew = false }
                    .controlSize(.small)
            } else {
                // The dropdown: current name on the button, every known person
                // inside, plus a fill-in. Picking a name reassigns immediately.
                Menu {
                    if candidates.isEmpty {
                        Text("No other saved voices yet").foregroundStyle(.secondary)
                    } else {
                        Section("Reassign this voice to") {
                            ForEach(candidates, id: \.self) { person in
                                Button(person) { reassign(to: person) }
                            }
                        }
                    }
                    Divider()
                    Button("New name…") { newName = ""; addingNew = true }
                    // The over-match fix: if the current label is a name (not
                    // already a Speaker N), let the user say "that's not them."
                    if !isAnonymous {
                        Button("Not \(speaker.label) — unknown voice", role: .destructive) {
                            controller.markSpeakerUnknown(recordingID: recordingID, label: speaker.label)
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text(speaker.label).lineLimit(1)
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
            Spacer(minLength: 4)
        }
    }

    private func reassign(to name: String) {
        controller.reassignSpeaker(recordingID: recordingID, label: speaker.label, to: name)
    }

    private func commitNew() {
        let n = newName.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty else { return }
        reassign(to: n)
        addingNew = false
    }
}

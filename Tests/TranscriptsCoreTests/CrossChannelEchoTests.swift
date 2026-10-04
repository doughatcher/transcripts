import Testing
import Foundation
@testable import TranscriptsCore

/// Cross-channel echo on a speakerphone call: the same utterance lands on both
/// tracks and must survive as exactly one turn, under the speaker the evidence
/// supports. Shapes taken from the 2026-10-04 77-minute interview where a
/// two-person call came out as six speakers with most turns doubled.
struct CrossChannelEchoTests {

    private func seg(_ speaker: String, _ start: Double, _ text: String) -> AttributedSegment {
        AttributedSegment(speaker: speaker, start: start, text: text)
    }

    @Test func diarizedSystemCopyBeatsMicMe() {
        // Dad's story bleeds into Doug's mic; diarization put it under Speaker 1.
        let mine = [seg("Me", 640, "I don't know if you remember George.")]
        let theirs = [seg("Speaker 1", 640.4, "I don't know if you remember George.")]
        let out = SpeakerTurns.dedupeCrossChannel(mine: mine, theirs: theirs, fallback: "Others")
        #expect(out.mine.isEmpty)
        #expect(out.theirs == theirs)
    }

    @Test func micMeBeatsFallbackSystemCopy() {
        // Doug's own voice echoes back through the call audio with no diarized
        // span behind it — the fallback-labeled copy is the one to drop.
        let mine = [seg("Me", 642, "Oh, yeah. Who owns that house right next door to you?")]
        let theirs = [seg("Others", 643, "Oh yeah, who owns that house right next door to you")]
        let out = SpeakerTurns.dedupeCrossChannel(mine: mine, theirs: theirs, fallback: "Others")
        #expect(out.mine == mine)
        #expect(out.theirs.isEmpty)
    }

    @Test func distinctSpeechAtTheSameMomentIsKept() {
        let mine = [seg("Me", 100, "So tell me about buying the store back then.")]
        let theirs = [seg("Speaker 1", 101, "Well, that was eighty-eight or eighty-nine, I believe.")]
        let out = SpeakerTurns.dedupeCrossChannel(mine: mine, theirs: theirs, fallback: "Others")
        #expect(out.mine.count == 1)
        #expect(out.theirs.count == 1)
    }

    @Test func identicalWordsFarApartInTimeAreKept() {
        // The same sentence twenty seconds apart is repetition, not echo.
        let mine = [seg("Me", 100, "I don't know if you remember George.")]
        let theirs = [seg("Speaker 1", 120, "I don't know if you remember George.")]
        let out = SpeakerTurns.dedupeCrossChannel(mine: mine, theirs: theirs, fallback: "Others")
        #expect(out.mine.count == 1)
        #expect(out.theirs.count == 1)
    }

    @Test func shortBackchannelDedupesOnlyOnExactTightMatch() {
        // "Yeah." is said by everybody constantly: both sides keep theirs when
        // the clocks disagree beyond the tight window…
        let mine = [seg("Me", 100, "Yeah.")]
        let farApart = [seg("Speaker 1", 104, "Yeah.")]
        let kept = SpeakerTurns.dedupeCrossChannel(mine: mine, theirs: farApart, fallback: "Others")
        #expect(kept.mine.count == 1 && kept.theirs.count == 1)

        // …but an exact match a second apart is one person heard twice.
        let close = [seg("Speaker 1", 101, "Yeah.")]
        let deduped = SpeakerTurns.dedupeCrossChannel(mine: mine, theirs: close, fallback: "Others")
        #expect(deduped.mine.isEmpty)
        #expect(deduped.theirs.count == 1)
    }

    @Test func driftBetweenEnginesStillCountsAsDuplicate() {
        // The two tracks are transcribed independently, so the copies differ in
        // punctuation and a word or two.
        let mine = [seg("Me", 2919, "But George told me he was doing well, see, I didn't have a job when I first got out.")]
        let theirs = [seg("Speaker 1", 2920, "But George told me he was doing, well, see, I didn't have a job when I 1st got out")]
        let out = SpeakerTurns.dedupeCrossChannel(mine: mine, theirs: theirs, fallback: "Others")
        #expect(out.mine.isEmpty)
        #expect(out.theirs.count == 1)
    }

    @Test func eachEchoConsumesOneCopyOnly() {
        // Two people genuinely saying similar things near-simultaneously must
        // not be collapsed to zero: a duplicate pair removes one copy, never both.
        let mine = [seg("Me", 100, "I don't know if you remember George."),
                    seg("Me", 102, "I don't know if you remember George.")]
        let theirs = [seg("Speaker 1", 101, "I don't know if you remember George.")]
        let out = SpeakerTurns.dedupeCrossChannel(mine: mine, theirs: theirs, fallback: "Others")
        #expect(out.mine.count + out.theirs.count == 2)
    }
}

/// Long-transcript summarization must reduce oversized notes with further model
/// passes, never by cutting them off — the title is derived from the whole
/// conversation or not at all.
struct LongSummaryTests {
    private struct CountingModel: ChatModel {
        let calls: Counter
        func chat(system: String, user: String, jsonFormat: Bool, maxTokens: Int) async throws -> String {
            await calls.add(user)
            if system.contains("condense") || system.contains("You condense") {
                return "- note from a part"
            }
            return "TITLE: Whole Conversation Title\n\n**TL;DR:** ok\n\n**Key Points:**\n- a\n\n**Action Items:**\n- N/A"
        }
    }
    actor Counter {
        var users: [String] = []
        func add(_ u: String) { users.append(u) }
    }

    @Test func oversizedTranscriptNeverTruncatesNotesIntoTheFinalPrompt() async throws {
        let counter = Counter()
        let model = CountingModel(calls: counter)
        // ~5 budgets of transcript → multiple chunks; stub notes stay small, so
        // one condense round suffices and the final prompt carries them intact.
        let sentence = "This is one sentence of a very long biographical interview. "
        let transcript = String(repeating: sentence, count: (SummarizeStage.promptCharBudget * 5) / sentence.count)
        let raw = try await SummarizeStage.summarize(transcript, with: model)
        #expect(raw.contains("TITLE:"))
        let finals = await counter.users.filter { $0.contains("CONDENSED NOTES") }
        #expect(finals.count == 1)
        #expect(finals[0].count <= SummarizeStage.promptCharBudget + 200)
    }
}

# Capture diagnostics

Each new macOS capture writes `capture-diagnostics.jsonl` beside its audio in
Application Support. Scribe uses the renamed Application Support directory.
The sidecar follows existing capture-backup retention; it is not copied into
meeting notes or sent anywhere.

The first event includes the capture ID, application/build/OS and process ID.
Start, stop and 15-second snapshots record requested and actual AudioUnit input,
Core Audio default input/output, device names/UIDs/rates, aggregate membership,
mute state, meeting-app device UIDs and whether mic voice processing is enabled.
The system start event identifies Core Audio tap versus ScreenCaptureKit and the
capture scope. `input-selection` records the preferences and call inputs used to
choose the microphone.

Per-track counters distinguish received, written, dropped and failed-write
buffers. First/last source timestamps, callback arrival dates, written duration
and source-clock discontinuities help separate capture latency, missing data and
clock changes. Mic source time is host seconds; system source time is the incoming
presentation timestamp. Do not substitute callback arrival dates for source
clock alignment. Mic frame counts refer to the input buffers; a format converter
can change the frame count written to the file while preserving its duration.

Recovery events link the prior capture paths and their placements. Archive mix
events record the files and actual placements, separately from the offset used
for transcription. This exposes the current zero-offset archive mix behavior.
The sidecar contains no audio samples, window titles or transcript content.
Device UIDs are local diagnostic identifiers, so inspect the file before sharing.

Run the installed app with `TRANSCRIPTS_SELFCHECK=1` to exercise both capture
flows and validate the diagnostic file. The self-check deletes its test capture.
For Scribe, the environment variable is renamed to `SCRIBE_SELFCHECK`.

## Shared-signal audit

`scripts/audit-call-audio.py <capture-directory>` compares saved separate tracks.
Run it with a Python environment containing NumPy and SciPy; decoding uses macOS
`afconvert`. `--self-test` checks a known delayed copy, unrelated signal and
silence. `--output <path>` also saves the JSON results.

The audit bandpasses mono audio to 250–3000 Hz, compares 10-second windows every
30 seconds, and searches up to 10 seconds either side. Correlation magnitude at
least 0.3 flags shared-signal evidence. It skips silent mic windows and guards
against numerical noise in silent system windows. It does not establish the
source of the shared signal, detect every kind of echo, or rate audibility.
Reported lag is system index minus mic index on the stored file timelines;
assembled backups can already contain offsets. Compare the diagnostic placements
before interpreting that number as physical acoustic latency.

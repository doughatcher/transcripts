# Overlay views

Status: **designed, not built.** The retrieval overlay — `OverlayEngine`,
`PassageIndex`, `QuestionDetector`, `OverlayCard` — is built and shipping.
Everything here is the next step.

## The problem

There is one overlay and it does one thing: notice a question, retrieve against
the indexed passages, show what the record already says. It is good at that, and
it is the only thing it can ever be, because the behaviour is compiled in.

A second behaviour — "someone just asked for my take, tell me what I know" —
is not a variation on retrieval. It fires on different turns, needs different
context, and wants a different model. Today adding it means editing
`OverlayEngine`, rebuilding, reinstalling. That is fine for the second view and
hopeless for the tenth, and the interesting ones are the tenth: a view that only
makes sense during one negotiation, on one Tuesday, is worth having and not
worth shipping.

## The discriminator already exists

`QuestionDetector.fillers` is a suppress list, and half of it is not noise:

```swift
"what do you think", "what are your thoughts", "how do you feel",
"any questions", "any other questions", "any questions on that",
```

Its own comment says why they are there — "comprehension checks, call-quality
checks, and **requests for an opinion**" — and for a retrieval overlay that is
correct, because the passage index cannot answer what you think.

Those turns are exactly the trigger for a feedback view. So the set wants
splitting, not extending:

| Bucket | Example | Routes to |
|---|---|---|
| answerable question | "when's the deadline?" | retrieval |
| **solicitation** | "what are your thoughts?" | **feedback** |
| noise | "can you hear me?" | dropped |

No classifier, no model, no added latency. People asking for your take say one
of about fifteen things, and they are already written down. Gate on speaker as
well — `Others` asking fires, `Me` asking does not — which `live.md` already
attributes.

## The shape

**A view is data, not Swift.** Four parts, all of which map onto something that
already exists:

- **Trigger** — which turns wake it. `question`, `solicitation`, `topicChange`
  (`TopicSegmenter` is built), `manual`, `timer`.
- **Context** — what it gets. A transcript window from `live.md`, passage
  retrieval from `PassageIndex`, the case folder that `.transcripts/routing.json`
  already resolves, or the output of a command.
- **Engine** — who reasons. In-process (FoundationModels, MLX) or a spawned
  `claude -p` for the views that need the whole machine.
- **Render** — `OverlayCard` already models `fact` / `conclusion` / `question`
  with a headline, an optional answer, a source and a timestamp. A view picks a
  kind and fills it.

Views live in a folder, are read at launch and on change, and are listed in the
overlay as tabs. The shipping retrieval view becomes one entry among them rather
than the hardcoded default.

## Authoring

A prompt box at the foot of the overlay, hidden until summoned, writes a view
file and reloads it. That is the whole mechanism — because the view is a file,
generating one is writing text, and an agent can do it in a sentence.

**But not live.** A generated view that misfires during a client call is worse
than no feature, and a call is the one place you cannot iterate. Author against
the archive instead: 244 completed recordings, each with a full transcript and
speaker attribution. Replay a candidate view over last week's call and read what
it *would* have surfaced, at the timestamps it would have surfaced it. Tight
loop, no audience.

## The gallery

Generated views are mostly bad, which is fine if they are cheap and reviewable.
Every one is kept with the conversation it was born in. After the call they can
be replayed, rated, discarded or promoted to a named view.

That turns improvisation into curation: the ones that earn a name got there by
being right about a real meeting, and the rest cost a file.

## Constraints

- **`claude -p` is a `Process` spawn, so any view using it is brew-build only.**
  App Sandbox forbids spawning arbitrary executables, which is the same rule that
  rules out CLI Ollama. In-process views work in both editions; the
  whole-machine ones cannot. This is a better argument for a Deluxe edition than
  the summarizer difference — "the App Store one cannot see your knowledge base"
  is a reason to choose, where "it has a bigger model" is a spec line.
- **Precision over recall.** The manual trigger is the mechanism; auto-firing is
  the convenience. A view that surfaces unbidden mid-sentence spends trust that
  a missed trigger does not.
- **Prime once, feed on trigger.** A session fed every turn for forty-five
  minutes is a lot of tokens for something used twice. The meeting is
  identifiable at `startRecording` — the window titles are already logged there
  and routing resolves the case — so prime then, and send the transcript delta
  only when a trigger fires.

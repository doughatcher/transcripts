import Foundation

/// Native Classify stage — decides which folder a recording is filed into. Three
/// modes (see `RoutingConfig`): `off` files everything to the fallback; `automatic`
/// uses deterministic keyword rails then an on-device model with a confidence
/// threshold; `script` hands the decision to a user command. It never moves files —
/// the Persist stage does — it only sets `context.routing`.
public struct ClassifyStage: PipelineStage {
    public let id: StageID = .classify
    private let model: any ChatModel
    private let knowledgeRoot: URL
    private let routing: RoutingConfig
    private let destinations: [RoutingConfig.Destination]
    private let runner: CommandRunner?

    public init(
        model: any ChatModel,
        knowledgeRoot: URL,
        routing: RoutingConfig = .default,
        destinations: [RoutingConfig.Destination] = [],
        runner: CommandRunner? = nil
    ) {
        self.model = model
        self.knowledgeRoot = knowledgeRoot
        self.routing = routing
        self.destinations = destinations
        self.runner = runner
    }

    public init(config: AppConfig) {
        self.model = OllamaClient(config: config.ollama)
        self.knowledgeRoot = config.destinations.resolvedRoot
        self.routing = .default
        self.destinations = []
        self.runner = nil
    }

    public func run(_ context: inout PipelineContext) async throws {
        let sourceURL = context.transcriptURL ?? context.summaryURL
        guard let sourceURL else { return }
        let content = (try? String(contentsOf: sourceURL, encoding: .utf8)) ?? ""

        // A running session's destination is a statement of intent, not a guess,
        // so it settles the question before any inference runs. Classifying a
        // D&D session by keyword would be both wasteful and occasionally wrong.
        if let forced = context.forcedDestination, !forced.isEmpty {
            context.routing = decision(forced, confidence: 1, note: "session destination")
            return
        }

        switch routing.mode {
        case .off:
            context.routing = decision(routing.fallback, confidence: 1, note: "sorting off — fixed folder")
        case .script:
            context.routing = await runScript(context) ?? decision(routing.fallback, confidence: 0, note: "sort script gave no destination")
        case .automatic:
            context.routing = await automatic(
                title: context.recording.title ?? sourceURL.lastPathComponent,
                windowTitles: context.recording.windowTitles,
                content: content)
        }
    }

    // MARK: - Automatic (rails → model → fallback)

    private func automatic(title: String, windowTitles: [String], content: String) async -> RoutingDecision {
        // The meeting window title (e.g. "Contoso Rollout Standup | Microsoft Teams")
        // usually names the client, so a keyword hit there is authoritative.
        let windowText = windowTitles.joined(separator: " ").lowercased()
        let text = (title + "\n" + windowText + "\n" + content).lowercased()
        let candidates = destinations.filter { !$0.path.isEmpty }

        func matches(_ dest: RoutingConfig.Destination, in haystack: String) -> Set<String> {
            Set(dest.keywords.filter { kw in
                let k = kw.lowercased()
                return (k.contains(" ") || k.count >= 4) && haystack.contains(k)
            }.map { $0.lowercased() })
        }

        // Rails: keyword hits per destination, plus whether any hit is in the window title.
        let scored = candidates.map { dest -> (dest: RoutingConfig.Destination, hits: Set<String>, windowHit: Bool) in
            let hits = matches(dest, in: text)
            let windowHit = !windowText.isEmpty && !matches(dest, in: windowText).isEmpty
            return (dest, hits, windowHit)
        }.filter { !$0.hits.isEmpty }

        // A *strong* match: a window-title hit (authoritative), a multi-word phrase, a
        // single-word folder name, or 2+ tokens — not a lone generic token ("claude").
        func isStrong(_ s: (dest: RoutingConfig.Destination, hits: Set<String>, windowHit: Bool)) -> Bool {
            s.windowHit || s.hits.contains { $0.contains(" ") } || s.dest.keywords.count == 1 || s.hits.count >= 2
        }
        // Prefer window-title matches, then more keyword hits.
        let strong = scored.filter(isStrong).sorted {
            $0.windowHit != $1.windowHit ? ($0.windowHit && !$1.windowHit) : $0.hits.count > $1.hits.count
        }

        if let top = strong.first,
           strong.count == 1 || top.windowHit || top.hits.count > (strong.dropFirst().first?.hits.count ?? 0) {
            let via = top.windowHit ? "meeting title" : "rails"
            return decision(top.dest.path, confidence: min(0.98, (top.windowHit ? 0.85 : 0.7) + 0.1 * Double(top.hits.count)),
                            note: "\(via): matched \(top.hits.sorted().first ?? "keyword")")
        }

        // Multiple strong matches, or only weak/generic single-token hits → let the
        // model choose among the plausible destinations (or all if nothing hit).
        let poolDests = !strong.isEmpty ? strong.map { $0.dest }
                       : (!scored.isEmpty ? scored.map { $0.dest } : candidates)
        let pool = poolDests
        guard !pool.isEmpty else { return decision(routing.fallback, confidence: 0, note: "no destinations configured") }

        // Clamped to the on-device context budget: by classify time the document
        // leads with frontmatter + the generated summary, so the prefix carries
        // the routing signal even for very long meetings.
        let system = """
        You file a meeting transcript into ONE folder based on its CONTENT. Reply ONLY \
        with JSON: {"destination": string, "confidence": number, "note": string}. \
        destination MUST be exactly one of the allowed paths, or "" if none clearly fit.
        """
        let user = """
        ALLOWED destinations (path — keywords):
        \(pool.map { "  - \($0.path) — \($0.keywords.joined(separator: ", "))" }.joined(separator: "\n"))

        TRANSCRIPT:
        \(content.prefix(SummarizeStage.promptCharBudget))

        Return the JSON decision now.
        """

        do {
            let raw = try await model.chat(system: system, user: user, jsonFormat: true)
            let d = try JSONDecoder().decode(RoutingDecision.self, from: Data(raw.utf8))
            let valid = pool.contains { $0.path == d.destination }
            if valid, (d.confidence ?? 0) >= routing.confidenceThreshold {
                return d
            }
            return decision(routing.fallback, confidence: d.confidence ?? 0,
                            note: valid ? "below confidence threshold" : "no clear match")
        } catch {
            return decision(routing.fallback, confidence: 0, note: "model unavailable (\(error))")
        }
    }

    // MARK: - Script mode

    private func runScript(_ context: PipelineContext) async -> RoutingDecision? {
        guard let runner, var cmd = routing.script else { return nil }
        var vars = TemplateEngine.variables(for: context)
        vars["transcriptURL"] = context.transcriptURL?.path ?? ""
        vars["knowledgeRoot"] = knowledgeRoot.path
        vars["title"] = context.recording.title ?? ""
        cmd.arguments = cmd.arguments.map { TemplateEngine.substitute($0, with: vars) }

        let stdin = (try? JSONEncoder().encode(context)) ?? Data()
        guard let result = try? await runner.run(cmd, stdin: stdin), result.exitCode == 0 else {
            return nil
        }
        let out = String(decoding: result.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !out.isEmpty, out.lowercased() != "handled" else { return nil }

        // Accept a bare path or {"destination": "..."}.
        var dest = out
        if out.hasPrefix("{"), let obj = try? JSONDecoder().decode(RoutingDecision.self, from: Data(out.utf8)) {
            dest = obj.destination
        }
        guard isSafeRelativePath(dest) else { return nil }
        if !dest.hasSuffix("/") { dest += "/" }
        return decision(dest, confidence: 1, note: "sorted by script")
    }

    private func isSafeRelativePath(_ p: String) -> Bool {
        !p.isEmpty && !p.hasPrefix("/") && !p.contains("..")
    }

    private func decision(_ path: String, confidence: Double, note: String) -> RoutingDecision {
        RoutingDecision(destination: path, primaryCase: nil, confidence: confidence, note: note)
    }
}

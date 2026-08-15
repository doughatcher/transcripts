import SwiftUI
import AppKit
import TranscriptsEngine

/// A lightweight, dependency-free Markdown reader for a single recording document.
/// It splits YAML frontmatter into a header card (title / description / metadata)
/// and renders the body block-by-block: headings, bullets, and paragraphs (with
/// inline bold/italic via `AttributedString`'s Markdown parsing).
struct MarkdownViewerView: View {
    let url: URL
    /// Re-read the file every few seconds — used for the live (mid-call)
    /// transcript so viewers without Obsidian can watch turns land (#11).
    var autoRefresh: Bool = false

    @State private var frontmatter: [String: String] = [:]
    @State private var blocks: [MarkdownBlock] = []
    @State private var loadError: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                headerCard

                if let loadError {
                    Label(loadError, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }

                ForEach(blocks) { block in
                    block.view
                }
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 24)
            // Constrain measure for comfortable reading; center in wider windows.
            .frame(maxWidth: 720, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .textSelection(.enabled)
        .frame(minWidth: 520, minHeight: 420)
        // The "Open" action lives in the Recordings-window toolbar and uses the
        // configured "open with" app. Here we only offer Reveal in Finder — a second
        // open button that always went to the default Markdown app (Xcode) was
        // duplicative.
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                } label: {
                    Label("Reveal in Finder", systemImage: "folder")
                }
            }
        }
        .navigationTitle(frontmatter["title"] ?? url.deletingPathExtension().lastPathComponent)
        .task(id: url) { load() }
        .task(id: autoRefresh) {
            guard autoRefresh else { return }
            // Rewritten atomically by LiveTranscript a few seconds behind speech;
            // 3s polling is indistinguishable from live and costs nothing.
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3))
                load()
            }
        }
    }

    @ViewBuilder
    private var headerCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(frontmatter["title"] ?? url.deletingPathExtension().lastPathComponent)
                .font(.largeTitle.bold())
            if let desc = frontmatter["description"], !desc.isEmpty {
                Text(desc).font(.title3).foregroundStyle(.secondary)
            }
            HStack(spacing: 12) {
                if let app = frontmatter["active_app"] {
                    Label(app, systemImage: "app.badge")
                }
                if let when = frontmatter["recorded_at"] {
                    Label(Self.prettyDate(when), systemImage: "calendar")
                }
                if let dur = frontmatter["duration_seconds"], let secs = Int(dur) {
                    Label(Self.prettyDuration(secs), systemImage: "clock")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    // MARK: - Loading / parsing

    private func load() {
        do {
            let text = try String(contentsOf: url, encoding: .utf8)
            let (fm, body) = Self.split(text)
            frontmatter = fm
            blocks = MarkdownBlock.parse(body)
            loadError = nil
        } catch {
            loadError = "Could not open \(url.lastPathComponent): \(error.localizedDescription)"
        }
    }

    static func split(_ text: String) -> (fm: [String: String], body: String) {
        guard text.hasPrefix("---\n"),
              let end = text.range(of: "\n---\n", range: text.index(text.startIndex, offsetBy: 4)..<text.endIndex)
        else { return ([:], text) }
        let fmText = String(text[text.index(text.startIndex, offsetBy: 4)..<end.lowerBound])
        var map: [String: String] = [:]
        for line in fmText.components(separatedBy: "\n") {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
            let value = String(line[line.index(after: colon)...])
                .trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            if !key.isEmpty { map[key] = value }
        }
        return (map, String(text[end.upperBound...]))
    }

    static func prettyDate(_ iso: String) -> String {
        let f = ISO8601DateFormatter()
        guard let date = f.date(from: iso) else { return iso }
        let out = DateFormatter()
        out.dateStyle = .medium
        out.timeStyle = .short
        return out.string(from: date)
    }

    static func prettyDuration(_ seconds: Int) -> String {
        let m = seconds / 60, s = seconds % 60
        return m > 0 ? "\(m)m \(s)s" : "\(s)s"
    }
}

/// One rendered block of the document.
struct MarkdownBlock: Identifiable {
    let id = UUID()
    enum Kind { case h1, h2, h3, bullet, paragraph }
    let kind: Kind
    let text: String

    @ViewBuilder var view: some View {
        switch kind {
        case .h1: Text(text).font(.title.bold()).padding(.top, 8)
        case .h2: Text(text).font(.title2.bold()).padding(.top, 6)
        case .h3: Text(text).font(.title3.bold()).padding(.top, 2)
        case .bullet:
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("•").foregroundStyle(.secondary)
                Self.inline(text).lineSpacing(3)
            }
            .padding(.leading, 4)
        case .paragraph:
            Self.inline(text)
                .lineSpacing(5)
                .font(.body)
                .padding(.bottom, 2)
        }
    }

    /// Renders inline Markdown (bold/italic/links) safely, falling back to plain text.
    @ViewBuilder static func inline(_ s: String) -> some View {
        if let attributed = try? AttributedString(
            markdown: s,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        ) {
            Text(attributed).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        } else {
            Text(s).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        }
    }

    static func parse(_ body: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        for rawLine in body.components(separatedBy: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            if line.hasPrefix("### ") {
                blocks.append(.init(kind: .h3, text: String(line.dropFirst(4))))
            } else if line.hasPrefix("## ") {
                blocks.append(.init(kind: .h2, text: String(line.dropFirst(3))))
            } else if line.hasPrefix("# ") {
                blocks.append(.init(kind: .h1, text: String(line.dropFirst(2))))
            } else if line.hasPrefix("- ") || line.hasPrefix("* ") {
                blocks.append(.init(kind: .bullet, text: String(line.dropFirst(2))))
            } else {
                // Break run-on transcript lines into readable paragraphs at render
                // time, so historical transcripts (stored as one blob) read well too.
                let formatted = TranscriptFormatter.format(line)
                for para in formatted.components(separatedBy: "\n\n") where !para.isEmpty {
                    blocks.append(.init(kind: .paragraph, text: para))
                }
            }
        }
        return blocks
    }
}

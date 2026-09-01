import AppKit
import SwiftUI
import TranscriptsCore

/// What the overlay is currently showing. Separate from the panel so SwiftUI can
/// observe it without the panel having to rebuild its hosting controller.
@MainActor final class OverlayModel: ObservableObject {
    @Published var digest = OverlayDigest()
    /// What someone is part-way through saying. Shown in preference to the last
    /// finalized line, because the pill's job is to be current.
    @Published var partial = ""
    @Published var expanded = false

    var pillText: String {
        if !partial.isEmpty { return partial }
        return digest.lastSpoken
    }
}

/// The during-the-call overlay: a floating pill under the menu bar showing the
/// last thing worth knowing, which opens into a short stack on hover.
///
/// The window recipe is `DeadAirPanel`'s, and for the same reason — a call lives
/// in a full-screen Zoom or Teams window, and anything that steals focus from it
/// mid-sentence is worse than useless. `.nonactivatingPanel` plus
/// `becomesKeyOnlyIfNeeded` plus `fullScreenAuxiliary` is the combination that
/// floats over one without touching it. What differs here is the chrome:
/// borderless and transparent, so the material capsule inside is the whole of
/// what the user sees.
///
/// Sizes are fixed per state rather than fitted to content. A window that
/// resizes itself as the model streams cards in wanders around the screen while
/// someone is trying to read it; two known heights and a scroll view inside is
/// steadier and much simpler to keep pinned by its top edge.
@MainActor
final class OverlayPanel {
    static let width: CGFloat = 380
    static let collapsedHeight: CGFloat = 44
    static let expandedHeight: CGFloat = 300

    private var panel: NSPanel?
    private let model = OverlayModel()
    /// Top-left the panel is pinned to, so growing on hover extends downward
    /// instead of shifting the pill the cursor is sitting on.
    private var anchor: NSPoint = .zero
    /// Set while we reposition the panel ourselves, so the resulting move
    /// notification isn't mistaken for the user dragging it.
    private var repositioning = false

    /// Called when the user closes the overlay from its own control.
    var onClose: (() -> Void)?
    /// Called once the user finishes dragging, so the position can be persisted.
    var onMoved: ((CGPoint) -> Void)?
    /// Coalesces a drag's stream of move notifications into one save.
    private var moveSettleTimer: Timer?

    /// Shows the panel, restoring `origin` (its top-left) when there is one.
    func show(origin: CGPoint?) {
        guard panel == nil else { return }
        model.digest = OverlayDigest()
        model.expanded = false

        let host = NSHostingController(rootView: OverlayContent(
            model: model,
            onClose: { [weak self] in self?.onClose?() }))
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: Self.width, height: Self.collapsedHeight),
                        styleMask: [.nonactivatingPanel, .borderless],
                        backing: .buffered, defer: false)
        p.contentViewController = host
        p.isFloatingPanel = true
        p.level = .floating
        p.becomesKeyOnlyIfNeeded = true
        p.hidesOnDeactivate = false
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.isMovableByWindowBackground = true
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        // Excluded from the window list: it is chrome, not a document, and it
        // should never show up in a screen-share picker during the very call it
        // is floating over.
        p.isExcludedFromWindowsMenu = true

        // A remembered position is a request, not an instruction: it may name a
        // spot on a display that is no longer plugged in.
        anchor = Self.place(origin.map { NSPoint(x: $0.x, y: $0.y) } ?? Self.defaultAnchor())
        panel = p
        p.setFrameTopLeftPoint(anchor)
        p.orderFrontRegardless()

        NotificationCenter.default.addObserver(
            self, selector: #selector(panelMoved),
            name: NSWindow.didMoveNotification, object: p)
        // Hosting a SwiftUI view means the *content* owns the window's size —
        // `setFrame` here is overruled the moment SwiftUI lays out again. So the
        // height is declared in the view (see `OverlayContent`) and this only
        // re-pins the top edge, which is what keeps the pill still under the
        // cursor while the panel grows downward on hover.
        NotificationCenter.default.addObserver(
            self, selector: #selector(panelResized),
            name: NSWindow.didResizeNotification, object: p)
    }

    func update(_ digest: OverlayDigest) {
        model.digest = digest
        // A finalized line supersedes the guess that preceded it.
        model.partial = ""
    }

    /// The live edge — text still being revised, seconds ahead of the transcript.
    func showPartial(_ text: String) {
        model.partial = text
    }

    func hide() {
        moveSettleTimer?.invalidate()
        moveSettleTimer = nil
        if let panel {
            NotificationCenter.default.removeObserver(self, name: NSWindow.didMoveNotification, object: panel)
            NotificationCenter.default.removeObserver(self, name: NSWindow.didResizeNotification, object: panel)
            panel.orderOut(nil)
        }
        panel = nil
    }

    var isVisible: Bool { panel != nil }

    /// Where the panel currently sits, for persisting on the way out.
    ///
    /// Pulled at teardown rather than pushed on every move: `didMove` fires
    /// continuously while a window is dragged, and persisting from there would
    /// rewrite the config file on every frame of the drag.
    var currentOrigin: CGPoint? {
        panel == nil ? nil : CGPoint(x: anchor.x, y: anchor.y)
    }

    // MARK: - Geometry

    /// Centred under the menu bar — where a notch-adjacent HUD belongs, and
    /// clear of the meeting controls most apps put at the bottom of the screen.
    private static func defaultAnchor() -> NSPoint {
        guard let screen = NSScreen.main else { return NSPoint(x: 100, y: 100) }
        let frame = screen.visibleFrame
        return NSPoint(x: frame.midX - width / 2, y: frame.maxY - 8)
    }

    /// SwiftUI just changed the window's height; put its top edge back where the
    /// user left it so the panel grows downward instead of jumping.
    @objc private func panelResized() {
        guard !repositioning, let panel else { return }
        repositioning = true
        panel.setFrameTopLeftPoint(anchor)
        repositioning = false
    }

    @objc private func panelMoved() {
        guard !repositioning, let panel else { return }
        anchor = NSPoint(x: panel.frame.minX, y: panel.frame.maxY)
        // `didMove` fires on every frame of a drag. Persisting from here would
        // rewrite the config file dozens of times per second, so wait for the
        // drag to settle and save once.
        moveSettleTimer?.invalidate()
        moveSettleTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self, let panel = self.panel else { return }
                // Clamp on the way out: a panel shoved past an edge should come
                // back, and should not be *remembered* out there either.
                let placed = Self.place(NSPoint(x: panel.frame.minX, y: panel.frame.maxY))
                if placed != self.anchor {
                    self.anchor = placed
                    self.repositioning = true
                    panel.setFrameTopLeftPoint(placed)
                    self.repositioning = false
                }
                self.onMoved?(CGPoint(x: placed.x, y: placed.y))
            }
        }
    }

    /// Puts a wanted top-left somewhere that actually exists on this Mac.
    private static func place(_ wanted: NSPoint) -> NSPoint {
        let size = CGSize(width: width, height: collapsedHeight)
        let screens = NSScreen.screens.map(\.visibleFrame)
        guard let clamped = OverlayPlacement.clamp(topLeft: CGPoint(x: wanted.x, y: wanted.y),
                                                   size: size, screens: screens) else { return wanted }
        return NSPoint(x: clamped.x, y: clamped.y)
    }
}

// MARK: - The view

private struct OverlayContent: View {
    @ObservedObject var model: OverlayModel
    let onClose: () -> Void

    var body: some View {
        Group {
            if model.expanded { lanes } else { pill }
        }
        // Explicit, because the hosting controller sizes the window from this.
        // `maxHeight: .infinity` resolved to the content's ideal height, which
        // left the expanded panel drawn at pill height with its list clipped off.
        .frame(width: OverlayPanel.width,
               height: model.expanded ? OverlayPanel.expandedHeight : OverlayPanel.collapsedHeight,
               alignment: .top)
        .background(WindowDragHandle())
        .modifier(OverlaySurface(shape: shape, expanded: model.expanded))
        .onHover { model.expanded = $0 }
        .animation(.easeOut(duration: 0.14), value: model.expanded)
    }

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: model.expanded ? 18 : 22, style: .continuous)
    }

    /// Collapsed: the last thing said, verbatim. Not a summary and not a card —
    /// a line of the room, so a glance tells you the thing is alive and where
    /// the conversation is, with no model in the path to lag it.
    private var pill: some View {
        HStack(spacing: 9) {
            Image(systemName: "waveform")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.tint)
                .symbolEffect(.variableColor.iterative.dimInactiveLayers)
            Text(model.pillText.isEmpty ? "Listening" : model.pillText)
                .font(.system(size: 12))
                .foregroundStyle(model.pillText.isEmpty ? AnyShapeStyle(.secondary)
                                 : model.partial.isEmpty ? AnyShapeStyle(.primary)
                                 : AnyShapeStyle(.primary.opacity(0.75)))
                .lineLimit(1)
                .truncationMode(.head)   // the end of a sentence is the live edge
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .frame(height: OverlayPanel.collapsedHeight)
    }

    /// Expanded: the three things you actually reach for mid-call — where we
    /// landed, the figures, and what was just asked of you.
    private var lanes: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().opacity(0.4)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Lane(title: "Last conclusion", icon: "flag.checkered") {
                        if let c = model.digest.conclusion {
                            LaneText(c.headline)
                        } else {
                            LaneEmpty("Nothing settled yet")
                        }
                    }
                    Lane(title: "Facts & figures", icon: "number") {
                        if model.digest.facts.isEmpty {
                            LaneEmpty("No numbers or names yet")
                        } else {
                            VStack(alignment: .leading, spacing: 5) {
                                ForEach(model.digest.facts) { fact in
                                    HStack(alignment: .firstTextBaseline, spacing: 7) {
                                        Circle().frame(width: 3, height: 3).foregroundStyle(.tertiary)
                                        LaneText(fact.headline)
                                    }
                                }
                            }
                        }
                    }
                    Lane(title: "Last question", icon: "questionmark") {
                        if let q = model.digest.lastQuestion {
                            VStack(alignment: .leading, spacing: 4) {
                                LaneText(q.headline).fontWeight(.semibold)
                                if let answer = q.answer { LaneText(answer) }
                                Text(attribution(for: q))
                                    .font(.system(size: 10))
                                    .foregroundStyle(.secondary)
                            }
                        } else {
                            LaneEmpty("Nothing asked yet")
                        }
                    }
                }
                .padding(.horizontal, 15)
                .padding(.vertical, 13)
            }
            Spacer(minLength: 0)
        }
    }

    private var header: some View {
        HStack {
            Label("Overlay", systemImage: "waveform")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            Spacer()
            Button(action: onClose) {
                Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Hide the overlay for this call")
        }
        .padding(.horizontal, 15)
        .padding(.top, 11)
        .padding(.bottom, 7)
    }

    /// Every answer says where it came from. An unanswered question says that
    /// too — the overlay heard it and found nothing, which is information, and
    /// is very much not the same as the overlay having missed it.
    private func attribution(for card: OverlayCard) -> String {
        switch card.source {
        case .thisCall(let at): return "Said at \(MarkdownBlock.clock(at)) in this call"
        case .note(let title, _): return "From your notes — \(title)"
        case .unsourced: return "Not answered in this call or your notes"
        }
    }
}

/// Makes the panel draggable from anywhere on its surface.
///
/// `isMovableByWindowBackground` alone is not enough here: the window's content
/// is an `NSHostingView`, which takes the mouse-down that the background-drag
/// behaviour depends on, so the panel looks draggable and simply is not. Sitting
/// an `NSView` behind the SwiftUI content and calling `performDrag` from its
/// `mouseDown` puts the AppKit drag back — and because it is *behind* the
/// content, the close button and the scroll view still get their own events.
private struct WindowDragHandle: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { Handle() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    final class Handle: NSView {
        override func mouseDown(with event: NSEvent) {
            window?.performDrag(with: event)
        }
        /// Not `.crosshair` or `.closedHand` — the pointer should say "you can
        /// pick this up" without implying a drag is in progress.
        override func resetCursorRects() {
            addCursorRect(bounds, cursor: .openHand)
        }
    }
}

private struct Lane<Content: View>: View {
    let title: String
    let icon: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Label(title, systemImage: icon)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct LaneText: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text)
            .font(.system(size: 12))
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct LaneEmpty: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(.tertiary)
    }
}

/// Liquid Glass while it is a pill sitting over someone's call, and a plainer,
/// more opaque surface once it is opened and there is text to actually read.
///
/// Glass is right for the resting state — it is chrome floating over a meeting,
/// and it should read as part of the system rather than as a window someone left
/// open. It is the wrong call for three lanes of small type over arbitrary
/// video: legibility beats the effect the moment the thing is being read.
private struct OverlaySurface: ViewModifier {
    let shape: RoundedRectangle
    let expanded: Bool

    func body(content: Content) -> some View {
        if #available(macOS 26, *), !expanded {
            content
                .glassEffect(.regular.interactive(), in: shape)
        } else {
            content
                .background(.ultraThinMaterial, in: shape)
                .overlay(shape.strokeBorder(.primary.opacity(0.12), lineWidth: 1))
                .clipShape(shape)
        }
    }
}

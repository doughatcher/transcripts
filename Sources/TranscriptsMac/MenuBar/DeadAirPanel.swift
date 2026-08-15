import AppKit

/// A small floating alert panel for recording problems that need eyes *now* —
/// dead mic, minutes of dead air. Notification banners are unreliable here
/// (the user may not have granted notification permission, and banners vanish),
/// and an NSAlert would steal focus mid-call. This panel floats near the menu
/// bar, never takes key focus away from the meeting, and shows over full-screen
/// apps (where Teams/Zoom calls usually live).
@MainActor
final class DeadAirPanel {
    static let shared = DeadAirPanel()

    private var panel: NSPanel?
    private var dismissTask: Task<Void, Never>?
    private var primaryAction: (() -> Void)?
    private var secondaryAction: (() -> Void)?

    /// Shows (or replaces) the panel. `autoDismissAfter` nil = sticky.
    func show(title: String, body: String,
              primary: (title: String, action: () -> Void)? = nil,
              secondary: (title: String, action: () -> Void)? = nil,
              autoDismissAfter: TimeInterval? = nil) {
        dismiss()

        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .boldSystemFont(ofSize: 13)
        let bodyLabel = NSTextField(wrappingLabelWithString: body)
        bodyLabel.font = .systemFont(ofSize: 12)
        bodyLabel.preferredMaxLayoutWidth = 300

        let stack = NSStackView(views: [titleLabel, bodyLabel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6

        var buttons: [NSButton] = []
        if let secondary {
            secondaryAction = secondary.action
            let b = NSButton(title: secondary.title, target: self, action: #selector(runSecondary))
            b.bezelStyle = .rounded
            buttons.append(b)
        }
        if let primary {
            primaryAction = primary.action
            let b = NSButton(title: primary.title, target: self, action: #selector(runPrimary))
            b.bezelStyle = .rounded
            b.keyEquivalent = "\r"
            buttons.append(b)
        }
        if !buttons.isEmpty {
            let row = NSStackView(views: buttons)
            row.orientation = .horizontal
            row.spacing = 8
            stack.addArrangedSubview(row)
        }

        let content = NSView()
        content.addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 14),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -14),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            content.widthAnchor.constraint(lessThanOrEqualToConstant: 340),
        ])

        let p = NSPanel(contentRect: .zero,
                        styleMask: [.nonactivatingPanel, .titled, .closable, .utilityWindow],
                        backing: .buffered, defer: false)
        p.title = "Transcripts"
        p.contentView = content
        p.isFloatingPanel = true
        p.level = .floating
        p.becomesKeyOnlyIfNeeded = true
        p.hidesOnDeactivate = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.layoutIfNeeded()
        p.setContentSize(content.fittingSize)

        // Top-right of the active screen, tucked under the menu bar.
        if let screen = NSScreen.main {
            let f = screen.visibleFrame
            p.setFrameTopLeftPoint(NSPoint(x: f.maxX - p.frame.width - 16, y: f.maxY - 8))
        }
        p.orderFrontRegardless()
        panel = p

        if let autoDismissAfter {
            dismissTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(autoDismissAfter))
                guard !Task.isCancelled else { return }
                self?.dismiss()
            }
        }
    }

    func dismiss() {
        dismissTask?.cancel()
        dismissTask = nil
        panel?.orderOut(nil)
        panel = nil
        primaryAction = nil
        secondaryAction = nil
    }

    @objc private func runPrimary() {
        let action = primaryAction
        dismiss()
        action?()
    }

    @objc private func runSecondary() {
        let action = secondaryAction
        dismiss()
        action?()
    }
}

import AppKit
import SwiftUI
import TranscriptsCore

/// Owns the menu-bar item as a real `NSStatusItem` (not SwiftUI's `MenuBarExtra`).
///
/// This exists for one reason: **a live, level-reactive menu-bar icon.** SwiftUI's
/// `MenuBarExtra` snapshots its label and won't redraw on frequent `@Published`
/// updates, and forcing it with a `TimelineView` renders the label black and
/// unclickable. An `NSStatusItem` button image, by contrast, can be reassigned on a
/// timer — so while recording the acorn pulses dim-red → bright-red with the input
/// level, proving audio is actually flowing.
///
/// The dropdown is the existing `MenuBarView`, hosted in an `NSPopover`. Because
/// `openWindow`/`SettingsLink` don't work inside a popover, Recordings is an
/// AppKit-hosted `NSWindow` and Settings opens via the standard app selector; the
/// popover routes both through `AppController`.
@MainActor
final class StatusBarController: NSObject {
    private let controller: AppController
    private let statusItem: NSStatusItem
    private let popover = NSPopover()
    private var iconTimer: Timer?
    private var recordingsWindow: NSWindow?
    private var settingsWindow: NSWindow?

    init(controller: AppController) {
        self.controller = controller
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        if let button = statusItem.button {
            button.image = controller.menuBarImage
            button.imagePosition = .imageOnly
            button.target = self
            button.action = #selector(togglePopover(_:))
        }

        popover.behavior = .transient
        popover.animates = false
        popover.contentViewController = NSHostingController(
            rootView: MenuBarView().environmentObject(controller))

        controller.onOpenRecordings = { [weak self] id in self?.showRecordings(select: id) }
        controller.onOpenSettings = { [weak self] in self?.openSettings() }

        startIconTimer()
    }

    // MARK: - Live icon

    /// Redraws the menu-bar icon ~12×/sec. Reassigns the button image only when it
    /// actually changes (the renderer caches per state / per level-bucket and returns
    /// the same `NSImage`), so identity comparison keeps redraws minimal.
    private func startIconTimer() {
        let t = Timer(timeInterval: 0.08, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshIcon() }
        }
        RunLoop.main.add(t, forMode: .common)
        iconTimer = t
    }

    private func refreshIcon() {
        let image = controller.isRecording ? controller.recordingIcon() : controller.menuBarImage
        if statusItem.button?.image !== image { statusItem.button?.image = image }
    }

    // MARK: - Popover

    @objc private func togglePopover(_ sender: Any?) {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(sender)
        } else {
            NSApp.activate(ignoringOtherApps: true)
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    // MARK: - AppKit-hosted windows

    private func showRecordings(select id: UUID?) {
        controller.selectedRecordID = id
        popover.performClose(nil)
        if recordingsWindow == nil {
            let host = NSHostingController(rootView: LibraryView().environmentObject(controller))
            let win = NSWindow(contentViewController: host)
            win.title = "Recordings"
            win.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            win.setContentSize(NSSize(width: 940, height: 640))
            win.isReleasedWhenClosed = false
            win.center()
            recordingsWindow = win
        }
        NSApp.activate(ignoringOtherApps: true)
        recordingsWindow?.makeKeyAndOrderFront(nil)
    }

    // Host SettingsView in an AppKit window we fully control. The SwiftUI Settings
    // scene's `showSettingsWindow:` selector "succeeds" (a Settings scene exists) but
    // opens nothing visible from an accessory app — so we don't use it at all.
    private func openSettings() {
        popover.performClose(nil)
        if settingsWindow == nil {
            let host = NSHostingController(rootView: SettingsView().environmentObject(controller))
            let win = NSWindow(contentViewController: host)
            win.title = "Transcripts Settings"
            win.styleMask = [.titled, .closable]
            win.isReleasedWhenClosed = false
            win.center()
            settingsWindow = win
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
        settingsWindow?.orderFrontRegardless()
    }
}
